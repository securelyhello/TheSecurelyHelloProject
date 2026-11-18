import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:securelyhello/core/chat/wire_protocol.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/crypto/device_manager.dart';
import 'package:securelyhello/core/crypto/session_manager.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';

/// The prekey directory, in memory (what server/src/devices.js does).
class FakeServer {
  final Map<String, Map<String, Map<String, dynamic>>> devices = {}; // user → device → record
  int _next = 0;

  List<Map<String, dynamic>> devicesOf(String userId) => [
        for (final d in (devices[userId] ?? {}).values)
          {
            'device_id': d['device_id'],
            'signing_public_key': d['signing_public_key'],
            'identity_public_key': d['identity_public_key'],
          }
      ];
}

class FakeDirectory extends DirectoryService {
  final FakeServer server;
  final String userId;
  String? deviceId;

  FakeDirectory(this.server, this.userId)
      : super(baseUrl: 'https://fake.invalid', tokenStore: SecureKeyStore(storage: MemorySecretStorage()));

  @override
  Future<Map<String, dynamic>> registerDevice({
    String? deviceId,
    required String name,
    required String signingKey,
    required String identityKey,
    required Map<String, dynamic> signedPreKey,
    List<Map<String, dynamic>> oneTimePreKeys = const [],
    String? proof,
  }) async {
    final mine = server.devices.putIfAbsent(userId, () => {});
    final id = this.deviceId ??
        (deviceId != null && mine.containsKey(deviceId) ? deviceId : 'dev${server._next++}');
    final rec = mine.putIfAbsent(id, () => {'device_id': id, 'otpks': <Map<String, dynamic>>[]});
    rec['signing_public_key'] = signingKey;
    rec['identity_public_key'] = identityKey;
    rec['spk'] = signedPreKey;
    (rec['otpks'] as List).addAll(oneTimePreKeys);
    this.deviceId = id;
    return {'device_id': id, 'prekeys_remaining': (rec['otpks'] as List).length};
  }

  @override
  Future<Map<String, dynamic>> getCurrentDevice() async => {
        'device_id': deviceId,
        'prekeys_remaining': (server.devices[userId]![deviceId]!['otpks'] as List).length,
      };

  @override
  Future<int> uploadPreKeys(List<Map<String, dynamic>> keys) async {
    final list = server.devices[userId]![deviceId]!['otpks'] as List;
    list.addAll(keys);
    return list.length;
  }

  @override
  Future<void> rotateSignedPreKey(Map<String, dynamic> spk) async {
    server.devices[userId]![deviceId]!['spk'] = spk;
  }

  @override
  Future<List<Map<String, dynamic>>> getUserDevices(String userId) async => server.devicesOf(userId);

  @override
  Future<List<Map<String, dynamic>>> claimPreKeyBundles(String userId, List<String> deviceIds) async => [
        for (final id in deviceIds)
          if (server.devices[userId]?[id] case final d?)
            {
              'device_id': id,
              'signing_public_key': d['signing_public_key'],
              'identity_public_key': d['identity_public_key'],
              'signed_prekey': d['spk'],
              'one_time_prekey': (d['otpks'] as List).isEmpty ? null : (d['otpks'] as List).removeAt(0),
            }
      ];
}

/// One app install: identity, local DB, device registration, sessions.
class Install {
  final String userId;
  final FakeDirectory directory;
  final LocalStorage storage;
  final CryptoIdentity identity = CryptoCore.generateIdentity();
  late final String deviceId;
  late final SessionManager sessions;
  final changes = <String>[];

  Install._(this.userId, this.directory, this.storage);

  static Future<Install> create(FakeServer server, String userId) async {
    final dir = await Directory.systemTemp.createTemp('sh_sm_');
    final storage = LocalStorage(databaseFactory: databaseFactoryFfi, baseDirectory: () async => dir.path);
    await storage.openForUser(userId, encryptionKey: CryptoCore.randomBytes(32));
    final i = Install._(userId, FakeDirectory(server, userId), storage);
    i.deviceId = await DeviceManager(storage: storage, directory: i.directory).register(i.identity);
    i.sessions = SessionManager(
      storage: storage,
      directory: i.directory,
      identity: i.identity,
      myUserId: userId,
      myDeviceId: i.deviceId,
      onDevicesChanged: (u, c) => i.changes.add('$u +${c.added.length} -${c.removed.length} ~${c.changed.length}'),
    );
    return i;
  }

