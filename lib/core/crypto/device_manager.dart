import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/crypto/ratchet.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

/// Registers this device with the server and keeps its prekeys stocked.
///
/// * The device id lives in the account's local database, together with the
///   sessions and prekeys it belongs to; losing the database means becoming
///   a new device.
/// * One-time prekeys: kept at [target]; topped up when fewer than
///   [lowWater] remain on the server. Ids are never reused.
/// * The signed prekey rotates every [rotateAfter]; old ones are kept for
///   [keepOldFor] so messages already in flight can still be opened.
class DeviceManager {
  static const target = 100;
  static const lowWater = 30;
  static const rotateAfter = Duration(days: 7);
  static const keepOldFor = Duration(days: 30);

  final LocalStorage _storage;
  final DirectoryService _directory;
  bool _toppingUp = false;

  DeviceManager({required LocalStorage storage, required DirectoryService directory})
      : _storage = storage,
        _directory = directory;

  /// A readable default name, e.g. "Linux · my-laptop" or "Android".
  static String defaultName() {
    try {
      final os = Platform.isAndroid
          ? 'Android'
          : Platform.isIOS
              ? 'iPhone'
              : Platform.isMacOS
                  ? 'Mac'
                  : Platform.isWindows
                      ? 'Windows'
                      : Platform.isLinux
                          ? 'Linux'
                          : 'Device';
      if (Platform.isAndroid || Platform.isIOS) return os;
      final host = Platform.localHostname.split('.').first;
      return host.isEmpty ? os : '$os · $host';
    } catch (_) {
      return 'Device';
    }
  }

  /// Whether this device was approved, as last known (offline start).
  Future<bool> storedApproved() async => await _storage.kvGet('device_approved') != '0';

  Future<void> markApproved() => _storage.kvSet('device_approved', '1');

  /// The device id stored for this account, if registered before.
  Future<String?> storedDeviceId() => _storage.kvGet('device_id');

  /// Whether this device was approved when last registered.
  bool lastApproved = false;

  /// What an approving device signs (matches server/src/devices.js).
  static String approvalMessage(
          String userId, String deviceId, String signingKey, String identityKey) =>
      'securelyhello-approve-v1|$userId|$deviceId|$signingKey|$identityKey';

  /// What a device signs to take itself back in a new session (matches
  /// server/src/devices.js, deviceProofMessage).
  static String proofMessage(String userId, String deviceId, String tokenHash,
          String signingKey, String identityKey) =>
      'securelyhello-device-proof-v1|$userId|$deviceId|$tokenHash|$signingKey|$identityKey';

  String? _proof(CryptoIdentity identity, String deviceId) {
    final userId = _directory.myUserId;
    final tokenHash = _directory.sessionTokenHash;
    if (userId == null || tokenHash == null) return null;
    final msg = proofMessage(userId, deviceId, tokenHash, identity.publicSigningKeyBase64,
        identity.publicEncryptionKeyBase64);
    final signed = identity.signingKey.sign(Uint8List.fromList(utf8.encode(msg)));
    return base64Encode(Uint8List.fromList(signed.signature));
  }

  /// Our device's signature approving another device of the account.
  static String signApproval(CryptoIdentity me, String userId, String deviceId,
      String signingKey, String identityKey) {
    final signed = me.signingKey.sign(Uint8List.fromList(
        utf8.encode(approvalMessage(userId, deviceId, signingKey, identityKey))));
    return base64Encode(Uint8List.fromList(signed.signature));
  }

  /// Short fingerprint of a device key for people to compare.
  static String fingerprint(String signingKey) {
    final h = Kdf.sha256(base64Decode(signingKey));
    final hex = h.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    return [for (var i = 0; i < 16; i += 4) hex.substring(i, i + 4)].join(' ');
  }

