import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'package:securelyhello/core/chat/file_string_codec.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

/// Profile photos and "about" lines, shared end to end.
///
/// The server never holds a photo: each contact gets it inside an encrypted
/// `profile` payload, and stores it locally. Photos are small square JPEGs
/// made on the sender's device; received ones are checked before anything
/// decodes them for display.
class ProfileService extends ChangeNotifier {
  /// Side of the square photo we send.
  static const photoSize = 256;

  /// Largest photo accepted from a contact (bytes and pixels).
  static const maxPhotoBytes = 64 * 1024;
  static const maxPhotoSide = 1024;
  static const maxAbout = 140;

  final LocalStorage _storage;
  ProfileService({required LocalStorage storage}) : _storage = storage;

  final Map<String, Uint8List> _photos = {};
  final Map<String, String> _about = {};
  bool _loaded = false;

  Uint8List? photoOf(String userId) => _photos[userId];
  String aboutOf(String userId) => _about[userId] ?? '';

  /// Loads every stored profile into memory (after the account's database
  /// is open).
  Future<void> load() async {
    _photos.clear();
    _about.clear();
    for (final row in await _storage.kvSealedByPrefix('profile:')) {
      final userId = row.key.substring('profile:'.length);
      _apply(userId, jsonDecode(row.value) as Map<String, dynamic>);
    }
    _loaded = true;
    notifyListeners();
  }

  bool get loaded => _loaded;

  void reset() {
    _photos.clear();
    _about.clear();
    _loaded = false;
    notifyListeners();
  }

