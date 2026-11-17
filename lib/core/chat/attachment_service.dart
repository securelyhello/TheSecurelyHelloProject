import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import 'package:securelyhello/core/chat/file_string_codec.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/networking/directory_service.dart';

/// The file is bigger than the server accepts.
class AttachmentTooLargeException implements Exception {
  final int size;
  const AttachmentTooLargeException(this.size);
  @override
  String toString() =>
      'Files can be at most ${AttachmentService.maxBytes ~/ (1024 * 1024)} MB';
}

/// The downloaded bytes don't match the digest in the message.
class AttachmentCorruptException implements Exception {
  const AttachmentCorruptException();
  @override
  String toString() => 'The attachment was damaged in transit';
}

/// Encrypted attachments.
///
/// Small files travel *inside* the message: they are converted to an FTS1
/// string (see `file_string_codec.dart`) that rides in the end-to-end
/// encrypted payload, so nothing is uploaded or stored on the server. A file
/// whose FTS1 string is longer than [inlineMaxChars] is uploaded instead:
///
/// Sending: the file is encrypted on the device with a fresh random 32-byte
/// key (XSalsa20-Poly1305 secretbox), and only the ciphertext is uploaded.
/// The returned metadata (blob id, key, SHA-256 of the ciphertext, name,
/// type, size) goes inside the end-to-end encrypted message, so the server
/// never learns the key, the name or the type.
///
/// Receiving: the ciphertext is downloaded, checked against the digest,
/// decrypted, and cached on disk *still encrypted* (its key lives only in
/// the message row, which is itself encrypted at rest).
class AttachmentService {
  /// Server default is 16 MB per blob (ATTACHMENT_MAX_MB); secretbox adds 40.
  static const maxBytes = 16 * 1024 * 1024 - 64;

  /// Largest FTS1 string sent inside a message. Encrypted and wrapped it
  /// stays well under the server's 128 KB per-envelope limit.
  static const inlineMaxChars = 48 * 1024;

  /// Whether [meta] describes a file carried inside the message.
  static bool isInline(Map<String, dynamic> meta) => meta['inline'] is String;

  /// Images up to this size are fetched as soon as they are shown.
  static const autoDownloadBytes = 8 * 1024 * 1024;

  final DirectoryService _directory;
  final Future<String?> Function() _cacheDir;

  /// Decrypted bytes of recently viewed attachments (bounded).
  final LinkedHashMap<String, Uint8List> _memory = LinkedHashMap();
  int _memoryBytes = 0;
  static const _memoryLimit = 48 * 1024 * 1024;
  final Map<String, Future<Uint8List>> _inFlight = {};

  AttachmentService({
    required DirectoryService directory,
    required Future<String?> Function() cacheDirectory,
  })  : _directory = directory,
        _cacheDir = cacheDirectory;

  static String mimeFor(String name, [List<int>? header]) =>
      lookupMimeType(name, headerBytes: header) ?? 'application/octet-stream';

  static bool isImage(Map<String, dynamic> meta) {
    final mime = meta['mime'] as String? ?? '';
    // Only formats Flutter can decode.
    return const ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/bmp']
        .contains(mime);
  }

  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Prepares [bytes] for sending and returns the metadata that goes into
  /// the message: the file itself as an FTS1 string when it is small,
  /// otherwise the blob id and key of an encrypted upload.
  Future<Map<String, dynamic>> upload(Uint8List bytes,
      {required String name, String? mime}) async {
    if (bytes.length > maxBytes) throw AttachmentTooLargeException(bytes.length);
    final cleanName = p.basename(name).trim().isEmpty ? 'file' : p.basename(name).trim();
    final type = mime ?? mimeFor(name, bytes.take(32).toList());
    // Base64 inside FTS1: smaller than base45 for JSON transport.
    if (bytes.length <= inlineMaxChars) {
      final fts = FileStringCodec.encode(bytes, filename: cleanName);
      if (fts.length <= inlineMaxChars) {
        // A local id only (keys the UI and the memory cache); nothing is
        // uploaded, so no server ever holds this file.
        final id = _localId();
        _remember(id, bytes);
        return {
          'id': id,
          'inline': fts,
          'name': cleanName,
          'mime': type,
          'size': bytes.length,
        };
      }
    }
    final key = CryptoCore.randomBytes(32);
    final sealed = CryptoCore.secretEncrypt(bytes, key);
    final digest = hash.sha256.convert(sealed).bytes;
    final id = await _directory.uploadAttachment(sealed);
    await _writeCache(id, sealed);
    _remember(id, bytes);
    return {
      'id': id,
      'key': CryptoCore.toBase64(key),
      'sha256': CryptoCore.toBase64(Uint8List.fromList(digest)),
      'name': cleanName,
      'mime': type,
      'size': bytes.length,
    };
  }

