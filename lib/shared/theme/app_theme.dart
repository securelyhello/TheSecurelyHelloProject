import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:securelyhello/shared/theme/app_palette.dart';
import 'package:securelyhello/shared/theme/app_typography.dart';

export 'package:securelyhello/shared/theme/app_palette.dart';

/// Spacing constants used throughout the app.
abstract final class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Standard page padding.
  static const EdgeInsets pagePadding = EdgeInsets.symmetric(
    horizontal: md,
    vertical: sm,
  );

  /// Card inner padding.
  static const EdgeInsets cardPadding = EdgeInsets.all(md);
}

/// Corner radii.
abstract final class AppRadius {
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double pill = 999;

  /// Named roles for the same scale.
  static const double input = md;
  static const double control = lg;
  static const double card = xl;
  static const double sheet = xl;
  static const double onboarding = xxl;

  /// Message bubble outer corner and the tighter corner used inside a group.
  static const double bubble = 20;
  static const double bubbleGrouped = 6;
}

/// Animation durations and curves: short, with one decisive curve.
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration medium = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 320);

  /// The default curve: fast out, soft landing.
  static const Curve snap = Cubic(0.22, 1, 0.36, 1);
  static const Curve curve = snap;

  /// Slight overshoot. Only for the primary button and FAB press.
  static const Curve spring = Cubic(0.34, 1.56, 0.64, 1);

  /// [d], or zero when the system asks for no animations.
  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false ? Duration.zero : d;
}

/// Layout breakpoints.
abstract final class AppBreakpoints {
  /// At or above this width the home screen shows list + conversation side
  /// by side.
  static const double twoPane = 840;

  /// At or above this width the navigation rail shows labels.
  static const double extendedRail = 1200;

  /// Width of the list pane in the two-pane layout.
  static const double listPaneWidth = 380;

  /// Max width for single-column content (settings, forms) on wide windows.
  static const double contentMaxWidth = 720;

  /// Max bubble width on wide windows.
  static const double bubbleMaxWidth = 560;
}

/// Securely Hello themes. Dark is the primary theme.
abstract final class AppTheme {
  static ThemeData get dark => _build(AppPalette.dark, Brightness.dark);

  /// Light variant built from the same tokens.
  static ThemeData get light => _build(AppPalette.light, Brightness.light);

  static ThemeData _build(AppPalette p, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final text = AppTypography.textThemeFor(p);

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: p.accent,
      onPrimary: p.onAccent,
      primaryContainer: p.accentContainer,
      onPrimaryContainer: p.onAccentContainer,
      secondary: p.accent,
      onSecondary: p.onAccent,
      secondaryContainer: p.accentContainer,
      onSecondaryContainer: p.onAccentContainer,
      tertiary: p.info,
      onTertiary: isDark ? p.onBrand : Colors.white,
      error: p.danger,
      onError: isDark ? p.onBrand : Colors.white,
      surface: p.surface,
      onSurface: p.textPrimary,
      onSurfaceVariant: p.textSecondary,
      surfaceContainerLowest: p.background,
      surfaceContainerLow: p.surface,
      surfaceContainer: p.surface,
      surfaceContainerHigh: p.elevated,
      surfaceContainerHighest: p.inputFill,
      outline: p.border,
      outlineVariant: p.divider,
      shadow: isDark ? Colors.black : const Color(0xFF12161C),
      scrim: Colors.black,
      inverseSurface: isDark
          ? const Color(0xFFF1EFE6)
          : const Color(0xFF12161C),
      onInverseSurface: isDark
          ? const Color(0xFF12161C)
          : const Color(0xFFF7F5EC),
      inversePrimary: p.accent,
    );

