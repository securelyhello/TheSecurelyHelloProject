import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:securelyhello/core/chat/wire_protocol.dart';
import 'package:securelyhello/core/stories/story_service.dart';

void main() {
  final t0 = DateTime(2026, 11, 20, 9);

  Story story(String id, String owner, {int minutes = 0, bool seen = false}) => Story(
        id: id,
        ownerId: owner,
        created: t0.add(Duration(minutes: minutes)),
        expires: t0.add(const Duration(hours: 24)),
        type: 'text',
        text: 'hi',
        seen: seen,
      );

  group('audience', () {
    const contacts = ['a', 'b', 'c'];
    test('all contacts, all except, only share with', () {
      expect(StoryAudience.everyone.resolve(contacts), {'a', 'b', 'c'});
      expect(const StoryAudience(AudienceMode.allExcept, {'b'}).resolve(contacts), {'a', 'c'});
      expect(const StoryAudience(AudienceMode.onlyShareWith, {'b', 'zed'}).resolve(contacts), {'b'},
          reason: 'never someone who is not a contact');
    });
    test('remembered; junk falls back to everyone', () {
      const a = StoryAudience(AudienceMode.allExcept, {'b'});
      final back = StoryAudience.decode(a.encode());
      expect(back.mode, AudienceMode.allExcept);
      expect(back.users, {'b'});
      expect(StoryAudience.decode('nope').mode, AudienceMode.allContacts);
      expect(StoryAudience.decode(null).mode, AudienceMode.allContacts);
    });
  });

  test('the row shows unseen stories first, then the newest', () {
    final order = orderOwners({
      'seen_recent': [story('1', 'seen_recent', minutes: 50, seen: true)],
      'unseen_old': [story('2', 'unseen_old', minutes: 1)],
      'unseen_new': [story('3', 'unseen_new', minutes: 40), story('4', 'unseen_new', minutes: 2, seen: true)],
    });
    expect(order, ['unseen_new', 'unseen_old', 'seen_recent']);
  });

  test('a story never lives longer than a day, whatever it claims', () {
    final p = {'id': 's', 'type': 'text', 'text': 'x', 'exp': t0.add(const Duration(days: 30)).millisecondsSinceEpoch};
    final s = Story.fromPayload('mira', t0.millisecondsSinceEpoch, p);
    expect(s.expires, t0.add(StoryService.lifetime));
    expect(s.expiredAt(t0.add(const Duration(hours: 23))), isFalse);
    expect(s.expiredAt(t0.add(const Duration(hours: 24))), isTrue);
  });

  test('stored and read back', () {
    final s = story('x', 'mira')..seen = true;
    final back = Story.fromJson(jsonDecode(jsonEncode(s.toJson())))!;
    expect([back.id, back.ownerId, back.text, back.seen, back.expires], [s.id, s.ownerId, s.text, true, s.expires]);
    expect(Story.fromJson({'id': 1}), isNull);
  });

  test('photos are shrunk and lose their metadata (no location)', () {
    final big = img.Image(width: 4000, height: 2000);
    big.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(23, 1);
    final out = StoryService.shrinkPhoto(Uint8List.fromList(img.encodeJpg(big)));
    final decoded = img.decodeJpg(out)!;
    expect(decoded.width, StoryService.maxPhotoSide);
    expect(decoded.exif.gpsIfd.isEmpty, isTrue);
  });

  group('story payloads are checked like any other', () {
    Uint8List wire(Object? story) => Uint8List.fromList(
        utf8.encode(jsonEncode({'k': 'story', 'from': 'a', 'to': 'b', 't': 1, 'story': story})));
    test('good ones', () {
      final p = WirePayload.decode(wire({'id': 's1', 'type': 'text', 'text': 'hi', 'exp': 5}));
      expect(p.kind, PayloadKind.story);
      expect(p.story!['text'], 'hi');
      WirePayload.decode(wire({'id': 's2', 'type': 'photo', 'att': {'id': 'x'}, 'exp': 5}));
    });
    test('bad ones', () {
      for (final bad in [
        null,
        {'type': 'text', 'exp': 5},
        {'id': 's', 'type': 'gif', 'exp': 5},
        {'id': 's', 'type': 'text', 'text': 'x' * 1001, 'exp': 5},
        {'id': 's', 'type': 'photo', 'exp': 5}, // no attachment
        {'id': 's', 'type': 'text', 'exp': '5'},
      ]) {
        expect(() => WirePayload.decode(wire(bad)), throwsFormatException, reason: '$bad');
      }
    });
  });
}
