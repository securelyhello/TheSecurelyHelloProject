import 'dart:ui';

/// Securely Hello: the Night (dark) palette as constants, used by the static
/// type scale in [AppTypography]. Screens read colours from `context.palette`
/// ([AppPalette]), which also carries the Paper (light) values.
///
/// Pear #F7D21A and ink #12161C are the brand pair; see docs/BRAND.md.
abstract final class AppColors {
  // Backgrounds.
  static const Color scaffold = Color(0xFF0B1015);
  static const Color surface = Color(0xFF151A21);
  static const Color elevated = Color(0xFF1E252D);

  // Brand / accent (Pear).
  static const Color accent = Color(0xFFF7D21A);
  static const Color onAccent = Color(0xFF12161C);

  // Text.
  static const Color textPrimary = Color(0xFFF1EFE6);
  static const Color textSecondary = Color(0xFFC7C4BA);
  static const Color textHint = Color(0xFF999FA7);

  // Message bubbles.
  static const Color sentBubble = Color(0xFFE9C619);
  static const Color receivedBubble = Color(0xFF1E252D);

  // Status.
  static const Color success = Color(0xFF69D98D);
  static const Color warning = Color(0xFFF7D21A);
  static const Color error = Color(0xFFFB817F);
  static const Color info = Color(0xFF60AAF3);
  static const Color online = Color(0xFF69D98D);

  // Borders and dividers.
  static const Color border = Color(0xFF2D333B);
  static const Color divider = Color(0xFF222830);

  // Overlays.
  static const Color scrim = Color(0x99000000);
}
