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

  /// Dark: deep ink with Iris (indigo-violet) and Ember (coral) accents.
  static const dark = AppPalette(
    background: Color(0xFF0E0F1C),
    chatBackground: Color(0xFF0B0C17),
    surface: Color(0xFF15162A),
    elevated: Color(0xFF1C1E36),
    inputFill: Color(0xFF1F2140),
    border: Color(0xFF2D3052),
    divider: Color(0xFF212341),
    textPrimary: Color(0xFFF4F4FB),
    textSecondary: Color(0xFFBCBEDA),
    // 6.2:1 on the background.
    textMuted: Color(0xFF9295B8),
    accent: Color(0xFF9C8FFF),
    onAccent: Color(0xFF14123A),
    accentContainer: Color(0xFF2B2766),
    onAccentContainer: Color(0xFFDCD8FF),
    bubbleOut: Color(0xFF5546D9),
    bubbleOutText: Color(0xFFFFFFFF),
    bubbleOutMeta: Color(0xFFD9D4FF),
    bubbleIn: Color(0xFF1C1E36),
    bubbleInText: Color(0xFFF4F4FB),
    bubbleInMeta: Color(0xFFA5A8CA),
    tickRead: Color(0xFF86F2CB),
    link: Color(0xFFB3BEFF),
    systemChip: Color(0xFF1C1E36),
    onSystemChip: Color(0xFFC9CBE6),
    success: Color(0xFF3DD69B),
    warning: Color(0xFFFFC266),
    danger: Color(0xFFFF7A7A),
    info: Color(0xFF7FB2FF),
    online: Color(0xFF3DD69B),
    shimmerBase: Color(0xFF1C1E36),
    shimmerHighlight: Color(0xFF2A2C4C),
    selection: Color(0xFF26234F),
    avatarColors: [
      Color(0xFF6C5CE7),
      Color(0xFFE8674A),
      Color(0xFF1597A8),
      Color(0xFFD6336C),
      Color(0xFFE09B00),
      Color(0xFF2F9E5E),
      Color(0xFF2B7BD6),
      Color(0xFFA83FC4),
    ],
  );

  /// Light: soft lavender neutrals, Iris accents.
  static const light = AppPalette(
    background: Color(0xFFF7F6FC),
    chatBackground: Color(0xFFF0EEF9),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    inputFill: Color(0xFFEFEDF8),
    border: Color(0xFFDEDBEE),
    divider: Color(0xFFEAE8F4),
    textPrimary: Color(0xFF16152C),
    textSecondary: Color(0xFF4A4868),
    // 5.4:1 on the background.
    textMuted: Color(0xFF65638A),
    accent: Color(0xFF5546D9),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFE9E6FF),
    onAccentContainer: Color(0xFF2C2380),
    bubbleOut: Color(0xFF5546D9),
    bubbleOutText: Color(0xFFFFFFFF),
    bubbleOutMeta: Color(0xFFDCD8FF),
    bubbleIn: Color(0xFFFFFFFF),
    bubbleInText: Color(0xFF16152C),
    bubbleInMeta: Color(0xFF65638A),
    tickRead: Color(0xFF86F2CB),
    link: Color(0xFF3B48C9),
    systemChip: Color(0xFFFFFFFF),
    onSystemChip: Color(0xFF4A4868),
    success: Color(0xFF16834F),
    warning: Color(0xFFA85A00),
    danger: Color(0xFFC92A3A),
    info: Color(0xFF2456C9),
    online: Color(0xFF1FA463),
    shimmerBase: Color(0xFFE8E6F3),
    shimmerHighlight: Color(0xFFF5F4FB),
    selection: Color(0xFFECE9FF),
    avatarColors: [
      Color(0xFF6C5CE7),
      Color(0xFFE0603F),
      Color(0xFF128A99),
      Color(0xFFD02F68),
      Color(0xFFC98A00),
      Color(0xFF268A50),
      Color(0xFF2A70C2),
      Color(0xFF9C36B5),
    ],
  );

  /// The warm second colour (story rings, highlights, call accept).
  static const ember = Color(0xFFFF7A59);

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
