import 'package:flutter/material.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// Predefined avatar sizes.
enum AvatarSize {
  /// 32 logical pixels.
  small(32),

  /// 44 logical pixels (default).
  medium(44),

  /// 52 logical pixels — chat list rows.
  list(52),

  /// 64 logical pixels.
  large(64),

  /// 96 logical pixels — profile headers.
  xlarge(96);

  const AvatarSize(this.value);

  /// The diameter in logical pixels.
  final double value;
}

/// A circular avatar: network image when available, otherwise initials on a
/// colour derived from [seed] (or the name), so each contact is recognisable.
///
/// A presence dot is drawn bottom-right when [isOnline] is `true`.
class AvatarWidget extends StatelessWidget {
  const AvatarWidget({
    super.key,
    this.imageUrl,
    required this.displayName,
    this.size = AvatarSize.medium,
    this.isOnline = false,
    this.seed,
    this.ringColor,
  });

  final String? imageUrl;
  final String displayName;
  final AvatarSize size;
  final bool isOnline;

  /// Stable value (e.g. the user id) used to pick the fallback colour.
  final String? seed;

  /// Colour of the ring around the presence dot; defaults to the surface.
  final Color? ringColor;

  /// Up to two initials ("Ada Lovelace" → "AL", "ada" → "A").
  static String initialsOf(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    String first(String s) => String.fromCharCodes(s.runes.take(1));
    if (parts.length == 1) return first(parts.first).toUpperCase();
    return (first(parts.first) + first(parts.last)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final d = size.value;
    final dot = (d * 0.26).clamp(9.0, 18.0);
    final ring = (d * 0.04).clamp(1.5, 3.0);

    return Semantics(
      label: isOnline ? '$displayName, online' : displayName,
      image: true,
      child: SizedBox(
        width: d,
        height: d,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _avatar(context, p, d),
            if (isOnline)
              Positioned(
                right: d * 0.02,
                bottom: d * 0.02,
                child: Container(
                  width: dot,
                  height: dot,
                  decoration: BoxDecoration(
                    color: p.online,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: ringColor ?? p.surface,
                      width: ring,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(BuildContext context, AppPalette p, double d) {
    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;
    if (hasImage) {
      return ClipOval(
        child: Image.network(
          imageUrl!,
          width: d,
          height: d,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _initials(context, p, d),
        ),
      );
    }
    return _initials(context, p, d);
  }

  Widget _initials(BuildContext context, AppPalette p, double d) {
    final base = p.avatarColorFor(seed ?? displayName);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            Color.lerp(base, Colors.white, isDark ? 0.08 : 0.12)!,
            Color.lerp(base, Colors.black, isDark ? 0.35 : 0.18)!,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initialsOf(displayName),
        maxLines: 1,
        textScaler: TextScaler.noScaling,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontSize: d * 0.38,
          height: 1,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
