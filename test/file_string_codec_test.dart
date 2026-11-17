// FTS1 codec: Dart port vs the Python reference (tools/file_to_string.py),
// driven through the reference's CLI, in both directions.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/chat/file_string_codec.dart';

final _py = '${Directory.current.path}/tools/file_to_string.py';

String py(List<String> args) {
  final r = Process.runSync('python3', [_py, ...args], stdoutEncoding: utf8);
  if (r.exitCode != 0) fail('python3 ${args.join(' ')} failed: ${r.stderr}');
  return r.stdout as String;
}

Directory tmp() => Directory.systemTemp.createTempSync('fts_dart_');

void main() {
  final rng = Random(42);
  final samples = <String, Uint8List>{
    'empty.bin': Uint8List(0),
    'one.bin': Uint8List.fromList([255]),
    'odd.bin': Uint8List.fromList([1, 2, 3]),
    'random.bin': Uint8List.fromList(List.generate(100003, (_) => rng.nextInt(256))),
    'text.txt': Uint8List.fromList(utf8.encode('Securely Hello — the quick brown fox 🦊\n' * 5000)),
    'zeros.bin': Uint8List(70000),
  };

  test('uncompressed output is byte-identical to Python, including non-ASCII names', () {
    final dir = tmp();
    for (final name in ['plain.txt', 'résumé 😀.txt']) {
      final f = File('${dir.path}/$name')..writeAsStringSync('hello world, odd length!');
      for (final enc in ftsEncodings) {
        final ours = FileStringCodec.encode(f.readAsBytesSync(),
            filename: name, encoding: enc, compress: false);
        final theirs = py(['encode', f.path, '--encoding', enc, '--no-compress']).trim();
        expect(ours, theirs, reason: '$name $enc');
      }
    }
  });

  test('Python encodes, Dart decodes (every sample, both encodings, with/without gzip)', () {
    final dir = tmp();
    samples.forEach((name, bytes) {
      final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
      for (final enc in ftsEncodings) {
        for (final flag in [<String>[], ['--no-compress']]) {
          final s = py(['encode', f.path, '--encoding', enc, ...flag]).trim();
          final out = FileStringCodec.decode(s);
          expect(out.filename, name);
          expect(out.bytes, bytes, reason: '$name $enc $flag');
        }
      }
    });
  });

  test('Dart encodes, Python decodes', () {
    samples.forEach((name, bytes) {
      for (final enc in ftsEncodings) {
        final dir = tmp();
        final encoded = File('${dir.path}/encoded.txt')
          ..writeAsStringSync(FileStringCodec.encode(bytes, filename: name, encoding: enc));
        py(['decode', encoded.path, '-o', '${dir.path}/out']);
        expect(File('${dir.path}/out/$name').readAsBytesSync(), bytes, reason: '$name $enc');
      }
    });
  });

  test('chunks interoperate both ways, any order; pieces may start or end with a space', () {
    final s = FileStringCodec.encode(samples['random.bin']!, filename: 'random.bin', encoding: 'base45');
    final ours = FileStringCodec.chunk(s, chunkSize: 400);
    expect(ours.any((c) => c.endsWith(' ') || c.split('|').last.startsWith(' ')), isTrue,
        reason: 'the sample exercises space-edged pieces');
    final dir = tmp();
    final chunkDir = Directory('${dir.path}/chunks')..createSync();
    for (var i = 0; i < ours.length; i++) {
      File('${chunkDir.path}/chunk_${(i + 1).toString().padLeft(4, '0')}.txt').writeAsStringSync(ours[i]);
    }
    py(['unchunk', chunkDir.path, '-o', '${dir.path}/rebuilt.txt']);
    expect(File('${dir.path}/rebuilt.txt').readAsStringSync(), s);

    final encoded = File('${dir.path}/encoded.txt')..writeAsStringSync(s);
    py(['chunk', encoded.path, '--size', '333', '-o', '${dir.path}/py']);
    final theirs = Directory('${dir.path}/py')
        .listSync()
        .whereType<File>()
        .map((f) => f.readAsStringSync())
        .toList()
      ..shuffle(rng);
    expect(FileStringCodec.reassemble(theirs), s);
    expect(FileStringCodec.decode(FileStringCodec.reassemble(theirs)).bytes, samples['random.bin']);
  });

  test('missing, mixed and malformed chunks are reported', () {
    final s = 'x' * 1000;
    final a = FileStringCodec.chunk(s, chunkSize: 100, sessionId: 'aaaa1111');
    expect(
        () => FileStringCodec.reassemble([for (var i = 0; i < a.length; i++) if (i != 3 && i != 7) a[i]]),
        throwsA(predicate((e) => '$e'.contains('Missing chunk(s): [4, 8]'))));
    final b = FileStringCodec.chunk(s, chunkSize: 100, sessionId: 'bbbb2222');
    expect(() => FileStringCodec.reassemble([...a.take(5), ...b.skip(5)]),
        throwsA(predicate((e) => '$e'.contains('multiple sessions'))));
    expect(() => FileStringCodec.reassemble(['FTS1|nope']), throwsA(isA<FileStringException>()));
  });

  test('tampering and malformed input are rejected', () {
    final s = FileStringCodec.encode(utf8.encode('important contract text, v1'),
        filename: 'c.txt', compress: false);
    final parts = s.split('|');
    final flipped = (parts[2][0] == 'A' ? 'B' : 'A') + parts[2].substring(1);
    expect(() => FileStringCodec.decode('${parts[0]}|${parts[1]}|$flipped'),
        throwsA(predicate((e) => '$e'.contains('Integrity check failed'))));
    expect(() => FileStringCodec.decode('FTS2|${parts[1]}|${parts[2]}'), throwsA(isA<FileStringException>()));
    expect(() => FileStringCodec.decode('just text'), throwsA(isA<FileStringException>()));
    expect(() => FileStringCodec.decode('FTS1|!!!|${parts[2]}'), throwsA(isA<FileStringException>()));
    expect(() => FileStringCodec.base45Decode('A~'), throwsA(isA<FileStringException>()),
        reason: 'the 2-character tail is validated too');
    expect(() => FileStringCodec.base45Decode('ABCD'), throwsA(isA<FileStringException>()));
    expect(() => FileStringCodec.base45Decode(':::'), throwsA(isA<FileStringException>()));
  });

  test('hardening: crafted file names cannot escape the target folder', () {
    for (final evil in ['../../.bashrc', '/etc/passwd', r'..\..\win.ini', '..', '']) {
      final out = FileStringCodec.decode(
          FileStringCodec.encode([1, 2, 3], filename: evil, compress: false));
      expect(out.filename.contains('/') || out.filename.contains(r'\') || out.filename == '..', isFalse,
          reason: evil);
    }
    expect(FileStringCodec.safeFilename('../../.bashrc'), '.bashrc');
  });

  test('hardening: a gzip bomb with a small declared size is stopped early', () {
    final bomb = GZipCodec(level: 9).encode(Uint8List(50 * 1024 * 1024));
    String meta(int size) => base64Url.encode(utf8.encode(jsonEncode({
          'filename': 'x', 'size': size, 'sha256': '0' * 64, 'compressed': true, 'encoding': 'base64'
        })));
    final sw = Stopwatch()..start();
    expect(() => FileStringCodec.decode('FTS1|${meta(10)}|${base64.encode(bomb)}'),
        throwsA(predicate((e) => '$e'.contains('exceeds the declared size'))));
    expect(sw.elapsed.inSeconds, lessThan(10));
    expect(() => FileStringCodec.decode('FTS1|${meta(1 << 40)}|AAAA'),
        throwsA(predicate((e) => '$e'.contains('too large'))));
  });
}
