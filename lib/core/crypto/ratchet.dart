import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;
import 'package:pinenacl/ed25519.dart';
import 'package:pinenacl/tweetnacl.dart';
import 'package:pinenacl/x25519.dart' show PrivateKey, SecretBox, EncryptedMessage;

import 'package:securelyhello/core/crypto/crypto_core.dart';

// Forward-secret sessions: X3DH + Double Ratchet
//
// Every device has an identity (Ed25519 signing key + X25519 key, see
// [CryptoIdentity]), a signed prekey (SPK) and a stock of one-time prekeys
// (OPK) published on the server. To talk to a device for the first time we
// run X3DH against its prekey bundle, which gives both sides the same secret
// without the other being online, then run the Double Ratchet:
//
// * a new DH ratchet step on every change of speaker, so a stolen key can't
//   decrypt earlier messages (forward secrecy) and stops working once the
//   other side replies (post-compromise security);
// * a symmetric chain step per message, with each message key used once.
//
// Follows the Signal specifications (X3DH rev. 1, Double Ratchet rev. 4)
// with these primitives: X25519, HKDF-SHA256 / HMAC-SHA256, and
// XSalsa20-Poly1305 (NaCl secretbox) for message encryption. The secretbox
// has no associated-data input, so the plaintext starts with
// SHA-256(AD ‖ header), which binds the identities and the header to the
// ciphertext.

const _x3dhInfo = 'SecurelyHello X3DH v1';
const _rootInfo = 'SecurelyHello ratchet v1';
const _messageInfo = 'SecurelyHello message keys v1';
const _spkLabel = 'securelyhello-spk-v1';

/// Message keys kept for messages that arrive out of order.
const int maxSkippedPerStep = 1000;
const int maxSkippedTotal = 2000;

/// The ciphertext could not be decrypted with the session (wrong session,
/// tampered, replayed or too far out of order).
class RatchetException implements Exception {
  final String message;
  const RatchetException(this.message);
  @override
  String toString() => 'RatchetException: $message';
}

// Primitives

class Kdf {
  Kdf._();

  static Uint8List hmac(List<int> key, List<int> data) =>
      Uint8List.fromList(hash.Hmac(hash.sha256, key).convert(data).bytes);

  static Uint8List sha256(List<int> data) =>
      Uint8List.fromList(hash.sha256.convert(data).bytes);

  /// HKDF-SHA256 (RFC 5869).
  static Uint8List hkdf(List<int> ikm,
      {List<int>? salt, required String info, required int length}) {
    final prk = hmac(salt ?? Uint8List(32), ikm);
    final infoBytes = utf8.encode(info);
    final out = BytesBuilder();
    var t = <int>[];
    for (var i = 1; out.length < length; i++) {
      t = hmac(prk, [...t, ...infoBytes, i]);
      out.add(t);
    }
    return Uint8List.fromList(out.toBytes().sublist(0, length));
  }
}

/// X25519. Rejects all-zero outputs (low-order public keys).
Uint8List x25519(Uint8List privateKey, Uint8List publicKey) {
  if (privateKey.length != 32 || publicKey.length != 32) {
    throw const RatchetException('X25519 keys must be 32 bytes');
  }
  final out = TweetNaCl.crypto_scalarmult(Uint8List(32), privateKey, publicKey);
  if (out.every((b) => b == 0)) {
    throw const RatchetException('Invalid public key');
  }
  return out;
}

class DhKeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;
  const DhKeyPair(this.privateKey, this.publicKey);

  factory DhKeyPair.generate() {
    final priv = PrivateKey.generate();
    return DhKeyPair(Uint8List.fromList(priv), Uint8List.fromList(priv.publicKey));
  }

  factory DhKeyPair.fromPrivate(Uint8List privateKey) {
    final priv = PrivateKey(privateKey);
    return DhKeyPair(Uint8List.fromList(priv), Uint8List.fromList(priv.publicKey));
  }

  String get publicBase64 => base64Encode(publicKey);

  Map<String, String> toJson() =>
      {'priv': base64Encode(privateKey), 'pub': base64Encode(publicKey)};

  static DhKeyPair fromJson(Map<String, dynamic> j) => DhKeyPair(
      base64Decode(j['priv'] as String), base64Decode(j['pub'] as String));
}

