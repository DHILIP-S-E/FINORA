import 'package:flutter/material.dart';

/// CASCADE design tokens: navy/charcoal base, emerald = healthy, amber = uncertainty, red = projected negative.
class C {
  static const bg = Color(0xFF0A101D);
  static const surface = Color(0xFF111A2C);
  static const card = Color(0xFF172238);
  static const cardHi = Color(0xFF1E2C47);
  static const line = Color(0xFF263552);
  static const text = Color(0xFFEAF0FA);
  static const muted = Color(0xFF9AA9C4);
  static const emerald = Color(0xFF34D3A0);
  static const amber = Color(0xFFF5B942);
  static const red = Color(0xFFFF6B6B);
  static const blue = Color(0xFF6EA8FF);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: C.emerald,
    brightness: Brightness.dark,
    surface: C.surface,
  ).copyWith(primary: C.emerald, onPrimary: const Color(0xFF05241B), error: C.red, secondary: C.blue);
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, scaffoldBackgroundColor: C.bg);
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: C.text, displayColor: C.text),
    appBarTheme: const AppBarTheme(backgroundColor: C.bg, elevation: 0, scrolledUnderElevation: 0, centerTitle: false),
    cardTheme: CardThemeData(
      color: C.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: C.line)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: C.surface,
      indicatorColor: C.emerald.withValues(alpha: 0.18),
      labelTextStyle: WidgetStatePropertyAll(const TextStyle(fontSize: 12, color: C.text)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.card,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.line)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 52),
        side: const BorderSide(color: C.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    dividerTheme: const DividerThemeData(color: C.line, space: 1),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: C.cardHi),
  );
}
