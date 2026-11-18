import 'dart:convert';
import 'dart:math';

import 'package:pinenacl/digests.dart';
import 'package:pinenacl/ed25519.dart';
import 'package:pinenacl/x25519.dart';

/// Holds both signing (Ed25519) and encryption (X25519) keypairs.
///
/// The identity of one device. Private keys stay in the platform keystore;
/// only the public halves are registered with the server.
class CryptoIdentity {
  /// Ed25519 signing keypair — used to sign outgoing messages
  /// so recipients can verify authenticity.
  final SigningKey signingKey;

  /// X25519 encryption keypair — used for NaCl box
  /// authenticated encryption between two parties.
  final PrivateKey encryptionPrivateKey;
  final PublicKey encryptionPublicKey;

  CryptoIdentity._({
    required this.signingKey,
    required this.encryptionPrivateKey,
    required this.encryptionPublicKey,
  });

  /// The Ed25519 public verification key.
  VerifyKey get verifyKey => signingKey.verifyKey;

  /// Raw 32-byte X25519 private key, as expected by [CryptoCore.encrypt].
  Uint8List get encryptionPrivateKeyBytes =>
      Uint8List.fromList(encryptionPrivateKey);

  /// Signs [message] and returns `signature (64 bytes) ‖ message`.
  Uint8List sign(Uint8List message) =>
      Uint8List.fromList(signingKey.sign(message).toList());

  // Public key export (safe to publish)

  /// Returns only the public signing key as Base64 (safe to publish).
  String get publicSigningKeyBase64 =>
      base64Encode(Uint8List.fromList(verifyKey));

  /// Returns only the public encryption key as Base64 (safe to publish).
  String get publicEncryptionKeyBase64 =>
      base64Encode(Uint8List.fromList(encryptionPublicKey));

  // Full serialization (for LOCAL storage only — includes private keys)

  /// Serializes the full identity (including private keys) to a map of
  /// Base64-encoded strings. **Store only in the local SQLite database.**
  Map<String, String> toMap() {
    return {
      'signing_private_key': base64Encode(Uint8List.fromList(signingKey)),
      'signing_public_key': publicSigningKeyBase64,
      'encryption_private_key':
          base64Encode(Uint8List.fromList(encryptionPrivateKey)),
      'encryption_public_key': publicEncryptionKeyBase64,
    };
  }

  /// Reconstructs a [CryptoIdentity] from a previously serialized map.
  /// Returns `null` if the map is missing any required key.
  static CryptoIdentity? fromMap(Map<String, String?> map) {
    final sigPriv = map['signing_private_key'];
    final encPriv = map['encryption_private_key'];

    if (sigPriv == null || encPriv == null) return null;

    try {
      final signingKeyBytes = base64Decode(sigPriv);
      final encPrivBytes = base64Decode(encPriv);

      final signingKey = SigningKey(seed: signingKeyBytes.length == 32
          ? signingKeyBytes
          : signingKeyBytes.sublist(0, 32));
      final encryptionPrivateKey = PrivateKey(Uint8List.fromList(encPrivBytes));
      final encryptionPublicKey = encryptionPrivateKey.publicKey;

      return CryptoIdentity._(
        signingKey: signingKey,
        encryptionPrivateKey: encryptionPrivateKey,
        encryptionPublicKey: encryptionPublicKey,
      );
    } catch (e) {
      return null;
    }
  }

  @override
  String toString() =>
      'CryptoIdentity(verifyKey=${publicSigningKeyBase64.substring(0, 8)}…, '
      'encPub=${publicEncryptionKeyBase64.substring(0, 8)}…)';
}

/// Stateless NaCl cryptography helpers.
///
/// All methods are static so they can be called from isolates or without
/// holding mutable state.
class CryptoCore {
  CryptoCore._(); // prevent instantiation

  // Identity generation

  /// Generates a fresh Ed25519 signing keypair **and** X25519 encryption
  /// keypair.  The returned [CryptoIdentity] should be persisted to local
  /// storage immediately.
  static CryptoIdentity generateIdentity() {
    final signingKey = SigningKey.generate();
    final encryptionPrivateKey = PrivateKey.generate();
    final encryptionPublicKey = encryptionPrivateKey.publicKey;

    return CryptoIdentity._(
      signingKey: signingKey,
      encryptionPrivateKey: encryptionPrivateKey,
      encryptionPublicKey: encryptionPublicKey,
    );
  }

  // NaCl Box encryption (X25519 + XSalsa20-Poly1305)

  /// Encrypts [plaintext] using NaCl box (authenticated encryption).
  ///
  /// * [recipientPublicKey] — the contact's X25519 public key (32 bytes).
  /// * [senderPrivateKey]   — our own X25519 private key (32 bytes).
  ///
  /// Returns the full encrypted payload **including** the 24-byte nonce prefix
  /// so the recipient can decrypt without out-of-band nonce exchange.
  static Uint8List encrypt(
    Uint8List plaintext,
    Uint8List recipientPublicKey,
    Uint8List senderPrivateKey,
  ) {
    final box = Box(
      myPrivateKey: PrivateKey(senderPrivateKey),
      theirPublicKey: PublicKey(recipientPublicKey),
    );
    final encrypted = box.encrypt(plaintext);
    // encrypted.toList() contains nonce (24 bytes) + ciphertext + MAC
    return Uint8List.fromList(encrypted.toList());
  }

