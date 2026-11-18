import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

/// A finished recording, ready to send as an attachment.
class VoiceClip {
  final Uint8List bytes;
  final Duration duration;

  /// Loudness over time, [VoiceNote.waveformPoints] values in 0..31.
  final List<int> waveform;
  const VoiceClip(this.bytes, this.duration, this.waveform);
}

/// What a voice note adds to attachment metadata, and how it is read back
/// from a contact (who could send anything there).
class VoiceNote {
  static const mime = 'audio/mp4';
  static const fileName = 'voice-note.m4a';
  static const waveformPoints = 48;
  static const maxLength = Duration(minutes: 10);

  static Map<String, dynamic> meta(VoiceClip c) => {
        'voice': true,
        'duration_ms': c.duration.inMilliseconds,
        'waveform': c.waveform,
      };

  static bool isVoice(Map<String, dynamic>? a) =>
      a != null && a['voice'] == true && (a['mime'] as String? ?? '').startsWith('audio/');

  static Duration durationOf(Map<String, dynamic> a) {
    final ms = a['duration_ms'];
    return ms is int && ms >= 0 && ms <= maxLength.inMilliseconds * 2
        ? Duration(milliseconds: ms)
        : Duration.zero;
  }

  /// Exactly [waveformPoints] values in 0..31, whatever was sent.
  static List<int> waveformOf(Map<String, dynamic> a) {
    final raw = a['waveform'];
    final values = raw is List ? raw.whereType<int>().map((v) => v.clamp(0, 31)).toList() : <int>[];
    if (values.isEmpty) return List.filled(waveformPoints, 4);
    return resample(values, waveformPoints);
  }

  /// [levels] (any length) averaged into [n] buckets.
  static List<int> resample(List<num> levels, int n) {
    if (levels.isEmpty) return List.filled(n, 0);
    return [
      for (var i = 0; i < n; i++)
        () {
          final from = (i * levels.length / n).floor();
          final to = max(from + 1, ((i + 1) * levels.length / n).floor());
          final slice = levels.sublist(from, min(to, levels.length));
          return (slice.fold<num>(0, (a, b) => a + b) / slice.length).round();
        }(),
    ];
  }

  /// dBFS (about -60 quiet .. 0 loud) to 0..31.
  static int level(double dbfs) => (((dbfs.clamp(-50.0, 0.0) + 50) / 50) * 31).round();

  static String clock(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

/// Records one voice note at a time.
abstract class VoiceRecorder {
  Future<bool> hasPermission();
  Future<void> start();

  /// Current level, 0..31, while recording.
  Stream<int> get levels;
  Future<VoiceClip?> stop();
  Future<void> cancel();
  Future<void> dispose();
}

/// Plays one clip at a time.
abstract class VoicePlayer {
  Future<void> play(Uint8List bytes);
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration to);
  Stream<Duration> get position;
  Stream<bool> get playing;
  Future<void> dispose();
}

/// AAC (m4a), mono, 32 kbit/s: about 240 KB a minute.
class DeviceVoiceRecorder implements VoiceRecorder {
  final _rec = AudioRecorder();
  final _levels = StreamController<int>.broadcast();
  final _history = <int>[];
  StreamSubscription<Amplitude>? _amp;
  DateTime? _started;
  String? _path;

  @override
  Future<bool> hasPermission() => _rec.hasPermission();

  @override
  Stream<int> get levels => _levels.stream;

  @override
  Future<void> start() async {
    final dir = await Directory.systemTemp.createTemp('sh_voice_');
    _path = p.join(dir.path, VoiceNote.fileName);
    _history.clear();
    await _rec.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 32000, sampleRate: 16000, numChannels: 1),
      path: _path!,
    );
    _started = DateTime.now();
    _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((a) {
      final l = VoiceNote.level(a.current);
      _history.add(l);
      _levels.add(l);
    });
  }

  @override
  Future<VoiceClip?> stop() async {
    final started = _started;
    await _amp?.cancel();
    final path = await _rec.stop();
    _started = null;
    if (path == null || started == null) return null;
    final file = File(path);
    final bytes = await file.readAsBytes();
    await file.parent.delete(recursive: true); // nothing stays on disk unencrypted
    return VoiceClip(bytes, DateTime.now().difference(started),
        VoiceNote.resample(_history, VoiceNote.waveformPoints));
  }

  @override
  Future<void> cancel() async {
    await _amp?.cancel();
    await _rec.cancel();
    final path = _path;
    if (path != null) {
      final dir = Directory(p.dirname(path));
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
    _started = null;
  }

  @override
  Future<void> dispose() async {
    await _amp?.cancel();
    await _rec.dispose();
    await _levels.close();
  }
}

class DeviceVoicePlayer implements VoicePlayer {
  final _player = ap.AudioPlayer();

  @override
  Future<void> play(Uint8List bytes) => _player.play(ap.BytesSource(bytes, mimeType: VoiceNote.mime));

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> seek(Duration to) => _player.seek(to);

  @override
  Stream<Duration> get position => _player.onPositionChanged;

  @override
  Stream<bool> get playing => _player.onPlayerStateChanged.map((s) => s == ap.PlayerState.playing);

  @override
  Future<void> dispose() => _player.dispose();
}
