import 'package:flutter/material.dart';

import 'package:securelyhello/shared/theme/app_colors.dart';

/// A shimmer / skeleton loader with a smooth gradient-sweep animation.
///
/// Use one of the named constructors for pre-built placeholder layouts:
/// - [SkeletonLoader.chatList] — chat-list screen placeholder.
/// - [SkeletonLoader.messageList] — conversation screen placeholder.
/// - [SkeletonLoader.contactList] — contacts screen placeholder.
class SkeletonLoader extends StatefulWidget {
  /// Creates a generic skeleton with the supplied [child] wrapped in a
  /// shimmer gradient overlay.
  const SkeletonLoader({
    super.key,
    required this.child,
  });

  /// The static skeleton layout to animate.
  final Widget child;

  /// 6 rows — avatar circle + two text lines each.
  factory SkeletonLoader.chatList() => SkeletonLoader(
        child: _SkeletonChatList(),
      );

  /// Alternating left / right message bubbles.
  factory SkeletonLoader.messageList() => SkeletonLoader(
        child: _SkeletonMessageList(),
      );

  /// 8 rows — avatar circle + single text line.
  factory SkeletonLoader.contactList() => SkeletonLoader(
        child: _SkeletonContactList(),
      );

  @override
  State<SkeletonLoader> createState() => _SkeletonLoaderState();
}

class _SkeletonLoaderState extends State<SkeletonLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _animation = Tween<double>(begin: -2, end: 2).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment(_animation.value - 1, 0),
              end: Alignment(_animation.value + 1, 0),
              colors: const [
                AppColors.shimmerBase,
                AppColors.shimmerHighlight,
                AppColors.shimmerBase,
              ],
              stops: const [0.0, 0.5, 1.0],
            ).createShader(bounds);
          },
          blendMode: BlendMode.srcATop,
          child: widget.child,
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Pre-built skeleton layouts
// ═══════════════════════════════════════════════════════════════════════════

/// A placeholder bone element.
class _Bone extends StatelessWidget {
  const _Bone({
    required this.width,
    required this.height,
    this.borderRadius = 6,
  });

  final double width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.shimmerBase,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

class _CircleBone extends StatelessWidget {
  const _CircleBone({required this.diameter});

  final double diameter;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: const BoxDecoration(
        color: AppColors.shimmerBase,
        shape: BoxShape.circle,
      ),
    );
  }
}

// ─── Chat list skeleton ──────────────────────────────────────────────────
class _SkeletonChatList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: List.generate(6, (index) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                const _CircleBone(diameter: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Bone(
                        width: 100 + (index % 3) * 30.0,
                        height: 14,
                      ),
                      const SizedBox(height: 8),
                      _Bone(
                        width: 160 + (index % 2) * 40.0,
                        height: 12,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const _Bone(width: 36, height: 10),
              ],
            ),
          );
        }),
      ),
    );
  }
}

// ─── Message list skeleton ───────────────────────────────────────────────
class _SkeletonMessageList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final bubbles = <_BubbleSpec>[
      _BubbleSpec(isSent: false, widthFraction: 0.65, height: 52),
      _BubbleSpec(isSent: true, widthFraction: 0.55, height: 44),
      _BubbleSpec(isSent: false, widthFraction: 0.45, height: 36),
      _BubbleSpec(isSent: true, widthFraction: 0.70, height: 60),
      _BubbleSpec(isSent: false, widthFraction: 0.50, height: 44),
      _BubbleSpec(isSent: true, widthFraction: 0.40, height: 36),
      _BubbleSpec(isSent: false, widthFraction: 0.60, height: 52),
      _BubbleSpec(isSent: true, widthFraction: 0.50, height: 44),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: bubbles.map((spec) {
          return Align(
            alignment:
                spec.isSent ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: FractionallySizedBox(
                widthFactor: spec.widthFraction,
                child: _Bone(
                  width: double.infinity,
                  height: spec.height,
                  borderRadius: 16,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _BubbleSpec {
  const _BubbleSpec({
    required this.isSent,
    required this.widthFraction,
    required this.height,
  });

  final bool isSent;
  final double widthFraction;
  final double height;
}

// ─── Contact list skeleton ───────────────────────────────────────────────
class _SkeletonContactList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: List.generate(8, (index) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                const _CircleBone(diameter: 44),
                const SizedBox(width: 12),
                _Bone(
                  width: 110 + (index % 4) * 20.0,
                  height: 14,
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}
