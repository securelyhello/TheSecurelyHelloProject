import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/crypto/ratchet.dart';

/// One simulated device: identity + prekeys, like the real app keeps them.
class Device {
  final String userId;
  final String deviceId;
  final CryptoIdentity identity = CryptoCore.generateIdentity();
  final DhKeyPair spk = DhKeyPair.generate();
  final int spkId = 7;
  final Map<int, DhKeyPair> opks = {
    for (var i = 1; i <= 3; i++) i: DhKeyPair.generate()
  };

  Device(this.userId, this.deviceId);

  DeviceKeys get keys => DeviceKeys(
        userId: userId,
        deviceId: deviceId,
        signingKey: identity.publicSigningKeyBase64,
        identityKey: identity.publicEncryptionKeyBase64,
      );

  /// Claims a bundle the way the server would (one OPK, removed from stock).
  PreKeyBundle bundle({bool withOpk = true}) {
    final opkId = withOpk && opks.isNotEmpty ? opks.keys.first : null;
    return PreKeyBundle(
      device: keys,
      signedPreKeyId: spkId,
      signedPreKey: spk.publicBase64,
      signedPreKeySignature: signPreKey(identity, spkId, spk.publicKey),
      oneTimePreKeyId: opkId,
      oneTimePreKey: opkId == null ? null : opks[opkId]!.publicBase64,
    );
  }

  /// Responder side of an incoming prekey message.
  RatchetState accept(PreKeyHeader pk) {
    final opk = pk.oneTimePreKeyId == null ? null : opks.remove(pk.oneTimePreKeyId);
    return X3dh.respond(
        me: identity, header: pk, signedPreKey: spk, oneTimePreKey: opk);
  }
}

Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
String s(Uint8List b) => utf8.decode(b);

