import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One worker at a time on the account's database and ratchet sessions
/// (security review M2): the app, or a background isolate handling a push or
/// a notification action, never both. Two copies advancing the same
/// sessions would corrupt them.
///
/// Two layers, because file locks are per process (POSIX fcntl): an
/// exclusive lock on a file in the app support directory keeps other
/// processes out, and a name claimed in [IsolateNameServer] (process wide,
/// claimed atomically) keeps other isolates of this process out.
class AppDataLock {
  AppDataLock._(this._file, this._name, this._port);

  final RandomAccessFile _file;
  final String _name;
  final ReceivePort _port;
  bool _held = true;

  /// Whether this lock is still held (not released).
  bool get held => _held;

  /// Takes the lock at [path], trying again every [retry] for up to
  /// [timeout] (zero: one try). Null if someone else holds it.
  static Future<AppDataLock?> acquire(
    String path, {
    Duration timeout = Duration.zero,
    Duration retry = const Duration(milliseconds: 100),
  }) async {
    final name = 'securelyhello_data_lock|${p.normalize(path)}';
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final lock = await _tryOnce(path, name);
      if (lock != null) return lock;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      await Future<void>.delayed(left < retry ? left : retry);
    }
  }

  static Future<AppDataLock?> _tryOnce(String path, String name) async {
    final port = ReceivePort();
    if (!IsolateNameServer.registerPortWithName(port.sendPort, name)) {
      port.close();
      return null;
    }
    RandomAccessFile? file;
    try {
      final f = File(path);
      await f.parent.create(recursive: true);
      file = await f.open(mode: FileMode.append);
      // Doesn't wait: throws while another process holds it.
      await file.lock(FileLock.exclusive);
      return AppDataLock._(file, name, port);
    } catch (_) {
      try {
        await file?.close();
      } catch (_) {}
      IsolateNameServer.removePortNameMapping(name);
      port.close();
      return null;
    }
  }

  /// Lets go (once; later calls do nothing).
  Future<void> release() async {
    if (!_held) return;
    _held = false;
    try {
      await _file.unlock();
    } catch (_) {}
    try {
      await _file.close();
    } catch (_) {}
    IsolateNameServer.removePortNameMapping(_name);
    _port.close();
  }

  /// The lock file for [profile] (see AppConfig.profile).
  static Future<String> pathFor(String profile) async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, profile.isEmpty ? 'data.lock' : 'data-$profile.lock');
  }

  /// How long the app waits for a background run to finish before it
  /// starts anyway (a background run takes a few seconds).
  static const appWait = Duration(seconds: 10);

  static AppDataLock? _app;

  /// The app's hold on the lock, taken before messaging starts and kept
  /// while it runs. Waits up to [appWait] for a background run, then goes
  /// ahead regardless (the app must not stay stuck behind it).
  static Future<void> holdForApp(String profile, {Duration wait = appWait}) async {
    if (_app?.held ?? false) return;
    if (kIsWeb) return;
    try {
      final lock = await acquire(await pathFor(profile), timeout: wait);
      if (lock == null) {
        debugPrint('Background work still running; starting anyway');
        return;
      }
      _app = lock;
    } catch (e) {
      debugPrint('Data lock unavailable: $e');
    }
  }
}
