import 'package:intl/intl.dart';

/// Timestamp formatting following common chat-app conventions.
///
/// Every function takes an optional [now] so it can be tested.
abstract final class ChatTimeFormat {
  static DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

  /// Whole calendar days between [t] and [now] (0 = today, 1 = yesterday).
  static int daysAgo(DateTime t, {DateTime? now}) {
    final n = now ?? DateTime.now();
    // Use UTC dates so DST changes don't produce fractional days.
    final a = DateTime.utc(t.year, t.month, t.day);
    final b = DateTime.utc(n.year, n.month, n.day);
    return b.difference(a).inDays;
  }

  static bool isSameDay(DateTime a, DateTime b) => _day(a) == _day(b);

  /// Clock time, e.g. `14:05` or `2:05 PM` depending on [use24h].
  static String time(DateTime t, {bool use24h = true}) =>
      (use24h ? DateFormat.Hm() : DateFormat.jm()).format(t);

  /// Chat list timestamp: time today, "Yesterday", weekday within the last
  /// week, otherwise a short date (with year if not this year).
  static String listTimestamp(DateTime t, {DateTime? now, bool use24h = true}) {
    final n = now ?? DateTime.now();
    final d = daysAgo(t, now: n);
    if (d <= 0) return time(t, use24h: use24h);
    if (d == 1) return 'Yesterday';
    if (d < 7) return DateFormat.EEEE().format(t);
    if (t.year == n.year) return DateFormat('d MMM').format(t);
    return DateFormat('d/M/yy').format(t);
  }

  /// Date separator inside a conversation: "Today", "Yesterday", weekday
  /// within the last week, otherwise a full date.
  static String dateSeparator(DateTime t, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final d = daysAgo(t, now: n);
    if (d <= 0) return 'Today';
    if (d == 1) return 'Yesterday';
    if (d < 7) return DateFormat.EEEE().format(t);
    if (t.year == n.year) return DateFormat('EEEE, d MMMM').format(t);
    return DateFormat('d MMMM y').format(t);
  }

  /// "last seen …" text for a contact's presence.
  static String lastSeen(DateTime? t, {DateTime? now, bool use24h = true}) {
    if (t == null) return 'last seen recently';
    final n = now ?? DateTime.now();
    final diff = n.difference(t);
    if (diff.inMinutes < 1) return 'last seen just now';
    if (diff.inMinutes < 60 && diff.inMinutes >= 1 && daysAgo(t, now: n) == 0) {
      final m = diff.inMinutes;
      return 'last seen $m ${m == 1 ? 'minute' : 'minutes'} ago';
    }
    final d = daysAgo(t, now: n);
    final clock = time(t, use24h: use24h);
    if (d <= 0) return 'last seen today at $clock';
    if (d == 1) return 'last seen yesterday at $clock';
    if (d < 7) return 'last seen ${DateFormat.EEEE().format(t)} at $clock';
    if (t.year == n.year) return 'last seen ${DateFormat('d MMM').format(t)}';
    return 'last seen ${DateFormat('d MMM y').format(t)}';
  }

  /// Full date and time for the message-info sheet.
  static String full(DateTime t, {bool use24h = true}) =>
      '${DateFormat('EEE d MMM y').format(t)}, ${time(t, use24h: use24h)}';
}
