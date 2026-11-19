import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:securelyhello/core/chat/file_string_codec.dart';
import 'package:securelyhello/core/chat/profile_service.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

Uint8List png(int w, int h) => Uint8List.fromList(img.encodePng(img.Image(width: w, height: h)));

/// A PNG whose header claims [w]x[h] pixels but holds almost nothing: what a
/// decompression bomb looks like before anyone decodes it.
Uint8List lyingPng(int w, int h) {
  final real = png(1, 1);
  final b = ByteData.sublistView(real);
  b.setUint32(16, w); // IHDR width
  b.setUint32(20, h); // IHDR height
  return real;
}

String fts(Uint8List bytes) => FileStringCodec.encode(bytes, filename: 'photo.jpg');

void main() {
  sqfliteFfiInit();
  late LocalStorage storage;
  late ProfileService profiles;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sh_prof_');
    storage = LocalStorage(databaseFactory: databaseFactoryFfi, baseDirectory: () async => dir.path);
    await storage.openForUser('me', encryptionKey: CryptoCore.randomBytes(32));
    profiles = ProfileService(storage: storage);
    await profiles.load();
  });

  tearDown(() async {
    await storage.close();
    await dir.delete(recursive: true);
  });

  test('photos are cropped to a small square JPEG', () {
    final out = ProfileService.squareJpeg(png(400, 200));
    final decoded = img.decodeJpg(out)!;
    expect([decoded.width, decoded.height], [ProfileService.photoSize, ProfileService.photoSize]);
    expect(out.length, lessThan(ProfileService.maxPhotoBytes));
    expect(() => ProfileService.squareJpeg(Uint8List.fromList(utf8.encode('not an image'))),
        throwsFormatException);
  });

  test('received photos are checked before anything decodes them', () async {
    expect(await ProfileService.validPhoto(fts(ProfileService.squareJpeg(png(300, 300)))), isTrue);
    expect(await ProfileService.validPhoto(fts(lyingPng(50000, 50000))), isFalse,
        reason: 'a tiny file claiming a huge image is refused');
    expect(await ProfileService.validPhoto(fts(Uint8List.fromList(utf8.encode('<svg/>')))), isFalse);
    expect(await ProfileService.validPhoto('FTS1:garbage'), isFalse);
  });

  test('a contact profile is stored, sealed, and only newer versions replace it', () async {
    final photo = fts(ProfileService.squareJpeg(png(64, 64)));
    expect(await profiles.receive('mira', {'photo': photo, 'about': 'At work', 'v': 2}), isTrue);
    expect(profiles.photoOf('mira'), isNotNull);
    expect(profiles.aboutOf('mira'), 'At work');
    expect(await profiles.receive('mira', {'about': 'older', 'v': 1}), isFalse);
    expect(profiles.aboutOf('mira'), 'At work');
    expect(await profiles.receive('mira', {'about': 'x' * 141, 'v': 3}), isFalse);
    expect(await profiles.receive('mira', {'about': 'Removed my photo', 'v': 4}), isTrue);
    expect(profiles.photoOf('mira'), isNull);

    final raw = await storage.db.query('kv', where: "key = 'profile:mira'");
    expect(raw.single['value'], isNot(contains('Removed my photo')), reason: 'encrypted at rest');

    final again = ProfileService(storage: storage);
    await again.load();
    expect(again.aboutOf('mira'), 'Removed my photo');
  });

  test('our own profile: new photo, keep it on about-only edits, remove it', () async {
    final first = await profiles.setMine('me', photo: png(500, 300), about: '  Hello  ');
    expect(first['about'], 'Hello');
    expect(profiles.photoOf('me'), isNotNull);
    final second = await profiles.setMine('me', about: 'Busy');
    expect(second['photo'], first['photo'], reason: 'photo kept');
    expect(second['v'], greaterThan(first['v'] as int), reason: 'receivers drop versions that are not newer');
    await profiles.setMine('me', removePhoto: true);
    expect(profiles.photoOf('me'), isNull);
    expect(profiles.aboutOf('me'), 'Busy');
  });

  // Regression: photo changes didn't reach existing contacts. "Sent" was
  // one version number per contact, so a contact's later devices never got
  // the photo, and a send lost on a dying direct link was never retried.
  group('which devices still need our profile', () {
    final t0 = DateTime(2026, 11, 1, 9);

    test('everything is needed before anything was sent', () async {
      expect(await profiles.devicesNeeding('mira', 5, ['m1', 'm2'], now: t0), {'m1', 'm2'});
    });

    test('queued devices wait; a device added later gets it', () async {
      await profiles.markSent('mira', 5, {'m1'}, now: t0);
      expect(await profiles.devicesNeeding('mira', 5, ['m1', 'm2'], now: t0), {'m2'});
      await profiles.markSent('mira', 5, {'m2'}, now: t0);
      expect(await profiles.devicesNeeding('mira', 5, ['m1', 'm2'], now: t0), isEmpty);
      expect(await profiles.devicesNeeding('mira', 5, ['m1', 'm2', 'm3'], now: t0), {'m3'});
      expect(await profiles.devicesNeeding('mira', 6, ['m1', 'm2'], now: t0), {'m1', 'm2'},
          reason: 'a newer profile goes to every device again');
    });

    test('unacknowledged sends are repeated before the relay drops them', () async {
      await profiles.markSent('mira', 5, {'m1', 'm2'}, now: t0);
      expect(await profiles.confirm('mira', 5, 'm1'), isTrue);
      expect(await profiles.confirm('mira', 5, 'm1'), isFalse);
      final later = t0.add(ProfileService.resendAfter);
      expect(ProfileService.resendAfter, lessThan(const Duration(hours: 24)));
      expect(await profiles.devicesNeeding('mira', 5, ['m1', 'm2'], now: later), {'m2'},
          reason: 'm1 acknowledged; m2 may have been offline past the relay lifetime');
    });

    test('an acknowledgement for an older version changes nothing', () async {
      await profiles.markSent('mira', 6, {'m1'}, now: t0);
      expect(await profiles.confirm('mira', 5, 'm1'), isFalse);
      expect(await profiles.devicesNeeding('mira', 6, ['m1'], now: t0), isEmpty,
          reason: 'version 6 is still on its way');
    });

    test('markers from 1.0 (just a version) count as not sent', () async {
      await storage.kvSet('profile_sent:mira', '5');
      expect(await profiles.devicesNeeding('mira', 5, ['m1'], now: t0), {'m1'});
    });

    test('ack ids', () {
      expect(ProfileService.ackedVersion(ProfileService.ackId(42)), 42);
      expect(ProfileService.ackedVersion('3f1c2b9e-0000-4000-8000-000000000000'), isNull);
      expect(ProfileService.ackedVersion('profile:x'), isNull);
    });
  });

  test('a received newer photo replaces the shown one', () async {
    Uint8List filled(int r) => Uint8List.fromList(
        img.encodePng(img.fill(img.Image(width: 64, height: 64), color: img.ColorRgb8(r, 40, 90))));
    final a = fts(ProfileService.squareJpeg(filled(20)));
    final b = fts(ProfileService.squareJpeg(filled(230)));
    var notified = 0;
    profiles.addListener(() => notified++);
    expect(await profiles.receive('mira', {'photo': a, 'about': '', 'v': 1}), isTrue);
    final first = profiles.photoOf('mira');
    expect(await profiles.receive('mira', {'photo': b, 'about': '', 'v': 2}), isTrue);
    expect(profiles.photoOf('mira'), isNot(equals(first)));
    expect(notified, 2, reason: 'avatars rebuild');
  });
}
