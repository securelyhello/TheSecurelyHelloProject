import 'dart:async';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'package:securelyhello/core/calls/call_service.dart';
import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/notifications/notification_actions.dart';
import 'package:securelyhello/core/notifications/notification_service.dart';
import 'package:securelyhello/core/notifications/push_service.dart';

/// A data-only push (1.1 devices, see server/src/push.js) while the app is in
/// the background or closed: fetch and decrypt what is waiting, show real
/// notifications (names and text only if the user allows them), and ring
/// for a call. The push itself carries nothing but "something is waiting".
///
/// A call offer is not answered here: it is stashed for the app, which
/// rings and answers when the user taps Answer (CallService.replayStashedOffer).
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  // The app is running (in the background): it fetches the queue itself.
  // Two copies working on the same database and sessions must not race.
  final running = IsolateNameServer.lookupPortByName(NotificationService.portName);
  if (running != null) {
    running.send(const {'k': 'wake'});
    return;
  }
  final options = PushService.optionsFromEnv();
  if (options != null && Firebase.apps.isEmpty) {
    try {
      await Firebase.initializeApp(options: options);
    } catch (_) {}
  }
  final notifications = NotificationService();
  await notifications.init(backgroundHandler: notificationBackgroundHandler);
  notifications.appInForeground = false;
  await withHeadlessChat((chat, directory) async {
    final names = <String, String>{};
    try {
      for (final c in await directory.getContacts()) {
        final u = (c['contact_user'] as Map?) ?? c;
        final id = '${u['user_id'] ?? c['contact_user_id']}';
        final name = '${u['display_name'] ?? ''}'.trim();
        names[id] = name.isEmpty ? '@${u['username'] ?? ''}' : name;
      }
    } catch (_) {}
    final subs = <StreamSubscription<dynamic>>[
      chat.onMessageReceived.listen((m) {
        final group = chat.groupOf(m.conversationId);
        unawaited(notifications.showMessage(
          contactId: m.conversationId,
          sender: names[m.senderId] ?? 'Someone',
          senderId: m.senderId,
          groupName: group?.name,
          senderPhoto: chat.profiles.photoOf(m.senderId),
          preview: ChatService.previewText(m.content, m.attachment),
          activeConversation: null,
          time: m.timestamp,
        ));
      }),
      chat.onCallSignal.listen((s) {
        if (s.data['t'] != 'offer') return;
        if (DateTime.now().difference(s.sentAt) > CallService.maxOfferAge) return;
        unawaited(CallService.stashOffer(s));
        unawaited(notifications.showIncomingCall(
          callId: '${s.data['id']}',
          name: names[s.from] ?? 'Securely Hello',
          video: s.data['video'] == true,
        ));
      }),
    ];
    try {
      await chat.drainRelayQueue();
      // Live pushes that arrive while we're here are handled too.
      await Future<void>.delayed(const Duration(seconds: 4));
    } finally {
      for (final sub in subs) {
        await sub.cancel();
      }
    }
  });
  debugPrint('Push handled in the background');
}
