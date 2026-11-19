import 'package:flutter/material.dart';

/// The app's typefaces, bundled (assets/fonts, SIL Open Font License): no
/// font is ever fetched from the network.
///
/// - [heading]: Plus Jakarta Sans, friendly and geometric, for titles.
/// - [body]: Inter, for everything people read.
/// - [mono]: Source Code Pro, for safety numbers and codes.
///
/// Scripts these don't cover (Devanagari, Gujarati…) fall back to the
/// system's fonts.
abstract final class AppFonts {
  static const headingFamily = 'PlusJakartaSans';
  static const bodyFamily = 'Inter';
  static const monoFamily = 'SourceCodePro';

  static TextStyle heading({double? fontSize, FontWeight? fontWeight, Color? color, double? height, double? letterSpacing}) =>
      TextStyle(
          fontFamily: headingFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
          height: height,
          letterSpacing: letterSpacing);

  static TextStyle body({double? fontSize, FontWeight? fontWeight, Color? color, double? height, double? letterSpacing}) =>
      TextStyle(
          fontFamily: bodyFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
          height: height,
          letterSpacing: letterSpacing);

  static TextStyle mono({double? fontSize, FontWeight? fontWeight, Color? color, double? height, double? letterSpacing}) =>
      TextStyle(
          fontFamily: monoFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
          height: height,
          letterSpacing: letterSpacing,
          fontFeatures: const [FontFeature.tabularFigures()]);
}