// Signed prekeys

/// The bytes a signed prekey signature covers (the server checks the same).
Uint8List signedPreKeyMessage(int id, Uint8List publicKey) {
  final idBytes = ByteData(4)..setUint32(0, id);
  return Uint8List.fromList([
    ...utf8.encode(_spkLabel),
    ...idBytes.buffer.asUint8List(),
    ...publicKey,
  ]);
}

/// Detached Ed25519 signature over a signed prekey.
String signPreKey(CryptoIdentity identity, int id, Uint8List publicKey) {
  final signed = identity.signingKey.sign(signedPreKeyMessage(id, publicKey));
  return base64Encode(Uint8List.fromList(signed.signature));
}

bool verifyPreKey(String signingKeyB64, int id, String preKeyB64, String sigB64) {
  try {
    final key = VerifyKey(base64Decode(signingKeyB64));
    return key.verify(
      signature: Signature(base64Decode(sigB64)),
      message: signedPreKeyMessage(id, base64Decode(preKeyB64)),
    );
  } catch (_) {
    return false;
  }
}

// X3DH

/// Public keys of one remote device, as published on the server.
class DeviceKeys {
  final String userId;
  final String deviceId;

  /// Ed25519, base64.
  final String signingKey;

  /// X25519, base64.
  final String identityKey;

  const DeviceKeys({
    required this.userId,
    required this.deviceId,
    required this.signingKey,
    required this.identityKey,
  });

  String get address => '$userId:$deviceId';
}

/// What the server hands out to start a session with one device.
class PreKeyBundle {
  final DeviceKeys device;
  final int signedPreKeyId;
  final String signedPreKey;
  final String signedPreKeySignature;
  final int? oneTimePreKeyId;
  final String? oneTimePreKey;

  const PreKeyBundle({
    required this.device,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    this.oneTimePreKeyId,
    this.oneTimePreKey,
  });

  factory PreKeyBundle.fromJson(String userId, Map<String, dynamic> j) {
    final spk = j['signed_prekey'] as Map<String, dynamic>;
    final opk = j['one_time_prekey'] as Map<String, dynamic>?;
    return PreKeyBundle(
      device: DeviceKeys(
        userId: userId,
        deviceId: j['device_id'] as String,
        signingKey: j['signing_public_key'] as String,
        identityKey: j['identity_public_key'] as String,
      ),
      signedPreKeyId: spk['id'] as int,
      signedPreKey: spk['key'] as String,
      signedPreKeySignature: spk['signature'] as String,
      oneTimePreKeyId: opk?['id'] as int?,
      oneTimePreKey: opk?['key'] as String?,
    );
  }
}

/// Sent with every message until the responder has replied, so the
/// responder can derive the same secret.
class PreKeyHeader {
  /// Initiator identity (Ed25519 signing key, X25519 key), base64.
  final String signingKey;
  final String identityKey;

  /// Initiator ephemeral (base key), base64. Also identifies the session.
  final String baseKey;
  final int signedPreKeyId;
  final int? oneTimePreKeyId;

  const PreKeyHeader({
    required this.signingKey,
    required this.identityKey,
    required this.baseKey,
    required this.signedPreKeyId,
    this.oneTimePreKeyId,
  });

  Map<String, dynamic> toJson() => {
        'ik': signingKey,
        'ix': identityKey,
        'ek': baseKey,
        'spk': signedPreKeyId,
        if (oneTimePreKeyId != null) 'opk': oneTimePreKeyId,
      };