  /// Decrypts [ciphertext] that was produced by [encrypt].
  ///
  /// * [senderPublicKey]      — the sender's X25519 public key (32 bytes).
  /// * [recipientPrivateKey]  — our own X25519 private key (32 bytes).
  ///
  /// The [ciphertext] must include the 24-byte nonce prefix.
  ///
  /// Throws [Exception] if authentication fails (tampered or wrong keys).
  static Uint8List decrypt(
    Uint8List ciphertext,
    Uint8List senderPublicKey,
    Uint8List recipientPrivateKey,
  ) {
    final box = Box(
      myPrivateKey: PrivateKey(recipientPrivateKey),
      theirPublicKey: PublicKey(senderPublicKey),
    );
    final encrypted = EncryptedMessage(
      nonce: ciphertext.sublist(0, 24),
      cipherText: ciphertext.sublist(24),
    );
    final decrypted = box.decrypt(encrypted);
    return Uint8List.fromList(decrypted);
  }

  // Ed25519 signing / verification

  /// Signs [message] with the Ed25519 [signingPrivateKey] (seed, 32 bytes).
  ///
  /// Returns the **signed message** (64-byte signature ‖ original message).
  static Uint8List sign(Uint8List message, Uint8List signingPrivateKey) {
    final signingKey = SigningKey(seed: signingPrivateKey);
    final signedMsg = signingKey.sign(message);
    return Uint8List.fromList(signedMsg.toList());
  }

  /// Verifies a [signedMessage] (64-byte signature ‖ original message) against
  /// the sender's Ed25519 [signingPublicKey] (32 bytes).
  ///
  /// Returns `true` if the signature is valid, `false` otherwise.
  static bool verify(Uint8List signedMessage, Uint8List signingPublicKey) {
    try {
      final verifyKey = VerifyKey(signingPublicKey);
      final signedMsgObj = SignedMessage.fromList(signedMessage: signedMessage);
      verifyKey.verifySignedMessage(signedMessage: signedMsgObj);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Verifies [signedMessage] and returns the embedded message bytes.
  ///
  /// Throws [FormatException] if the signature does not match
  /// [signingPublicKey].
  static Uint8List openSigned(
    Uint8List signedMessage,
    Uint8List signingPublicKey,
  ) {
    if (signedMessage.length < 64 || !verify(signedMessage, signingPublicKey)) {
      throw const FormatException('Invalid message signature');
    }
    return Uint8List.fromList(signedMessage.sublist(64));
  }

  // Local at-rest encryption (XSalsa20-Poly1305 SecretBox)

  /// Cryptographically secure random bytes.
  static Uint8List randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(length, (_) => rng.nextInt(256)));
  }

  /// Encrypts [plaintext] with a 32-byte symmetric [key].
  /// Returns `nonce (24 bytes) ‖ ciphertext`.
  static Uint8List secretEncrypt(Uint8List plaintext, Uint8List key) {
    final encrypted = SecretBox(key).encrypt(plaintext);
    return Uint8List.fromList(encrypted.toList());
  }

  /// Reverses [secretEncrypt].  Throws if the data was tampered with.
  static Uint8List secretDecrypt(Uint8List data, Uint8List key) {
    final decrypted = SecretBox(key).decrypt(EncryptedMessage(
      nonce: data.sublist(0, 24),
      cipherText: data.sublist(24),
    ));
    return Uint8List.fromList(decrypted);
  }

  // Safety numbers

  /// Computes a 60-digit safety number for two people.
  ///
  /// Each side is a user id plus the keys of all of that user's devices
  /// (`"<signing key>|<identity key>"`, in any order). The result is
  /// symmetric (both people derive the same digits) and changes whenever
  /// either side adds, removes or re-keys a device. Users compare it out of
  /// band (in person, on a call) to rule out a key-substitution attack by
  /// the directory server.
  static String safetyNumber({
    required String myUserId,
    required List<String> myDeviceKeys,
    required String theirUserId,
    required List<String> theirDeviceKeys,
  }) {
    String party(String id, List<String> keys) =>
        '$id|${([...keys]..sort()).join(',')}';
    final parties = [
      party(myUserId, myDeviceKeys),
      party(theirUserId, theirDeviceKeys),
    ]..sort();
    final digest = Hash.sha512(
        Uint8List.fromList(utf8.encode('securelyhello-sn-v2|${parties.join('#')}')));

    final groups = <String>[];
    for (var i = 0; i < 12; i++) {
      var value = 0;
      for (var j = 0; j < 5; j++) {
        value = (value << 8) | digest[i * 5 + j];
      }
      groups.add((value % 100000).toString().padLeft(5, '0'));
    }
    return groups.join(' ');
  }

  // Base64 helpers

  /// Encodes raw bytes to a URL-safe, unpadded Base64 string.
  static String toBase64(Uint8List bytes) => base64Encode(bytes);

  /// Decodes a Base64 string (standard or URL-safe) back to bytes.
  static Uint8List fromBase64(String encoded) =>
      Uint8List.fromList(base64Decode(encoded));
}
