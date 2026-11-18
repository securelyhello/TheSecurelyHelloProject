import 'dart:convert';
import 'dart:io' show GZipCodec;
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;

// File <-> string codec ("FTS1")
//
// Dart port of tools/file_to_string.py (the reference implementation), wire
// compatible in both directions:
//
//   FILE   -> bytes -> gzip (only if smaller) -> SHA-256 of the original
//          -> base64 or base45 (RFC 9285) -> "FTS1|<meta>|<payload>"
//   STRING -> parse -> decode -> gunzip (if flagged) -> check size + SHA-256
//
//   <meta> = urlsafe-base64(JSON {"filename","size","sha256","compressed",
//            "encoding"}), compact, non-ASCII escaped like Python's json.
//
// Optional chunking for size-limited transports (e.g. one QR code each):
//   "FTS1C|<session>|<i>/<total>|<piece>", reassembled in any order.
//
// Hardening over the reference decoder (same format, stricter reading):
// * the file name is reduced to a plain base name: no "../", no folders;
// * decompression stops at the declared size, so a small string can't
//   expand into gigabytes (gzip bomb);
// * every base45 character, including a 2-character tail, is validated.
//
// The string is NOT encrypted. Send it only inside an end-to-end encrypted
// payload (or encrypt the bytes first).

const String ftsMagic = 'FTS1';
const String ftsChunkMagic = 'FTS1C';
const List<String> ftsEncodings = ['base64', 'base45'];

/// Hard ceiling on what a decoder will produce (independent of the meta).
const int ftsMaxDecodedBytes = 64 * 1024 * 1024;

class FileStringException implements Exception {
  final String message;
  const FileStringException(this.message);
  @override
  String toString() => 'FileStringException: $message';
}

/// What a decoded string contained.
class DecodedFile {
  final String filename;
  final Uint8List bytes;
  final String sha256;
  const DecodedFile(this.filename, this.bytes, this.sha256);
}

class FileStringCodec {
  FileStringCodec._();

  // Base45 (RFC 9285)

  static const _b45 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ \$%*+-./:';
  static final Map<int, int> _b45Index = {
    for (var i = 0; i < _b45.length; i++) _b45.codeUnitAt(i): i,
  };

  static String base45Encode(List<int> data) {
    final out = StringBuffer();
    final n = data.length;
    for (var i = 0; i + 1 < n; i += 2) {
      var v = data[i] * 256 + data[i + 1];
      final c = v % 45;
      v ~/= 45;
      out
        ..writeCharCode(_b45.codeUnitAt(c))
        ..writeCharCode(_b45.codeUnitAt(v % 45))
        ..writeCharCode(_b45.codeUnitAt(v ~/ 45));
    }
    if (n.isOdd) {
      final v = data[n - 1];
      out
        ..writeCharCode(_b45.codeUnitAt(v % 45))
        ..writeCharCode(_b45.codeUnitAt(v ~/ 45));
    }
    return out.toString();
  }

  static Uint8List base45Decode(String s) {
    int idx(int unit) {
      final v = _b45Index[unit];
      if (v == null) {
        throw FileStringException(
            'Invalid base45 character: ${String.fromCharCode(unit)}');
      }
      return v;
    }

    if (s.length % 3 == 1) {
      throw const FileStringException('Invalid base45 string length');
    }
    final units = s.codeUnits;
    final out = BytesBuilder(copy: false);
    final full = units.length ~/ 3;
    for (var i = 0; i < full; i++) {
      final v = idx(units[i * 3]) +
          idx(units[i * 3 + 1]) * 45 +
          idx(units[i * 3 + 2]) * 45 * 45;
      if (v > 0xFFFF) {
        throw const FileStringException('Invalid base45 triplet (out of range)');
      }
      out.add([v >> 8, v & 0xFF]);
    }
    if (units.length % 3 == 2) {
      final v = idx(units[full * 3]) + idx(units[full * 3 + 1]) * 45;
      if (v > 0xFF) {
        throw const FileStringException('Invalid base45 pair (out of range)');
      }
      out.addByte(v);
    }
    return out.takeBytes();
  }

  // Encode: bytes -> string

