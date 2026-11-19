import 'dart:ui';

/// Securely Hello — Dark-mode-first color palette.
///
/// Every color is hand-picked for OLED-friendly dark surfaces,
/// high-contrast readability, and a the Iris (indigo-violet) and Ember (coral) identity (docs/BRAND.md).
abstract final class AppColors {
  // ─── Backgrounds ───────────────────────────────────────────────────
  /// Scaffold / deepest background — near-black.
  static const Color scaffold = Color(0xFF0E0F1C);

  /// Primary surface (cards, sheets, dialogs).
  static const Color surface = Color(0xFF15162A);

  /// Elevated surface (floating action buttons, modals, popovers).
  static const Color elevated = Color(0xFF1C1E36);

  // ─── Brand / Accent ────────────────────────────────────────────────
  /// Iris, the signature colour.
  static const Color accent = Color(0xFF9C8FFF);

  /// Lighter Iris for hover / highlight states.
  static const Color accentLight = Color(0xFFC2BAFF);

  /// Darker Iris for pressed / active states.
  static const Color accentDark = Color(0xFF6F5FF0);

  /// Accent at 15 % opacity — used for sent-message bubble fill.
  static const Color accentSubtle = Color(0x269C8FFF);

  // ─── Text ──────────────────────────────────────────────────────────
  /// Primary text — full white.
  static const Color textPrimary = Color(0xFFF4F4FB);

  /// Secondary text — muted lavender-grey.
  static const Color textSecondary = Color(0xFFBCBEDA);

  /// Hint / placeholder text.
  static const Color textHint = Color(0xFF9295B8);

  /// Disabled text.
  static const Color textDisabled = Color(0xFF5A5C7E);

  // ─── Message Bubbles ───────────────────────────────────────────────
  /// Sent bubble background.
  static const Color sentBubble = Color(0xFF5546D9);

  /// Sent bubble border.
  static const Color sentBubbleBorder = Color(0xFF6F5FF0);

  /// Received bubble background.
  static const Color receivedBubble = Color(0xFF1C1E36);

  /// Received bubble border (transparent — no visible border).
  static const Color receivedBubbleBorder = Color(0xFF2D3052);

  // ─── Status / Semantic ─────────────────────────────────────────────
  /// Success green.
  static const Color success = Color(0xFF3DD69B);

  /// Warning amber.
  static const Color warning = Color(0xFFFFC266);

  /// Error / destructive red.
  static const Color error = Color(0xFFFF7A7A);

  /// Informational blue.
  static const Color info = Color(0xFF7FB2FF);

  // ─── Borders & Dividers ────────────────────────────────────────────
  /// Standard surface border.
  static const Color border = Color(0xFF2D3052);

  /// Divider.
  static const Color divider = Color(0xFF212341);

  /// Focused input border.
  static const Color focusBorder = Color(0xFF9C8FFF);

  // ─── Shadows & Overlays ────────────────────────────────────────────
  /// Shadow color for elevation.
  static const Color shadow = Color(0x66000000);

  /// Scrim / barrier overlay.
  static const Color scrim = Color(0x99000000);

  // ─── Online indicator ──────────────────────────────────────────────
  /// Online presence dot.
  static const Color online = Color(0xFF3DD69B);

  // ─── Gradient helpers ──────────────────────────────────────────────
  /// Avatar fallback gradient start.
  static const Color avatarGradientStart = Color(0xFF9C8FFF);

  /// Avatar fallback gradient end.
  static const Color avatarGradientEnd = Color(0xFF5546D9);

  /// Shimmer base.
  static const Color shimmerBase = Color(0xFF1C1E36);

  /// Shimmer highlight.
  static const Color shimmerHighlight = Color(0xFF2A2C4C);
}