  /// Registers (or re-binds) this device; returns its id.
  Future<String> register(CryptoIdentity identity, {String? name}) async {
    final stored = await storedDeviceId();
    final spk = await _currentSignedPreKey(identity);
    final fresh = stored == null;
    var res = await _directory.registerDevice(
      deviceId: stored,
      proof: stored == null ? null : _proof(identity, stored),
      name: name ?? defaultName(),
      signingKey: identity.publicSigningKeyBase64,
      identityKey: identity.publicEncryptionKeyBase64,
      signedPreKey: spk,
      oneTimePreKeys: fresh ? await _newOneTimePreKeys(target) : const [],
    );
    final id = res['device_id'] as String;
    if (stored != null && stored != id) {
      // Our old device was removed (unlinked elsewhere): start over as a
      // new device with fresh prekeys and no sessions.
      debugPrint('Device $stored is gone; registered as $id');
      await _storage.resetDeviceState();
      res = await _directory.registerDevice(
        deviceId: id,
        name: name ?? defaultName(),
        signingKey: identity.publicSigningKeyBase64,
        identityKey: identity.publicEncryptionKeyBase64,
        signedPreKey: await _currentSignedPreKey(identity),
        oneTimePreKeys: await _newOneTimePreKeys(target),
      );
    }
    await _storage.kvSet('device_id', id);
    lastApproved = res['approved'] != false;
    await _storage.kvSet('device_approved', lastApproved ? '1' : '0');
    await topUp(remaining: res['prekeys_remaining'] as int?);
    await maybeRotate(identity);
    return id;
  }

  /// Uploads one-time prekeys until the server holds [target].
  Future<void> topUp({int? remaining}) async {
    if (_toppingUp) return;
    _toppingUp = true;
    try {
      final have =
          remaining ?? (await _directory.getCurrentDevice())['prekeys_remaining'] as int;
      if (have >= lowWater) return;
      await _directory.uploadPreKeys(await _newOneTimePreKeys(target - have));
    } catch (e) {
      debugPrint('Prekey top-up failed: $e');
    } finally {
      _toppingUp = false;
    }
  }

  /// Rotates the signed prekey once it is older than [rotateAfter].
  Future<void> maybeRotate(CryptoIdentity identity) async {
    try {
      final currentId = int.tryParse(await _storage.kvGet('spk_id') ?? '');
      if (currentId == null) return;
      final current = await _storage.getPreKey('spk', currentId);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (current != null && now - current.createdAt < rotateAfter.inMilliseconds) {
        return;
      }
      final next = await _generateSignedPreKey(identity);
      await _directory.rotateSignedPreKey(next);
      await _storage.kvSet('spk_id', '${next['id']}');
      await _storage.deletePreKeysBefore('spk', now - keepOldFor.inMilliseconds,
          keep: next['id'] as int);
    } catch (e) {
      debugPrint('Signed prekey rotation failed: $e');
    }
  }

  Future<Map<String, dynamic>> _currentSignedPreKey(CryptoIdentity identity) async {
    final id = int.tryParse(await _storage.kvGet('spk_id') ?? '');
    if (id != null) {
      final row = await _storage.getPreKey('spk', id);
      if (row != null) {
        return {
          'id': id,
          'key': row.public,
          'signature': signPreKey(identity, id, CryptoCore.fromBase64(row.public)),
        };
      }
    }
    final spk = await _generateSignedPreKey(identity);
    await _storage.kvSet('spk_id', '${spk['id']}');
    return spk;
  }

  Future<Map<String, dynamic>> _generateSignedPreKey(CryptoIdentity identity) async {
    final id = await _storage.maxPreKeyId('spk') + 1;
    final pair = DhKeyPair.generate();
    await _storage.insertPreKeys('spk', [
      (id: id, private: CryptoCore.toBase64(pair.privateKey), public: pair.publicBase64)
    ]);
    return {
      'id': id,
      'key': pair.publicBase64,
      'signature': signPreKey(identity, id, pair.publicKey),
    };
  }

  Future<List<Map<String, dynamic>>> _newOneTimePreKeys(int count) async {
    if (count <= 0) return const [];
    final first = int.tryParse(await _storage.kvGet('otpk_next') ?? '') ?? 1;
    final keys = [
      for (var i = 0; i < count; i++) (id: first + i, pair: DhKeyPair.generate())
    ];
    await _storage.insertPreKeys('otpk', [
      for (final k in keys)
        (
          id: k.id,
          private: CryptoCore.toBase64(k.pair.privateKey),
          public: k.pair.publicBase64,
        )
    ]);
    await _storage.kvSet('otpk_next', '${first + count}');
    return [for (final k in keys) {'id': k.id, 'key': k.pair.publicBase64}];
  }
}
