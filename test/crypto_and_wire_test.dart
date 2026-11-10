import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/chat/wire_protocol.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

PeerKeys keysOf(CryptoIdentity id) => PeerKeys(
      signingKey: id.publicSigningKeyBase64,
      encryptionKey: id.publicEncryptionKeyBase64,
    );

void main() {
  final alice = CryptoCore.generateIdentity();
  final bob = CryptoCore.generateIdentity();
  final mallory = CryptoCore.generateIdentity();

  group('CryptoCore', () {
    test('box encrypt/decrypt round-trips and rejects tampering', () {
      final ct = CryptoCore.encrypt(
        bytes('hello'),
        CryptoCore.fromBase64(bob.publicEncryptionKeyBase64),
        alice.encryptionPrivateKeyBytes,
      );
      final pt = CryptoCore.decrypt(
        ct,
        CryptoCore.fromBase64(alice.publicEncryptionKeyBase64),
        bob.encryptionPrivateKeyBytes,
      );
      expect(utf8.decode(pt), 'hello');

      final tampered = Uint8List.fromList(ct)..[ct.length - 1] ^= 1;
      expect(
        () => CryptoCore.decrypt(
          tampered,
          CryptoCore.fromBase64(alice.publicEncryptionKeyBase64),
          bob.encryptionPrivateKeyBytes,
        ),
        throwsA(anything),
      );
    });

    test('signatures verify only with the signer key', () {
      final signed = alice.sign(bytes('payload'));
      final opened = CryptoCore.openSigned(
          signed, CryptoCore.fromBase64(alice.publicSigningKeyBase64));
      expect(utf8.decode(opened), 'payload');

      expect(
        () => CryptoCore.openSigned(
            signed, CryptoCore.fromBase64(mallory.publicSigningKeyBase64)),
        throwsFormatException,
      );
    });

    test('secretbox round-trips and fails with the wrong key', () {
      final key = CryptoCore.randomBytes(32);
      final sealed = CryptoCore.secretEncrypt(bytes('at rest'), key);
      expect(utf8.decode(CryptoCore.secretDecrypt(sealed, key)), 'at rest');
      expect(
        () => CryptoCore.secretDecrypt(sealed, CryptoCore.randomBytes(32)),
        throwsA(anything),
      );
    });

    test('identity survives serialization', () {
      final restored = CryptoIdentity.fromMap(alice.toMap())!;
      expect(restored.publicSigningKeyBase64, alice.publicSigningKeyBase64);
      expect(
          restored.publicEncryptionKeyBase64, alice.publicEncryptionKeyBase64);
      final signed = restored.sign(bytes('x'));
      expect(
          CryptoCore.verify(
              signed, CryptoCore.fromBase64(alice.publicSigningKeyBase64)),
          isTrue);
    });

    test('safety number is symmetric, 60 digits, and key-sensitive', () {
      String sn(CryptoIdentity me, String myId, CryptoIdentity them,
              String theirId) =>
          CryptoCore.safetyNumber(
            myUserId: myId,
            mySigningKey: me.publicSigningKeyBase64,
            myEncryptionKey: me.publicEncryptionKeyBase64,
            theirUserId: theirId,
            theirSigningKey: them.publicSigningKeyBase64,
            theirEncryptionKey: them.publicEncryptionKeyBase64,
          );

      final ab = sn(alice, 'a', bob, 'b');
      expect(ab, sn(bob, 'b', alice, 'a'));
      expect(ab, matches(RegExp(r'^(\d{5} ){11}\d{5}$')));
      expect(sn(alice, 'a', mallory, 'b'), isNot(ab));
    });
  });

  group('WireCodec', () {
    WireEnvelope sealFromAlice(WirePayload payload) => WireCodec.seal(
          envelopeId: 'env-1',
          payload: payload,
          identity: alice,
          recipientEncryptionKey: bob.publicEncryptionKeyBase64,
        );

    WirePayload openAsBob(WireEnvelope env,
            {PeerKeys? sender, String expectedSender = 'alice'}) =>
        WireCodec.open(
          envelope: WireEnvelope.decodeJson(env.encodeJson()),
          identity: bob,
          sender: sender ?? keysOf(alice),
          expectedSender: expectedSender,
          myUserId: 'bob',
        );

    test('text message round-trips', () {
      final env = sealFromAlice(WirePayload.message(
        messageId: 'm1',
        from: 'alice',
        to: 'bob',
        timestampMs: 42,
        body: 'hi bob 👋',
      ));
      expect(env.version, kWireVersion);

      final payload = openAsBob(env);
      expect(payload.kind, PayloadKind.message);
      expect(payload.messageId, 'm1');
      expect(payload.body, 'hi bob 👋');
      expect(payload.timestampMs, 42);
    });

    test('receipt and typing payloads round-trip', () {
      final receipt = openAsBob(sealFromAlice(WirePayload.receipt(
        from: 'alice',
        to: 'bob',
        timestampMs: 1,
        ids: ['m1', 'm2'],
        status: ReceiptStatus.read,
      )));
      expect(receipt.kind, PayloadKind.receipt);
      expect(receipt.receiptIds, ['m1', 'm2']);
      expect(receipt.receiptStatus, ReceiptStatus.read);

      final typing = openAsBob(sealFromAlice(WirePayload.typing(
          from: 'alice', to: 'bob', timestampMs: 1, isTyping: true)));
      expect(typing.kind, PayloadKind.typing);
      expect(typing.isTyping, isTrue);
    });

    test('rejects an envelope claiming a different sender', () {
      final env = sealFromAlice(WirePayload.message(
          messageId: 'm', from: 'alice', to: 'bob', timestampMs: 1, body: 'x'));
      expect(() => openAsBob(env, expectedSender: 'mallory'),
          throwsFormatException);
    });

    test('rejects a payload addressed to someone else', () {
      final env = sealFromAlice(WirePayload.message(
          messageId: 'm', from: 'alice', to: 'carol', timestampMs: 1, body: 'x'));
      expect(() => openAsBob(env), throwsFormatException);
    });

    test('rejects a forged signature', () {
      final env = sealFromAlice(WirePayload.message(
          messageId: 'm', from: 'alice', to: 'bob', timestampMs: 1, body: 'x'));
      final wrongSigner = PeerKeys(
        signingKey: mallory.publicSigningKeyBase64,
        encryptionKey: alice.publicEncryptionKeyBase64,
      );
      expect(() => openAsBob(env, sender: wrongSigner), throwsFormatException);
    });

    test('still opens legacy v1 envelopes', () {
      final ct = CryptoCore.encrypt(
        bytes('old client'),
        CryptoCore.fromBase64(bob.publicEncryptionKeyBase64),
        alice.encryptionPrivateKeyBytes,
      );
      final legacyJson = jsonEncode({
        'id': 'legacy-1',
        's': 'alice',
        't': 7,
        'c': CryptoCore.toBase64(ct),
      });
      final payload = WireCodec.open(
        envelope: WireEnvelope.decodeJson(legacyJson),
        identity: bob,
        sender: keysOf(alice),
        expectedSender: 'alice',
        myUserId: 'bob',
      );
      expect(payload.kind, PayloadKind.message);
      expect(payload.messageId, 'legacy-1');
      expect(payload.body, 'old client');
    });
  });
}