    final overlay = isDark
        ? const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            statusBarBrightness: Brightness.dark,
          )
        : const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
          );

    OutlineInputBorder inputBorder(Color c, [double w = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.input),
          borderSide: BorderSide(color: c, width: w),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: p.background,
      canvasColor: p.background,
      textTheme: text,
      extensions: [p],
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,

      appBarTheme: AppBarTheme(
        backgroundColor: p.surface,
        foregroundColor: p.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: AppSpacing.md,
        titleTextStyle: text.titleLarge,
        iconTheme: IconThemeData(color: p.textPrimary, size: 22),
        actionsIconTheme: IconThemeData(color: p.textSecondary, size: 22),
        systemOverlayStyle: overlay,
        shape: Border(bottom: BorderSide(color: p.divider)),
      ),

      cardTheme: CardThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: p.border),
        ),
      ),

      listTileTheme: ListTileThemeData(
        iconColor: p.textSecondary,
        textColor: p.textPrimary,
        titleTextStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
        subtitleTextStyle: text.bodyMedium?.copyWith(color: p.textSecondary),
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        minVerticalPadding: 10,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.inputFill,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        hintStyle: text.bodyMedium?.copyWith(color: p.textMuted),
        labelStyle: text.bodyMedium?.copyWith(color: p.textSecondary),
        floatingLabelStyle: text.labelMedium?.copyWith(color: p.accent),
        errorStyle: text.bodySmall?.copyWith(color: p.danger),
        prefixIconColor: p.textMuted,
        suffixIconColor: p.textMuted,
        border: inputBorder(p.border),
        enabledBorder: inputBorder(p.border),
        focusedBorder: inputBorder(p.accent, 1.5),
        errorBorder: inputBorder(p.danger),
        focusedErrorBorder: inputBorder(p.danger, 1.5),
        disabledBorder: inputBorder(p.divider),
      ),

      // Elevated and outlined buttons are full width by default; the auth
      // screens rely on that. Pear fill, ink label, flat (the optional ledge
      // fights Material's ink and press states).
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.brand,
          foregroundColor: p.onBrand,
          disabledBackgroundColor: p.brand.withAlpha(77),
          disabledForegroundColor: p.textMuted,
          elevation: 0,
          shadowColor: Colors.transparent,
          minimumSize: const Size(double.infinity, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          textStyle: text.labelLarge?.copyWith(fontSize: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.textPrimary,
          minimumSize: const Size(double.infinity, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          side: BorderSide(color: p.textPrimary, width: 1.5),
          textStyle: text.labelLarge?.copyWith(fontSize: 16),
        ),
      ),
      // Filled buttons are intrinsic width: dialogs, rows, sheets.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.brand,
          foregroundColor: p.onBrand,
          disabledBackgroundColor: p.brand.withAlpha(77),
          disabledForegroundColor: p.textMuted,
          minimumSize: const Size(64, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.accent,
          minimumSize: const Size(48, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        extendedTextStyle: text.labelLarge,
        backgroundColor: p.brand,
        foregroundColor: p.onBrand,
        elevation: isDark ? 0 : 6,
        highlightElevation: isDark ? 0 : 8,
        focusElevation: isDark ? 0 : 6,
        hoverElevation: isDark ? 0 : 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control + 4),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: p.brand,
        elevation: 0,
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return AppTypography.tabLabel.copyWith(
            color: selected ? p.textPrimary : p.textMuted,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? p.onBrand : p.textMuted,
            size: 22,
          );
        }),
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: p.surface,
        indicatorColor: p.brand,
        selectedIconTheme: IconThemeData(color: p.onBrand, size: 22),
        unselectedIconTheme: IconThemeData(color: p.textMuted, size: 22),
        selectedLabelTextStyle: AppTypography.tabLabel.copyWith(
          color: p.textPrimary,
        ),
        unselectedLabelTextStyle: AppTypography.tabLabel.copyWith(
          color: p.textMuted,
        ),
      ),

      badgeTheme: BadgeThemeData(
        backgroundColor: p.brand,
        textColor: p.onBrand,
        textStyle: text.labelSmall?.copyWith(fontWeight: FontWeight.w700),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.elevated,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: p.elevated,
        showDragHandle: true,
        dragHandleColor: p.border,
        elevation: isDark ? 0 : 8,
        shadowColor: p.onBrand,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
        ),
        constraints: const BoxConstraints(maxWidth: 640),
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: p.elevated,
        surfaceTintColor: Colors.transparent,
        elevation: isDark ? 0 : 6,
        shadowColor: p.onBrand,
        textStyle: text.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
          side: BorderSide(color: p.border),
        ),
      ),

      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(p.elevated),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.control),
              side: BorderSide(color: p.border),
            ),
          ),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: p.elevated,
        surfaceTintColor: Colors.transparent,
        elevation: isDark ? 0 : 8,
        shadowColor: p.onBrand,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: p.border),
        ),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium?.copyWith(color: p.textSecondary),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.onBrand : p.textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.brand : p.inputFill,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.ledge : p.border,
        ),
      ),

      // Selected chip: ink fill with paper text; unselected: card with a rule.
      chipTheme: ChipThemeData(
        backgroundColor: p.surface,
        selectedColor: p.textPrimary,
        labelStyle: text.labelLarge?.copyWith(color: p.textSecondary),
        secondaryLabelStyle: text.labelLarge?.copyWith(color: p.background),
        side: BorderSide(color: p.border),
        checkmarkColor: p.background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.accent,
        linearTrackColor: p.inputFill,
        circularTrackColor: Colors.transparent,
      ),

      dividerTheme: DividerThemeData(color: p.divider, thickness: 1, space: 1),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark
            ? const Color(0xFF2D333B)
            : const Color(0xFF12161C),
        contentTextStyle: text.bodyMedium?.copyWith(
          color: const Color(0xFFF1EFE6),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 4,
        actionTextColor: const Color(0xFFF7D21A),
        width: null,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2D333B) : const Color(0xFF12161C),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        textStyle: text.bodySmall?.copyWith(color: Colors.white),
        waitDuration: const Duration(milliseconds: 500),
      ),

      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(p.textMuted.withAlpha(90)),
        radius: const Radius.circular(4),
        thickness: WidgetStateProperty.all(4),
      ),

      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.accent,
        selectionColor: p.accent.withAlpha(70),
        selectionHandleColor: p.accent,
      ),

      splashColor: p.accent.withAlpha(20),
      highlightColor: p.accent.withAlpha(13),
      hoverColor: p.textPrimary.withAlpha(10),
      splashFactory: InkSparkle.splashFactory,
    );
  }
}
