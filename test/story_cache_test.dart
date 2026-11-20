import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:securelyhello/features/stories/story_viewer.dart';

// Security review L7: decrypted story videos don't stay in the cache.
void main() {
  test('stale story videos are removed, other cache files kept', () async {
    final dir = Directory.systemTemp.createTempSync('sh_story_cache');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'story-abc.mp4')).writeAsBytesSync([1, 2, 3]);
    File(p.join(dir.path, 'story-def.mp4')).writeAsBytesSync([4]);
    File(p.join(dir.path, 'story-notes.txt')).writeAsStringSync('keep');
    File(p.join(dir.path, 'other.mp4')).writeAsBytesSync([5]);
    Directory(p.join(dir.path, 'story-dir.mp4')).createSync();

    expect(await purgeStoryVideos(dir), 2);
    final left = dir.listSync().map((e) => p.basename(e.path)).toSet();
    expect(left, {'story-notes.txt', 'other.mp4', 'story-dir.mp4'});
  });

  test('a missing cache directory is fine', () async {
    expect(await purgeStoryVideos(Directory(p.join(Directory.systemTemp.path, 'sh_no_such_dir_xyz'))), 0);
  });
}
