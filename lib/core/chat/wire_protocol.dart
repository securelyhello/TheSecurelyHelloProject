import 'dart:convert';
import 'dart:typed_data';

// =============================================================================
// Wire protocol v3
// =============================================================================
//
// Everything that leaves the device, over a WebRTC data channel or through
// the server's relay queue, is a [WireEnvelope] addressed to ONE device:
//
// ```json
// { "v": 3, "id": "<uuid>", "s": "<sender user>", "sd": "<sender device>",
//   "rd": "<recipient device>", "t": <unix ms>,
//   "h": "<ratchet header JSON>", "c": "<base64 ciphertext>" }
// ```
//
// `h` and `c` come from the Double Ratchet session between the two devices
// (see `ratchet.dart`). `c` decrypts to a [WirePayload] (JSON), which
// repeats the sender and recipient user ids inside the authenticated part.
// A message to a contact is sealed once per device of theirs, plus a `sync`
// copy for each of our own other devices.

const int kWireVersion = 3;

enum PayloadKind {
  /// A chat message (text and/or one attachment).
  message('msg'),

  /// Delivery / read acknowledgement for one or more message ids.
  receipt('receipt'),

  /// Typing indicator. Only ever sent over a live P2P channel.
  typing('typing'),

  /// To our own other devices: a message we sent, or messages we read.
  sync('sync'),

  /// A reaction to one message (empty emoji removes it).
  react('react'),

  /// New text for one of the sender's own messages.
  edit('edit'),

  /// The sender deleted one of their messages for everyone.
  delete('del');

  const PayloadKind(this.wire);
  final String wire;

  static PayloadKind fromWire(String value) =>
      PayloadKind.values.firstWhere((k) => k.wire == value,
          orElse: () => throw FormatException('Unknown payload kind $value'));
}

/// Receipt levels, ordered so a higher index always wins.
enum ReceiptStatus {
  delivered,
  read;

  static ReceiptStatus fromWire(String value) =>
      ReceiptStatus.values.firstWhere((s) => s.name == value,
          orElse: () => throw FormatException('Unknown receipt $value'));
}

/// Outer envelope: routing only; the server sees nothing else.
class WireEnvelope {
  final String id;
  final String senderId;
  final String senderDevice;
  final String recipientDevice;
  final int timestampMs;

  /// Ratchet header, exactly as authenticated.
  final String header;
  final String ciphertextBase64;

  const WireEnvelope({
    required this.id,
    required this.senderId,
    required this.senderDevice,
    required this.recipientDevice,
    required this.timestampMs,
    required this.header,
    required this.ciphertextBase64,
  });

  String get senderAddress => '$senderId:$senderDevice';

  Map<String, dynamic> toJson() => {
        'v': kWireVersion,
        'id': id,
        's': senderId,
        'sd': senderDevice,
        'rd': recipientDevice,
        't': timestampMs,
        'h': header,
        'c': ciphertextBase64,
      };

  String encodeJson() => jsonEncode(toJson());

  Uint8List encode() => Uint8List.fromList(utf8.encode(encodeJson()));

  static WireEnvelope fromJson(Map<String, dynamic> json) {
    if (json['v'] != kWireVersion) {
      throw FormatException('Unsupported envelope version ${json['v']}');
    }
    return WireEnvelope(
      id: json['id'] as String,
      senderId: json['s'] as String,
      senderDevice: json['sd'] as String,
      recipientDevice: json['rd'] as String,
      timestampMs: json['t'] as int,
      header: json['h'] as String,
      ciphertextBase64: json['c'] as String,
    );
  }

  static WireEnvelope decodeJson(String source) =>
      fromJson(jsonDecode(source) as Map<String, dynamic>);

  static WireEnvelope fromBytes(Uint8List bytes) =>
      decodeJson(utf8.decode(bytes));
}

/// Inner payload (encrypted).
class WirePayload {
  final PayloadKind kind;

  /// Message id for [PayloadKind.message] and sent-message syncs.
  final String? messageId;
  final String from;
  final String to;
  final int timestampMs;

  /// Text for [PayloadKind.message] (may be empty with an attachment).
  final String? body;

  /// Attachment metadata (id, key, digest, name, mime, size …), if any.
  final Map<String, dynamic>? attachment;

  /// Acknowledged message ids for [PayloadKind.receipt].
  final List<String> receiptIds;
  final ReceiptStatus? receiptStatus;

  /// For [PayloadKind.typing].
  final bool isTyping;

  /// [PayloadKind.sync]: the contact the synced messages belong to.
  final String? conversation;

  /// [PayloadKind.sync]: incoming message ids we read on another device.
  final List<String> readIds;

  /// A message this one replies to: `{id, from, preview}`.
  final Map<String, dynamic>? reply;

  /// [react] / [edit] / [delete]: the message acted on.
  final String? target;

  /// [react]: the emoji, or '' to remove.
  final String? emoji;

  const WirePayload._({
    required this.kind,
    required this.from,
    required this.to,
    required this.timestampMs,
    this.messageId,
    this.body,
    this.attachment,
    this.receiptIds = const [],
    this.receiptStatus,
    this.isTyping = false,
    this.conversation,
    this.readIds = const [],
    this.reply,
    this.target,
    this.emoji,
  });