  /// The decrypted bytes for [meta], from memory, disk or the server.
  Future<Uint8List> load(Map<String, dynamic> meta) {
    final id = meta['id'] as String;
    final hit = _memory.remove(id);
    if (hit != null) {
      _memory[id] = hit; // most recently used
      return Future.value(hit);
    }
    // (Block body: returning the removed future would make whenComplete
    // wait for itself.)
    return _inFlight[id] ??= _load(meta).whenComplete(() {
      _inFlight.remove(id);
    });
  }

  /// Already on this device (no download needed)?
  Future<bool> isAvailableOffline(Map<String, dynamic> meta) async {
    if (isInline(meta)) return true;
    final id = meta['id'] as String;
    if (_memory.containsKey(id)) return true;
    final f = await _cacheFile(id);
    return f != null && f.existsSync();
  }

  Future<Uint8List> _load(Map<String, dynamic> meta) async {
    final id = meta['id'] as String;
    final inline = meta['inline'];
    if (inline is String) {
      // Verified (size + SHA-256) by the codec; the message it came in was
      // already authenticated end to end.
      try {
        final decoded = FileStringCodec.decode(inline, maxBytes: maxBytes);
        _remember(id, decoded.bytes);
        return decoded.bytes;
      } on FileStringException {
        throw const AttachmentCorruptException();
      }
    }
    final key = CryptoCore.fromBase64(meta['key'] as String);
    final expected = meta['sha256'] as String;

    Uint8List? sealed;
    final f = await _cacheFile(id);
    if (f != null && f.existsSync()) sealed = await f.readAsBytes();
    if (sealed == null || _digest(sealed) != expected) {
      sealed = await _directory.downloadAttachment(id);
      if (_digest(sealed) != expected) throw const AttachmentCorruptException();
      await _writeCache(id, sealed);
    }
    Uint8List plain;
    try {
      plain = CryptoCore.secretDecrypt(sealed, key);
    } catch (_) {
      throw const AttachmentCorruptException();
    }
    _remember(id, plain);
    return plain;
  }

  static String _digest(Uint8List bytes) =>
      CryptoCore.toBase64(Uint8List.fromList(hash.sha256.convert(bytes).bytes));

  static String _localId() {
    final b = CryptoCore.randomBytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  void _remember(String id, Uint8List bytes) {
    if (bytes.length > _memoryLimit ~/ 4) return;
    _memory[id] = bytes;
    _memoryBytes += bytes.length;
    while (_memoryBytes > _memoryLimit && _memory.isNotEmpty) {
      final first = _memory.keys.first;
      _memoryBytes -= _memory.remove(first)!.length;
    }
  }

  Future<File?> _cacheFile(String id) async {
    if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(id)) return null;
    final dir = await _cacheDir();
    return dir == null ? null : File(p.join(dir, '$id.bin'));
  }

  Future<void> _writeCache(String id, Uint8List sealed) async {
    final f = await _cacheFile(id);
    if (f == null) return;
    await f.parent.create(recursive: true);
    await f.writeAsBytes(sealed, flush: true);
  }

  /// Sign-out: forget decrypted bytes held in memory.
  void clearMemory() {
    _memory.clear();
    _memoryBytes = 0;
  }
}
