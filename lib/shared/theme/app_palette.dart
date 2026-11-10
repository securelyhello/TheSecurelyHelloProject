import 'package:flutter/material.dart';

import 'package:securelyhello/shared/theme/app_colors.dart';

/// Semantic colour tokens for Securely Hello.
///
/// Screens and widgets read colours from here (`context.palette`) rather than
/// from [AppColors] constants, so the same UI renders correctly in the dark
/// (primary) and light themes.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.background,
    required this.chatBackground,
    required this.surface,
    required this.elevated,
    required this.inputFill,
    required this.border,
    required this.divider,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.onAccent,
    required this.accentContainer,
    required this.onAccentContainer,
    required this.bubbleOut,
    required this.bubbleOutText,
    required this.bubbleOutMeta,
    required this.bubbleIn,
    required this.bubbleInText,
    required this.bubbleInMeta,
    required this.tickRead,
    required this.link,
    required this.systemChip,
    required this.onSystemChip,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.online,
    required this.shimmerBase,
    required this.shimmerHighlight,
    required this.selection,
    required this.avatarColors,
  });

  /// Deepest background (scaffold).
  final Color background;

  /// Conversation canvas behind the bubbles.
  final Color chatBackground;

  /// Bars, list panes, cards.
  final Color surface;

  /// Sheets, dialogs, menus.
  final Color elevated;

  /// Text-field / search-field fill.
  final Color inputFill;

  final Color border;
  final Color divider;

  final Color textPrimary;
  final Color textSecondary;

  /// Hints, timestamps, placeholders (still ≥ 4.5:1 on [background]).
  final Color textMuted;

  final Color accent;
  final Color onAccent;
  final Color accentContainer;
  final Color onAccentContainer;

  final Color bubbleOut;
  final Color bubbleOutText;
  final Color bubbleOutMeta;
  final Color bubbleIn;
  final Color bubbleInText;
  final Color bubbleInMeta;

  /// Colour of the double tick once a message has been read.
  final Color tickRead;

  final Color link;

  /// Date separators and system notices in a conversation.
  final Color systemChip;
  final Color onSystemChip;

  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  final Color online;

  final Color shimmerBase;
  final Color shimmerHighlight;

  /// Highlight for the selected row in the two-pane layout.
  final Color selection;

  /// Fallback avatar colours, picked deterministically per name.
  final List<Color> avatarColors;

  static const dark = AppPalette(
    background: AppColors.scaffold,
    chatBackground: Color(0xFF0D0D14),
    surface: AppColors.surface,
    elevated: AppColors.elevated,
    inputFill: Color(0xFF1C1C2B),
    border: AppColors.border,
    divider: AppColors.divider,
    textPrimary: AppColors.textPrimary,
    textSecondary: AppColors.textSecondary,
    // Lighter than the legacy hint colour so it passes 4.5:1 on the scaffold.
    textMuted: Color(0xFF8C8CA3),
    accent: AppColors.accent,
    onAccent: AppColors.scaffold,
    accentContainer: Color(0xFF0F3B37),
    onAccentContainer: Color(0xFF7FF5E6),
    bubbleOut: Color(0xFF0F4A44),
    bubbleOutText: Color(0xFFF2FFFD),
    bubbleOutMeta: Color(0xFF9FD3CC),
    bubbleIn: Color(0xFF1C1C2B),
    bubbleInText: AppColors.textPrimary,
    bubbleInMeta: Color(0xFF9A9AB0),
    tickRead: Color(0xFF4DF0DD),
    link: Color(0xFF7FDBFF),
    systemChip: Color(0xFF1C1C2B),
    onSystemChip: Color(0xFFC4C4D6),
    success: AppColors.success,
    warning: AppColors.warning,
    danger: Color(0xFFF26B6B),
    info: AppColors.info,
    online: AppColors.online,
    shimmerBase: AppColors.shimmerBase,
    shimmerHighlight: AppColors.shimmerHighlight,
    selection: Color(0xFF16302E),
    avatarColors: [
      Color(0xFF00A693),
      Color(0xFF3B6FE0),
      Color(0xFF7C4DDB),
      Color(0xFFD13F86),
      Color(0xFFC77A0A),
      Color(0xFF0E9C6E),
      Color(0xFF0A8FB0),
      Color(0xFFD9573F),
    ],
  );

  static const light = AppPalette(
    background: Color(0xFFF5F6F8),
    chatBackground: Color(0xFFECEFF2),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    inputFill: Color(0xFFEEF0F4),
    border: Color(0xFFD9DDE3),
    divider: Color(0xFFE6E9ED),
    textPrimary: Color(0xFF10141A),
    textSecondary: Color(0xFF454D5A),
    textMuted: Color(0xFF636B78),
    accent: Color(0xFF00796B),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFD3F4EF),
    onAccentContainer: Color(0xFF00463E),
    bubbleOut: Color(0xFFD3F4EF),
    bubbleOutText: Color(0xFF0B1F1C),
    bubbleOutMeta: Color(0xFF3F6B65),
    bubbleIn: Color(0xFFFFFFFF),
    bubbleInText: Color(0xFF10141A),
    bubbleInMeta: Color(0xFF636B78),
    tickRead: Color(0xFF0277BD),
    link: Color(0xFF0B63B5),
    systemChip: Color(0xFFFFFFFF),
    onSystemChip: Color(0xFF454D5A),
    success: Color(0xFF15803D),
    warning: Color(0xFFB45309),
    danger: Color(0xFFC62828),
    info: Color(0xFF1D4ED8),
    online: Color(0xFF16A34A),
    shimmerBase: Color(0xFFE4E7EB),
    shimmerHighlight: Color(0xFFF3F4F6),
    selection: Color(0xFFDDF3EF),
    avatarColors: [
      Color(0xFF00897B),
      Color(0xFF2563EB),
      Color(0xFF7C3AED),
      Color(0xFFDB2777),
      Color(0xFFD97706),
      Color(0xFF059669),
      Color(0xFF0891B2),
      Color(0xFFDC5A45),
    ],
  );

  /// Deterministic avatar colour for [seed] (usually a user id or name).
  Color avatarColorFor(String seed) {
    if (seed.isEmpty) return avatarColors.first;
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return avatarColors[hash % avatarColors.length];
  }

  @override
  AppPalette copyWith({
    Color? background,
    Color? chatBackground,
    Color? surface,
    Color? elevated,
    Color? inputFill,
    Color? border,
    Color? divider,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? accent,
    Color? onAccent,
    Color? accentContainer,
    Color? onAccentContainer,
    Color? bubbleOut,
    Color? bubbleOutText,
    Color? bubbleOutMeta,
    Color? bubbleIn,
    Color? bubbleInText,
    Color? bubbleInMeta,
    Color? tickRead,
    Color? link,
    Color? systemChip,
    Color? onSystemChip,
    Color? success,
    Color? warning,
    Color? danger,
    Color? info,
    Color? online,
    Color? shimmerBase,
    Color? shimmerHighlight,
    Color? selection,
    List<Color>? avatarColors,
  }) {
    return AppPalette(
      background: background ?? this.background,
      chatBackground: chatBackground ?? this.chatBackground,
      surface: surface ?? this.surface,
      elevated: elevated ?? this.elevated,
      inputFill: inputFill ?? this.inputFill,
      border: border ?? this.border,
      divider: divider ?? this.divider,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      accentContainer: accentContainer ?? this.accentContainer,
      onAccentContainer: onAccentContainer ?? this.onAccentContainer,
      bubbleOut: bubbleOut ?? this.bubbleOut,
      bubbleOutText: bubbleOutText ?? this.bubbleOutText,
      bubbleOutMeta: bubbleOutMeta ?? this.bubbleOutMeta,
      bubbleIn: bubbleIn ?? this.bubbleIn,
      bubbleInText: bubbleInText ?? this.bubbleInText,
      bubbleInMeta: bubbleInMeta ?? this.bubbleInMeta,
      tickRead: tickRead ?? this.tickRead,
      link: link ?? this.link,
      systemChip: systemChip ?? this.systemChip,
      onSystemChip: onSystemChip ?? this.onSystemChip,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      info: info ?? this.info,
      online: online ?? this.online,
      shimmerBase: shimmerBase ?? this.shimmerBase,
      shimmerHighlight: shimmerHighlight ?? this.shimmerHighlight,
      selection: selection ?? this.selection,
      avatarColors: avatarColors ?? this.avatarColors,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      background: l(background, other.background),
      chatBackground: l(chatBackground, other.chatBackground),
      surface: l(surface, other.surface),
      elevated: l(elevated, other.elevated),
      inputFill: l(inputFill, other.inputFill),
      border: l(border, other.border),
      divider: l(divider, other.divider),
      textPrimary: l(textPrimary, other.textPrimary),
      textSecondary: l(textSecondary, other.textSecondary),
      textMuted: l(textMuted, other.textMuted),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      accentContainer: l(accentContainer, other.accentContainer),
      onAccentContainer: l(onAccentContainer, other.onAccentContainer),
      bubbleOut: l(bubbleOut, other.bubbleOut),
      bubbleOutText: l(bubbleOutText, other.bubbleOutText),
      bubbleOutMeta: l(bubbleOutMeta, other.bubbleOutMeta),
      bubbleIn: l(bubbleIn, other.bubbleIn),
      bubbleInText: l(bubbleInText, other.bubbleInText),
      bubbleInMeta: l(bubbleInMeta, other.bubbleInMeta),
      tickRead: l(tickRead, other.tickRead),
      link: l(link, other.link),
      systemChip: l(systemChip, other.systemChip),
      onSystemChip: l(onSystemChip, other.onSystemChip),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      danger: l(danger, other.danger),
      info: l(info, other.info),
      online: l(online, other.online),
      shimmerBase: l(shimmerBase, other.shimmerBase),
      shimmerHighlight: l(shimmerHighlight, other.shimmerHighlight),
      selection: l(selection, other.selection),
      avatarColors: t < 0.5 ? avatarColors : other.avatarColors,
    );
  }
}

extension AppPaletteContext on BuildContext {
  /// The active [AppPalette]; falls back to the dark palette when the
  /// surrounding theme was not built by [AppTheme] (e.g. in tests).
  AppPalette get palette =>
      Theme.of(this).extension<AppPalette>() ??
      (Theme.of(this).brightness == Brightness.light
          ? AppPalette.light
          : AppPalette.dark);
}
