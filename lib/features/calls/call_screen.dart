import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/calls/call_service.dart';
import 'package:securelyhello/core/calls/call_system.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';

/// Register in MaterialApp.navigatorObservers: the call screen learns when
/// a page covers it (it is then no longer shown over the lock screen).
final RouteObserver<PageRoute<dynamic>> callRouteObserver = RouteObserver<PageRoute<dynamic>>();

/// Whether the call screen is open.
bool get callScreenShowing => _CallScreenState._showing;

/// Before leaving the call screen for something else (a chat from a
/// notification…): on a locked phone the user must unlock first. True when
/// that may go ahead.
Future<bool> unlockToLeaveCallScreen(BuildContext context) async {
  if (!callScreenShowing) return true;
  final system = context.read<CallSystemHolder?>()?.system;
  return system == null || await system.unlockToLeave();
}

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

/// The call screen is always on ink (the Night palette), in either theme.
const _ink = AppPalette.dark;

/// The full-screen view of a voice or video call.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with RouteAware {
  static bool _showing = false;

  CallSystem? _system;
  PageRoute<dynamic>? _route;

  /// The call ended: the screen may close (even while locked).
  bool _allowPop = false;
  bool _leaving = false;

  final _remote = RTCVideoRenderer();
  final _local = RTCVideoRenderer();
  bool _renderersReady = false;
  Timer? _tick;
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    _showing = true;
    _system = context.read<CallSystemHolder?>()?.system;
    // Shown over the lock screen (while the call rings or runs) only now.
    unawaited(_system?.setCallScreenShown(true));
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute && route != _route) {
      if (_route != null) callRouteObserver.unsubscribe(this);
      _route = route;
      callRouteObserver.subscribe(this, route);
    }
  }

  // A page (a chat…) opened over the call screen: no longer over the lock
  // screen. Back to the call screen: again.
  @override
  void didPushNext() => unawaited(_system?.setCallScreenShown(false));

  @override
  void didPopNext() => unawaited(_system?.setCallScreenShown(true));

  @override
  void dispose() {
    callRouteObserver.unsubscribe(this);
    unawaited(_system?.setCallScreenShown(false));
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
    _allowPop = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // The call is over (the native side stopped showing over the lock
      // screen with it); say so before the chats come into view.
      await _system?.setCallScreenShown(false);
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  /// Back during a call. On Android the app may be showing over the lock
  /// screen: the lock screen is dismissed first (the user unlocks), and
  /// only then does the call screen go, after the app has stopped showing
  /// over the lock screen.
  Future<void> _leave() async {
    final system = _system;
    if (_leaving || system == null) return;
    _leaving = true;
    try {
      if (!await system.unlockToLeave() || !mounted) return;
      await system.setCallScreenShown(false);
      if (!mounted) return;
      _allowPop = true;
      Navigator.of(context).pop();
    } finally {
      _leaving = false;
    }
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
      return Scaffold(backgroundColor: _ink.background);
    }
    final name = context.watch<ContactsProvider>().getContact(c.peer)?.displayLabel ?? 'Contact';
    if (_renderersReady) {
      if (_remote.srcObject != c.remoteStream) _remote.srcObject = c.remoteStream;
      if (_local.srcObject != c.localStream) _local.srcObject = c.localStream;
    }
    final remoteVideo = c.video && (c.remoteStream?.getVideoTracks().isNotEmpty ?? false);
    // Picture-in-picture (Android, video calls): only their video.
    final pip = context.watch<CallSystemHolder?>()?.system.inPictureInPicture;
    if (pip != null) {
      return ValueListenableBuilder<bool>(
        valueListenable: pip,
        builder: (context, inPip, child) => inPip ? _pipView(c, name, remoteVideo) : child!,
        child: _fullView(context, calls, c, name, remoteVideo),
      );
    }
    return _fullView(context, calls, c, name, remoteVideo);
  }

  Widget _pipView(ActiveCall c, String name, bool remoteVideo) => ColoredBox(
    key: const ValueKey('call-pip'),
    color: _ink.background,
    child: remoteVideo && _renderersReady
        ? RTCVideoView(_remote, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
        : Center(
            child: AvatarWidget(displayName: name, seed: c.peer, size: AvatarSize.large),
          ),
  );

  Widget _fullView(BuildContext context, CallService calls, ActiveCall c, String name, bool remoteVideo) {
    final localVideo = c.video && !c.cameraOff && (c.localStream?.getVideoTracks().isNotEmpty ?? false);
    final t = Theme.of(context).textTheme;
    final fg = _ink.textPrimary;
    final muted = _ink.textSecondary;
    // A short window (landscape phone, split screen): a smaller ring without
    // its pulsing halo, tighter gaps.
    final compact = MediaQuery.sizeOf(context).height < 480;

    return PopScope(
      // Back doesn't hang up; the call keeps going while the app is in use.
      // On Android it goes through [_leave] (the lock screen, H1).
      canPop: _allowPop || !(_system?.enabled ?? false),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        backgroundColor: _ink.background,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (remoteVideo && _renderersReady)
              RTCVideoView(_remote, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
            else
              ColoredBox(color: _ink.background),
            SafeArea(
              child: Column(
                children: [
                  // Who and how the call is going. Scrolls when the window is
                  // too short for it (the buttons below stay put).
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) => SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: box.maxHeight),
                          child: Column(
                            children: [
                              SizedBox(height: compact ? 8 : 24),
                              if (!remoteVideo) ...[
                                SizedBox(height: compact ? 0 : 24),
                                _PearRing(
                                  active: c.phase != CallPhase.ended,
                                  compact: compact,
                                  child: AvatarWidget(
                                    displayName: name,
                                    seed: c.peer,
                                    size: compact ? AvatarSize.large : AvatarSize.xlarge,
                                  ),
                                ),
                                SizedBox(height: compact ? 12 : 28),
                              ],
                              Text(
                                name,
                                key: const ValueKey('call-name'),
                                textAlign: TextAlign.center,
                                style: t.headlineSmall?.copyWith(color: fg),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _status(c),
                                key: const ValueKey('call-status'),
                                style: t.bodyLarge?.copyWith(color: muted),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(LucideIcons.lock, size: 13, color: _ink.textMuted),
                                  const SizedBox(width: 5),
                                  Text('End-to-end encrypted', style: t.bodySmall?.copyWith(color: _ink.textMuted)),
                                ],
                              ),
                              if (c.mediaUnavailable && c.phase != CallPhase.incoming)
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Text(
                                    c.video ? 'Camera and microphone unavailable' : 'Microphone unavailable',
                                    key: const ValueKey('call-no-media'),
                                    style: t.bodySmall?.copyWith(color: _ink.warning),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  _Controls(call: c, service: calls),
                  SizedBox(height: compact ? 12 : 28),
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
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: RTCVideoView(
                    _local,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
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
            color: _ink.danger,
            iconColor: _ink.onAccent,
            onPressed: () {
              HapticFeedback.mediumImpact();
              service.decline();
            },
          ),
          if (c.video)
            _RoundButton(
              key: const ValueKey('call-accept-voice'),
              icon: LucideIcons.phone,
              label: 'Voice only',
              color: _ink.elevated,
              onPressed: () => service.accept(video: false),
            ),
          _RoundButton(
            key: const ValueKey('call-accept'),
            icon: c.video ? LucideIcons.video : LucideIcons.phone,
            label: 'Accept',
            color: _ink.success,
            iconColor: _ink.onAccent,
            onPressed: () {
              HapticFeedback.mediumImpact();
              service.accept();
            },
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
          color: c.muted ? _ink.textPrimary : _ink.elevated,
          iconColor: c.muted ? _ink.background : _ink.textPrimary,
          onPressed: service.toggleMute,
        ),
        if (mobile)
          _RoundButton(
            key: const ValueKey('call-audio'),
            icon: c.speakerOn ? LucideIcons.volume2 : LucideIcons.ear,
            label: c.speakerOn ? 'Speaker' : 'Audio',
            color: c.speakerOn ? _ink.textPrimary : _ink.elevated,
            iconColor: c.speakerOn ? _ink.background : _ink.textPrimary,
            onPressed: () => _pickAudio(context),
          ),
        if (c.video) ...[
          _RoundButton(
            key: const ValueKey('call-camera'),
            icon: c.cameraOff ? LucideIcons.videoOff : LucideIcons.video,
            label: c.cameraOff ? 'Camera on' : 'Camera off',
            color: c.cameraOff ? _ink.textPrimary : _ink.elevated,
            iconColor: c.cameraOff ? _ink.background : _ink.textPrimary,
            onPressed: service.toggleCamera,
          ),
          if (mobile)
            _RoundButton(
              icon: LucideIcons.switchCamera,
              label: 'Flip',
              color: _ink.elevated,
              onPressed: service.switchCamera,
            ),
        ],
        _RoundButton(
          key: const ValueKey('call-hangup'),
          icon: LucideIcons.phoneOff,
          label: 'End',
          color: _ink.danger,
          iconColor: _ink.onAccent,
          onPressed: () {
            HapticFeedback.mediumImpact();
            service.hangUp();
          },
        ),
      ],
    );
  }

  /// Speaker, earpiece, Bluetooth or wired: a sheet when there is more
  /// than a phone's two choices, otherwise a speaker toggle.
  Future<void> _pickAudio(BuildContext context) async {
    final outputs = await service.audioOutputs();
    if (!context.mounted) return;
    if (outputs.length <= 2) {
      await service.toggleSpeaker();
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in outputs)
              ListTile(
                leading: Icon(_audioIcon(o.deviceId, o.label)),
                title: Text(o.label.isEmpty ? o.deviceId : o.label),
                trailing: o.deviceId == call.audioOutput ? const Icon(LucideIcons.check) : null,
                onTap: () => Navigator.pop(ctx, o.deviceId),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await service.selectAudioOutput(picked);
  }

  static IconData _audioIcon(String id, String label) {
    final s = '$id $label'.toLowerCase();
    if (s.contains('bluetooth')) return LucideIcons.bluetooth;
    if (s.contains('speaker')) return LucideIcons.volume2;
    if (s.contains('headset') || s.contains('wired')) return LucideIcons.headphones;
    return LucideIcons.ear;
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color? iconColor;
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
              child: SizedBox(width: 64, height: 64, child: Icon(icon, color: iconColor ?? _ink.textPrimary, size: 26)),
            ),
          ),
          const SizedBox(height: 8),
          Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: _ink.textSecondary)),
        ],
      ),
    );
  }
}