  static PreKeyHeader fromJson(Map<String, dynamic> j) => PreKeyHeader(
        signingKey: j['ik'] as String,
        identityKey: j['ix'] as String,
        baseKey: j['ek'] as String,
        signedPreKeyId: j['spk'] as int,
        oneTimePreKeyId: j['opk'] as int?,
      );
}

/// Associated data: both identities, initiator first.
Uint8List _associatedData({
  required String initiatorSigning,
  required String initiatorIdentity,
  required String responderSigning,
  required String responderIdentity,
}) =>
    Uint8List.fromList([
      ...base64Decode(initiatorSigning),
      ...base64Decode(initiatorIdentity),
      ...base64Decode(responderSigning),
      ...base64Decode(responderIdentity),
    ]);

Uint8List _x3dhSecret(List<Uint8List> dhs) => Kdf.hkdf(
      [...List.filled(32, 0xff), for (final d in dhs) ...d],
      info: _x3dhInfo,
      length: 32,
    );

class X3dh {
  X3dh._();

  /// Initiator side. Throws if the signed prekey's signature is invalid.
  static RatchetState initiate(CryptoIdentity me, PreKeyBundle bundle) {
    if (!verifyPreKey(bundle.device.signingKey, bundle.signedPreKeyId,
        bundle.signedPreKey, bundle.signedPreKeySignature)) {
      throw const RatchetException('Signed prekey signature is invalid');
    }
    final ek = DhKeyPair.generate();
    final spk = base64Decode(bundle.signedPreKey);
    final ikB = base64Decode(bundle.device.identityKey);
    final dhs = [
      x25519(me.encryptionPrivateKeyBytes, spk),
      x25519(ek.privateKey, ikB),
      x25519(ek.privateKey, spk),
      if (bundle.oneTimePreKey != null)
        x25519(ek.privateKey, base64Decode(bundle.oneTimePreKey!)),
    ];
    final ad = _associatedData(
      initiatorSigning: me.publicSigningKeyBase64,
      initiatorIdentity: me.publicEncryptionKeyBase64,
      responderSigning: bundle.device.signingKey,
      responderIdentity: bundle.device.identityKey,
    );
    final header = PreKeyHeader(
      signingKey: me.publicSigningKeyBase64,
      identityKey: me.publicEncryptionKeyBase64,
      baseKey: ek.publicBase64,
      signedPreKeyId: bundle.signedPreKeyId,
      oneTimePreKeyId: bundle.oneTimePreKeyId,
    );
    return DoubleRatchet.initInitiator(
      secret: _x3dhSecret(dhs),
      theirRatchetKey: spk,
      ad: ad,
      preKey: header,
    );
  }

  /// Responder side, from the initiator's [header] and our private prekeys.
  static RatchetState respond({
    required CryptoIdentity me,
    required PreKeyHeader header,
    required DhKeyPair signedPreKey,
    DhKeyPair? oneTimePreKey,
  }) {
    if (header.oneTimePreKeyId != null && oneTimePreKey == null) {
      throw const RatchetException('One-time prekey is gone');
    }
    final ek = base64Decode(header.baseKey);
    final dhs = [
      x25519(signedPreKey.privateKey, base64Decode(header.identityKey)),
      x25519(me.encryptionPrivateKeyBytes, ek),
      x25519(signedPreKey.privateKey, ek),
      if (oneTimePreKey != null) x25519(oneTimePreKey.privateKey, ek),
    ];
    final ad = _associatedData(
      initiatorSigning: header.signingKey,
      initiatorIdentity: header.identityKey,
      responderSigning: me.publicSigningKeyBase64,
      responderIdentity: me.publicEncryptionKeyBase64,
    );
    return DoubleRatchet.initResponder(
      secret: _x3dhSecret(dhs),
      ourRatchetKey: signedPreKey,
      ad: ad,
      baseKey: header.baseKey,
    );
  }
}

// Double Ratchet

