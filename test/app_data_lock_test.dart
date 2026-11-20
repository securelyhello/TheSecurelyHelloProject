import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:securelyhello/core/storage/app_data_lock.dart';

// Security review M2: the background isolate (push, notification actions)
// and the app never work on the database and ratchet sessions at once.
void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sh_lock');
    path = p.join(dir.path, 'sub', 'data.lock');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('one holder at a time within the process (isolates share it)', () async {
    final first = await AppDataLock.acquire(path);
    expect(first, isNotNull);
    expect(await AppDataLock.acquire(path), isNull);
    await first!.release();
    final again = await AppDataLock.acquire(path);
    expect(again, isNotNull);
    await again!.release();
  });

  test('different lock files are independent', () async {
    final a = await AppDataLock.acquire(path);
    final b = await AppDataLock.acquire(p.join(dir.path, 'other.lock'));
    expect(a, isNotNull);
    expect(b, isNotNull);
    await a!.release();
    await b!.release();
  });

  test('waits up to the timeout for the holder to let go', () async {
    final first = (await AppDataLock.acquire(path))!;
    Timer(const Duration(milliseconds: 150), () => unawaited(first.release()));
    final second = await AppDataLock.acquire(path, timeout: const Duration(seconds: 3));
    expect(second, isNotNull);
    await second!.release();
  });

  test('gives up after the timeout', () async {
    final first = (await AppDataLock.acquire(path))!;
    final sw = Stopwatch()..start();
    expect(await AppDataLock.acquire(path, timeout: const Duration(milliseconds: 200)), isNull);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(150));
    await first.release();
  });

  test('release is idempotent', () async {
    final l = (await AppDataLock.acquire(path))!;
    expect(l.held, isTrue);
    await l.release();
    await l.release();
    expect(l.held, isFalse);
    final other = (await AppDataLock.acquire(path))!;
    await l.release(); // must not free someone else's lock
    expect(await AppDataLock.acquire(path), isNull);
    await other.release();
  });

  test('another process holding the file lock keeps us out', () async {
    final root = Platform.environment['FLUTTER_ROOT'];
    final dart = root == null ? null : p.join(root, 'bin', Platform.isWindows ? 'dart.bat' : 'dart');
    if (dart == null || !File(dart).existsSync()) {
      markTestSkipped('dart executable not found');
      return;
    }
    File(path).parent.createSync(recursive: true);
    final script = File(p.join(dir.path, 'hold.dart'))
      ..writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> a) async {
  final f = await File(a[0]).open(mode: FileMode.append);
  await f.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.first;
}
''');
    final proc = await Process.start(dart, ['run', script.path, path]);
    try {
      await proc.stdout.transform(const SystemEncoding().decoder).firstWhere((l) => l.contains('locked'));
      expect(await AppDataLock.acquire(path), isNull);
    } finally {
      proc.stdin.writeln('done');
      await proc.stdin.close();
      await proc.exitCode;
    }
    final mine = await AppDataLock.acquire(path, timeout: const Duration(seconds: 2));
    expect(mine, isNotNull);
    await mine!.release();
  });
}
