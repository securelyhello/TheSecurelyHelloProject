import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/crypto/ratchet.dart';

/// Encrypted archives of chat history: backup files, and transfers to our
/// own new devices.
///
/// A backup is sealed with a random 125-bit backup key that the user writes
/// down (like Signal's): there is no passphrase to guess. File layout:
/// `SHBK1` then XSalsa20-Poly1305 (nonce + box) over gzipped JSON
/// `{v, user, created, history}`. Sessions and keys are never included.
class ChatBackup {
  static const _magic = 'SHBK1';
  static const _alphabet = 'abcdefghijkmnpqrstuvwxyz23456789'; // no l, o, 0, 1
  static const _keyChars = 25;

  /// A new backup key, e.g. `k4m9x-2pqrs-...` (5 groups of 5).
  static String newKey() {
    final r = CryptoCore.randomBytes(_keyChars);
    final chars = [for (final b in r) _alphabet[b & 31]].join();
    return [for (var i = 0; i < _keyChars; i += 5) chars.substring(i, i + 5)].join('-');
  }

  /// The key as typed: case, spaces and dashes don't matter.
  static String? normalizeKey(String typed) {
    final k = typed.toLowerCase().replaceAll(RegExp(r'[\s-]'), '');
    if (k.length != _keyChars || k.split('').any((c) => !_alphabet.contains(c))) return null;
    return k;
  }

  static Uint8List _derive(String normalizedKey) =>
      Kdf.hkdf(utf8.encode(normalizedKey), info: 'securelyhello-backup-v1', length: 32);

  /// Seals [history] (from LocalStorage.exportHistory) for [userId].
  static Future<Uint8List> seal(Map<String, dynamic> history,
          {required String userId, required String backupKey}) =>
      compute(_seal, (history, userId, normalizeKey(backupKey) ?? (throw ArgumentError('bad key'))));

  static Uint8List _seal((Map<String, dynamic>, String, String) a) {
    final (history, userId, key) = a;
    final plain = gzip.encode(utf8.encode(jsonEncode({
      'v': 1,
      'user': userId,
      'created': DateTime.now().toUtc().toIso8601String(),
      'history': history,
    })));
    final box = CryptoCore.secretEncrypt(Uint8List.fromList(plain), _derive(key));
    return Uint8List.fromList([...ascii.encode(_magic), ...box]);
  }

  /// Opens a backup file. Throws [BackupException] with a message for the
  /// user if the file, key or account is wrong.
  static Future<Map<String, dynamic>> open(Uint8List file,
      {required String userId, required String backupKey}) async {
    final key = normalizeKey(backupKey);
    if (key == null) throw const BackupException("That doesn't look like a backup key (25 letters and numbers)");
    final result = await compute(_open, (file, key));
    if (result == null) throw const BackupException("The key doesn't match this backup, or the file is damaged");
    if (result['user'] != userId) {
      throw const BackupException('This backup belongs to a different account');
    }
    final history = result['history'];
    if (history is! Map<String, dynamic>) throw const BackupException('The backup is damaged');
    return history;
  }

  static Map<String, dynamic>? _open((Uint8List, String) a) {
    final (file, key) = a;
    if (file.length < _magic.length + 40 || ascii.decode(file.sublist(0, 5), allowInvalid: true) != _magic) {
      return null;
    }
    try {
      final plain = CryptoCore.secretDecrypt(Uint8List.sublistView(file, _magic.length), _derive(key));
      final json = jsonDecode(utf8.decode(gzip.decode(plain)));
      return json is Map<String, dynamic> && json['v'] == 1 ? json : null;
    } catch (_) {
      return null;
    }
  }

  /// For a transfer to our own device: the archive, gzipped only. It is sent
  /// as an attachment, which is encrypted with a fresh key that travels end
  /// to end.
  static Uint8List packTransfer(Map<String, dynamic> history) =>
      Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode({'v': 1, 'history': history}))));

  static Map<String, dynamic> unpackTransfer(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(gzip.decode(bytes)));
      final h = json is Map ? json['history'] : null;
      if (h is Map<String, dynamic>) return h;
    } catch (_) {}
    throw const BackupException('The transferred history is damaged');
  }
}

class BackupException implements Exception {
  final String message;
  const BackupException(this.message);
  @override
  String toString() => message;
}
