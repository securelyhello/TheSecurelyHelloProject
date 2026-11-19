import 'package:flutter/material.dart';
import 'package:securelyhello/shared/theme/app_fonts.dart';

import 'package:securelyhello/shared/theme/app_colors.dart';
import 'package:securelyhello/shared/theme/app_palette.dart';

/// Securely Hello — Type scale.
///
/// Headings → Manrope (geometric, bold, premium).
/// Body / Labels → Inter (highly legible at small sizes).
abstract final class AppTypography {
  // ─── Display ───────────────────────────────────────────────────────
  static TextStyle get displayLarge => AppFonts.heading(
    fontSize: 57,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.25,
    height: 1.12,
    color: AppColors.textPrimary,
  );

  static TextStyle get displayMedium => AppFonts.heading(
    fontSize: 45,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    height: 1.16,
    color: AppColors.textPrimary,
  );

  static TextStyle get displaySmall => AppFonts.heading(
    fontSize: 36,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.22,
    color: AppColors.textPrimary,
  );

  // ─── Headline ──────────────────────────────────────────────────────
  static TextStyle get headlineLarge => AppFonts.heading(
    fontSize: 32,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.25,
    color: AppColors.textPrimary,
  );

  static TextStyle get headlineMedium => AppFonts.heading(
    fontSize: 28,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.29,
    color: AppColors.textPrimary,
  );

  static TextStyle get headlineSmall => AppFonts.heading(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.33,
    color: AppColors.textPrimary,
  );

  // ─── Title ─────────────────────────────────────────────────────────
  static TextStyle get titleLarge => AppFonts.heading(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.27,
    color: AppColors.textPrimary,
  );

  static TextStyle get titleMedium => AppFonts.heading(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.15,
    height: 1.50,
    color: AppColors.textPrimary,
  );

  static TextStyle get titleSmall => AppFonts.heading(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
    height: 1.43,
    color: AppColors.textPrimary,
  );

  // ─── Body ──────────────────────────────────────────────────────────
  static TextStyle get bodyLarge => AppFonts.body(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.5,
    height: 1.50,
    color: AppColors.textPrimary,
  );

  static TextStyle get bodyMedium => AppFonts.body(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.25,
    height: 1.43,
    color: AppColors.textPrimary,
  );

  static TextStyle get bodySmall => AppFonts.body(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.4,
    height: 1.33,
    color: AppColors.textSecondary,
  );

  // ─── Label ─────────────────────────────────────────────────────────
  static TextStyle get labelLarge => AppFonts.body(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
    height: 1.43,
    color: AppColors.textPrimary,
  );

  static TextStyle get labelMedium => AppFonts.body(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
    height: 1.33,
    color: AppColors.textSecondary,
  );

  static TextStyle get labelSmall => AppFonts.body(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.5,
    height: 1.45,
    color: AppColors.textHint,
  );

  // ─── Palette-aware TextTheme ───────────────────────────────────────
  /// The type scale coloured for [palette] (used by both light and dark).
  static TextTheme textThemeFor(AppPalette palette) => TextTheme(
    displayLarge: displayLarge.copyWith(color: palette.textPrimary),
    displayMedium: displayMedium.copyWith(color: palette.textPrimary),
    displaySmall: displaySmall.copyWith(color: palette.textPrimary),
    headlineLarge: headlineLarge.copyWith(color: palette.textPrimary),
    headlineMedium: headlineMedium.copyWith(color: palette.textPrimary),
    headlineSmall: headlineSmall.copyWith(color: palette.textPrimary),
    titleLarge: titleLarge.copyWith(color: palette.textPrimary),
    titleMedium: titleMedium.copyWith(color: palette.textPrimary),
    titleSmall: titleSmall.copyWith(color: palette.textPrimary),
    bodyLarge: bodyLarge.copyWith(
      color: palette.textPrimary,
      letterSpacing: 0.1,
    ),
    bodyMedium: bodyMedium.copyWith(
      color: palette.textPrimary,
      letterSpacing: 0.1,
    ),
    bodySmall: bodySmall.copyWith(color: palette.textSecondary),
    labelLarge: labelLarge.copyWith(color: palette.textPrimary),
    labelMedium: labelMedium.copyWith(color: palette.textSecondary),
    labelSmall: labelSmall.copyWith(color: palette.textMuted),
  );

  // ─── Full TextTheme ────────────────────────────────────────────────
  /// Returns the complete [TextTheme] wired to our type scale.
  static TextTheme get textTheme => TextTheme(
    displayLarge: displayLarge,
    displayMedium: displayMedium,
    displaySmall: displaySmall,
    headlineLarge: headlineLarge,
    headlineMedium: headlineMedium,
    headlineSmall: headlineSmall,
    titleLarge: titleLarge,
    titleMedium: titleMedium,
    titleSmall: titleSmall,
    bodyLarge: bodyLarge,
    bodyMedium: bodyMedium,
    bodySmall: bodySmall,
    labelLarge: labelLarge,
    labelMedium: labelMedium,
    labelSmall: labelSmall,
  );
}
