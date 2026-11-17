// Feeds random and mutated input to every decoder that sees bytes from the
// network or another person. The contract: reject with FormatException (or
// FileStringException), never another error type, never hang.
// FUZZ_SEED / FUZZ_ROUNDS reproduce or deepen a run.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/chat/file_string_codec.dart';
import 'package:securelyhello/core/chat/wire_protocol.dart';
import 'package:securelyhello/core/crypto/ratchet.dart';
import 'package:securelyhello/core/crypto/verify_code.dart';
import 'package:securelyhello/core/networking/tls_pinning.dart';

final _seed = int.tryParse(Platform.environment['FUZZ_SEED'] ?? '') ?? 20261117;
final _rounds = int.tryParse(Platform.environment['FUZZ_ROUNDS'] ?? '') ?? 2000;

Object? _value(Random r, int depth) {
  switch (r.nextInt(depth > 2 ? 6 : 8)) {
    case 0:
      return null;
    case 1:
      return r.nextBool();
    case 2:
      return [0, -1, 3, 1 << 40, 1.5][r.nextInt(5)];
    case 3:
      return ['', 'x', '\u0000', 'A' * 300, '%%', '{}', 'fts1', '3'][r.nextInt(8)];
    case 4:
      return base64Encode(List.generate(r.nextInt(48), (_) => r.nextInt(256)));
    case 5:
      return const Utf8Decoder(allowMalformed: true)
          .convert(List.generate(r.nextInt(20), (_) => r.nextInt(256)));
    case 6:
      return [for (var i = r.nextInt(3); i > 0; i--) _value(r, depth + 1)];
    default:
      return {
        for (var i = r.nextInt(6); i > 0; i--)
          ['v', 'id', 's', 'sd', 'rd', 't', 'h', 'c', 'k', 'from', 'to', 'body', 'att', 'ids', 'read',
              'reply', 'target', 'emoji', 'exp', 'dh', 'pn', 'n', 'pk', 'ik', 'ix', 'ek', 'spk', 'opk',
              'conv'][r.nextInt(29)]: _value(r, depth + 1),
      };
  }
}

/// Valid samples, so mutations reach past the first checks.
final _envelope = WireEnvelope(
  id: 'e1',
  senderId: 'a',
  senderDevice: 'da',
  recipientDevice: 'db',
  timestampMs: 1,
  header: '{"dh":"AAAA","pn":0,"n":0,"pk":{"ik":"a","ix":"b","ek":"c","spk":1}}',
  ciphertextBase64: 'AAAA',
).encodeJson();
final _payload = utf8.decode(WirePayload.message(
  from: 'a',
  to: 'b',
  timestampMs: 1,
  messageId: 'm',
  body: 'hi',
).encode());

String _mutate(Random r, String s) {
  final b = s.codeUnits.toList();
  for (var i = 1 + r.nextInt(4); i > 0 && b.isNotEmpty; i--) {
    final at = r.nextInt(b.length);
    switch (r.nextInt(3)) {
      case 0:
        b[at] = r.nextInt(128);
      case 1:
        b.removeAt(at);
      default:
        b.insert(at, '{}[]":,0'.codeUnitAt(r.nextInt(8)));
    }
  }
  return String.fromCharCodes(b);
}

void _expectRejectsCleanly(String what, void Function() decode, String input) {
  try {
    decode();
  } on FormatException {
    // Expected for bad input.
  } on FileStringException {
    // Expected for bad file strings.
  } catch (e) {
    fail('$what threw ${e.runtimeType} ($e) for input: ${input.length > 300 ? input.substring(0, 300) : input}');
  }
}

void main() {
  final r = Random(_seed);

  test('envelopes (seed $_seed)', () {
    for (var i = 0; i < _rounds; i++) {
      final input = i.isEven ? jsonEncode(_value(r, 0)) : _mutate(r, _envelope);
      _expectRejectsCleanly('WireEnvelope.decodeJson', () => WireEnvelope.decodeJson(input), input);
    }
  });

  test('payloads (seed $_seed)', () {
    for (var i = 0; i < _rounds; i++) {
      final input = i.isEven ? jsonEncode(_value(r, 0)) : _mutate(r, _payload);
      _expectRejectsCleanly(
          'WirePayload.decode', () => WirePayload.decode(Uint8List.fromList(utf8.encode(input))), input);
    }
    final bad = Uint8List.fromList([0xff, 0xfe, 0x00]);
    _expectRejectsCleanly('WirePayload.decode', () => WirePayload.decode(bad), 'invalid utf-8');
  });

  test('ratchet headers (seed $_seed)', () {
    final header = jsonDecode(_envelope)['h'] as String;
    for (var i = 0; i < _rounds; i++) {
      final input = i.isEven ? jsonEncode(_value(r, 0)) : _mutate(r, header);
      _expectRejectsCleanly('RatchetHeader.decode', () => RatchetHeader.decode(input), input);
    }
  });

  test('file strings (seed $_seed)', () {
    final valid = FileStringCodec.encode(Uint8List.fromList(utf8.encode('hello file')),
        filename: 'a.txt');
    for (var i = 0; i < _rounds ~/ 4; i++) {
      final input = i.isEven ? 'FTS1:${_value(r, 0)}' : _mutate(r, valid);
      _expectRejectsCleanly('FileStringCodec.decode', () => FileStringCodec.decode(input), input);
    }
  });

  test('verification codes and certificates never throw unexpectedly', () {
    for (var i = 0; i < _rounds; i++) {
      final input = i.isEven
          ? '${_value(r, 1)}'
          : _mutate(r, 'securelyhello:verify:1:bob:alice:${'1' * 60}');
      VerifyCode.check(input, me: 'alice', contact: 'bob', safetyNumber: '1' * 60);
      final der = Uint8List.fromList(List.generate(r.nextInt(80), (_) => r.nextInt(256)));
      _expectRejectsCleanly('spkiOf', () => spkiOf(der), base64Encode(der));
    }
  });
}
