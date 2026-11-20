import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// A top edge that looks torn from a sheet of paper: a ragged line a few dp
/// deep. The raggedness comes from a fixed seed, so it is the same on every
/// build and every screen size (it only repeats along the width).
class TornPaperClipper extends CustomClipper<Path> {
  const TornPaperClipper({this.depth = 5});

  /// Largest dip of the torn edge, in dp.
  final double depth;

  static final List<double> _noise = (() {
    final r = math.Random(1207);
    return List<double>.generate(96, (_) => r.nextDouble());
  })();

  @override
  Path getClip(Size size) {
    final path = Path()..moveTo(0, _y(0));
    const step = 11.0;
    var i = 0;
    for (var x = step; x < size.width; x += step) {
      path.lineTo(x, _y(i += 1));
    }
    path
      ..lineTo(size.width, _y(i + 1))
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    return path;
  }

  double _y(int i) => depth * _noise[i % _noise.length];

  @override
  bool shouldReclip(TornPaperClipper old) => old.depth != depth;
}

class _TornPaperPainter extends CustomPainter {
  _TornPaperPainter({required this.color, required this.shadows, required this.clipper});

  final Color color;
  final List<BoxShadow> shadows;
  final TornPaperClipper clipper;

  @override
  void paint(Canvas canvas, Size size) {
    final path = clipper.getClip(size);
    for (final s in shadows) {
      canvas.drawPath(path.shift(s.offset), s.toPaint());
    }
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TornPaperPainter old) =>
      old.color != color || old.shadows != shadows || old.clipper.depth != clipper.depth;
}

/// A sheet of card-stock with a torn top edge that holds a screen's actions.
class TornPaperSheet extends StatelessWidget {
  const TornPaperSheet({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    const clipper = TornPaperClipper();
    return CustomPaint(
      painter: _TornPaperPainter(color: p.surface, shadows: p.paperShadow, clipper: clipper),
      child: Padding(padding: const EdgeInsets.only(top: 5), child: child),
    );
  }
}

/// Paper on top (the mark and title), a torn sheet below that holds the
/// form and fills the rest of the screen. Scrolls when the content is long.
class AuthPaperLayout extends StatelessWidget {
  const AuthPaperLayout({super.key, required this.header, required this.sheet, this.maxWidth = 460});

  final Widget header;
  final Widget sheet;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Column(
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 24), child: header),
                ),
              ),
              Expanded(
                child: SizedBox(
                  width: double.infinity,
                  child: TornPaperSheet(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxWidth),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(24, 28, 24, 24 + MediaQuery.paddingOf(context).bottom),
                          child: sheet,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// An error message from the server, in the danger colour on a soft tint.
class AuthErrorBanner extends StatelessWidget {
  const AuthErrorBanner(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: p.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.input),
        border: Border.all(color: p.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.circleAlert, color: p.danger, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.danger)),
          ),
        ],
      ),
    );
  }
}
