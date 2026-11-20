import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/config/app_config.dart';
import 'package:securelyhello/core/config/release_logging.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/networking/tls_pinning.dart';
import 'package:securelyhello/core/notifications/notification_service.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/storage/app_data_lock.dart';
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
  silenceDebugPrintInRelease();
  final action = NotificationAction.fromResponse(response);
  if (action == null) return;
  final port = IsolateNameServer.lookupPortByName(NotificationService.portName);
  if (port != null) {
    // The app holds it until unlocked if App Lock covers it.
    port.send(action.toMessage());
    return;
  }
  unawaited(_runHeadlessUnlessLocked(action));
}

/// Whether [action] may run with the app closed. With App Lock on, Reply
/// and Mark-as-read need the unlock (security review L3); the plugin has no
/// setAuthenticationRequired for notification actions.
bool headlessAllowed(NotificationAction action, {required bool appLockEnabled}) => switch (action.kind) {
      NotificationActionKind.reply || NotificationActionKind.markRead => !appLockEnabled,
      NotificationActionKind.acceptCall || NotificationActionKind.declineCall => true,
    };

/// Whether App Lock is on. Mirrors AppLockService.init (a PIN is set, or a
/// wipe is pending) without starting local_auth on this isolate.
Future<bool> appLockEnabled(SecureKeyStore store) async =>
    await store.readSetting('lock_hash') != null || await store.readSetting('wipe_pending') == '1';

Future<void> _runHeadlessUnlessLocked(NotificationAction action) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  bool locked;
  try {
    locked = await appLockEnabled(SecureKeyStore(namespace: AppConfig.profile));
  } catch (_) {
    locked = true; // can't tell: don't act without the unlock
  }
  if (!headlessAllowed(action, appLockEnabled: locked)) {
    final notifications = NotificationService();
    await notifications.init();
    await notifications.showUnlockToReply(action.chatId);
    return;
  }
  await runHeadless(action);
}

/// Signs in from the saved session and performs [action]. Returns whether
/// it was done.
Future<bool> runHeadless(NotificationAction action) => withHeadlessChat((chat, _) async {
      switch (action.kind) {
        case NotificationActionKind.reply:
          await chat.sendMessage(action.chatId, action.text);
          await chat.markConversationRead(action.chatId);
        case NotificationActionKind.markRead:
          await chat.markConversationRead(action.chatId);
        case NotificationActionKind.acceptCall:
        case NotificationActionKind.declineCall:
          // Answer opens the app; a ring from a closed app times out.
          break;
      }
      // Receipts are sent in a short batch; let it go before stopping.
      await Future<void>.delayed(const Duration(seconds: 2));
    });

/// Runs [body] with a signed-in [ChatService] on a background isolate (the
/// app's own keys, storage and session), then stops it. Returns false when
/// nobody is signed in or something failed.
///
/// Holds the data lock (see [AppDataLock]) for the whole run, and does
/// nothing if the app or another background run has it.
Future<bool> withHeadlessChat(Future<void> Function(ChatService chat, DirectoryService directory) body) async {
  silenceDebugPrintInRelease();
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final profile = AppConfig.profile;
  AppDataLock? lock;
  try {
    lock = await AppDataLock.acquire(await AppDataLock.pathFor(profile));
  } catch (e) {
    debugPrint('Data lock unavailable: $e');
  }
  if (lock == null) {
    debugPrint('The app or another background run is busy; skipped');
    return false;
  }
  try {
    return await _headless(profile, body);
  } finally {
    await lock.release();
  }
}

Future<bool> _headless(String profile, Future<void> Function(ChatService chat, DirectoryService directory) body) async {
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {}
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
    await body(chat, directory);
    return true;
  } catch (e) {
    debugPrint('Background work failed: $e');
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
