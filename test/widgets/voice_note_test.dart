import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/chat/attachment_service.dart';
import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/media/voice.dart';
import 'package:securelyhello/features/chat/widgets/composer.dart';
import 'package:securelyhello/features/chat/widgets/voice_note.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';

import '../attachment_service_test.dart' show FakeBlobs;

class FakeRecorder implements VoiceRecorder {
  bool allowed = true;
  bool started = false;
  bool cancelled = false;
  bool disposed = false;
  final _levels = StreamController<int>.broadcast();

  void level(int l) => _levels.add(l);

  @override
  Future<bool> hasPermission() async => allowed;
  @override
  Future<void> start() async => started = true;
  @override
  Stream<int> get levels => _levels.stream;
  @override
  Future<VoiceClip?> stop() async =>
      VoiceClip(Uint8List.fromList(List.filled(800, 7)), const Duration(seconds: 3), List.filled(48, 12));
  @override
  Future<void> cancel() async => cancelled = true;
  @override
  Future<void> dispose() async => disposed = true;
}

class FakePlayer implements VoicePlayer {
  Uint8List? played;
  final pos = StreamController<Duration>.broadcast();
  final on = StreamController<bool>.broadcast();

  @override
  Future<void> play(Uint8List bytes) async {
    played = bytes;
    on.add(true);
  }

  @override
  Future<void> pause() async => on.add(false);
  @override
  Future<void> resume() async => on.add(true);
  @override
  Future<void> seek(Duration to) async {}
  @override
  Stream<Duration> get position => pos.stream;
  @override
  Stream<bool> get playing => on.stream;
  @override
  Future<void> dispose() async {}
}

void main() {
  test('waveforms from contacts are clamped and resampled', () {
    expect(VoiceNote.waveformOf({'waveform': [-5, 99, 3]}), hasLength(VoiceNote.waveformPoints));
    expect(VoiceNote.waveformOf({'waveform': [-5, 99, 3]}).every((v) => v >= 0 && v <= 31), isTrue);
    expect(VoiceNote.waveformOf({'waveform': 'nope'}), hasLength(VoiceNote.waveformPoints));
    expect(VoiceNote.durationOf({'duration_ms': -1}), Duration.zero);
    expect(VoiceNote.durationOf({'duration_ms': 12345}), const Duration(milliseconds: 12345));
    expect(VoiceNote.level(-60), 0);
    expect(VoiceNote.level(0), 31);
    expect(VoiceNote.clock(const Duration(seconds: 75)), '1:15');
  });

  test('voice notes have their own preview', () {
    final meta = {'voice': true, 'mime': 'audio/mp4', 'duration_ms': 12000};
    expect(ChatService.previewText('', meta), '🎤 Voice message 0:12');
    expect(VoiceNote.isVoice({'voice': true, 'mime': 'image/png'}), isFalse,
        reason: 'a contact flagging an image as voice gets the file view');
  });

  Future<FakeRecorder> pumpComposer(WidgetTester t, List<VoiceClip> sent, {bool allowed = true}) async {
    final rec = FakeRecorder()..allowed = allowed;
    final controller = TextEditingController();
    await t.pumpWidget(Provider<VoiceMedia>.value(
      value: VoiceMedia(recorder: () => rec, player: FakePlayer.new),
      child: MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Composer(
            controller: controller,
            focusNode: FocusNode(),
            onSend: () {},
            onVoice: (clip) async => sent.add(clip),
          ),
        ),
      ),
    ));
    return rec;
  }

  testWidgets('record, watch the level, send', (t) async {
    final sent = <VoiceClip>[];
    final rec = await pumpComposer(t, sent);
    await t.tap(find.byKey(const ValueKey('composer-mic')));
    await t.pump();
    expect(rec.started, isTrue);
    expect(find.byKey(const ValueKey('recording-bar')), findsOneWidget);
    rec.level(20);
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const ValueKey('voice-send')));
    await t.pump();
    expect(sent, hasLength(1));
    expect(sent.single.duration, const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('recording-bar')), findsNothing);
    expect(rec.disposed, isTrue);
  });

  testWidgets('discarding sends nothing', (t) async {
    final sent = <VoiceClip>[];
    final rec = await pumpComposer(t, sent);
    await t.tap(find.byKey(const ValueKey('composer-mic')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('voice-cancel')));
    await t.pump();
    expect(rec.cancelled, isTrue);
    expect(sent, isEmpty);
    expect(find.byKey(const ValueKey('composer-mic')), findsOneWidget);
  });

  testWidgets('no microphone permission: a message, no recording', (t) async {
    final sent = <VoiceClip>[];
    final rec = await pumpComposer(t, sent, allowed: false);
    await t.tap(find.byKey(const ValueKey('composer-mic')));
    await t.pump();
    expect(rec.started, isFalse);
    expect(find.textContaining('microphone'), findsOneWidget);
  });

  testWidgets('a received voice note plays the decrypted audio', (t) async {
    final dir = Directory.systemTemp.createTempSync('sh_vn');
    final service = AttachmentService(directory: FakeBlobs(), cacheDirectory: () async => dir.path);
    final audio = Uint8List.fromList(List.generate(3000, (i) => i % 251));
    late Map<String, dynamic> meta;
    await t.runAsync(() async {
      meta = {
        ...await service.upload(audio, name: VoiceNote.fileName, mime: VoiceNote.mime),
        ...VoiceNote.meta(VoiceClip(audio, const Duration(seconds: 4), List.filled(48, 9))),
      };
    });
    final player = FakePlayer();
    await t.pumpWidget(Provider<VoiceMedia>.value(
      value: VoiceMedia(recorder: FakeRecorder.new, player: () => player),
      child: MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(body: VoiceNoteView(meta: meta, service: service, isSent: false)),
      ),
    ));
    expect(find.text('0:04'), findsOneWidget);
    await t.runAsync(() async {
      await t.tap(find.byKey(ValueKey('voice-play-${meta['id']}')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await t.pump();
    expect(player.played, audio);
    expect(find.byTooltip('Pause'), findsOneWidget);
    player.pos.add(const Duration(seconds: 2));
    await t.pump();
    expect(find.text('0:02'), findsOneWidget);
  });
}