  /// Our own profile as it goes on the wire: `{photo?, about, v}`.
  Future<Map<String, dynamic>?> mine(String me) async {
    final raw = await _storage.kvGetSealed('profile:$me');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Sets our profile. [photo] is any image the user picked; it is
  /// cropped to a square and re-encoded here. [removePhoto] clears it.
  Future<Map<String, dynamic>> setMine(String me,
      {Uint8List? photo, bool removePhoto = false, String? about}) async {
    final current = await mine(me) ?? {};
    final next = <String, dynamic>{
      if (!removePhoto && photo == null && current['photo'] != null) 'photo': current['photo'],
      if (photo != null)
        'photo': FileStringCodec.encode(await compute(squareJpeg, photo), filename: 'photo.jpg'),
      'about': (about ?? current['about'] as String? ?? '').trim(),
      // Strictly newer than the last version, or receivers would drop it.
      'v': max(DateTime.now().millisecondsSinceEpoch, (current['v'] as int? ?? 0) + 1),
    };
    if ((next['about'] as String).length > maxAbout) {
      next['about'] = (next['about'] as String).substring(0, maxAbout);
    }
    await _store(me, next);
    return next;
  }

  /// A profile received from [userId] (or from our own other device).
  /// Older versions than what we have are ignored. Returns whether it was
  /// accepted.
  Future<bool> receive(String userId, Map<String, dynamic> wire) async {
    final v = wire['v'];
    final about = wire['about'];
    final photo = wire['photo'];
    if (v is! int || about is! String || about.length > maxAbout) return false;
    if (photo != null && (photo is! String || !await validPhoto(photo))) return false;
    final current = await _storage.kvGetSealed('profile:$userId');
    if (current != null && ((jsonDecode(current) as Map)['v'] as int? ?? 0) >= v) return false;
    await _store(userId, {if (photo != null) 'photo': photo, 'about': about, 'v': v});
    return true;
  }

  /// How long a queued profile counts as on its way before it is sent
  /// again. The relay keeps envelopes for 24 hours (RELAY_TTL_HOURS), so a
  /// device that was offline longer than that never got it.
  static const resendAfter = Duration(hours: 20);

  /// The receipt id that acknowledges version [v] of a profile.
  static String ackId(int v) => 'profile:$v';

  /// The version in a [ackId] receipt id, or null for any other id.
  static int? ackedVersion(String receiptId) =>
      receiptId.startsWith('profile:') ? int.tryParse(receiptId.substring(8)) : null;

  /// The devices of [contactId] (of [current]) that need version [v] of our
  /// profile: never sent, or sent more than [resendAfter] ago and not
  /// acknowledged. Tracked per device, so devices a contact adds later get
  /// it too. Markers from 1.0 held only a version and may stand for a
  /// send that was lost; they count as not sent.
  Future<Set<String>> devicesNeeding(String contactId, int v, Iterable<String> current,
      {DateTime? now, Duration resendAfter = resendAfter}) async {
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final s = await _sent(contactId, v);
    return current.where((d) {
      if (s.acked.contains(d)) return false;
      final at = s.queued[d];
      return at == null || t - at >= resendAfter.inMilliseconds;
    }).toSet();
  }

  /// Records that version [v] was queued for [devices] of [contactId].
  Future<void> markSent(String contactId, int v, Set<String> devices, {DateTime? now}) async {
    final s = await _sent(contactId, v);
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    for (final d in devices) {
      s.queued[d] = t;
    }
    await _saveSent(contactId, v, s.queued, s.acked);
  }

  /// [device] of [contactId] acknowledged version [v]. Returns whether
  /// that was news.
  Future<bool> confirm(String contactId, int v, String device) async {
    final raw = await _storage.kvGet('profile_sent:$contactId');
    // Only for the version we are sending now; an old one changes nothing.
    if (raw == null || !raw.startsWith('{') || (jsonDecode(raw) as Map)['v'] != v) return false;
    final s = await _sent(contactId, v);
    if (s.acked.contains(device)) return false;
    s.acked.add(device);
    s.queued.remove(device);
    await _saveSent(contactId, v, s.queued, s.acked);
    return true;
  }

  Future<({Map<String, int> queued, Set<String> acked})> _sent(String contactId, int v) async {
    final raw = await _storage.kvGet('profile_sent:$contactId');
    try {
      final m = raw == null ? null : jsonDecode(raw);
      if (m is Map && m['v'] == v) {
        return (
          queued: {for (final e in (m['q'] as Map? ?? {}).entries) '${e.key}': e.value as int},
          acked: {for (final d in m['ok'] as List? ?? const []) '$d'},
        );
      }
    } on FormatException {
      // Unreadable: start over.
    }
    // Nothing yet, an older version, or a 1.0 marker (just a version).
    return (queued: <String, int>{}, acked: <String>{});
  }

  Future<void> _saveSent(String contactId, int v, Map<String, int> queued, Set<String> acked) =>
      _storage.kvSet('profile_sent:$contactId',
          jsonEncode({'v': v, 'q': queued, 'ok': acked.toList()..sort()}));

  Future<void> _store(String userId, Map<String, dynamic> p) async {
    await _storage.kvSetSealed('profile:$userId', jsonEncode(p));
    _apply(userId, p);
    notifyListeners();
  }

  void _apply(String userId, Map<String, dynamic> p) {
    final photo = p['photo'];
    if (photo is String) {
      try {
        _photos[userId] = FileStringCodec.decode(photo, maxBytes: maxPhotoBytes).bytes;
      } on FileStringException {
        _photos.remove(userId);
      }
    } else {
      _photos.remove(userId);
    }
    _about[userId] = p['about'] as String? ?? '';
  }

  /// A received photo: a valid file string, small, and a JPEG or PNG whose
  /// header declares sane dimensions (checked before full decoding, so a
  /// tiny file can't claim a gigantic image).
  static Future<bool> validPhoto(String fts) async {
    try {
      final bytes = FileStringCodec.decode(fts, maxBytes: maxPhotoBytes).bytes;
      return await compute(_sane, bytes);
    } on FileStringException {
      return false;
    }
  }

  static bool _sane(Uint8List bytes) {
    try {
      final decoder = img.findDecoderForData(bytes);
      if (decoder == null || (decoder is! img.JpegDecoder && decoder is! img.PngDecoder)) return false;
      final info = decoder.startDecode(bytes);
      if (info == null) return false;
      return info.width > 0 &&
          info.height > 0 &&
          info.width <= maxPhotoSide &&
          info.height <= maxPhotoSide;
    } catch (_) {
      // The decoder refuses some headers by throwing (e.g. absurd sizes).
      return false;
    }
  }

  /// Centre-crops [input] to a square and encodes a [photoSize] JPEG.
  static Uint8List squareJpeg(Uint8List input) {
    final decoded = img.decodeImage(input);
    if (decoded == null) throw const FormatException('Not an image');
    final side = decoded.width < decoded.height ? decoded.width : decoded.height;
    final cropped = img.copyCrop(decoded,
        x: (decoded.width - side) ~/ 2, y: (decoded.height - side) ~/ 2, width: side, height: side);
    final resized = img.copyResize(cropped, width: photoSize, height: photoSize, interpolation: img.Interpolation.average);
    return Uint8List.fromList(img.encodeJpg(resized, quality: 82));
  }
}
