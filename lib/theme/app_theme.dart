import 'package:flutter/material.dart';

abstract final class AppColors {
  static const background = Color(0xFF090C0A);
  static const surface = Color(0xFF111613);
  static const surfaceRaised = Color(0xFF171D19);
  static const surfaceLight = Color(0xFF202721);
  static const border = Color(0xFF2A322C);
  static const text = Color(0xFFF5F5EF);
  static const muted = Color(0xFFA5ADA7);
  static const accent = Color(0xFFD4FF72);
  static const accentDark = Color(0xFF19230C);
  static const blue = Color(0xFF7ACBFF);
  static const amber = Color(0xFFFFC86B);
  static const danger = Color(0xFFFF8C82);
}

abstract final class AppTheme {
  static ThemeData get dark {
    const colorScheme = ColorScheme.dark(
      primary: AppColors.accent,
      onPrimary: AppColors.background,
      secondary: AppColors.blue,
      onSecondary: AppColors.background,
      surface: AppColors.surface,
      onSurface: AppColors.text,
      error: AppColors.danger,
      onError: AppColors.background,
      outline: AppColors.border,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.background,
      fontFamily: 'Arial',
      visualDensity: VisualDensity.standard,
    );

    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        displayLarge: const TextStyle(
          color: AppColors.text,
          fontSize: 68,
          height: .97,
          fontWeight: FontWeight.w700,
          letterSpacing: -3.5,
        ),
        displayMedium: const TextStyle(
          color: AppColors.text,
          fontSize: 46,
          height: 1.02,
          fontWeight: FontWeight.w700,
          letterSpacing: -2.2,
        ),
        headlineLarge: const TextStyle(
          color: AppColors.text,
          fontSize: 32,
          height: 1.08,
          fontWeight: FontWeight.w700,
          letterSpacing: -1.2,
        ),
        headlineMedium: const TextStyle(
          color: AppColors.text,
          fontSize: 24,
          height: 1.12,
          fontWeight: FontWeight.w700,
          letterSpacing: -.5,
        ),
        titleLarge: const TextStyle(
          color: AppColors.text,
          fontSize: 20,
          height: 1.2,
          fontWeight: FontWeight.w700,
          letterSpacing: -.25,
        ),
        titleMedium: const TextStyle(
          color: AppColors.text,
          fontSize: 16,
          height: 1.25,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: const TextStyle(
          color: AppColors.muted,
          fontSize: 17,
          height: 1.55,
          fontWeight: FontWeight.w400,
        ),
        bodyMedium: const TextStyle(
          color: AppColors.muted,
          fontSize: 14,
          height: 1.45,
          fontWeight: FontWeight.w400,
        ),
        labelLarge: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: .05,
        ),
      ),
      cardTheme: const CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          side: BorderSide(color: AppColors.border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: AppColors.background,
          disabledBackgroundColor: AppColors.surfaceLight,
          disabledForegroundColor: AppColors.muted,
          minimumSize: const Size(0, 54),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.text,
          minimumSize: const Size(0, 54),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
          side: const BorderSide(color: AppColors.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: AppColors.text,
          minimumSize: const Size.square(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.accent,
        linearTrackColor: AppColors.surfaceLight,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.text,
        contentTextStyle: const TextStyle(color: AppColors.background),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}
