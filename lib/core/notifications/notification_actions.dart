import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/config/app_config.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/networking/tls_pinning.dart';
import 'package:securelyhello/core/notifications/notification_service.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';

/// Reply and Mark-as-read from a notification, without opening the app.
///
/// Android runs this on a background isolate. If the app is running, the
/// action goes to it (its open database and sessions do the work). If not,
/// a minimal app starts here: the same keys and storage, signed in from the
/// saved session, sends the encrypted reply (or the read receipts) and
/// stops again.
@pragma('vm:entry-point')
void notificationBackgroundHandler(NotificationResponse response) {
  final action = NotificationAction.fromResponse(response);
  if (action == null) return;
  final port = IsolateNameServer.lookupPortByName(NotificationService.portName);
  if (port != null) {
    port.send(action.toMessage());
    return;
  }
  unawaited(runHeadless(action));
}

/// Signs in from the saved session and performs [action]. Returns whether
/// it was done.
Future<bool> runHeadless(NotificationAction action) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {}
  final profile = AppConfig.profile;
  final storage = LocalStorage(profile: profile);
  final keyStore = SecureKeyStore(namespace: profile);
  final directory = DirectoryService(
    baseUrl: AppConfig.apiBaseUrl,
    tokenStore: keyStore,
    pinning: TlsPinning.parse(AppConfig.certPins),
  );
  final p2p = P2PConnectionManager();
  final chat = ChatService(storage: storage, directory: directory, p2p: p2p);
  final auth = AuthProvider(directoryService: directory, localStorage: storage, keyStore: keyStore);
  try {
    await auth.init();
    if (!auth.isAuthenticated || auth.identity == null) return false;
    await chat.start(identity: auth.identity!, myUserId: auth.myUserId!, deviceId: auth.deviceId!);
    switch (action.kind) {
      case NotificationActionKind.reply:
        await chat.sendMessage(action.chatId, action.text);
        await chat.markConversationRead(action.chatId);
      case NotificationActionKind.markRead:
        await chat.markConversationRead(action.chatId);
    }
    // Receipts are sent in a short batch; let it go before stopping.
    await Future<void>.delayed(const Duration(seconds: 2));
    return true;
  } catch (e) {
    debugPrint('Notification action in the background failed: $e');
    return false;
  } finally {
    try {
      await chat.stop();
      await storage.close();
      await p2p.dispose();
      await directory.dispose();
    } catch (_) {}
  }
}
