import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:securelyhello/core/chat/wire_protocol.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/crypto/ratchet.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

/// An envelope that can't be opened: wrong or missing session, bad header,
/// tampered, or the sender's identity doesn't match the directory.
class UndecryptableException implements Exception {
  final String reason;
  const UndecryptableException(this.reason);
  @override
  String toString() => 'Undecryptable: $reason';
}

/// How a user's device list changed since we last looked.
class DeviceListChange {
  final List<String> added;
  final List<String> removed;

  /// Same device id, different keys (reinstalled).
  final List<String> changed;
  const DeviceListChange(this.added, this.removed, this.changed);
  bool get isEmpty => added.isEmpty && removed.isEmpty && changed.isEmpty;
}

/// Owns the Double Ratchet sessions of this device with every other device
/// (contacts' and our own), backed by the encrypted local database.
///
/// All work on one remote device (address `user:device`) is serialized, so
/// a send and a receive never interleave on the same ratchet state.
class SessionManager {
  static const deviceListTtl = Duration(minutes: 30);

  final LocalStorage _storage;
  final DirectoryService _directory;
  final CryptoIdentity identity;
  final String myUserId;
  final String myDeviceId;

  /// Called when a user's devices were added, removed or re-keyed.
  final void Function(String userId, DeviceListChange change)? onDevicesChanged;

  final Map<String, Future<void>> _tails = {};
  final Map<String, Future<List<DeviceKeys>>> _deviceFetches = {};

  SessionManager({
    required LocalStorage storage,
    required DirectoryService directory,
    required this.identity,
    required this.myUserId,
    required this.myDeviceId,
    this.onDevicesChanged,
  })  : _storage = storage,
        _directory = directory;

  String get myAddress => '$myUserId:$myDeviceId';

  /// Runs [fn] after every earlier task for [key] has finished.
  Future<T> _serial<T>(String key, Future<T> Function() fn) {
    final previous = _tails[key] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[key] = done.future;
    return previous.then((_) => fn()).whenComplete(() {
      done.complete();
      if (identical(_tails[key], done.future)) _tails.remove(key);
    });
  }

  // ===========================================================================
  // Device lists
  // ===========================================================================

  /// [userId]'s devices, from the cache unless it is stale or [refresh].
  /// For ourselves, this device is left out (it is never a recipient).
  Future<List<DeviceKeys>> devices(String userId, {bool refresh = false}) async {
    if (!refresh) {
      final at = await _storage.peerDevicesFetchedAt(userId);
      if (at != null &&
          DateTime.now().millisecondsSinceEpoch - at <
              deviceListTtl.inMilliseconds) {
        return _cachedDevices(userId);
      }
    }
    // Coalesce concurrent refreshes of the same user.
    final inFlight = _deviceFetches[userId];
    if (inFlight != null) return inFlight;
    final fetch = _fetchDevices(userId);
    _deviceFetches[userId] = fetch;
    try {
      return await fetch;
    } finally {
      _deviceFetches.remove(userId);
    }
  }

  Future<List<DeviceKeys>> _cachedDevices(String userId) async {
    final rows = await _storage.getPeerDevices(userId);
    return [
      for (final r in rows)
        if (!(userId == myUserId && r['device_id'] == myDeviceId))
          DeviceKeys(
            userId: userId,
            deviceId: r['device_id'] as String,
            signingKey: r['signing_key'] as String,
            identityKey: r['identity_key'] as String,
          ),
    ];
  }

  Future<List<DeviceKeys>> _fetchDevices(String userId) async {
    List<Map<String, dynamic>> rows;
    try {
      rows = await _directory.getUserDevices(userId);
    } on NetworkException {
      // Offline: whatever we knew is better than nothing.
      if (await _storage.peerDevicesFetchedAt(userId) != null) {
        return _cachedDevices(userId);
      }
      rethrow;
    }
    final change = await _storage.replacePeerDevices(userId, [
      for (final r in rows)
        (
          deviceId: r['device_id'] as String,
          signingKey: r['signing_public_key'] as String,
          identityKey: r['identity_public_key'] as String,
        ),
    ]);
    // Sessions with removed or re-keyed devices are void. (Not serialized:
    // this can run inside open() for the same address.)
    for (final d in [...change.removed, ...change.changed]) {
      await _storage.deleteSessionRecord('$userId:$d');
    }
    final diff = DeviceListChange(change.added, change.removed, change.changed);
    if (!diff.isEmpty) onDevicesChanged?.call(userId, diff);
    return _cachedDevices(userId);
  }

