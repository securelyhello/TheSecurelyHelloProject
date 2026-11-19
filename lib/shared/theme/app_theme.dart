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
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;
  static const double pill = 999;

  /// Message bubble outer corner and the tighter corner used inside a group.
  static const double bubble = 18;
  static const double bubbleGrouped = 5;
}

/// Animation durations and curves — kept short and restrained.
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);
  static const Curve curve = Curves.easeOutCubic;
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
      onTertiary: p.onAccent,
      error: p.danger,
      onError: isDark ? const Color(0xFF1A0505) : Colors.white,
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
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: isDark
          ? const Color(0xFFE8E8F0)
          : const Color(0xFF1C1F24),
      onInverseSurface: isDark ? const Color(0xFF12121A) : Colors.white,
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
          borderRadius: BorderRadius.circular(AppRadius.md),
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
        titleTextStyle: text.titleLarge?.copyWith(fontSize: 20),
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
          borderRadius: BorderRadius.circular(AppRadius.lg),
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
      // screens rely on that.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.onAccent,
          disabledBackgroundColor: p.accent.withAlpha(77),
          disabledForegroundColor: p.textMuted,
          elevation: 0,
          minimumSize: const Size(double.infinity, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.accent,
          minimumSize: const Size(double.infinity, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
          side: BorderSide(color: p.accent, width: 1.5),
          textStyle: text.labelLarge,
        ),
      ),
      // Filled buttons are intrinsic width — used in dialogs, rows, sheets.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.accent,
          minimumSize: const Size(48, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        elevation: 2,
        highlightElevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: p.accentContainer,
        elevation: 0,
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return text.labelMedium?.copyWith(
            color: selected ? p.textPrimary : p.textMuted,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? p.onAccentContainer : p.textMuted,
            size: 22,
          );
        }),
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: p.surface,
        indicatorColor: p.accentContainer,
        selectedIconTheme: IconThemeData(color: p.onAccentContainer, size: 22),
        unselectedIconTheme: IconThemeData(color: p.textMuted, size: 22),
        selectedLabelTextStyle: text.labelMedium?.copyWith(
          color: p.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: text.labelMedium?.copyWith(
          color: p.textMuted,
        ),
      ),

      badgeTheme: BadgeThemeData(
        backgroundColor: p.accent,
        textColor: p.onAccent,
        textStyle: text.labelSmall?.copyWith(fontWeight: FontWeight.w700),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.elevated,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: p.elevated,
        showDragHandle: true,
        dragHandleColor: p.border,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
        ),
        constraints: const BoxConstraints(maxWidth: 640),
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: p.elevated,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        textStyle: text.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: p.border),
        ),
      ),

      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(p.elevated),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              side: BorderSide(color: p.border),
            ),
          ),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: p.elevated,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          side: BorderSide(color: p.border),
        ),
        titleTextStyle: text.titleLarge?.copyWith(fontSize: 20),
        contentTextStyle: text.bodyMedium?.copyWith(color: p.textSecondary),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.onAccent : p.textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.accent : p.inputFill,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.accent : p.border,
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: p.inputFill,
        selectedColor: p.accentContainer,
        labelStyle: text.labelLarge?.copyWith(color: p.textSecondary),
        secondaryLabelStyle: text.labelLarge?.copyWith(
          color: p.onAccentContainer,
        ),
        side: BorderSide.none,
        checkmarkColor: p.onAccentContainer,
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
            ? const Color(0xFF26263A)
            : const Color(0xFF1F2329),
        contentTextStyle: text.bodyMedium?.copyWith(
          color: const Color(0xFFF4F4F8),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 4,
        actionTextColor: isDark ? p.accent : const Color(0xFFC2BAFF),
        width: null,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2A40) : const Color(0xFF2B3038),
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
        selectionColor: p.accent.withAlpha(80),
        selectionHandleColor: p.accent,
      ),

      splashColor: p.accent.withAlpha(20),
      highlightColor: p.accent.withAlpha(13),
      hoverColor: p.textPrimary.withAlpha(10),
      splashFactory: InkSparkle.splashFactory,
    );
  }
}