  /// Seals a text message for every device of [to]; returns envelopes by device.
  Future<Map<String, WireEnvelope>> send(String to, String text, {String id = 'm'}) async {
    final targets = await sessions.devices(to, refresh: true);
    return sessions.seal(
      to,
      targets,
      to == userId
          ? WirePayload.sentSync(me: userId, conversation: 'peer', messageId: id, timestampMs: 1, body: text)
          : WirePayload.message(messageId: id, from: userId, to: to, timestampMs: 1, body: text),
      envelopeId: id,
    );
  }

  Future<String> receive(WireEnvelope env) async => (await sessions.open(env)).body!;
}

void main() {
  sqfliteFfiInit();

  late FakeServer server;
  setUp(() => server = FakeServer());

  test('registration stocks 100 one-time prekeys and a signed prekey', () async {
    final a = await Install.create(server, 'alice');
    final rec = server.devices['alice']![a.deviceId]!;
    expect((rec['otpks'] as List).length, DeviceManager.target);
    expect(rec['identity_public_key'], a.identity.publicEncryptionKeyBase64);
    expect(await a.storage.getPreKey('otpk', 1), isNotNull, reason: 'private halves kept locally');
  });

  test('a message reaches every device of the recipient, each with its own session', () async {
    final alice = await Install.create(server, 'alice');
    final bob1 = await Install.create(server, 'bob');
    final bob2 = await Install.create(server, 'bob');

    final out = await alice.send('bob', 'hello both');
    expect(out.keys.toSet(), {bob1.deviceId, bob2.deviceId});
    expect(out[bob1.deviceId]!.ciphertextBase64, isNot(out[bob2.deviceId]!.ciphertextBase64));
    expect(await bob1.receive(out[bob1.deviceId]!), 'hello both');
    expect(await bob2.receive(out[bob2.deviceId]!), 'hello both');

    // A device can't open the copy meant for its sibling.
    await expectLater(bob1.receive(out[bob2.deviceId]!), throwsA(isA<UndecryptableException>()));

    // Replies, both ways, many times (ratchet keeps turning).
    for (var i = 0; i < 5; i++) {
      final r = await bob2.send('alice', 'reply $i', id: 'r$i');
      expect(await alice.receive(r[alice.deviceId]!), 'reply $i');
      final m = await alice.send('bob', 'msg $i', id: 'a$i');
      expect(await bob1.receive(m[bob1.deviceId]!), 'msg $i');
      expect(await bob2.receive(m[bob2.deviceId]!), 'msg $i');
    }
  });

  test('sync copies go to our other devices only', () async {
    final a1 = await Install.create(server, 'alice');
    final a2 = await Install.create(server, 'alice');
    final out = await a1.send('alice', 'sent from laptop');
    expect(out.keys, [a2.deviceId], reason: 'never to itself');
    final payload = await a2.sessions.open(out[a2.deviceId]!);
    expect(payload.kind, PayloadKind.sync);
    expect(payload.body, 'sent from laptop');
  });

  test('one-time prekeys are consumed; a redelivered first message is undecryptable', () async {
    final alice = await Install.create(server, 'alice');
    final bob = await Install.create(server, 'bob');
    final out = await alice.send('bob', 'first');
    final env = out[bob.deviceId]!;
    expect(await bob.receive(env), 'first');
    // Same ciphertext again (relay redelivery after a crash, or a replay).
    await expectLater(bob.receive(env), throwsA(isA<UndecryptableException>()));
  });

  // Audit run 1, U4-1: without a one-time prekey, a replayed first message
  // used to decrypt again once a failure had reset the session.
  test('a replayed session start never decrypts again, even after a reset', () async {
    final alice = await Install.create(server, 'alice');
    final bob = await Install.create(server, 'bob');
    (server.devices['bob']![bob.deviceId]!['otpks'] as List).clear(); // relay withholds them
    final env = (await alice.send('bob', 'first'))[bob.deviceId]!;
    expect(await bob.receive(env), 'first');
    await expectLater(bob.receive(env), throwsA(isA<UndecryptableException>()));
    await bob.sessions.resetSession(env.senderAddress);
    await expectLater(bob.receive(env), throwsA(isA<UndecryptableException>()));
  });

  test('a prekey message claiming someone else\'s identity is refused', () async {
    final alice = await Install.create(server, 'alice');
    final bob = await Install.create(server, 'bob');
    final out = await alice.send('bob', 'hi');
    // The server (or a network attacker) re-labels it as from another device.
    final carol = await Install.create(server, 'carol');
    final env = out[bob.deviceId]!;
    final relabelled = WireEnvelope(
      id: env.id,
      senderId: 'carol',
      senderDevice: carol.deviceId,
      recipientDevice: env.recipientDevice,
      timestampMs: env.timestampMs,
      header: env.header,
      ciphertextBase64: env.ciphertextBase64,
    );
    await expectLater(bob.receive(relabelled), throwsA(isA<UndecryptableException>()));
  });

  test('device changes are reported and void old sessions', () async {
    final alice = await Install.create(server, 'alice');
    final bob = await Install.create(server, 'bob');
    final m = await alice.send('bob', 'one');
    await bob.receive(m[bob.deviceId]!);
    expect(alice.changes, isEmpty, reason: 'first fetch is not a change');

    final bob2 = await Install.create(server, 'bob');
    final m2 = await alice.send('bob', 'two', id: 'm2');
    expect(alice.changes, ['bob +1 -0 ~0']);
    expect(await bob2.receive(m2[bob2.deviceId]!), 'two');
    expect(await bob.receive(m2[bob.deviceId]!), 'two', reason: 'existing session kept');

    // Bob's first device reinstalls (same id, new keys).
    final rec = server.devices['bob']![bob.deviceId]!;
    final fresh = CryptoCore.generateIdentity();
    rec['signing_public_key'] = fresh.publicSigningKeyBase64;
    rec['identity_public_key'] = fresh.publicEncryptionKeyBase64;
    await alice.sessions.devices('bob', refresh: true);
    expect(alice.changes.last, 'bob +0 -0 ~1');
    expect(await alice.storage.getSessionRecord('bob:${bob.deviceId}'), isNull);
  });

  test('sessions persist across a restart of the session manager', () async {
    final alice = await Install.create(server, 'alice');
    final bob = await Install.create(server, 'bob');
    await bob.receive((await alice.send('bob', 'before'))[bob.deviceId]!);
    final restarted = SessionManager(
      storage: bob.storage,
      directory: bob.directory,
      identity: bob.identity,
      myUserId: 'bob',
      myDeviceId: bob.deviceId,
    );
    final r = await restarted.seal('alice', await restarted.devices('alice'),
        WirePayload.message(messageId: 'x', from: 'bob', to: 'alice', timestampMs: 1, body: 'after'),
        envelopeId: 'x');
    expect(await alice.receive(r[alice.deviceId]!), 'after');
    final stored = await bob.storage.getSessionRecord('alice:${alice.deviceId}');
    expect(stored, isNotNull);
    expect(stored!.contains(base64Encode(bob.identity.encryptionPrivateKeyBytes)), isFalse,
        reason: 'identity private key is not in the session record');
  });

  test('envelopes are not decrypted by the wrong device', () async {
    final alice = await Install.create(server, 'alice');
    final bob = await Install.create(server, 'bob');
    final out = await alice.send('bob', 'x');
    final env = out[bob.deviceId]!;
    final misrouted = WireEnvelope.fromJson({...env.toJson(), 'rd': 'someone-else'});
    await expectLater(bob.sessions.open(misrouted), throwsA(isA<UndecryptableException>()));
  });
}
