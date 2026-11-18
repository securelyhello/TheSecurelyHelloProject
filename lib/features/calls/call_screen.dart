import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/calls/call_service.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';

/// Opens the call screen for the current call (once; a second call to this
/// while it's showing does nothing).
Future<void> showCallScreen(BuildContext context) {
  if (_CallScreenState._showing) return Future.value();
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: true,
      fullscreenDialog: true,
      pageBuilder: (_, _, _) => const CallScreen(),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ),
  );
}

/// The full-screen view of a voice or video call.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  static bool _showing = false;

  final _remote = RTCVideoRenderer();
  final _local = RTCVideoRenderer();
  bool _renderersReady = false;
  Timer? _tick;
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    _showing = true;
    unawaited(_initRenderers());
    // The call timer.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _initRenderers() async {
    try {
      await _remote.initialize();
      await _local.initialize();
      if (mounted) setState(() => _renderersReady = true);
    } catch (e) {
      debugPrint('Video renderers unavailable: $e');
    }
  }

  @override
  void dispose() {
    _showing = false;
    _tick?.cancel();
    if (_renderersReady) {
      _remote.srcObject = null;
      _local.srcObject = null;
    }
    unawaited(_remote.dispose());
    unawaited(_local.dispose());
    super.dispose();
  }

  void _close() {
    if (_popped) return;
    _popped = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  String _status(ActiveCall c) => switch (c.phase) {
        CallPhase.outgoing => 'Ringing…',
        CallPhase.incoming => c.video ? 'Incoming video call' : 'Incoming voice call',
        CallPhase.connecting => 'Connecting…',
        CallPhase.active => CallService.clock(c.elapsed),
        CallPhase.ended => switch (c.endedBy) {
            CallEnd.declined => 'Declined',
            CallEnd.busy => 'Busy',
            CallEnd.noAnswer => c.outgoing ? 'No answer' : 'Missed call',
            CallEnd.failed => 'Couldn’t connect',
            CallEnd.elsewhere => 'Answered on another device',
            _ => 'Call ended',
          },
      };

  @override
  Widget build(BuildContext context) {
    final calls = context.watch<CallService?>();
    final c = calls?.call;
    if (calls == null || c == null) {
      _close();
      return const Scaffold(backgroundColor: Colors.black);
    }
    final name = context.watch<ContactsProvider>().getContact(c.peer)?.displayLabel ?? 'Contact';
    if (_renderersReady) {
      if (_remote.srcObject != c.remoteStream) _remote.srcObject = c.remoteStream;
      if (_local.srcObject != c.localStream) _local.srcObject = c.localStream;
    }
    final remoteVideo = c.video && (c.remoteStream?.getVideoTracks().isNotEmpty ?? false);
    final localVideo = c.video && !c.cameraOff && (c.localStream?.getVideoTracks().isNotEmpty ?? false);
    final t = Theme.of(context).textTheme;
    const fg = Colors.white;

    return PopScope(
      // Back doesn't hang up; the call keeps going while the app is in use.
      canPop: true,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1418),
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (remoteVideo && _renderersReady)
              RTCVideoView(_remote, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
            else
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF12343B), Color(0xFF0B1418)],
                  ),
                ),
              ),
            SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  if (!remoteVideo) ...[
                    AvatarWidget(displayName: name, seed: c.peer, size: AvatarSize.xlarge),
                    const SizedBox(height: 18),
                  ],
                  Text(
                    name,
                    key: const ValueKey('call-name'),
                    textAlign: TextAlign.center,
                    style: t.headlineSmall?.copyWith(color: fg, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _status(c),
                    key: const ValueKey('call-status'),
                    style: t.bodyLarge?.copyWith(color: fg.withValues(alpha: 0.8)),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(LucideIcons.lock, size: 13, color: fg.withValues(alpha: 0.6)),
                      const SizedBox(width: 5),
                      Text('End-to-end encrypted',
                          style: t.bodySmall?.copyWith(color: fg.withValues(alpha: 0.6))),
                    ],
                  ),
                  if (c.mediaUnavailable && c.phase != CallPhase.incoming)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        c.video ? 'Camera and microphone unavailable' : 'Microphone unavailable',
                        key: const ValueKey('call-no-media'),
                        style: t.bodySmall?.copyWith(color: const Color(0xFFFFC56B)),
                      ),
                    ),
                  const Spacer(),
                  _Controls(call: c, service: calls),
                  const SizedBox(height: 28),
                ],
              ),
            ),
            if (localVideo && _renderersReady)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 16,
                right: 16,
                width: 112,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: RTCVideoView(_local,
                      mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.call, required this.service});

  final ActiveCall call;
  final CallService service;

  @override
  Widget build(BuildContext context) {
    final c = call;
    if (c.phase == CallPhase.ended) return const SizedBox(height: 72);
    if (c.phase == CallPhase.incoming) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _RoundButton(
            key: const ValueKey('call-decline'),
            icon: LucideIcons.phoneOff,
            label: 'Decline',
            color: const Color(0xFFE5484D),
            onPressed: service.decline,
          ),
          if (c.video)
            _RoundButton(
              key: const ValueKey('call-accept-voice'),
              icon: LucideIcons.phone,
              label: 'Voice only',
              color: Colors.white24,
              onPressed: () => service.accept(video: false),
            ),
          _RoundButton(
            key: const ValueKey('call-accept'),
            icon: c.video ? LucideIcons.video : LucideIcons.phone,
            label: 'Accept',
            color: const Color(0xFF2FB36B),
            onPressed: () => service.accept(),
          ),
        ],
      );
    }
    final mobile = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 18,
      runSpacing: 16,
      children: [
        _RoundButton(
          key: const ValueKey('call-mute'),
          icon: c.muted ? LucideIcons.micOff : LucideIcons.mic,
          label: c.muted ? 'Unmute' : 'Mute',
          color: c.muted ? Colors.white : Colors.white24,
          iconColor: c.muted ? Colors.black : Colors.white,
          onPressed: service.toggleMute,
        ),
        if (mobile)
          _RoundButton(
            icon: LucideIcons.volume2,
            label: 'Speaker',
            color: c.speakerOn ? Colors.white : Colors.white24,
            iconColor: c.speakerOn ? Colors.black : Colors.white,
            onPressed: service.toggleSpeaker,
          ),
        if (c.video) ...[
          _RoundButton(
            key: const ValueKey('call-camera'),
            icon: c.cameraOff ? LucideIcons.videoOff : LucideIcons.video,
            label: c.cameraOff ? 'Camera on' : 'Camera off',
            color: c.cameraOff ? Colors.white : Colors.white24,
            iconColor: c.cameraOff ? Colors.black : Colors.white,
            onPressed: service.toggleCamera,
          ),
          if (mobile)
            _RoundButton(
              icon: LucideIcons.switchCamera,
              label: 'Flip',
              color: Colors.white24,
              onPressed: service.switchCamera,
            ),
        ],
        _RoundButton(
          key: const ValueKey('call-hangup'),
          icon: LucideIcons.phoneOff,
          label: 'End',
          color: const Color(0xFFE5484D),
          onPressed: service.hangUp,
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
    this.iconColor = Colors.white,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color iconColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: SizedBox(width: 64, height: 64, child: Icon(icon, color: iconColor, size: 26)),
            ),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Colors.white.withValues(alpha: 0.85))),
        ],
      ),
    );
  }
}
