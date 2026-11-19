import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// How messages to a contact currently travel.
enum PeerConnectionState {
  /// WebRTC handshake in progress (messages use the relay meanwhile).
  connecting,

  /// Direct peer-to-peer data channel is open.
  connected,

  /// No direct channel: encrypted messages go through the relay queue.
  offline;

  String get shortLabel => switch (this) {
    PeerConnectionState.connected => 'Direct',
    PeerConnectionState.connecting => 'Connecting',
    PeerConnectionState.offline => 'Relay',
  };

  String get description => switch (this) {
    PeerConnectionState.connected =>
      'Direct peer-to-peer connection. Messages go straight to their '
          'device.',
    PeerConnectionState.connecting =>
      'Setting up a direct connection. Messages are relayed (still '
          'end-to-end encrypted) until it is ready.',
    PeerConnectionState.offline =>
      'No direct connection. Messages wait, end-to-end encrypted, in a '
          'short-lived relay queue until their device picks them up.',
  };
}

/// A small, subtle transport indicator ("Direct" / "Relay" / "Connecting")
/// for the chat app bar. Long-press / hover shows an explanation.
class ConnectionBadge extends StatefulWidget {
  const ConnectionBadge({
    super.key,
    required this.connectionState,
    this.isEncrypted = true,
    this.compact = true,
  });

  final PeerConnectionState connectionState;

  /// Kept for API compatibility; every channel is end-to-end encrypted.
  final bool isEncrypted;

  /// Icon + short label (true) or a pill with a longer label (false).
  final bool compact;

  @override
  State<ConnectionBadge> createState() => _ConnectionBadgeState();
}

class _ConnectionBadgeState extends State<ConnectionBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
    lowerBound: 0.35,
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant ConnectionBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.connectionState == PeerConnectionState.connecting) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = widget.connectionState;
    final (IconData icon, Color color) = switch (state) {
      PeerConnectionState.connected => (LucideIcons.zap, p.accent),
      PeerConnectionState.connecting => (LucideIcons.loaderCircle, p.warning),
      PeerConnectionState.offline => (LucideIcons.cloud, p.textMuted),
    };
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: state == PeerConnectionState.offline ? p.textMuted : color,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
    );

    final content = FadeTransition(
      opacity: _pulse,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
            widget.compact
                ? state.shortLabel
                : switch (state) {
                    PeerConnectionState.connected => 'Direct connection',
                    PeerConnectionState.connecting => 'Connecting…',
                    PeerConnectionState.offline => 'Via relay',
                  },
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    return Tooltip(
      message: state.description,
      child: Semantics(
        label: 'Connection: ${state.shortLabel}',
        child: widget.compact
            ? content
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: p.inputFill,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: content,
              ),
      ),
    );
  }
}