/// A slow pear ring around the avatar: a still ring plus a soft halo that
/// breathes out and fades (still when the system asks for no animations).
class _PearRing extends StatefulWidget {
  const _PearRing({required this.child, required this.active, this.compact = false});

  final Widget child;
  final bool active;

  /// For short windows: a 64dp avatar and no pulsing halo.
  final bool compact;

  @override
  State<_PearRing> createState() => _PearRingState();
}

class _PearRingState extends State<_PearRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_PearRing old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Breathing only while the call is live, the window has room for the
  /// halo, and the system allows animation.
  void _sync() {
    final d = AppMotion.of(context, const Duration(milliseconds: 2800));
    if (d == Duration.zero || !widget.active || widget.compact) {
      _c.stop();
    } else {
      _c.duration = d;
      if (!_c.isAnimating) _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final avatar = widget.compact ? 64.0 : 96.0;
    const gap = 6.0;
    const ring = 3.0;
    final box = avatar + 2 * (gap + ring);
    // Room for the halo to grow into.
    final halo = widget.compact ? 0.0 : 40.0;
    return SizedBox(
      width: box + halo,
      height: box + halo,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = Curves.easeOut.transform(_c.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              if (_c.isAnimating)
                Container(
                  width: box + 40 * t,
                  height: box + 40 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _ink.brand.withValues(alpha: 0.5 * (1 - t)),
                      width: ring,
                    ),
                  ),
                ),
              child!,
            ],
          );
        },
        child: Container(
          width: box,
          height: box,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: _ink.brand, width: ring),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
