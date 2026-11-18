import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/chat/attachment_service.dart';
import 'package:securelyhello/core/media/voice.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';

/// Makes recorders and players. Tests provide fakes; the app uses the
/// device's microphone and speaker.
class VoiceMedia {
  final VoiceRecorder Function() recorder;
  final VoicePlayer Function() player;
  const VoiceMedia({required this.recorder, required this.player});

  static final device = VoiceMedia(recorder: DeviceVoiceRecorder.new, player: DeviceVoicePlayer.new);

  static VoiceMedia of(BuildContext context) {
    try {
      return Provider.of<VoiceMedia>(context, listen: false);
    } on ProviderNotFoundException {
      return device;
    }
  }
}

/// Bars for a waveform; the first [progress] of them in the accent colour.
class Waveform extends StatelessWidget {
  final List<int> levels;
  final double progress;
  final Color played;
  final Color unplayed;
  final double height;
  const Waveform({
    super.key,
    required this.levels,
    required this.played,
    required this.unplayed,
    this.progress = 0,
    this.height = 28,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < levels.length; i++)
              Expanded(
                child: Center(
                  child: Container(
                    width: 2.5,
                    height: 3 + (height - 3) * levels[i] / 31,
                    decoration: BoxDecoration(
                      color: i / levels.length < progress ? played : unplayed,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

/// A voice message in a bubble: play/pause, waveform, time.
class VoiceNoteView extends StatefulWidget {
  final Map<String, dynamic> meta;
  final AttachmentService service;
  final bool isSent;
  const VoiceNoteView({super.key, required this.meta, required this.service, required this.isSent});

  @override
  State<VoiceNoteView> createState() => _VoiceNoteViewState();
}

class _VoiceNoteViewState extends State<VoiceNoteView> {
  VoicePlayer? _player;
  final _subs = <StreamSubscription<Object?>>[];
  bool _loading = false;
  bool _playing = false;
  bool _started = false;
  bool _failed = false;
  Duration _position = Duration.zero;

  Duration get _length => VoiceNote.durationOf(widget.meta);

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_loading) return;
    final player = _player ??= VoiceMedia.of(context).player();
    if (_playing) return player.pause();
    if (_started) return player.resume();
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final bytes = await widget.service.load(widget.meta);
      _subs
        ..add(player.position.listen((p) {
          if (mounted) setState(() => _position = p);
        }))
        ..add(player.playing.listen((on) {
          if (!mounted) return;
          setState(() {
            _playing = on;
            // Finished: back to the start.
            if (!on && _length > Duration.zero && _position >= _length - const Duration(milliseconds: 300)) {
              _position = Duration.zero;
              _started = false;
            }
          });
        }));
      await player.play(bytes);
      _started = true;
    } catch (e) {
      debugPrint('Voice note failed: $e');
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = widget.isSent ? p.bubbleOutText : p.bubbleInText;
    final progress = _length.inMilliseconds == 0 ? 0.0 : _position.inMilliseconds / _length.inMilliseconds;
    final shown = _started || _playing ? _position : _length;
    return SizedBox(
      width: 240,
      child: Row(children: [
        SizedBox(
          width: 40,
          height: 40,
          child: _loading
              ? Padding(
                  padding: const EdgeInsets.all(10),
                  child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                )
              : IconButton(
                  key: ValueKey('voice-play-${widget.meta['id']}'),
                  tooltip: _failed ? "Couldn't play. Try again" : (_playing ? 'Pause' : 'Play'),
                  icon: Icon(
                    _failed ? LucideIcons.rotateCw : (_playing ? LucideIcons.pause : LucideIcons.play),
                    color: fg,
                  ),
                  onPressed: _toggle,
                ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Semantics(
            label: 'Voice message, ${VoiceNote.clock(_length)}',
            child: Waveform(
              levels: VoiceNote.waveformOf(widget.meta),
              progress: progress.clamp(0.0, 1.0),
              played: fg,
              unplayed: fg.withValues(alpha: 0.35),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(VoiceNote.clock(shown),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: fg.withValues(alpha: 0.8),
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
      ]),
    );
  }
}

/// Shown in place of the text field while recording.
class RecordingBar extends StatefulWidget {
  final VoiceRecorder recorder;
  final Future<void> Function(VoiceClip clip) onSend;
  final VoidCallback onDone;
  const RecordingBar({super.key, required this.recorder, required this.onSend, required this.onDone});

  @override
  State<RecordingBar> createState() => _RecordingBarState();
}

class _RecordingBarState extends State<RecordingBar> {
  final _recent = <int>[];
  final _clock = Stopwatch()..start();
  StreamSubscription<int>? _levels;
  Timer? _tick;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _levels = widget.recorder.levels.listen((l) {
      if (!mounted) return;
      setState(() {
        _recent.add(l);
        if (_recent.length > 40) _recent.removeAt(0);
      });
    });
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      if (_clock.elapsed >= VoiceNote.maxLength) {
        _send();
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _levels?.cancel();
    super.dispose();
  }

  Future<void> _send() async {
    if (_finishing) return;
    _finishing = true;
    _tick?.cancel();
    final clip = await widget.recorder.stop();
    if (clip != null && clip.bytes.isNotEmpty) await widget.onSend(clip);
    widget.onDone();
  }

  Future<void> _cancel() async {
    if (_finishing) return;
    _finishing = true;
    await widget.recorder.cancel();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(children: [
      IconButton(
        key: const ValueKey('voice-cancel'),
        tooltip: 'Discard',
        icon: Icon(LucideIcons.trash2, color: p.danger),
        onPressed: _cancel,
      ),
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: p.danger, shape: BoxShape.circle),
      ),
      const SizedBox(width: 8),
      Text(VoiceNote.clock(_clock.elapsed),
          key: const ValueKey('voice-clock'),
          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
      const SizedBox(width: 12),
      Expanded(
        child: Semantics(
          label: 'Recording',
          liveRegion: true,
          child: Waveform(
            levels: [...List.filled(40 - _recent.length, 0), ..._recent],
            progress: 1,
            played: p.accent,
            unplayed: p.accent,
          ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton.filled(
        key: const ValueKey('voice-send'),
        tooltip: 'Send voice message',
        icon: const Icon(LucideIcons.sendHorizontal),
        onPressed: _send,
      ),
    ]);
  }
}
