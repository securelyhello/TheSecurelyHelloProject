import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securelyhello/core/chat/wire_protocol.dart';
import 'package:securelyhello/core/config/release_logging.dart';

void main() {
  group('silenceDebugPrintInRelease', () {
    late DebugPrintCallback original;
    setUp(() => original = debugPrint);
    tearDown(() => debugPrint = original);

    test('release builds drop every debugPrint', () {
      final seen = <String?>[];
      debugPrint = (String? m, {int? wrapWidth}) => seen.add(m);
      silenceDebugPrintInRelease(release: true);
      debugPrint('device abc failed');
      debugPrint(null, wrapWidth: 80);
      expect(seen, isEmpty);
    });

    test('debug builds keep printing', () {
      final seen = <String?>[];
      debugPrint = (String? m, {int? wrapWidth}) => seen.add(m);
      silenceDebugPrintInRelease(release: false);
      debugPrint('hello');
      expect(seen, ['hello']);
    });
  });

  group('payload decode errors', () {
    test('do not echo the decrypted text', () {
      const secret = 'meet me at the docks at 9 {';
      final bytes = Uint8List.fromList(utf8.encode(secret));
      try {
        WirePayload.decode(bytes);
        fail('should throw');
      } on FormatException catch (e) {
        expect(e.toString(), isNot(contains('docks')));
        expect(e.source, isNull);
      }
    });

    test('envelope decode errors do not echo the input either', () {
      try {
        WireEnvelope.decodeJson('{"v":3, "secret-token-xyz');
        fail('should throw');
      } on FormatException catch (e) {
        expect(e.toString(), isNot(contains('secret-token-xyz')));
      }
    });
  });
}
