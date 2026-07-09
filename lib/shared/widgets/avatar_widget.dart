import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:securelyhello/shared/theme/app_colors.dart';

/// Predefined avatar sizes.
enum AvatarSize {
  /// 32 logical pixels.
  small(32),

  /// 44 logical pixels (default).
  medium(44),

  /// 64 logical pixels.
  large(64);

  const AvatarSize(this.value);

  /// The diameter in logical pixels.
  final double value;
}

/// A circular avatar that renders a network image when available, otherwise
/// falls back to the user's initials on a teal gradient background.
///
/// An optional green "online" indicator dot is drawn in the bottom-right
/// corner when [isOnline] is `true`.
class AvatarWidget extends StatelessWidget {
  const AvatarWidget({
    super.key,
    this.imageUrl,
    required this.displayName,
    this.size = AvatarSize.medium,
    this.isOnline = false,
  });

  /// Optional network image URL.
  final String? imageUrl;

  /// Used to derive the fallback initial(s).
  final String displayName;

  /// Visual size of the avatar.
  final AvatarSize size;

  /// Whether to show the green presence dot.
  final bool isOnline;

  /// Returns the first character of [displayName] uppercased, or `?`.
  String get _initials {
    if (displayName.trim().isEmpty) return '?';
    return displayName.trim()[0].toUpperCase();
  }

  double get _fontSize {
    switch (size) {
      case AvatarSize.small:
        return 13;
      case AvatarSize.medium:
        return 17;
      case AvatarSize.large:
        return 26;
    }
  }

  double get _indicatorSize {
    switch (size) {
      case AvatarSize.small:
        return 9;
      case AvatarSize.medium:
        return 12;
      case AvatarSize.large:
        return 16;
    }
  }

  double get _indicatorBorder {
    switch (size) {
      case AvatarSize.small:
        return 1.5;
      case AvatarSize.medium:
        return 2;
      case AvatarSize.large:
        return 2.5;
    }
  }

  @override
  Widget build(BuildContext context) {
    final diameter = size.value;

    return SizedBox(
      width: diameter,
      height: diameter,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // ── Avatar circle ──────────────────────────────────────────
          _buildAvatar(diameter),
          // ── Online indicator ───────────────────────────────────────
          if (isOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: _indicatorSize,
                height: _indicatorSize,
                decoration: BoxDecoration(
                  color: AppColors.online,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.surface,
                    width: _indicatorBorder,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAvatar(double diameter) {
    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;

    if (hasImage) {
      return Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.border, width: 1),
          image: DecorationImage(
            image: NetworkImage(imageUrl!),
            fit: BoxFit.cover,
          ),
        ),
      );
    }

    // Initials fallback with gradient.
    return Container(
      width: diameter,
      height: diameter,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [AppColors.avatarGradientStart, AppColors.avatarGradientEnd],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        _initials,
        style: GoogleFonts.manrope(
          fontSize: _fontSize,
          fontWeight: FontWeight.w700,
          color: AppColors.scaffold,
        ),
      ),
    );
  }
}
