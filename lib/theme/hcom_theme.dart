import 'package:flutter/material.dart';

abstract final class HcomTheme {
  static const darkPrimary = Color(0xFFA8C7FA);
  static const darkSurface = Color(0xFF101418);
  static const darkSurfaceLowest = Color(0xFF0B0F13);
  static const darkSurfaceLow = Color(0xFF181C20);
  static const darkSurfaceContainer = Color(0xFF1C2024);
  static const darkSurfaceHigh = Color(0xFF262A2F);
  static const darkSurfaceHighest = Color(0xFF31353A);
  static const rxDark = Color(0xFFA8C7FA);
  static const txDark = Color(0xFF7BD88F);
  static const rxLight = Color(0xFF0B57D0);
  static const txLight = Color(0xFF146C2E);

  static ThemeData dark() => _create(_darkScheme, Brightness.dark);
  static ThemeData light() => _create(_lightScheme, Brightness.light);

  static ThemeData _create(ColorScheme scheme, Brightness brightness) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: 'Roboto',
    );
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainer,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
            color: scheme.onSurface, fontSize: 22, fontWeight: FontWeight.w400),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(4))),
        enabledBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            borderSide: BorderSide(color: scheme.outline)),
        focusedBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            borderSide: BorderSide(color: scheme.primary, width: 2)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        contentTextStyle: TextStyle(color: scheme.onSurface),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  static const _darkScheme = ColorScheme.dark(
    primary: darkPrimary,
    onPrimary: Color(0xFF0A305F),
    primaryContainer: Color(0xFF284777),
    onPrimaryContainer: Color(0xFFD6E3FF),
    secondaryContainer: Color(0xFF3B4758),
    onSecondaryContainer: Color(0xFFD7E3F8),
    surface: darkSurface,
    surfaceContainerLowest: darkSurfaceLowest,
    surfaceContainerLow: darkSurfaceLow,
    surfaceContainer: darkSurfaceContainer,
    surfaceContainerHigh: darkSurfaceHigh,
    surfaceContainerHighest: darkSurfaceHighest,
    onSurface: Color(0xFFE2E2E9),
    onSurfaceVariant: Color(0xFFC4C6CF),
    outline: Color(0xFF8E9099),
    outlineVariant: Color(0xFF44474E),
    error: Color(0xFFFFB4AB),
    errorContainer: Color(0xFF93000A),
  );

  static const _lightScheme = ColorScheme.light(
    primary: Color(0xFF0B57D0),
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFD3E3FD),
    onPrimaryContainer: Color(0xFF041E49),
    secondaryContainer: Color(0xFFDEE3EB),
    onSecondaryContainer: Color(0xFF191C20),
    surface: Color(0xFFF8FAFD),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF3F6FC),
    surfaceContainer: Color(0xFFEDF1F7),
    surfaceContainerHigh: Color(0xFFE7ECF2),
    surfaceContainerHighest: Color(0xFFE1E5EC),
    onSurface: Color(0xFF1A1C1E),
    onSurfaceVariant: Color(0xFF43474E),
    outline: Color(0xFF73777F),
    outlineVariant: Color(0xFFC3C6CF),
    error: Color(0xFFB3261E),
  );
}
