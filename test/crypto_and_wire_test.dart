import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/chat/wire_protocol.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

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

    test('safety number covers every device, is symmetric and order-free', () {
      String keys(CryptoIdentity id) =>
          '${id.publicSigningKeyBase64}|${id.publicEncryptionKeyBase64}';
      final aliceLaptop = CryptoCore.generateIdentity();
      final a = CryptoCore.safetyNumber(
        myUserId: 'alice',
        myDeviceKeys: [keys(alice), keys(aliceLaptop)],
        theirUserId: 'bob',
        theirDeviceKeys: [keys(bob)],
      );
      final b = CryptoCore.safetyNumber(
        myUserId: 'bob',
        myDeviceKeys: [keys(bob)],
        theirUserId: 'alice',
        theirDeviceKeys: [keys(aliceLaptop), keys(alice)],
      );
      expect(a, b);
      expect(RegExp(r'^(\d{5} ){11}\d{5}$').hasMatch(a), isTrue);

      final withoutLaptop = CryptoCore.safetyNumber(
        myUserId: 'alice',
        myDeviceKeys: [keys(alice)],
        theirUserId: 'bob',
        theirDeviceKeys: [keys(bob)],
      );
      expect(withoutLaptop, isNot(a), reason: 'adding a device changes it');
      final swapped = CryptoCore.safetyNumber(
        myUserId: 'alice',
        myDeviceKeys: [keys(alice), keys(aliceLaptop)],
        theirUserId: 'bob',
        theirDeviceKeys: [keys(mallory)],
      );
      expect(swapped, isNot(a), reason: 'a substituted key changes it');
    });
  });

  group('wire protocol v3', () {
    test('envelope round-trips and rejects other versions', () {
      const env = WireEnvelope(
        id: 'e1',
        senderId: 'alice',
        senderDevice: 'a1',
        recipientDevice: 'b1',
        timestampMs: 42,
        header: '{"dh":"x","pn":0,"n":0}',
        ciphertextBase64: 'AAAA',
      );
      final back = WireEnvelope.fromBytes(env.encode());
      expect(back.senderAddress, 'alice:a1');
      expect(back.recipientDevice, 'b1');
      expect(back.header, env.header);
      expect(jsonDecode(env.encodeJson()).keys.toList()..sort(),
          ['c', 'h', 'id', 'rd', 's', 'sd', 't', 'v']);
      final v2 = Map<String, dynamic>.from(jsonDecode(env.encodeJson()))..['v'] = 2;
      expect(() => WireEnvelope.fromJson(v2), throwsFormatException);
    });

    test('payloads round-trip: message with attachment, receipt, typing, syncs', () {
      final msg = WirePayload.decode(WirePayload.message(
        messageId: 'm1',
        from: 'alice',
        to: 'bob',
        timestampMs: 1,
        body: '',
        attachment: {'id': 'blob', 'name': 'cat.png', 'size': 3},
      ).encode());
      expect(msg.kind, PayloadKind.message);
      expect(msg.attachment!['name'], 'cat.png');

      final receipt = WirePayload.decode(WirePayload.receipt(
              from: 'bob', to: 'alice', timestampMs: 2, ids: ['m1'], status: ReceiptStatus.read)
          .encode());
      expect(receipt.receiptIds, ['m1']);
      expect(receipt.receiptStatus, ReceiptStatus.read);

      final typing = WirePayload.decode(
          WirePayload.typing(from: 'a', to: 'b', timestampMs: 3, isTyping: true).encode());
      expect(typing.isTyping, isTrue);

      final sent = WirePayload.decode(WirePayload.sentSync(
              me: 'alice', conversation: 'bob', messageId: 'm2', timestampMs: 4, body: 'hi')
          .encode());
      expect(sent.kind, PayloadKind.sync);
      expect(sent.conversation, 'bob');
      expect(sent.to, 'alice');

      final read = WirePayload.decode(WirePayload.readSync(
              me: 'alice', conversation: 'bob', ids: ['x', 'y'], timestampMs: 5)
          .encode());
      expect(read.readIds, ['x', 'y']);
      expect(read.messageId, isNull);
    });

    test('malformed payloads are rejected', () {
      Uint8List enc(Map<String, dynamic> m) => bytes(jsonEncode(m));
      expect(() => WirePayload.decode(enc({'k': 'msg', 'from': 'a', 'to': 'b', 't': 1})),
          throwsFormatException);
      expect(() => WirePayload.decode(enc({'k': 'sync', 'from': 'a', 'to': 'a', 't': 1})),
          throwsFormatException);
      expect(() => WirePayload.decode(enc({'k': 'nope', 'from': 'a', 'to': 'b', 't': 1})),
          throwsFormatException);
    });
  });
}