  /// Encodes [bytes] (a file called [filename]) into one self-describing
  /// string. Matches `encode_file()` in the Python reference.
  static String encode(
    List<int> bytes, {
    required String filename,
    String encoding = 'base64',
    bool compress = true,
  }) {
    if (!ftsEncodings.contains(encoding)) {
      throw FileStringException('encoding must be one of $ftsEncodings');
    }
    final raw = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final digest = hash.sha256.convert(raw).toString();

    List<int> payload = raw;
    var compressed = false;
    if (compress) {
      final z = GZipCodec(level: 9).encode(raw);
      if (z.length < raw.length) {
        payload = z;
        compressed = true;
      }
    }
    final payloadText =
        encoding == 'base64' ? base64.encode(payload) : base45Encode(payload);

    // Same key order and compact separators as Python's json.dumps(...,
    // separators=(",", ":")), with non-ASCII escaped like ensure_ascii.
    final meta = _asciiJson({
      'filename': filename,
      'size': raw.length,
      'sha256': digest,
      'compressed': compressed,
      'encoding': encoding,
    });
    final metaB64 = base64Url.encode(utf8.encode(meta));
    return '$ftsMagic|$metaB64|$payloadText';
  }

  static String _asciiJson(Object value) {
    final s = jsonEncode(value);
    final out = StringBuffer();
    for (final r in s.runes) {
      if (r < 0x80) {
        out.writeCharCode(r);
      } else if (r <= 0xFFFF) {
        out.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
      } else {
        // Surrogate pair, as Python writes astral characters.
        final v = r - 0x10000;
        out
          ..write('\\u${(0xD800 + (v >> 10)).toRadixString(16)}')
          ..write('\\u${(0xDC00 + (v & 0x3FF)).toRadixString(16)}');
      }
    }
    return out.toString();
  }

  // Decode: string -> bytes

  /// Reverses [encode]: checks the size and SHA-256, returns the file.
  /// Throws [FileStringException] on anything malformed or tampered.
  static DecodedFile decode(String s, {int maxBytes = ftsMaxDecodedBytes}) {
    final text = _stripNewlines(s);
    final first = text.indexOf('|');
    final second = first < 0 ? -1 : text.indexOf('|', first + 1);
    if (first < 0 || second < 0) {
      throw const FileStringException(
          "Malformed string: expected 'MAGIC|meta|payload'");
    }
    final magic = text.substring(0, first);
    if (magic != ftsMagic) {
      throw FileStringException('Unrecognized format magic: $magic');
    }

    Map<String, dynamic> meta;
    try {
      meta = jsonDecode(utf8.decode(
              base64Url.decode(base64Url.normalize(text.substring(first + 1, second)))))
          as Map<String, dynamic>;
    } catch (_) {
      throw const FileStringException('Malformed metadata');
    }
    final size = meta['size'];
    final sha = meta['sha256'];
    final encoding = meta['encoding'];
    final compressed = meta['compressed'];
    if (size is! int || size < 0 || sha is! String || compressed is! bool) {
      throw const FileStringException('Malformed metadata');
    }
    if (size > maxBytes) {
      throw FileStringException('File too large ($size bytes, limit $maxBytes)');
    }

    final payloadText = text.substring(second + 1);
    Uint8List payload;
    try {
      if (encoding == 'base64') {
        payload = base64.decode(payloadText);
      } else if (encoding == 'base45') {
        payload = base45Decode(payloadText);
      } else {
        throw FileStringException('Unknown encoding in metadata: $encoding');
      }
    } on FileStringException {
      rethrow;
    } on FormatException {
      throw const FileStringException('Invalid payload text');
    }

    final raw = compressed ? _gunzipLimited(payload, size) : payload;
    if (raw.length != size) {
      throw FileStringException('Size mismatch: expected $size, got ${raw.length}');
    }
    final actual = hash.sha256.convert(raw).toString();
    if (actual != sha.toLowerCase()) {
      throw FileStringException(
          'Integrity check failed: expected sha256 $sha, got $actual');
    }
    return DecodedFile(safeFilename(meta['filename']), raw, actual);
  }

