import 'package:flutter/material.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// The Securely Hello mark: the Sealed note, a speech bubble whose top
/// carries an envelope flap with a pear seal at the V (assets/brand/logo.svg
/// and mark.svg, docs/BRAND.md), drawn from the same geometry so it stays
/// sharp at any size and follows the theme.
///
/// By default it is the app icon: an ink tile holding the cream bubble. With
/// [tile] false only the bubble, flap and seal are drawn, in ink on a light
/// surface and in cream on a dark one, so it sits straight on a screen.
class BrandLogo extends StatelessWidget {
  const BrandLogo({
    super.key,
    this.size = 64,
    this.float = false,
    this.tile = true,
  });

  final double size;

  /// A slow, gentle float (off when the system asks for less motion).
  final bool float;

  /// Draw the ink tile behind the bubble (the app icon).
  final bool tile;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dark = p.background.computeLuminance() < 0.5;
    // Colours come from the palette: ink and cream are its text colours.
    final ink = p.onBrand;
    final cream = dark ? p.textPrimary : p.background;
    final mark = Semantics(
      label: 'Securely Hello',
      image: true,
      child: ExcludeSemantics(
        child: CustomPaint(
          size: Size.square(size),
          painter: _MarkPainter(
            tile: tile,
            tileColor: ink,
            bubble: tile ? cream : (dark ? p.textPrimary : ink),
            cut: tile ? ink : p.background,
            seal: p.brand,
          ),
        ),
      ),
    );
    if (!float || MediaQuery.disableAnimationsOf(context)) return mark;
    return _Float(child: mark);
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter({
    required this.tile,
    required this.tileColor,
    required this.bubble,
    required this.cut,
    required this.seal,
  });

  final bool tile;
  final Color tileColor;
  final Color bubble;

  /// The flap line and seal rim (the tile colour, or the screen behind a
  /// tile-less mark).
  final Color cut;
  final Color seal;

  /// The 512 x 512 design grid of the SVG.
  static Path _bubblePath() => Path()
    ..moveTo(176, 112)
    ..lineTo(336, 112)
    ..arcToPoint(const Offset(408, 184), radius: const Radius.circular(72))
    ..lineTo(408, 272)
    ..arcToPoint(const Offset(336, 344), radius: const Radius.circular(72))
    ..lineTo(204, 344)
    ..lineTo(138, 398)
    ..cubicTo(126, 408, 112, 400, 116, 386)
    ..lineTo(132, 330)
    ..arcToPoint(const Offset(104, 272), radius: const Radius.circular(72))
    ..lineTo(104, 184)
    ..arcToPoint(const Offset(176, 112), radius: const Radius.circular(72))
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 512, size.height / 512);
    if (tile) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(0, 0, 512, 512),
          const Radius.circular(116),
        ),
        Paint()..color = tileColor,
      );
    }
    canvas.drawPath(_bubblePath(), Paint()..color = bubble);
    final flap = Paint()
      ..color = cut
      ..style = PaintingStyle.stroke
      ..strokeWidth = 24
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(150, 160)
        ..lineTo(256, 236)
        ..lineTo(362, 160),
      flap,
    );
    canvas.drawCircle(const Offset(256, 236), 30, Paint()..color = seal);
    canvas.drawCircle(
      const Offset(256, 236),
      30,
      Paint()
        ..color = cut
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.tile != tile ||
      old.tileColor != tileColor ||
      old.bubble != bubble ||
      old.cut != cut ||
      old.seal != seal;
}

class _Float extends StatefulWidget {
  const _Float({required this.child});
  final Widget child;

  @override
  State<_Float> createState() => _FloatState();
}

class _FloatState extends State<_Float> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, child) => Transform.translate(
      offset: Offset(0, -6 * Curves.easeInOut.transform(_c.value)),
      child: Transform.rotate(
        angle: 0.03 * (Curves.easeInOut.transform(_c.value) - 0.5),
        child: child,
      ),
    ),
    child: widget.child,
  );
}
