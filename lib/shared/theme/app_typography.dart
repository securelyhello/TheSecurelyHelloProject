import 'package:flutter/material.dart';
import 'package:securelyhello/shared/theme/app_fonts.dart';

import 'package:securelyhello/shared/theme/app_colors.dart';
import 'package:securelyhello/shared/theme/app_palette.dart';

/// Securely Hello type scale: 12 / 14 / 16 / 19 / 23 / 28 / 34.
///
/// Headings, names, titles and buttons are Chillax 600 (tab labels 500) with
/// -0.02em tracking, in sentence case. Body and messages are Inter 400/500.
/// Hindi and Gujarati fall back to the system fonts glyph by glyph.
abstract final class AppTypography {
  static TextStyle _heading(double size, double height, {FontWeight? weight}) =>
      AppFonts.heading(
        fontSize: size,
        fontWeight: weight ?? FontWeight.w600,
        letterSpacing: -0.02 * size,
        height: height,
        color: AppColors.textPrimary,
      );

  // Display.
  static TextStyle get displayLarge => _heading(34, 1.15);
  static TextStyle get displayMedium => _heading(34, 1.15);
  static TextStyle get displaySmall => _heading(28, 1.2);

  // Headline.
  static TextStyle get headlineLarge => _heading(34, 1.15);
  static TextStyle get headlineMedium => _heading(28, 1.2);
  static TextStyle get headlineSmall => _heading(23, 1.25);

  // Title.
  static TextStyle get titleLarge => _heading(19, 1.3);
  static TextStyle get titleMedium => _heading(16, 1.4);
  static TextStyle get titleSmall => _heading(14, 1.4);

  // Body.
  static TextStyle get bodyLarge => AppFonts.body(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.5,
    color: AppColors.textPrimary,
  );

  static TextStyle get bodyMedium => AppFonts.body(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.43,
    color: AppColors.textPrimary,
  );

  static TextStyle get bodySmall => AppFonts.body(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.33,
    color: AppColors.textSecondary,
  );

  // Label. Large is the button label (Chillax 600); the smaller two are Inter.
  static TextStyle get labelLarge => AppFonts.heading(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.43,
    color: AppColors.textPrimary,
  );

  static TextStyle get labelMedium => AppFonts.body(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.33,
    color: AppColors.textSecondary,
  );

  static TextStyle get labelSmall => AppFonts.body(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.33,
    color: AppColors.textHint,
  );

  /// Tab labels (bottom bar and rail): Chillax 500.
  static TextStyle get tabLabel => AppFonts.heading(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.33,
  );

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
    bodyLarge: bodyLarge.copyWith(color: palette.textPrimary),
    bodyMedium: bodyMedium.copyWith(color: palette.textPrimary),
    bodySmall: bodySmall.copyWith(color: palette.textSecondary),
    labelLarge: labelLarge.copyWith(color: palette.textPrimary),
    labelMedium: labelMedium.copyWith(color: palette.textSecondary),
    labelSmall: labelSmall.copyWith(color: palette.textMuted),
  );

  /// The complete [TextTheme] in the Night colours.
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
