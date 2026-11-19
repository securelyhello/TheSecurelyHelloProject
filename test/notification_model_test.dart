import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/notifications/notification_model.dart';

void main() {
  final now = DateTime(2026, 11, 20, 10);

  group('mutes', () {
    test('for a while, forever, and unmute', () {
      final m = MuteRules();
      expect(m.isMuted('a', now), isFalse);
      m.mute('a', const Duration(hours: 8), now);
      expect(m.isMuted('a', now.add(const Duration(hours: 7))), isTrue);
      expect(m.isMuted('a', now.add(const Duration(hours: 8))), isFalse, reason: 'ends on time');
      m.mute('b', null, now);
      expect(m.isMuted('b', now.add(const Duration(days: 3650))), isTrue);
      m.unmute('b');
      expect(m.isMuted('b', now), isFalse);
    });

    test('survive a restart; expired ones are pruned; junk is ignored', () {
      final m = MuteRules()
        ..mute('a', const Duration(hours: 1), now)
        ..mute('b', null, now)
        ..mute('c', const Duration(minutes: 1), now);
      final back = MuteRules.decode(m.encode())..prune(now.add(const Duration(minutes: 5)));
      expect(back.isMuted('a', now), isTrue);
      expect(back.isMuted('b', now), isTrue);
      expect(back.mutedUntil('c', now), isNull);
      expect(MuteRules.decode('not json').isMuted('a', now), isFalse);
      expect(MuteRules.decode('{"a":"x"}').isMuted('a', now), isFalse);
      expect(MuteRules.decode(null).isMuted('a', now), isFalse);
    });
  });

  group('what notifications say', () {
    test('hidden by default: no name, no text', () {
      final t = messageNotificationText(sender: 'Mira', preview: 'meet at 6', showPreview: false, group: 'Trip');
      expect(t.title, 'Securely Hello');
      expect(t.body, 'New message');
    });

    test('shown: sender and text; in a group, the group and who wrote', () {
      expect(messageNotificationText(sender: 'Mira', preview: 'hi', showPreview: true).title, 'Mira');
      final g = messageNotificationText(sender: 'Mira', preview: 'hi', showPreview: true, group: 'Trip');
      expect(g.title, 'Trip');
      expect(g.body, 'Mira: hi');
      expect(messageNotificationText(sender: 'Mira', preview: '', showPreview: true).body, 'New message');
    });
  });

  group('inbox', () {
    NotificationLine line(String t) => NotificationLine(sender: 'M', senderId: 'm', text: t, time: now);

    test('keeps the last few lines per chat and counts unread', () {
      final inbox = NotificationInbox();
      for (var i = 0; i < 9; i++) {
        inbox.add('a', line('$i'));
      }
      final lines = inbox.add('a', line('last'));
      expect(lines.length, NotificationInbox.maxLines);
      expect(lines.last.text, 'last');
      inbox.add('b', line('x'));
      expect(inbox.countFor('a'), 10);
      expect(inbox.total, 11);
      expect(inbox.chats, 2);
      inbox.clear('a');
      expect(inbox.total, 1);
      expect(inbox.countFor('a'), 0);
    });
  });

  test('chat notification ids are stable and clear of the fixed ones', () {
    expect(NotificationIds.chat('abc'), NotificationIds.chat('abc'));
    expect(NotificationIds.chat('abc'), greaterThanOrEqualTo(1000));
  });
}