  factory WirePayload.message({
    required String messageId,
    required String from,
    required String to,
    required int timestampMs,
    required String body,
    Map<String, dynamic>? attachment,
    Map<String, dynamic>? reply,
  }) =>
      WirePayload._(
        kind: PayloadKind.message,
        messageId: messageId,
        from: from,
        to: to,
        timestampMs: timestampMs,
        body: body,
        attachment: attachment,
        reply: reply,
      );

  /// A reaction, edit or deletion of message [target]. Sent to the contact
  /// (`to` = contact, no [conversation]) and to our own other devices
  /// (`to` = us, [conversation] = the contact).
  factory WirePayload.action({
    required PayloadKind kind,
    required String from,
    required String to,
    required int timestampMs,
    required String target,
    String? conversation,
    String? emoji,
    String? body,
  }) =>
      WirePayload._(
        kind: kind,
        from: from,
        to: to,
        timestampMs: timestampMs,
        target: target,
        conversation: conversation,
        emoji: emoji,
        body: body,
      );

  factory WirePayload.receipt({
    required String from,
    required String to,
    required int timestampMs,
    required List<String> ids,
    required ReceiptStatus status,
  }) =>
      WirePayload._(
        kind: PayloadKind.receipt,
        from: from,
        to: to,
        timestampMs: timestampMs,
        receiptIds: ids,
        receiptStatus: status,
      );

  factory WirePayload.typing({
    required String from,
    required String to,
    required int timestampMs,
    required bool isTyping,
  }) =>
      WirePayload._(
        kind: PayloadKind.typing,
        from: from,
        to: to,
        timestampMs: timestampMs,
        isTyping: isTyping,
      );

  /// Copy of a message we sent to [conversation], for our other devices.
  factory WirePayload.sentSync({
    required String me,
    required String conversation,
    required String messageId,
    required int timestampMs,
    required String body,
    Map<String, dynamic>? attachment,
    Map<String, dynamic>? reply,
  }) =>
      WirePayload._(
        kind: PayloadKind.sync,
        from: me,
        to: me,
        conversation: conversation,
        messageId: messageId,
        timestampMs: timestampMs,
        body: body,
        attachment: attachment,
        reply: reply,
      );

  /// We read [ids] from [conversation] on this device.
  factory WirePayload.readSync({
    required String me,
    required String conversation,
    required List<String> ids,
    required int timestampMs,
  }) =>
      WirePayload._(
        kind: PayloadKind.sync,
        from: me,
        to: me,
        conversation: conversation,
        readIds: ids,
        timestampMs: timestampMs,
      );

  Map<String, dynamic> toJson() => {
        'k': kind.wire,
        'from': from,
        'to': to,
        't': timestampMs,
        if (messageId != null) 'id': messageId,
        if (body != null) 'body': body,
        if (attachment != null) 'att': attachment,
        if (kind == PayloadKind.receipt) 'ids': receiptIds,
        if (receiptStatus != null) 'st': receiptStatus!.name,
        if (kind == PayloadKind.typing) 'on': isTyping,
        if (conversation != null) 'conv': conversation,
        if (readIds.isNotEmpty) 'read': readIds,
        if (reply != null) 'reply': reply,
        if (target != null) 'target': target,
        if (emoji != null) 'emoji': emoji,
      };

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static WirePayload decode(Uint8List bytes) =>
      fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);

  static WirePayload fromJson(Map<String, dynamic> json) {
    final kind = PayloadKind.fromWire(json['k'] as String);
    final att = json['att'];
    final reply = json['reply'];
    final payload = WirePayload._(
      kind: kind,
      from: json['from'] as String,
      to: json['to'] as String,
      timestampMs: json['t'] as int,
      messageId: json['id'] as String?,
      body: json['body'] as String?,
      attachment: att is Map ? Map<String, dynamic>.from(att) : null,
      receiptIds: (json['ids'] as List<dynamic>?)?.cast<String>() ?? const [],
      receiptStatus: json['st'] != null
          ? ReceiptStatus.fromWire(json['st'] as String)
          : null,
      isTyping: json['on'] as bool? ?? false,
      conversation: json['conv'] as String?,
      readIds: (json['read'] as List<dynamic>?)?.cast<String>() ?? const [],
      reply: reply is Map ? Map<String, dynamic>.from(reply) : null,
      target: json['target'] as String?,
      emoji: json['emoji'] as String?,
    );
    switch (kind) {
      case PayloadKind.message:
        if (payload.messageId == null || payload.body == null) {
          throw const FormatException('Malformed message payload');
        }
        break;
      case PayloadKind.receipt:
        if (payload.receiptStatus == null) {
          throw const FormatException('Malformed receipt');
        }
        break;
      case PayloadKind.sync:
        if (payload.conversation == null ||
            (payload.messageId == null && payload.readIds.isEmpty)) {
          throw const FormatException('Malformed sync payload');
        }
        break;
      case PayloadKind.react:
        if (payload.target == null || payload.emoji == null || payload.emoji!.length > 16) {
          throw const FormatException('Malformed reaction');
        }
        break;
      case PayloadKind.edit:
        if (payload.target == null || payload.body == null) {
          throw const FormatException('Malformed edit');
        }
        break;
      case PayloadKind.delete:
        if (payload.target == null) throw const FormatException('Malformed delete');
        break;
      case PayloadKind.typing:
        break;
    }
    return payload;
  }
}
