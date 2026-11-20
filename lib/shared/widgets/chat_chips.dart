import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// Centred pill used for date separators ("Today", "Yesterday", …).
class DateSeparatorChip extends StatelessWidget {
  const DateSeparatorChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: p.systemChip,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: p.border),
          ),
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: p.onSystemChip),
          ),
        ),
      ),
    );
  }
}

/// Centred notice for local system messages (e.g. a safety-number change).
class SystemNoticeChip extends StatelessWidget {
  const SystemNoticeChip({
    super.key,
    required this.text,
    this.icon = LucideIcons.shieldAlert,
    this.onTap,
  });

  final String text;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Material(
            color: p.systemChip,
            borderRadius: BorderRadius.circular(AppRadius.control),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.control),
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  border: Border.all(color: p.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 15, color: p.warning),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        text,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: p.onSystemChip,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The "messages are end-to-end encrypted" banner shown at the very top of
/// a conversation.
class EncryptionBanner extends StatelessWidget {
  const EncryptionBanner({super.key, this.onTap, this.group = false});

  final VoidCallback? onTap;

  /// Group wording: messages go to each member through the relay, and
  /// there's no single safety number to verify.
  final bool group;

  @override
  Widget build(BuildContext context) {
    // Calm and on-brand: reassurance, not a warning.
    final p = context.palette;
    final bg = p.systemChip;
    final fg = p.onSystemChip;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 12, 32, 8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Material(
            color: bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.control),
              side: BorderSide(color: p.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(LucideIcons.shieldCheck, size: 14, color: p.accent),
                    ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        group
                            ? 'Messages are end-to-end encrypted for each member. '
                                  'Only people in this group can read them.'
                            : 'Messages are end-to-end encrypted and travel directly '
                                  'between devices when possible. No one outside this '
                                  'chat can read them.'
                                  '${onTap != null ? ' Tap to verify.' : ''}',
                        textAlign: TextAlign.center,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: fg, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Three softly pulsing dots ("typing…").
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color, this.size = 5});

  final Color? color;
  final double size;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.palette.accent;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = (_c.value - i * 0.18) % 1.0;
            final t = 0.5 + 0.5 * math.sin(phase * 2 * math.pi);
            return Padding(
              padding: EdgeInsets.only(right: i == 2 ? 0 : widget.size * 0.6),
              child: Opacity(
                opacity: 0.35 + 0.65 * t,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

/// Rounded unread counter ("3", "99+").
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count, this.muted = false});

  final int count;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: muted ? p.textMuted : p.brand,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: muted ? p.background : p.onBrand,
          fontWeight: FontWeight.w700,
          fontSize: 11.5,
          letterSpacing: 0,
        ),
      ),
    );
  }
}
