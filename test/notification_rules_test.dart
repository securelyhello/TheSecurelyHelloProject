import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/notifications/notification_service.dart';

void main() {
  test('notify in the background, or for a chat that is not on screen', () {
    bool decide({bool enabled = true, bool fg = true, String? active, String conv = 'bob'}) =>
        NotificationService.shouldNotify(
            enabled: enabled, appInForeground: fg, activeConversation: active, conversation: conv);
    expect(decide(fg: false, active: 'bob'), isTrue, reason: 'app in background');
    expect(decide(active: 'carol'), isTrue, reason: 'another chat is open');
    expect(decide(active: null), isTrue, reason: 'chat list is open');
    expect(decide(active: 'bob'), isFalse, reason: 'already reading it');
    expect(decide(enabled: false, fg: false), isFalse, reason: 'turned off');
  });

  test('previews can be hidden; empty text (attachment-only) still says something', () {
    final shown = NotificationService.messageText(sender: 'Mira', preview: 'hi', showPreview: true);
    expect(shown.title, 'Mira');
    expect(shown.body, 'hi');
    final hidden = NotificationService.messageText(sender: 'Mira', preview: 'hi', showPreview: false);
    expect(hidden.title, 'Securely Hello');
    expect(hidden.body, 'New message');
    expect(hidden.body.contains('Mira'), isFalse);
    expect(NotificationService.messageText(sender: 'M', preview: '', showPreview: true).body, 'New message');
  });

  test('muted chats stay quiet', () {
    expect(
        NotificationService.shouldNotify(
            enabled: true, appInForeground: false, activeConversation: null, conversation: 'bob', muted: true),
        isFalse);
  });

  group('notification actions', () {
    NotificationResponse resp(String? action, {String? input, String? payload = 'chat1'}) => NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: action,
        input: input,
        payload: payload);

    test('Reply carries the typed text; empty replies are dropped', () {
      final a = NotificationAction.fromResponse(resp(NotificationService.replyAction, input: '  on my way  '))!;
      expect(a.kind, NotificationActionKind.reply);
      expect(a.chatId, 'chat1');
      expect(a.text, 'on my way');
      expect(NotificationAction.fromResponse(resp(NotificationService.replyAction, input: '   ')), isNull);
    });

    test('Mark as read; plain taps and unknown actions are not actions', () {
      expect(NotificationAction.fromResponse(resp(NotificationService.markReadAction))!.kind,
          NotificationActionKind.markRead);
      expect(NotificationAction.fromResponse(resp(null)), isNull);
      expect(NotificationAction.fromResponse(resp('dance')), isNull);
      expect(NotificationAction.fromResponse(resp(NotificationService.markReadAction, payload: '')), isNull);
    });

    test('they cross isolates as plain maps', () {
      const a = NotificationAction(NotificationActionKind.reply, 'chat1', 'hi');
      final back = NotificationAction.fromMessage(a.toMessage())!;
      expect([back.kind, back.chatId, back.text], [a.kind, a.chatId, a.text]);
      expect(NotificationAction.fromMessage({'k': 'nope', 'c': 'x'}), isNull);
      expect(NotificationAction.fromMessage('junk'), isNull);
    });
  });
}
