import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:securelyhello/core/crypto/crypto_core.dart';

/// Minimal key/value secret backend, so tests (and the integration harness)
/// can swap the OS keystore for memory.
abstract class SecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// The platform keystore: Android Keystore, iOS/macOS Keychain, Windows
/// DPAPI, libsecret (Secret Service) on Linux.
class PlatformSecretStorage implements SecretStorage {
  final FlutterSecureStorage _storage;
  PlatformSecretStorage([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory secrets (tests; never used by the app itself).
class MemorySecretStorage implements SecretStorage {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// The persisted sign-in: an opaque bearer token plus who it belongs to (so
/// the app can start offline from its cached profile).
class StoredSession {
  final String token;
  final String userId;
  final String? email;
  const StoredSession({required this.token, required this.userId, this.email});

  Map<String, dynamic> toJson() =>
      {'token': token, 'user_id': userId, if (email != null) 'email': email};

  static StoredSession? fromJson(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final token = m['token'] as String?;
      final userId = m['user_id'] as String?;
      if (token == null || userId == null) return null;
      return StoredSession(
          token: token, userId: userId, email: m['email'] as String?);
    } catch (_) {
      return null;
    }
  }
}

/// Where the directory client keeps its session token.
abstract class SessionTokenStore {
  Future<StoredSession?> loadSession();
  Future<void> saveSession(StoredSession session);
  Future<void> clearSession();
}

/// Stores private key material and the session token in the platform
/// keystore.
///
/// Keys are namespaced by user id so several accounts can share a device
/// without seeing each other's keys, and by an optional [namespace] (the
/// `SH_PROFILE` launch profile) so two app instances on one machine never
/// share a session or keys.
class SecureKeyStore implements SessionTokenStore {
  final SecretStorage _storage;
  final String _ns;

  SecureKeyStore({SecretStorage? storage, String namespace = ''})
      : _storage = storage ?? PlatformSecretStorage(),
        _ns = namespace.isEmpty ? '' : '${namespace}_';

  String _identityKey(String userId) => 'sh_${_ns}identity_$userId';
  String _dbKey(String userId) => 'sh_${_ns}localdb_key_$userId';
  String get _sessionKey => 'sh_${_ns}session';

  // ---------------------------------------------------------------------------
  // Identity (Ed25519 + X25519 private keys)
  // ---------------------------------------------------------------------------

  Future<CryptoIdentity?> loadIdentity(String userId) async {
    final raw = await _storage.read(_identityKey(userId));
    if (raw == null) return null;
    try {
      final map = (jsonDecode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as String?));
      return CryptoIdentity.fromMap(map);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveIdentity(String userId, CryptoIdentity identity) =>
      _storage.write(_identityKey(userId), jsonEncode(identity.toMap()));

  // ---------------------------------------------------------------------------
  // Local database encryption key
  // ---------------------------------------------------------------------------

  /// Returns the 32-byte key that encrypts message bodies in SQLite,
  /// generating one on first use.
  Future<Uint8List> getOrCreateLocalDbKey(String userId) async {
    final existing = await _storage.read(_dbKey(userId));
    if (existing != null) return CryptoCore.fromBase64(existing);

    final key = CryptoCore.randomBytes(32);
    await _storage.write(_dbKey(userId), CryptoCore.toBase64(key));
    return key;
  }

  // ---------------------------------------------------------------------------
  // Session token
  // ---------------------------------------------------------------------------

  @override
  Future<StoredSession?> loadSession() async {
    final raw = await _storage.read(_sessionKey);
    return raw == null ? null : StoredSession.fromJson(raw);
  }

  @override
  Future<void> saveSession(StoredSession session) =>
      _storage.write(_sessionKey, jsonEncode(session.toJson()));

  @override
  Future<void> clearSession() => _storage.delete(_sessionKey);

  /// Device-wide settings that must survive sign-out (app lock), namespaced
  /// by launch profile.
  Future<String?> readSetting(String name) => _storage.read('sh_${_ns}setting_$name');
  Future<void> writeSetting(String name, String value) =>
      _storage.write('sh_${_ns}setting_$name', value);
  Future<void> deleteSetting(String name) => _storage.delete('sh_${_ns}setting_$name');

  // ---------------------------------------------------------------------------
  // Wipe
  // ---------------------------------------------------------------------------

  /// Removes every secret belonging to [userId] (account deletion).
  Future<void> deleteAll(String userId) async {
    await _storage.delete(_identityKey(userId));
    await _storage.delete(_dbKey(userId));
  }
}
