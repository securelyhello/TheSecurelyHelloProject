import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/shared/utils/chat_time_format.dart';

void main() {
  // Wednesday 12 Nov 2025, 15:30.
  final now = DateTime(2025, 11, 12, 15, 30);

  group('listTimestamp', () {
    test('today shows the time', () {
      expect(
        ChatTimeFormat.listTimestamp(DateTime(2025, 11, 12, 9, 5), now: now),
        '09:05',
      );
    });

    test('yesterday', () {
      expect(
        ChatTimeFormat.listTimestamp(DateTime(2025, 11, 11, 23, 59), now: now),
        'Yesterday',
      );
    });

    test('within a week shows the weekday', () {
      expect(
        ChatTimeFormat.listTimestamp(DateTime(2025, 11, 8, 10), now: now),
        'Saturday',
      );
    });

    test('older this year shows day and month', () {
      expect(
        ChatTimeFormat.listTimestamp(DateTime(2025, 3, 2), now: now),
        '2 Mar',
      );
    });

    test('previous years include the year', () {
      expect(
        ChatTimeFormat.listTimestamp(DateTime(2023, 3, 2), now: now),
        '2/3/23',
      );
    });
  });

  group('dateSeparator', () {
    test('today / yesterday / weekday / full date', () {
      expect(
        ChatTimeFormat.dateSeparator(DateTime(2025, 11, 12, 1), now: now),
        'Today',
      );
      expect(
        ChatTimeFormat.dateSeparator(DateTime(2025, 11, 11), now: now),
        'Yesterday',
      );
      expect(
        ChatTimeFormat.dateSeparator(DateTime(2025, 11, 9), now: now),
        'Sunday',
      );
      expect(
        ChatTimeFormat.dateSeparator(DateTime(2025, 1, 5), now: now),
        'Sunday, 5 January',
      );
      expect(
        ChatTimeFormat.dateSeparator(DateTime(2024, 1, 5), now: now),
        '5 January 2024',
      );
    });
  });

  group('lastSeen', () {
    test('unknown', () {
      expect(ChatTimeFormat.lastSeen(null, now: now), 'last seen recently');
    });

    test('minutes ago', () {
      expect(
        ChatTimeFormat.lastSeen(
          now.subtract(const Duration(minutes: 5)),
          now: now,
        ),
        'last seen 5 minutes ago',
      );
    });

    test('earlier today and yesterday', () {
      expect(
        ChatTimeFormat.lastSeen(DateTime(2025, 11, 12, 8, 15), now: now),
        'last seen today at 08:15',
      );
      expect(
        ChatTimeFormat.lastSeen(DateTime(2025, 11, 11, 22, 0), now: now),
        'last seen yesterday at 22:00',
      );
    });
  });

  test('daysAgo is calendar based, not 24h based', () {
    expect(
      ChatTimeFormat.daysAgo(
        DateTime(2025, 11, 11, 23, 59),
        now: DateTime(2025, 11, 12, 0, 1),
      ),
      1,
    );
  });

  test('relative times for stories', () {
    final now = DateTime(2026, 11, 20, 12);
    expect(ChatTimeFormat.relative(now.subtract(const Duration(seconds: 20)), now: now), 'Just now');
    expect(ChatTimeFormat.relative(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
    expect(ChatTimeFormat.relative(now.subtract(const Duration(hours: 3, minutes: 59)), now: now), '3 h ago');
    expect(ChatTimeFormat.relative(now.subtract(const Duration(days: 2)), now: now), '2 d ago');
  });
}