  /// Gunzips at most [limit] bytes; one more means the meta lied.
  static Uint8List _gunzipLimited(Uint8List data, int limit) {
    final out = BytesBuilder(copy: false);
    var total = 0;
    var tooBig = false;
    final sink = ByteConversionSink.withCallback((_) {});
    final decoder = GZipCodec().decoder.startChunkedConversion(
      _LimitedSink((chunk) {
        total += chunk.length;
        if (total > limit) {
          tooBig = true;
          return false;
        }
        out.add(chunk);
        return true;
      }, sink),
    );
    try {
      // Feed in slices so an overrun is caught early.
      const step = 64 * 1024;
      for (var i = 0; i < data.length && !tooBig; i += step) {
        decoder.add(data.sublist(i, min(i + step, data.length)));
      }
      if (!tooBig) decoder.close();
    } on FormatException {
      throw const FileStringException('Corrupt compressed payload');
    } catch (e) {
      if (!tooBig) throw FileStringException('Corrupt compressed payload: $e');
    }
    if (tooBig) {
      throw FileStringException('Decompressed data exceeds the declared size ($limit)');
    }
    return out.takeBytes();
  }

  /// A plain file name: no directories, no "..", no control characters.
  static String safeFilename(Object? raw) {
    var name = raw is String ? raw : '';
    name = name.replaceAll('\\', '/').split('/').last;
    name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    if (name.isEmpty || name == '.' || name == '..') return 'file';
    return name.length > 255 ? name.substring(name.length - 255) : name;
  }

  // Chunking

  /// Splits an encoded string into self-describing chunks of [chunkSize]
  /// characters (matches `chunk_string()`).
  static List<String> chunk(String s, {int chunkSize = 400, String? sessionId}) {
    if (chunkSize < 1) throw const FileStringException('chunkSize must be >= 1');
    final rng = Random.secure();
    final session = sessionId ??
        List.generate(8, (_) => rng.nextInt(16).toRadixString(16)).join();
    final pieces = <String>[
      for (var i = 0; i < s.length; i += chunkSize)
        s.substring(i, min(i + chunkSize, s.length))
    ];
    final total = pieces.length;
    return [
      for (var i = 0; i < total; i++) '$ftsChunkMagic|$session|${i + 1}/$total|${pieces[i]}'
    ];
  }

  /// Reassembles chunks in any order (matches `reassemble_chunks()`).
  /// Throws, naming the missing indices, if any are absent.
  static String reassemble(Iterable<String> chunks) {
    final parsed = <int, String>{};
    final sessions = <String>{};
    int? total;
    for (final c in chunks) {
      final parts = _splitN(_stripNewlines(c), '|', 4);
      if (parts.length != 4 || parts[0] != ftsChunkMagic) {
        throw FileStringException('Not a chunk record: ${parts.first}');
      }
      final it = parts[2].split('/');
      final i = it.length == 2 ? int.tryParse(it[0]) : null;
      final t = it.length == 2 ? int.tryParse(it[1]) : null;
      if (i == null || t == null || i < 1 || i > t) {
        throw FileStringException('Bad chunk index: ${parts[2]}');
      }
      if (total != null && total != t) {
        throw const FileStringException('Chunks disagree about the total');
      }
      total = t;
      sessions.add(parts[1]);
      parsed[i] = parts[3];
    }
    if (sessions.length > 1) {
      throw FileStringException('Chunks from multiple sessions mixed together: $sessions');
    }
    if (total == null) throw const FileStringException('No chunks');
    final missing = [
      for (var i = 1; i <= total; i++)
        if (!parsed.containsKey(i)) i
    ];
    if (missing.isNotEmpty) {
      throw FileStringException('Missing chunk(s): $missing');
    }
    return [for (var i = 1; i <= total; i++) parsed[i]!].join();
  }

  /// Base45 uses ' ' as a digit, so only line breaks may be stripped.
  static String _stripNewlines(String s) =>
      s.replaceAll(RegExp(r'^[\r\n]+|[\r\n]+$'), '');

  static List<String> _splitN(String s, String sep, int n) {
    final out = <String>[];
    var rest = s;
    while (out.length < n - 1) {
      final i = rest.indexOf(sep);
      if (i < 0) break;
      out.add(rest.substring(0, i));
      rest = rest.substring(i + 1);
    }
    out.add(rest);
    return out;
  }
}

/// Forwards chunks until [onChunk] returns false (limit reached).
class _LimitedSink implements Sink<List<int>> {
  final bool Function(List<int>) onChunk;
  final Sink<List<int>> inner;
  bool _stopped = false;
  _LimitedSink(this.onChunk, this.inner);

  @override
  void add(List<int> data) {
    if (_stopped) return;
    if (!onChunk(data)) _stopped = true;
  }

  @override
  void close() => inner.close();
}
