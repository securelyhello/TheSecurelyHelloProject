import 'package:flutter/material.dart';

/// Semantic colour tokens for Securely Hello.
///
/// Screens and widgets read colours from here (`context.palette`) rather than
/// from fixed colour constants, so the same UI renders correctly in the dark
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
    required this.brand,
    required this.onBrand,
    required this.ledge,
    required this.storyRing,
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
    required this.avatarOnColors,
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

  /// Readable accent for text, icons, links and focus rings
  /// (`colorScheme.primary`): blue on Paper, pear on Night.
  final Color accent;
  final Color onAccent;
  final Color accentContainer;
  final Color onAccentContainer;

  /// Pear, the brand fill for primary buttons, FAB, nav indicator, badges.
  /// Never use it as text on Paper; pair it with [onBrand].
  final Color brand;

  /// Ink on [brand].
  final Color onBrand;

  /// Underside of a pressed-down pear button (optional 4px ledge).
  final Color ledge;

  /// Ring around a contact with an unseen story.
  final Color storyRing;

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

  /// Initials colour for each entry of [avatarColors] (ink on light fills).
  final List<Color> avatarOnColors;

  /// Night: ink-blue surfaces stepped by lightness, pear accent.
  static const dark = AppPalette(
    background: Color(0xFF0B1015),
    chatBackground: Color(0xFF10151B),
    surface: Color(0xFF151A21),
    elevated: Color(0xFF1E252D),
    inputFill: Color(0xFF1E252D),
    border: Color(0xFF2D333B),
    divider: Color(0xFF222830),
    textPrimary: Color(0xFFF1EFE6),
    textSecondary: Color(0xFFC7C4BA),
    textMuted: Color(0xFF999FA7),
    accent: Color(0xFFF7D21A),
    onAccent: Color(0xFF12161C),
    accentContainer: Color(0xFF3A3410),
    onAccentContainer: Color(0xFFF7E27A),
    brand: Color(0xFFF7D21A),
    onBrand: Color(0xFF12161C),
    ledge: Color(0xFFC9A000),
    storyRing: Color(0xFFFF7979),
    bubbleOut: Color(0xFFE9C619),
    bubbleOutText: Color(0xFF12161C),
    bubbleOutMeta: Color(0xFF4A4420),
    bubbleIn: Color(0xFF1E252D),
    bubbleInText: Color(0xFFF1EFE6),
    bubbleInMeta: Color(0xFF999FA7),
    tickRead: Color(0xFF12161C),
    link: Color(0xFF60AAF3),
    systemChip: Color(0xFF1E252D),
    onSystemChip: Color(0xFFC7C4BA),
    success: Color(0xFF69D98D),
    warning: Color(0xFFF7D21A),
    danger: Color(0xFFFB817F),
    info: Color(0xFF60AAF3),
    online: Color(0xFF69D98D),
    shimmerBase: Color(0xFF1E252D),
    shimmerHighlight: Color(0xFF2D333B),
    selection: Color(0xFF242B34),
    avatarColors: _avatarFills,
    avatarOnColors: _avatarInks,
  );

  /// Paper: warm off-white, ink text, blue accent, pear fills.
  static const light = AppPalette(
    background: Color(0xFFF7F5EC),
    chatBackground: Color(0xFFF0EDE0),
    surface: Color(0xFFFCFBF6),
    elevated: Color(0xFFFCFBF6),
    inputFill: Color(0xFFF0EDE0),
    border: Color(0xFFD7D4C9),
    divider: Color(0xFFE6E1D1),
    textPrimary: Color(0xFF12161C),
    textSecondary: Color(0xFF3C424A),
    textMuted: Color(0xFF565B63),
    accent: Color(0xFF0064BE),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFDCE9F7),
    onAccentContainer: Color(0xFF00407A),
    brand: Color(0xFFF7D21A),
    onBrand: Color(0xFF12161C),
    ledge: Color(0xFFC9A000),
    // Plan value #FF5E63 is 2.7:1 on Paper; lightness lowered to reach 3:1.
    storyRing: Color(0xFFFF4A4F),
    bubbleOut: Color(0xFFF7D21A),
    bubbleOutText: Color(0xFF12161C),
    bubbleOutMeta: Color(0xFF4A4420),
    bubbleIn: Color(0xFFFCFBF6),
    bubbleInText: Color(0xFF12161C),
    bubbleInMeta: Color(0xFF565B63),
    tickRead: Color(0xFF0050A0),
    link: Color(0xFF0064BE),
    systemChip: Color(0xFFFCFBF6),
    onSystemChip: Color(0xFF3C424A),
    success: Color(0xFF00713E),
    warning: Color(0xFF8A5A00),
    danger: Color(0xFFBE222A),
    info: Color(0xFF0064BE),
    online: Color(0xFF1E9E5A),
    shimmerBase: Color(0xFFE6E1D1),
    shimmerHighlight: Color(0xFFF7F5EC),
    selection: Color(0xFFF4EBB8),
    avatarColors: _avatarFills,
    avatarOnColors: _avatarInks,
  );

  /// Pear, coral, blue, mint, kraft, sugar.
  static const _avatarFills = [
    Color(0xFFF7D21A),
    Color(0xFFFF5E63),
    Color(0xFF0064BE),
    Color(0xFF7ED6A4),
    Color(0xFFA9773F),
    Color(0xFFC9DDF0),
  ];

  /// Initials on each fill above: ink on the light ones, white on blue.
  static const _avatarInks = [
    Color(0xFF12161C),
    Color(0xFF12161C),
    Color(0xFFFFFFFF),
    Color(0xFF12161C),
    Color(0xFF12161C),
    Color(0xFF12161C),
  ];

  /// Paper-style shadow for cards, sheets and the FAB: a tight contact shadow
  /// plus a soft long one at ink 10-13%. Night uses lightness steps instead,
  /// so it is empty there.
  List<BoxShadow> get paperShadow => background.computeLuminance() < 0.5
      ? const []
      : const [
          BoxShadow(
            color: Color(0x1A12161C),
            offset: Offset(1.5, 2.5),
            blurRadius: 1.5,
          ),
          BoxShadow(
            color: Color(0x2112161C),
            offset: Offset(6, 14),
            blurRadius: 16,
          ),
        ];

  /// Coral, the warm second colour (call accept, highlights). Story rings use
  /// [storyRing].
  static const ember = Color(0xFFFF5E63);

  /// Deterministic avatar colour for [seed] (usually a user id or name).
  Color avatarColorFor(String seed) {
    if (seed.isEmpty) return avatarColors.first;
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return avatarColors[hash % avatarColors.length];
  }

  /// Initials colour that is readable on [avatarColorFor] for the same seed.
  Color onAvatarColorFor(String seed) {
    if (seed.isEmpty) return avatarOnColors.first;
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return avatarOnColors[hash % avatarOnColors.length];
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
    Color? brand,
    Color? onBrand,
    Color? ledge,
    Color? storyRing,
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
    List<Color>? avatarOnColors,
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
      brand: brand ?? this.brand,
      onBrand: onBrand ?? this.onBrand,
      ledge: ledge ?? this.ledge,
      storyRing: storyRing ?? this.storyRing,
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
      avatarOnColors: avatarOnColors ?? this.avatarOnColors,
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
      brand: l(brand, other.brand),
      onBrand: l(onBrand, other.onBrand),
      ledge: l(ledge, other.ledge),
      storyRing: l(storyRing, other.storyRing),
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
      avatarOnColors: t < 0.5 ? avatarOnColors : other.avatarOnColors,
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