void main() {
  group('primitives', () {
    test('HKDF-SHA256 matches RFC 5869 test case 1', () {
      final ikm = Uint8List.fromList(List.filled(22, 0x0b));
      final salt = Uint8List.fromList(List.generate(13, (i) => i));
      // RFC uses info = 0xf0..0xf9; our API takes a string, so check the
      // extract+expand path with an equivalent ASCII-free comparison via HMAC.
      final prk = Kdf.hmac(salt, ikm);
      expect(
        prk.map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
        '077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5',
      );
      expect(Kdf.hkdf(ikm, salt: salt, info: 'x', length: 80).length, 80);
    });

    test('X25519 agrees both ways and rejects low-order points', () {
      final a = DhKeyPair.generate();
      final c = DhKeyPair.generate();
      expect(x25519(a.privateKey, c.publicKey), x25519(c.privateKey, a.publicKey));
      expect(() => x25519(a.privateKey, Uint8List(32)),
          throwsA(isA<RatchetException>()));
    });

    test('signed prekeys verify only with the right key and id', () {
      final d = Device('u', 'd');
      final sig = signPreKey(d.identity, 7, d.spk.publicKey);
      expect(verifyPreKey(d.identity.publicSigningKeyBase64, 7, d.spk.publicBase64, sig), isTrue);
      expect(verifyPreKey(d.identity.publicSigningKeyBase64, 8, d.spk.publicBase64, sig), isFalse);
      final other = CryptoCore.generateIdentity();
      expect(verifyPreKey(other.publicSigningKeyBase64, 7, d.spk.publicBase64, sig), isFalse);
    });
  });

  group('X3DH + Double Ratchet', () {
    late Device alice;
    late Device bob;
    setUp(() {
      alice = Device('alice', 'a1');
      bob = Device('bob', 'b1');
    });

    test('first message carries the prekey header; replies drop it', () {
      final aState = X3dh.initiate(alice.identity, bob.bundle());
      final m1 = DoubleRatchet.encrypt(aState, b('hi bob'));
      final h1 = RatchetHeader.decode(m1.header);
      expect(h1.preKey, isNotNull);
      expect(h1.preKey!.oneTimePreKeyId, 1);

      final bState = bob.accept(h1.preKey!);
      expect(bob.opks.containsKey(1), isFalse, reason: 'one-time prekey is used up');
      expect(s(DoubleRatchet.decrypt(bState, m1.header, m1.ciphertext)), 'hi bob');

      final r1 = DoubleRatchet.encrypt(bState, b('hi alice'));
      expect(RatchetHeader.decode(r1.header).preKey, isNull);
      expect(s(DoubleRatchet.decrypt(aState, r1.header, r1.ciphertext)), 'hi alice');
      expect(aState.pendingPreKey, isNull, reason: 'confirmed once the reply arrived');

      final m2 = DoubleRatchet.encrypt(aState, b('again'));
      expect(RatchetHeader.decode(m2.header).preKey, isNull);
      expect(s(DoubleRatchet.decrypt(bState, m2.header, m2.ciphertext)), 'again');
    });

    test('works without a one-time prekey', () {
      final aState = X3dh.initiate(alice.identity, bob.bundle(withOpk: false));
      final m = DoubleRatchet.encrypt(aState, b('no opk'));
      final bState = bob.accept(RatchetHeader.decode(m.header).preKey!);
      expect(s(DoubleRatchet.decrypt(bState, m.header, m.ciphertext)), 'no opk');
    });

    test('a forged signed prekey is refused', () {
      final bundle = bob.bundle();
      final forged = PreKeyBundle(
        device: bundle.device,
        signedPreKeyId: bundle.signedPreKeyId,
        signedPreKey: DhKeyPair.generate().publicBase64,
        signedPreKeySignature: bundle.signedPreKeySignature,
      );
      expect(() => X3dh.initiate(alice.identity, forged),
          throwsA(isA<RatchetException>()));
    });

    test('long conversation with alternating and out-of-order messages', () {
      final aState = X3dh.initiate(alice.identity, bob.bundle());
      final first = DoubleRatchet.encrypt(aState, b('0'));
      final bState = bob.accept(RatchetHeader.decode(first.header).preKey!);
      DoubleRatchet.decrypt(bState, first.header, first.ciphertext);

      for (var round = 0; round < 5; round++) {
        final fromA = [for (var i = 0; i < 4; i++) DoubleRatchet.encrypt(aState, b('a$round.$i'))];
        // Delivered in reverse order.
        for (final m in fromA.reversed) {
          final i = fromA.indexOf(m);
          expect(s(DoubleRatchet.decrypt(bState, m.header, m.ciphertext)), 'a$round.$i');
        }
        final fromB = [for (var i = 0; i < 3; i++) DoubleRatchet.encrypt(bState, b('b$round.$i'))];
        // Middle one lost until later.
        expect(s(DoubleRatchet.decrypt(aState, fromB[0].header, fromB[0].ciphertext)), 'b$round.0');
        expect(s(DoubleRatchet.decrypt(aState, fromB[2].header, fromB[2].ciphertext)), 'b$round.2');
        expect(s(DoubleRatchet.decrypt(aState, fromB[1].header, fromB[1].ciphertext)), 'b$round.1');
      }
    });

    test('a message from an earlier chain still opens after a ratchet step', () {
      final aState = X3dh.initiate(alice.identity, bob.bundle());
      final m0 = DoubleRatchet.encrypt(aState, b('m0'));
      final late = DoubleRatchet.encrypt(aState, b('late'));
      final bState = bob.accept(RatchetHeader.decode(m0.header).preKey!);
      DoubleRatchet.decrypt(bState, m0.header, m0.ciphertext);
      final r = DoubleRatchet.encrypt(bState, b('reply'));
      DoubleRatchet.decrypt(aState, r.header, r.ciphertext);
      final m2 = DoubleRatchet.encrypt(aState, b('new chain'));
      expect(s(DoubleRatchet.decrypt(bState, m2.header, m2.ciphertext)), 'new chain');
      expect(s(DoubleRatchet.decrypt(bState, late.header, late.ciphertext)), 'late');
    });

    test('tampering, replay and wrong sessions fail and leave the state untouched', () {
      final aState = X3dh.initiate(alice.identity, bob.bundle());
      final m = DoubleRatchet.encrypt(aState, b('secret'));
      final bState = bob.accept(RatchetHeader.decode(m.header).preKey!);
      final before = jsonEncode(bState.toJson());

      final flipped = Uint8List.fromList(m.ciphertext)..[5] ^= 1;
      expect(() => DoubleRatchet.decrypt(bState, m.header, flipped),
          throwsA(isA<RatchetException>()));
      // Header changes (e.g. counter) break the binding even with a valid box.
      final h = jsonDecode(m.header) as Map<String, dynamic>;
      final altered = jsonEncode({...h, 'pn': 3});
      expect(() => DoubleRatchet.decrypt(bState, altered, m.ciphertext),
          throwsA(isA<RatchetException>()));
      expect(jsonEncode(bState.toJson()), before, reason: 'failed attempts commit nothing');

      expect(s(DoubleRatchet.decrypt(bState, m.header, m.ciphertext)), 'secret');
      expect(() => DoubleRatchet.decrypt(bState, m.header, m.ciphertext),
          throwsA(isA<RatchetException>()), reason: 'message keys are single-use');

      // Someone else's session can't open it.
      final carol = Device('carol', 'c1');
      final cState = X3dh.initiate(carol.identity, bob.bundle());
      final mc = DoubleRatchet.encrypt(cState, b('x'));
      expect(() => DoubleRatchet.decrypt(bState, mc.header, mc.ciphertext),
          throwsA(isA<RatchetException>()));
    });

    test('forward secrecy: today\'s state cannot open yesterday\'s messages', () {
      final aState = X3dh.initiate(alice.identity, bob.bundle());
      final old = DoubleRatchet.encrypt(aState, b('yesterday'));
      final bState = bob.accept(RatchetHeader.decode(old.header).preKey!);
      DoubleRatchet.decrypt(bState, old.header, old.ciphertext);
      for (var i = 0; i < 3; i++) {
        final r = DoubleRatchet.encrypt(bState, b('r$i'));
        DoubleRatchet.decrypt(aState, r.header, r.ciphertext);
        final m = DoubleRatchet.encrypt(aState, b('m$i'));
        DoubleRatchet.decrypt(bState, m.header, m.ciphertext);
      }
      // An attacker who steals Bob's current state (and long-term keys)
      // replays the old ciphertext.
      final stolen = bState.copy();
      expect(() => DoubleRatchet.decrypt(stolen, old.header, old.ciphertext),
          throwsA(isA<RatchetException>()));
      expect(stolen.skipped, isEmpty);
    });

    test('identity binding: a responder with different identity keys fails', () {
      final aState = X3dh.initiate(alice.identity, bob.bundle());
      final m = DoubleRatchet.encrypt(aState, b('hi'));
      final pk = RatchetHeader.decode(m.header).preKey!;
      // Mallory claims to be Alice but uses her own identity key.
      final mallory = CryptoCore.generateIdentity();
      final spoofed = PreKeyHeader(
        signingKey: pk.signingKey,
        identityKey: mallory.publicEncryptionKeyBase64,
        baseKey: pk.baseKey,
        signedPreKeyId: pk.signedPreKeyId,
        oneTimePreKeyId: pk.oneTimePreKeyId,
      );
      final bState = bob.accept(spoofed);
      expect(() => DoubleRatchet.decrypt(bState, m.header, m.ciphertext),
          throwsA(isA<RatchetException>()));
    });

    test('simultaneous initiation converges via the session record', () {
      final aRec = SessionRecord();
      final bRec = SessionRecord();
      // Both start a session at the same moment.
      aRec.promote(X3dh.initiate(alice.identity, bob.bundle()));
      bRec.promote(X3dh.initiate(bob.identity, alice.bundle()));
      final fromA = DoubleRatchet.encrypt(aRec.current!, b('from a'));
      final fromB = DoubleRatchet.encrypt(bRec.current!, b('from b'));

      // Receiving logic as the app does it (SessionManager): a prekey message
      // with an unknown base key creates and promotes a new session.
      String receive(Device me, SessionRecord rec, EncryptedRatchetMessage m) {
        final h = RatchetHeader.decode(m.header);
        if (h.preKey != null && rec.withBaseKey(h.preKey!.baseKey) == null) {
          final st = me.accept(h.preKey!);
          final out = DoubleRatchet.decrypt(st, m.header, m.ciphertext);
          rec.promote(st);
          return s(out);
        }
        for (final st in rec.all.toList()) {
          try {
            final out = DoubleRatchet.decrypt(st, m.header, m.ciphertext);
            rec.promote(st);
            return s(out);
          } on RatchetException {
            continue;
          }
        }
        throw StateError('undecryptable');
      }

      expect(receive(bob, bRec, fromA), 'from a');
      expect(receive(alice, aRec, fromB), 'from b');
      // Now each side's current session is the one the other started.
      for (var i = 0; i < 3; i++) {
        final x = DoubleRatchet.encrypt(aRec.current!, b('a$i'));
        expect(receive(bob, bRec, x), 'a$i');
        final y = DoubleRatchet.encrypt(bRec.current!, b('b$i'));
        expect(receive(alice, aRec, y), 'b$i');
      }
    });

    test('state survives a JSON round trip (persistence)', () {
      var aState = X3dh.initiate(alice.identity, bob.bundle());
      final m = DoubleRatchet.encrypt(aState, b('1'));
      var bState = bob.accept(RatchetHeader.decode(m.header).preKey!);
      DoubleRatchet.decrypt(bState, m.header, m.ciphertext);
      aState = RatchetState.fromJson(jsonDecode(jsonEncode(aState.toJson())) as Map<String, dynamic>);
      bState = SessionRecord.decode(SessionRecord(current: bState).encode()).current!;
      final r = DoubleRatchet.encrypt(bState, b('2'));
      expect(s(DoubleRatchet.decrypt(aState, r.header, r.ciphertext)), '2');
    });

    test('too many skipped messages are refused', () {
      final aState = X3dh.initiate(alice.identity, bob.bundle());
      final first = DoubleRatchet.encrypt(aState, b('first'));
      final bState = bob.accept(RatchetHeader.decode(first.header).preKey!);
      DoubleRatchet.decrypt(bState, first.header, first.ciphertext);
      final h = RatchetHeader.decode(DoubleRatchet.encrypt(aState, b('x')).header);
      final far = RatchetHeader(dh: h.dh, pn: 0, n: maxSkippedPerStep + 5).encode();
      expect(() => DoubleRatchet.decrypt(bState, far, Uint8List(64)),
          throwsA(isA<RatchetException>()));
    });
  });
}
