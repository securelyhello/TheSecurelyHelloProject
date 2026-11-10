import 'dart:convert';
import 'dart:typed_data';

import 'package:securelyhello/core/crypto/crypto_core.dart';

// =============================================================================
// Wire protocol
// =============================================================================
//
// Everything that leaves the device — over a WebRTC data channel or through
// the Supabase relay queue — is a [WireEnvelope]:
//
// ```json
// { "v": 2, "id": "<uuid>", "s": "<sender user_id>", "t": <unix_ms>,
//   "c": "<base64 NaCl box>" }
// ```
//
// For v2 the box contains `Ed25519 signature ‖ payload JSON`, where the
// payload is a [WirePayload].  The payload repeats the sender and recipient
// ids *inside* the signed, encrypted part so a relayed blob cannot be
// re-attributed to another user.
//
// v1 envelopes (no "v" field) carried the raw UTF-8 text in the box.  They are
// still accepted on receive so older builds can talk to this one.

const int kWireVersion = 2;

/// The kind of data carried by a [WirePayload].
enum PayloadKind {
  /// A chat text message.
  message('msg'),

  /// Delivery / read acknowledgement for one or more message ids.
  receipt('receipt'),

  /// Typing indicator.  Only ever sent over a live P2P channel.
  typing('typing');

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

/// Outer, unencrypted envelope.
class WireEnvelope {
  final int version;
  final String id;
  final String senderId;
  final int timestampMs;
  final String ciphertextBase64;

  const WireEnvelope({
    this.version = kWireVersion,
    required this.id,
    required this.senderId,
    required this.timestampMs,
    required this.ciphertextBase64,
  });

  Map<String, dynamic> toJson() => {
        'v': version,
        'id': id,
        's': senderId,
        't': timestampMs,
        'c': ciphertextBase64,
      };

  String encodeJson() => jsonEncode(toJson());

  Uint8List encode() => Uint8List.fromList(utf8.encode(encodeJson()));

  static WireEnvelope fromJson(Map<String, dynamic> json) => WireEnvelope(
        version: (json['v'] as int?) ?? 1,
        id: json['id'] as String,
        senderId: json['s'] as String,
        timestampMs: json['t'] as int,
        ciphertextBase64: json['c'] as String,
      );

  static WireEnvelope decodeJson(String source) =>
      fromJson(jsonDecode(source) as Map<String, dynamic>);

  static WireEnvelope fromBytes(Uint8List bytes) =>
      decodeJson(utf8.decode(bytes));
}

/// Inner, signed + encrypted payload.
class WirePayload {
  final PayloadKind kind;

  /// Message id for [PayloadKind.message]; unused otherwise.
  final String? messageId;
  final String from;
  final String to;
  final int timestampMs;

  /// Text body for [PayloadKind.message].
  final String? body;

  /// Acknowledged message ids for [PayloadKind.receipt].
  final List<String> receiptIds;
  final ReceiptStatus? receiptStatus;

  /// For [PayloadKind.typing].
  final bool isTyping;

  const WirePayload._({
    required this.kind,
    required this.from,
    required this.to,
    required this.timestampMs,
    this.messageId,
    this.body,
    this.receiptIds = const [],
    this.receiptStatus,
    this.isTyping = false,
  });

  factory WirePayload.message({
    required String messageId,
    required String from,
    required String to,
    required int timestampMs,
    required String body,
  }) =>
      WirePayload._(
        kind: PayloadKind.message,
        messageId: messageId,
        from: from,
        to: to,
        timestampMs: timestampMs,
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

  Map<String, dynamic> toJson() => {
        'k': kind.wire,
        'from': from,
        'to': to,
        't': timestampMs,
        if (messageId != null) 'id': messageId,
        if (body != null) 'body': body,
        if (kind == PayloadKind.receipt) 'ids': receiptIds,
        if (receiptStatus != null) 'st': receiptStatus!.name,
        if (kind == PayloadKind.typing) 'on': isTyping,
      };

  static WirePayload fromJson(Map<String, dynamic> json) {
    final kind = PayloadKind.fromWire(json['k'] as String);
    return WirePayload._(
      kind: kind,
      from: json['from'] as String,
      to: json['to'] as String,
      timestampMs: json['t'] as int,
      messageId: json['id'] as String?,
      body: json['body'] as String?,
      receiptIds: (json['ids'] as List<dynamic>?)?.cast<String>() ?? const [],
      receiptStatus: json['st'] != null
          ? ReceiptStatus.fromWire(json['st'] as String)
          : null,
      isTyping: json['on'] as bool? ?? false,
    );
  }
}

/// Public keys of the remote party, Base64-encoded as stored in Supabase.
class PeerKeys {
  final String signingKey;
  final String encryptionKey;
  const PeerKeys({required this.signingKey, required this.encryptionKey});

  bool get isComplete => signingKey.isNotEmpty && encryptionKey.isNotEmpty;
}

/// Seals and opens [WirePayload]s.
class WireCodec {
  WireCodec._();

  /// Signs [payload] with our Ed25519 key, encrypts it to the recipient's
  /// X25519 key, and wraps it in an envelope.
  static WireEnvelope seal({
    required String envelopeId,
    required WirePayload payload,
    required CryptoIdentity identity,
    required String recipientEncryptionKey,
  }) {
    final payloadBytes =
        Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson())));
    final signed = identity.sign(payloadBytes);
    final ciphertext = CryptoCore.encrypt(
      signed,
      CryptoCore.fromBase64(recipientEncryptionKey),
      identity.encryptionPrivateKeyBytes,
    );
    return WireEnvelope(
      id: envelopeId,
      senderId: payload.from,
      timestampMs: payload.timestampMs,
      ciphertextBase64: CryptoCore.toBase64(ciphertext),
    );
  }

  /// Decrypts, verifies and parses [envelope].
  ///
  /// Throws if decryption or signature verification fails, or if the ids
  /// inside the signed payload don't match [expectedSender] / [myUserId].
  static WirePayload open({
    required WireEnvelope envelope,
    required CryptoIdentity identity,
    required PeerKeys sender,
    required String expectedSender,
    required String myUserId,
  }) {
    if (envelope.senderId != expectedSender) {
      throw const FormatException('Envelope sender mismatch');
    }

    final plain = CryptoCore.decrypt(
      CryptoCore.fromBase64(envelope.ciphertextBase64),
      CryptoCore.fromBase64(sender.encryptionKey),
      identity.encryptionPrivateKeyBytes,
    );

    if (envelope.version < 2) {
      // Legacy v1: the box holds the bare text.
      return WirePayload.message(
        messageId: envelope.id,
        from: envelope.senderId,
        to: myUserId,
        timestampMs: envelope.timestampMs,
        body: utf8.decode(plain),
      );
    }

    final payloadBytes =
        CryptoCore.openSigned(plain, CryptoCore.fromBase64(sender.signingKey));
    final payload = WirePayload.fromJson(
        jsonDecode(utf8.decode(payloadBytes)) as Map<String, dynamic>);

    if (payload.from != expectedSender || payload.to != myUserId) {
      throw const FormatException('Payload addressed to someone else');
    }
    if (payload.kind == PayloadKind.message &&
        (payload.messageId == null || payload.body == null)) {
      throw const FormatException('Malformed message payload');
    }
    return payload;
  }
}