  /// All device keys of [userId] including, for ourselves, this device.
  Future<List<DeviceKeys>> allDeviceKeys(String userId) async {
    final list = await devices(userId);
    if (userId != myUserId) return list;
    return [
      DeviceKeys(
        userId: myUserId,
        deviceId: myDeviceId,
        signingKey: identity.publicSigningKeyBase64,
        identityKey: identity.publicEncryptionKeyBase64,
      ),
      ...list,
    ];
  }

  // ===========================================================================
  // Sending
  // ===========================================================================

  /// Seals [payload] once for each of [targets] (all devices of [userId]).
  /// Starts sessions (X3DH) with devices we have none with yet.
  Future<Map<String, WireEnvelope>> seal(
    String userId,
    List<DeviceKeys> targets,
    WirePayload payload, {
    required String envelopeId,
  }) async {
    await _ensureSessions(userId, targets);
    final out = <String, WireEnvelope>{};
    final plain = payload.encode();
    for (final d in targets) {
      final env = await _serial(d.address, () async {
        final record = await _load(d.address);
        final state = record?.current;
        if (state == null) return null; // no bundle (device just removed)
        final m = DoubleRatchet.encrypt(state, plain);
        await _save(d.address, record!);
        return WireEnvelope(
          id: envelopeId,
          senderId: myUserId,
          senderDevice: myDeviceId,
          recipientDevice: d.deviceId,
          timestampMs: payload.timestampMs,
          header: m.header,
          ciphertextBase64: base64Encode(m.ciphertext),
        );
      });
      if (env != null) out[d.deviceId] = env;
    }
    return out;
  }

  Future<void> _ensureSessions(String userId, List<DeviceKeys> targets) async {
    final missing = <DeviceKeys>[];
    for (final d in targets) {
      if ((await _load(d.address))?.current == null) missing.add(d);
    }
    if (missing.isEmpty) return;
    final bundles = await _directory.claimPreKeyBundles(
        userId, missing.map((d) => d.deviceId).toList());
    for (final raw in bundles) {
      final bundle = PreKeyBundle.fromJson(userId, raw);
      final known = missing.where((d) => d.deviceId == bundle.device.deviceId);
      if (known.isEmpty) continue;
      final d = known.first;
      // The bundle must belong to the device whose keys we cached (and show
      // in the safety number).
      if (bundle.device.signingKey != d.signingKey ||
          bundle.device.identityKey != d.identityKey) {
        await _storage.invalidatePeerDevices(userId);
        continue;
      }
      await _serial(d.address, () async {
        final record = await _load(d.address) ?? SessionRecord();
        if (record.current != null) return; // raced with an incoming session
        record.promote(X3dh.initiate(identity, bundle));
        await _save(d.address, record);
      });
    }
  }

  // ===========================================================================
  // Receiving
  // ===========================================================================

  /// Decrypts [env] (addressed to this device) and returns its payload.
  /// Throws [UndecryptableException]; network errors propagate (retry later).
  Future<WirePayload> open(WireEnvelope env) async {
    if (env.recipientDevice != myDeviceId) {
      throw const UndecryptableException('addressed to another device');
    }
    return _serial(env.senderAddress, () async {
      RatchetHeader header;
      Uint8List ciphertext;
      try {
        header = RatchetHeader.decode(env.header);
        ciphertext = base64Decode(env.ciphertextBase64);
      } on FormatException {
        throw const UndecryptableException('malformed envelope');
      }
      final record = await _load(env.senderAddress) ?? SessionRecord();
      Uint8List plain;

      final pk = header.preKey;
      final existing = pk == null ? null : record.withBaseKey(pk.baseKey);
      if (pk != null && existing == null) {
        plain = await _openNewSession(env, record, header, pk, ciphertext);
      } else {
        plain = _openExisting(record, existing, env.header, ciphertext);
      }
      await _save(env.senderAddress, record);

      WirePayload payload;
      try {
        payload = WirePayload.decode(plain);
      } catch (_) {
        throw const UndecryptableException('malformed payload');
      }
      if (payload.from != env.senderId || payload.to != myUserId) {
        throw const UndecryptableException('payload addressed to someone else');
      }
      return payload;
    });
  }