/// One message's ratchet header. Serialized as compact JSON; the exact
/// string is authenticated (see [DoubleRatchet.encrypt]).
class RatchetHeader {
  final String dh;
  final int pn;
  final int n;
  final PreKeyHeader? preKey;
  const RatchetHeader({required this.dh, required this.pn, required this.n, this.preKey});

  String encode() => jsonEncode({
        'dh': dh,
        'pn': pn,
        'n': n,
        if (preKey != null) 'pk': preKey!.toJson(),
      });

  static RatchetHeader decode(String raw) {
    final j = jsonDecode(raw);
    if (j is! Map<String, dynamic>) throw const FormatException('Bad header');
    final pk = j['pk'];
    final dh = j['dh'];
    final pn = j['pn'];
    final n = j['n'];
    if (dh is! String || pn is! int || n is! int || pn < 0 || n < 0) {
      throw const FormatException('Bad header');
    }
    return RatchetHeader(
      dh: dh,
      pn: pn,
      n: n,
      preKey: pk is Map<String, dynamic> ? _preKey(pk) : null,
    );
  }

  static PreKeyHeader _preKey(Map<String, dynamic> pk) {
    try {
      return PreKeyHeader.fromJson(pk);
    } on TypeError {
      throw const FormatException('Bad prekey header');
    }
  }
}

/// The complete state of one session with one remote device.
class RatchetState {
  Uint8List rootKey;
  DhKeyPair sendingKey;
  Uint8List? receivingKey;
  Uint8List? sendingChain;
  Uint8List? receivingChain;
  int sent;
  int received;
  int previousChainLength;

  /// "base64(dh):n" → message key, oldest first.
  final Map<String, String> skipped;
  final Uint8List ad;

  /// Set on the initiator until the first reply arrives.
  PreKeyHeader? pendingPreKey;

  /// The initiator's ephemeral key: identifies the session on both sides.
  final String baseKey;

  /// Something was decrypted with this session (the other side has it).
  bool confirmed;
  final int createdAt;

  RatchetState._({
    required this.rootKey,
    required this.sendingKey,
    required this.ad,
    required this.baseKey,
    required this.createdAt,
    this.receivingKey,
    this.sendingChain,
    this.receivingChain,
    this.sent = 0,
    this.received = 0,
    this.previousChainLength = 0,
    Map<String, String>? skipped,
    this.pendingPreKey,
    this.confirmed = false,
  }) : skipped = skipped ?? {};

  Map<String, dynamic> toJson() => {
        'rk': base64Encode(rootKey),
        'dhs': sendingKey.toJson(),
        if (receivingKey != null) 'dhr': base64Encode(receivingKey!),
        if (sendingChain != null) 'cks': base64Encode(sendingChain!),
        if (receivingChain != null) 'ckr': base64Encode(receivingChain!),
        'ns': sent,
        'nr': received,
        'pn': previousChainLength,
        'skip': skipped,
        'ad': base64Encode(ad),
        if (pendingPreKey != null) 'pk': pendingPreKey!.toJson(),
        'base': baseKey,
        'ok': confirmed,
        'at': createdAt,
      };

  static RatchetState fromJson(Map<String, dynamic> j) {
    Uint8List? opt(String k) => j[k] == null ? null : base64Decode(j[k] as String);
    return RatchetState._(
      rootKey: base64Decode(j['rk'] as String),
      sendingKey: DhKeyPair.fromJson(j['dhs'] as Map<String, dynamic>),
      receivingKey: opt('dhr'),
      sendingChain: opt('cks'),
      receivingChain: opt('ckr'),
      sent: j['ns'] as int,
      received: j['nr'] as int,
      previousChainLength: j['pn'] as int,
      skipped: Map<String, String>.from(j['skip'] as Map),
      ad: base64Decode(j['ad'] as String),
      pendingPreKey: j['pk'] == null
          ? null
          : PreKeyHeader.fromJson(j['pk'] as Map<String, dynamic>),
      baseKey: j['base'] as String,
      confirmed: j['ok'] as bool? ?? false,
      createdAt: j['at'] as int,
    );
  }

