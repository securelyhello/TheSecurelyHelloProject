import 'dart:ui';

/// Securely Hello — Dark-mode-first color palette.
///
/// Every color is hand-picked for OLED-friendly dark surfaces,
/// high-contrast readability, and a premium "electric teal" brand identity.
abstract final class AppColors {
  // ─── Backgrounds ───────────────────────────────────────────────────
  /// Scaffold / deepest background — near-black.
  static const Color scaffold = Color(0xFF0A0A0F);

  /// Primary surface (cards, sheets, dialogs).
  static const Color surface = Color(0xFF12121A);

  /// Elevated surface (floating action buttons, modals, popovers).
  static const Color elevated = Color(0xFF1A1A2E);

  // ─── Brand / Accent ────────────────────────────────────────────────
  /// Signature electric teal.
  static const Color accent = Color(0xFF00E5CC);

  /// Lighter teal for hover / highlight states.
  static const Color accentLight = Color(0xFF33FFEB);

  /// Darker teal for pressed / active states.
  static const Color accentDark = Color(0xFF00B8A3);

  /// Accent at 15 % opacity — used for sent-message bubble fill.
  static const Color accentSubtle = Color(0x2600E5CC);

  // ─── Text ──────────────────────────────────────────────────────────
  /// Primary text — full white.
  static const Color textPrimary = Color(0xFFFFFFFF);

  /// Secondary text — muted lavender-grey.
  static const Color textSecondary = Color(0xFFB8B8CC);

  /// Hint / placeholder text.
  static const Color textHint = Color(0xFF6B6B80);

  /// Disabled text.
  static const Color textDisabled = Color(0xFF4A4A5E);

  // ─── Message Bubbles ───────────────────────────────────────────────
  /// Sent bubble background (teal at 15 % opacity).
  static const Color sentBubble = Color(0x2600E5CC);

  /// Sent bubble border.
  static const Color sentBubbleBorder = Color(0xFF00E5CC);

  /// Received bubble background.
  static const Color receivedBubble = Color(0xFF1E1E30);

  /// Received bubble border (transparent — no visible border).
  static const Color receivedBubbleBorder = Color(0xFF2A2A3E);

  // ─── Status / Semantic ─────────────────────────────────────────────
  /// Success green.
  static const Color success = Color(0xFF34D399);

  /// Warning amber.
  static const Color warning = Color(0xFFFBBF24);

  /// Error / destructive red.
  static const Color error = Color(0xFFEF4444);

  /// Informational blue.
  static const Color info = Color(0xFF60A5FA);

  // ─── Borders & Dividers ────────────────────────────────────────────
  /// Standard surface border.
  static const Color border = Color(0xFF2A2A3E);

  /// Divider.
  static const Color divider = Color(0xFF1F1F30);

  /// Focused input border.
  static const Color focusBorder = Color(0xFF00E5CC);

  // ─── Shadows & Overlays ────────────────────────────────────────────
  /// Shadow color for elevation.
  static const Color shadow = Color(0x66000000);

  /// Scrim / barrier overlay.
  static const Color scrim = Color(0x99000000);

  // ─── Online indicator ──────────────────────────────────────────────
  /// Online presence dot.
  static const Color online = Color(0xFF34D399);

  // ─── Gradient helpers ──────────────────────────────────────────────
  /// Avatar fallback gradient start.
  static const Color avatarGradientStart = Color(0xFF00E5CC);

  /// Avatar fallback gradient end.
  static const Color avatarGradientEnd = Color(0xFF006B5F);

  /// Shimmer base.
  static const Color shimmerBase = Color(0xFF1A1A2E);

  /// Shimmer highlight.
  static const Color shimmerHighlight = Color(0xFF2A2A40);
}