  Uint8List _openExisting(SessionRecord record, RatchetState? preferred,
      String header, Uint8List ciphertext) {
    final candidates = [?preferred, ...record.all.where((s) => !identical(s, preferred))];
    for (final state in candidates) {
      try {
        final plain = DoubleRatchet.decrypt(state, header, ciphertext);
        record.promote(state);
        return plain;
      } on RatchetException {
        continue;
      }
    }
    throw UndecryptableException(
        candidates.isEmpty ? 'no session' : 'no session could decrypt it');
  }

  Future<Uint8List> _openNewSession(WireEnvelope env, SessionRecord record,
      RatchetHeader header, PreKeyHeader pk, Uint8List ciphertext) async {
    // The identity in the header must be the one the directory publishes
    // for this device (and that the safety number covers).
    var known = (await devices(env.senderId))
        .where((d) => d.deviceId == env.senderDevice);
    if (known.isEmpty ||
        known.first.signingKey != pk.signingKey ||
        known.first.identityKey != pk.identityKey) {
      known = (await devices(env.senderId, refresh: true))
          .where((d) => d.deviceId == env.senderDevice);
    }
    if (known.isEmpty ||
        known.first.signingKey != pk.signingKey ||
        known.first.identityKey != pk.identityKey) {
      throw const UndecryptableException('sender identity does not match');
    }

    // A base key starts one session, once. Without this, a relay could
    // replay a first message after a session reset and have it decrypt again
    // (audit run 1, U4-1).
    final usedKey = 'basekey:${env.senderAddress}:${pk.baseKey}';
    if (await _storage.kvGet(usedKey) != null) {
      throw const UndecryptableException('replayed session start');
    }

    final spk = await _storage.getPreKey('spk', pk.signedPreKeyId);
    if (spk == null) throw const UndecryptableException('signed prekey is gone');
    DhKeyPair? opk;
    if (pk.oneTimePreKeyId != null) {
      final row = await _storage.getPreKey('otpk', pk.oneTimePreKeyId!);
      if (row == null) {
        throw const UndecryptableException('one-time prekey already used');
      }
      opk = DhKeyPair.fromPrivate(base64Decode(row.private));
    }

    RatchetState state;
    Uint8List plain;
    try {
      state = X3dh.respond(
        me: identity,
        header: pk,
        signedPreKey: DhKeyPair.fromPrivate(base64Decode(spk.private)),
        oneTimePreKey: opk,
      );
      plain = DoubleRatchet.decrypt(state, env.header, ciphertext);
    } on RatchetException catch (e) {
      throw UndecryptableException(e.message);
    }
    record.promote(state);
    await _storage.kvSet(usedKey, '${DateTime.now().millisecondsSinceEpoch}');
    if (pk.oneTimePreKeyId != null) {
      await _storage.deletePreKey('otpk', pk.oneTimePreKeyId!);
    }
    return plain;
  }

  /// Forget our session with one device: the next message starts afresh.
  Future<void> resetSession(String address) =>
      _serial(address, () => _storage.deleteSessionRecord(address));

  // ===========================================================================
  // Persistence
  // ===========================================================================

  Future<SessionRecord?> _load(String address) async {
    final raw = await _storage.getSessionRecord(address);
    if (raw == null) return null;
    try {
      return SessionRecord.decode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(String address, SessionRecord record) =>
      _storage.saveSessionRecord(address, record.encode());
}
