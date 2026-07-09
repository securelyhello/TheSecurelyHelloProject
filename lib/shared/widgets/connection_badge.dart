import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/shared/theme/app_colors.dart';
import 'package:securelyhello/shared/theme/app_typography.dart';

/// The current peer-connection state.
enum PeerConnectionState {
  /// WebRTC or signaling handshake in progress.
  connecting,

  /// Fully connected via direct P2P channel.
  connected,

  /// No network or peer unreachable.
  offline,
}

/// A subtle pill-shaped badge that communicates the P2P connection status
/// and encryption state. Designed to sit inside the chat app bar.
class ConnectionBadge extends StatefulWidget {
  const ConnectionBadge({
    super.key,
    required this.connectionState,
    this.isEncrypted = true,
  });

  /// Current transport state.
  final PeerConnectionState connectionState;

  /// Whether the channel is end-to-end encrypted.
  final bool isEncrypted;

  @override
  State<ConnectionBadge> createState() => _ConnectionBadgeState();
}

class _ConnectionBadgeState extends State<ConnectionBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _pulseAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (widget.connectionState == PeerConnectionState.connecting) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant ConnectionBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.connectionState == PeerConnectionState.connecting) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      _pulseController.stop();
      _pulseController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  // ─── Visual config per state ───────────────────────────────────────
  Color get _dotColor {
    switch (widget.connectionState) {
      case PeerConnectionState.connected:
        return AppColors.accent;
      case PeerConnectionState.connecting:
        return AppColors.warning;
      case PeerConnectionState.offline:
        return AppColors.textHint;
    }
  }

  IconData get _icon {
    switch (widget.connectionState) {
      case PeerConnectionState.connected:
        return widget.isEncrypted ? LucideIcons.shieldCheck : LucideIcons.wifi;
      case PeerConnectionState.connecting:
        return LucideIcons.loader;
      case PeerConnectionState.offline:
        return LucideIcons.wifiOff;
    }
  }

  String get _label {
    switch (widget.connectionState) {
      case PeerConnectionState.connected:
        return widget.isEncrypted
            ? 'End-to-end encrypted · Direct connection'
            : 'Direct connection';
      case PeerConnectionState.connecting:
        return 'Connecting...';
      case PeerConnectionState.offline:
        return 'Offline';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.elevated.withAlpha(178),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppColors.border.withAlpha(102),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Status dot
              Opacity(
                opacity: widget.connectionState == PeerConnectionState.connecting
                    ? _pulseAnimation.value
                    : 1.0,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Icon
              Icon(_icon, size: 12, color: _dotColor),
              const SizedBox(width: 4),
              // Label
              Flexible(
                child: Text(
                  _label,
                  style: AppTypography.labelSmall.copyWith(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                    letterSpacing: 0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
