import 'dart:convert';

/// Pure parts of notifications: who is muted, what a notification says and
/// the recent lines of each chat (for MessagingStyle). Kept free of plugins
/// so tests can cover them.

/// Mutes per chat: chat id → muted until (ms since epoch), or [forever].
class MuteRules {
  MuteRules([Map<String, int>? until]) : _until = {...?until};

  static const forever = -1;
  final Map<String, int> _until;

  bool isMuted(String chatId, DateTime now) {
    final u = _until[chatId];
    if (u == null) return false;
    return u == forever || u > now.millisecondsSinceEpoch;
  }

  /// Mutes [chatId] for [duration] (null: until unmuted).
  void mute(String chatId, Duration? duration, DateTime now) =>
      _until[chatId] = duration == null ? forever : now.add(duration).millisecondsSinceEpoch;

  void unmute(String chatId) => _until.remove(chatId);

  /// When the mute ends, null if not muted (or [DateTime] far away for forever).
  DateTime? mutedUntil(String chatId, DateTime now) {
    if (!isMuted(chatId, now)) return null;
    final u = _until[chatId]!;
    return u == forever ? DateTime(9999) : DateTime.fromMillisecondsSinceEpoch(u);
  }

  /// Drops expired entries.
  void prune(DateTime now) => _until.removeWhere((_, u) => u != forever && u <= now.millisecondsSinceEpoch);

  String encode() => jsonEncode(_until);

  static MuteRules decode(String? raw) {
    if (raw == null) return MuteRules();
    try {
      final m = jsonDecode(raw);
      if (m is Map) return MuteRules({for (final e in m.entries) if (e.value is int) '${e.key}': e.value as int});
    } on FormatException {
      // Start over.
    }
    return MuteRules();
  }
}

/// One line in a chat's notification.
class NotificationLine {
  const NotificationLine({required this.sender, required this.senderId, required this.text, required this.time});
  final String sender;
  final String senderId;
  final String text;
  final DateTime time;
}

/// The recent lines and unread count of each chat with notifications up.
class NotificationInbox {
  static const maxLines = 6;
  final Map<String, List<NotificationLine>> _lines = {};

  /// Adds a line; returns the chat's recent lines (oldest first).
  List<NotificationLine> add(String chatId, NotificationLine line) {
    final list = _lines.putIfAbsent(chatId, () => []);
    list.add(line);
    if (list.length > maxLines) list.removeRange(0, list.length - maxLines);
    _counts[chatId] = (_counts[chatId] ?? 0) + 1;
    return List.unmodifiable(list);
  }

  final Map<String, int> _counts = {};

  /// Unread messages in [chatId] since its notification was cleared.
  int countFor(String chatId) => _counts[chatId] ?? 0;

  /// All unread messages with notifications up (the badge).
  int get total => _counts.values.fold(0, (a, b) => a + b);

  /// Chats with notifications up.
  int get chats => _counts.length;

  void clear(String chatId) {
    _lines.remove(chatId);
    _counts.remove(chatId);
  }

  void clearAll() {
    _lines.clear();
    _counts.clear();
  }
}

/// What a message notification says.
///
/// With [showPreview] off (the default), nothing about the chat is shown:
/// "Securely Hello" / "New message".
({String title, String body}) messageNotificationText({
  required String sender,
  required String preview,
  required bool showPreview,
  String? group,
}) {
  if (!showPreview) return (title: 'Securely Hello', body: 'New message');
  final body = preview.isEmpty ? 'New message' : preview;
  return group == null ? (title: sender, body: body) : (title: group, body: '$sender: $body');
}

/// Notification ids: one per chat, plus fixed ones.
class NotificationIds {
  static const summary = 1;
  static const request = 2;
  static const update = 3;
  static int chat(String chatId) => (chatId.hashCode & 0x3fffffff) + 1000;
}