  RatchetState copy() => fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);
}

class EncryptedRatchetMessage {
  /// Exactly the string that was authenticated.
  final String header;
  final Uint8List ciphertext;
  const EncryptedRatchetMessage(this.header, this.ciphertext);
}

class DoubleRatchet {
  DoubleRatchet._();

  static ({Uint8List root, Uint8List chain}) _kdfRoot(Uint8List rk, Uint8List dhOut) {
    final out = Kdf.hkdf(dhOut, salt: rk, info: _rootInfo, length: 64);
    return (root: out.sublist(0, 32), chain: out.sublist(32));
  }

  static ({Uint8List chain, Uint8List message}) _kdfChain(Uint8List ck) =>
      (chain: Kdf.hmac(ck, const [0x02]), message: Kdf.hmac(ck, const [0x01]));

  static RatchetState initInitiator({
    required Uint8List secret,
    required Uint8List theirRatchetKey,
    required Uint8List ad,
    required PreKeyHeader preKey,
  }) {
    final dhs = DhKeyPair.generate();
    final k = _kdfRoot(secret, x25519(dhs.privateKey, theirRatchetKey));
    return RatchetState._(
      rootKey: k.root,
      sendingKey: dhs,
      receivingKey: theirRatchetKey,
      sendingChain: k.chain,
      ad: ad,
      pendingPreKey: preKey,
      baseKey: preKey.baseKey,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static RatchetState initResponder({
    required Uint8List secret,
    required DhKeyPair ourRatchetKey,
    required Uint8List ad,
    required String baseKey,
  }) =>
      RatchetState._(
        rootKey: secret,
        sendingKey: ourRatchetKey,
        ad: ad,
        baseKey: baseKey,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

  static ({Uint8List key, Uint8List nonce}) _messageKeys(Uint8List mk) {
    final out = Kdf.hkdf(mk, info: _messageInfo, length: 56);
    return (key: out.sublist(0, 32), nonce: out.sublist(32));
  }

  static Uint8List _binding(Uint8List ad, String header) =>
      Kdf.sha256([...ad, ...utf8.encode(header)]);

  /// Encrypts [plaintext] and advances the sending chain. Mutates [s].
  static EncryptedRatchetMessage encrypt(RatchetState s, Uint8List plaintext) {
    final ck = s.sendingChain;
    if (ck == null) {
      // A responder can't send before it has received (it has no chain).
      throw const RatchetException('Session has no sending chain yet');
    }
    final step = _kdfChain(ck);
    s.sendingChain = step.chain;
    final header = RatchetHeader(
      dh: s.sendingKey.publicBase64,
      pn: s.previousChainLength,
      n: s.sent,
      preKey: s.pendingPreKey,
    ).encode();
    s.sent++;
    final keys = _messageKeys(step.message);
    final sealed = SecretBox(keys.key).encrypt(
      Uint8List.fromList([..._binding(s.ad, header), ...plaintext]),
      nonce: keys.nonce,
    );
    return EncryptedRatchetMessage(header, Uint8List.fromList(sealed.cipherText));
  }

  /// Decrypts and advances. On failure [s] is left exactly as it was.
  static Uint8List decrypt(RatchetState s, String header, Uint8List ciphertext) {
    final h = RatchetHeader.decode(header);
    final trial = s.copy();
    final plain = _decrypt(trial, h, header, ciphertext);
    // Commit.
    s
      ..rootKey = trial.rootKey
      ..sendingKey = trial.sendingKey
      ..receivingKey = trial.receivingKey
      ..sendingChain = trial.sendingChain
      ..receivingChain = trial.receivingChain
      ..sent = trial.sent
      ..received = trial.received
      ..previousChainLength = trial.previousChainLength
      ..pendingPreKey = null
      ..confirmed = true;
    s.skipped
      ..clear()
      ..addAll(trial.skipped);
    return plain;
  }

  static Uint8List _decrypt(
      RatchetState s, RatchetHeader h, String header, Uint8List ciphertext) {
    final skippedKey = '${h.dh}:${h.n}';
    final skippedMk = s.skipped.remove(skippedKey);
    if (skippedMk != null) {
      return _open(s, base64Decode(skippedMk), header, ciphertext);
    }

    final dh = base64Decode(h.dh);
    final current = s.receivingKey;
    if (current == null || base64Encode(current) != h.dh) {
      _skip(s, h.pn);
      // DH ratchet step.
      s.previousChainLength = s.sent;
      s.sent = 0;
      s.received = 0;
      s.receivingKey = dh;
      var k = _kdfRoot(s.rootKey, x25519(s.sendingKey.privateKey, dh));
      s.rootKey = k.root;
      s.receivingChain = k.chain;
      s.sendingKey = DhKeyPair.generate();
      k = _kdfRoot(s.rootKey, x25519(s.sendingKey.privateKey, dh));
      s.rootKey = k.root;
      s.sendingChain = k.chain;
    }
    _skip(s, h.n);
    final step = _kdfChain(s.receivingChain!);
    s.receivingChain = step.chain;
    s.received++;
    return _open(s, step.message, header, ciphertext);
  }

  /// Stores message keys up to [until] on the receiving chain.
  static void _skip(RatchetState s, int until) {
    final ck = s.receivingChain;
    if (ck == null) return;
    if (until - s.received > maxSkippedPerStep) {
      throw const RatchetException('Too many skipped messages');
    }
    var chain = ck;
    final dh = base64Encode(s.receivingKey!);
    while (s.received < until) {
      final step = _kdfChain(chain);
      chain = step.chain;
      s.skipped['$dh:${s.received}'] = base64Encode(step.message);
      s.received++;
    }
    s.receivingChain = chain;
    while (s.skipped.length > maxSkippedTotal) {
      s.skipped.remove(s.skipped.keys.first);
    }
  }

  static Uint8List _open(
      RatchetState s, Uint8List mk, String header, Uint8List ciphertext) {
    final keys = _messageKeys(mk);
    Uint8List plain;
    try {
      plain = Uint8List.fromList(SecretBox(keys.key)
          .decrypt(EncryptedMessage(nonce: keys.nonce, cipherText: ciphertext)));
    } catch (_) {
      throw const RatchetException('Message authentication failed');
    }
    final expected = _binding(s.ad, header);
    if (plain.length < 32) throw const RatchetException('Message too short');
    for (var i = 0; i < 32; i++) {
      if (plain[i] != expected[i]) {
        throw const RatchetException('Header or identity mismatch');
      }
    }
    return plain.sublist(32);
  }
}

// Session records

/// All sessions with one remote device: the one we send with, plus a few
/// older ones kept for decrypting messages still in flight (for example
/// when both sides started a session at the same time).
class SessionRecord {
  static const maxPrevious = 5;

  RatchetState? current;
  final List<RatchetState> previous;

  SessionRecord({this.current, List<RatchetState>? previous})
      : previous = previous ?? [];

  /// Makes [state] current, archiving the old current one.
  void promote(RatchetState state) {
    if (identical(current, state)) return;
    previous.remove(state);
    if (current != null) previous.insert(0, current!);
    current = state;
    while (previous.length > maxPrevious) {
      previous.removeLast();
    }
  }

  Iterable<RatchetState> get all => [?current, ...previous];

  RatchetState? withBaseKey(String baseKey) {
    for (final s in all) {
      if (s.baseKey == baseKey) return s;
    }
    return null;
  }

  String encode() => jsonEncode({
        'cur': current?.toJson(),
        'prev': previous.map((s) => s.toJson()).toList(),
      });

  static SessionRecord decode(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return SessionRecord(
      current: j['cur'] == null
          ? null
          : RatchetState.fromJson(j['cur'] as Map<String, dynamic>),
      previous: (j['prev'] as List)
          .map((e) => RatchetState.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
