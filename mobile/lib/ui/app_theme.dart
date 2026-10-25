import 'package:flutter/material.dart';

/// The app's palette. Everything else is a tint of these.
abstract final class AppColors {
  static const black = Color(0xFF000000);
  static const darkRed = Color(0xFF49111C);
  static const white = Color(0xFFF2F4F3);
  static const taupe = Color(0xFFA9927D);
  static const brown = Color(0xFF5E503F);

  /// The dark red is too dark to read on black, so dark mode's errors and the
  /// red dots over video (always dark) use this lighter tint of it instead.
  static const lightRed = Color(0xFFCF6679);

  /// "Online" stays green, as a status everyone reads at a glance; muted to
  /// sit with the warm palette.
  static const online = Color(0xFF6E9A6A);

  /// Translucent fill for pills and buttons floating over a camera feed.
  static final overlay = black.withValues(alpha: 0.55);
}

abstract final class AppTheme {
  static final light = _build(
    const ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.darkRed,
      onPrimary: AppColors.white,
      primaryContainer: AppColors.darkRed,
      onPrimaryContainer: AppColors.white,
      secondary: AppColors.brown,
      onSecondary: AppColors.white,
      secondaryContainer: Color(0xFFDCD7D0),
      onSecondaryContainer: AppColors.black,
      tertiary: AppColors.taupe,
      onTertiary: AppColors.black,
      error: AppColors.darkRed,
      onError: AppColors.white,
      errorContainer: Color(0xFFEBDADC),
      onErrorContainer: AppColors.darkRed,
      surface: AppColors.white,
      onSurface: AppColors.black,
      onSurfaceVariant: AppColors.brown,
      surfaceContainerLowest: AppColors.white,
      surfaceContainerLow: Color(0xFFEDEEEC),
      surfaceContainer: Color(0xFFE8E7E3),
      surfaceContainerHigh: Color(0xFFE3E0DB),
      surfaceContainerHighest: Color(0xFFDCD7D0),
      outline: AppColors.taupe,
      outlineVariant: Color(0xFFDCD7D0),
      inverseSurface: AppColors.black,
      onInverseSurface: AppColors.white,
      inversePrimary: AppColors.taupe,
      surfaceTint: Colors.transparent,
      shadow: AppColors.black,
      scrim: AppColors.black,
    ),
  );

  /// Taupe takes the dark red's place for text and icons, which the red is
  /// too dark to carry on black; filled buttons keep the red.
  static final dark = _build(
    const ColorScheme(
      brightness: Brightness.dark,
      primary: AppColors.taupe,
      onPrimary: AppColors.black,
      primaryContainer: AppColors.darkRed,
      onPrimaryContainer: AppColors.white,
      secondary: AppColors.taupe,
      onSecondary: AppColors.black,
      secondaryContainer: Color(0xFF2E2720),
      onSecondaryContainer: AppColors.white,
      tertiary: AppColors.brown,
      onTertiary: AppColors.white,
      error: AppColors.lightRed,
      onError: AppColors.black,
      errorContainer: AppColors.darkRed,
      onErrorContainer: AppColors.white,
      surface: AppColors.black,
      onSurface: AppColors.white,
      onSurfaceVariant: AppColors.taupe,
      surfaceContainerLowest: AppColors.black,
      surfaceContainerLow: Color(0xFF0F0E0D),
      surfaceContainer: Color(0xFF161412),
      surfaceContainerHigh: Color(0xFF1E1B18),
      surfaceContainerHighest: Color(0xFF27231F),
      outline: AppColors.brown,
      outlineVariant: Color(0xFF2E2720),
      inverseSurface: AppColors.white,
      onInverseSurface: AppColors.black,
      inversePrimary: AppColors.darkRed,
      surfaceTint: Colors.transparent,
      shadow: AppColors.black,
      scrim: AppColors.black,
    ),
  );

  /// Flat and quiet: no elevation shadows or tints, thin borders instead.
  static ThemeData _build(ColorScheme colors) {
    final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: colors.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: colors.surface,
        elevation: 0,
        shape: rounded.copyWith(side: BorderSide(color: colors.outlineVariant)),
      ),
      listTileTheme: ListTileThemeData(iconColor: colors.onSurfaceVariant, shape: rounded),
      dividerTheme: DividerThemeData(color: colors.outlineVariant, space: 1, thickness: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.primaryContainer,
          foregroundColor: colors.onPrimaryContainer,
          shape: rounded,
          minimumSize: const Size(64, 48),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.onSurface,
          side: BorderSide(color: colors.outline),
          shape: rounded,
          minimumSize: const Size(64, 48),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colors.primaryContainer,
          foregroundColor: colors.onPrimaryContainer,
          elevation: 0,
          shape: rounded,
        ),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: colors.primary)),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colors.primaryContainer,
        foregroundColor: colors.onPrimaryContainer,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: rounded,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.primary, width: 2),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.outlineVariant),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        modalBackgroundColor: colors.surface,
        dragHandleColor: colors.outline,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surfaceContainer,
        elevation: 0,
        shape: rounded.copyWith(side: BorderSide(color: colors.outlineVariant)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.inverseSurface,
        contentTextStyle: TextStyle(color: colors.onInverseSurface),
        shape: rounded,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: colors.primary),
    );
  }
}
