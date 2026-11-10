import 'package:flutter/material.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// Shimmering placeholder layouts shown while lists load.
///
/// - [SkeletonLoader.chatList] — chat list rows.
/// - [SkeletonLoader.messageList] — conversation bubbles.
/// - [SkeletonLoader.contactList] — contact rows.
class SkeletonLoader extends StatefulWidget {
  const SkeletonLoader({super.key, required this.child});

  final Widget child;

  factory SkeletonLoader.chatList({int rows = 8}) =>
      SkeletonLoader(child: _SkeletonRows(rows: rows, avatar: 52, lines: 2));

  factory SkeletonLoader.messageList() =>
      const SkeletonLoader(child: _SkeletonMessageList());

  factory SkeletonLoader.contactList({int rows = 10}) =>
      SkeletonLoader(child: _SkeletonRows(rows: rows, avatar: 44, lines: 2));

  @override
  State<SkeletonLoader> createState() => _SkeletonLoaderState();
}

class _SkeletonLoaderState extends State<SkeletonLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      label: 'Loading',
      child: ExcludeSemantics(
        child: ClipRect(
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: AnimatedBuilder(
              animation: _controller,
              child: widget.child,
              builder: (context, child) {
                final v = _controller.value * 4 - 2;
                return ShaderMask(
                  blendMode: BlendMode.srcATop,
                  shaderCallback: (bounds) => LinearGradient(
                    begin: Alignment(v - 1, 0),
                    end: Alignment(v + 1, 0),
                    colors: [p.shimmerBase, p.shimmerHighlight, p.shimmerBase],
                    stops: const [0.0, 0.5, 1.0],
                  ).createShader(bounds),
                  child: child,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Bone extends StatelessWidget {
  const _Bone({required this.width, required this.height, this.radius = 6});

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: context.palette.shimmerBase,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

class _SkeletonRows extends StatelessWidget {
  const _SkeletonRows({
    required this.rows,
    required this.avatar,
    required this.lines,
  });

  final int rows;
  final double avatar;
  final int lines;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(rows, (i) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              _Bone(width: avatar, height: avatar, radius: avatar / 2),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Bone(width: 90 + (i % 3) * 34.0, height: 13),
                    if (lines > 1) ...[
                      const SizedBox(height: 9),
                      _Bone(width: 150 + (i % 2) * 50.0, height: 11),
                    ],
                  ],
                ),
              ),
              if (lines > 1) const _Bone(width: 34, height: 10),
            ],
          ),
        );
      }),
    );
  }
}

class _SkeletonMessageList extends StatelessWidget {
  const _SkeletonMessageList();

  static const _specs = <(bool, double, double)>[
    (false, 0.62, 44),
    (false, 0.40, 36),
    (true, 0.55, 44),
    (false, 0.48, 36),
    (true, 0.70, 58),
    (true, 0.36, 36),
    (false, 0.58, 50),
    (true, 0.46, 36),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth.isFinite ? c.maxWidth : 400.0;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Column(
            children: [
              for (final (sent, frac, h) in _specs)
                Align(
                  alignment: sent
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: _Bone(
                      width: (w - 24) * frac,
                      height: h,
                      radius: AppRadius.bubble,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
