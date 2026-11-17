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
}
