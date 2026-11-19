import 'package:flutter/material.dart';

/// The Securely Hello app icon (assets/brand, see docs/BRAND.md).
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 64, this.float = false});

  final double size;

  /// A slow, gentle float (off when the system asks for less motion).
  final bool float;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      size <= 96 ? 'assets/brand/logo-192.png' : 'assets/brand/logo-384.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'Securely Hello',
    );
    if (!float || MediaQuery.disableAnimationsOf(context)) return image;
    return _Float(child: image);
  }
}

class _Float extends StatefulWidget {
  const _Float({required this.child});
  final Widget child;

  @override
  State<_Float> createState() => _FloatState();
}

class _FloatState extends State<_Float> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..repeat(reverse: true);

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
          child: Transform.rotate(angle: 0.03 * (Curves.easeInOut.transform(_c.value) - 0.5), child: child),
        ),
        child: widget.child,
      );
}
