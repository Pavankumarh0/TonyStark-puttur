import 'package:flutter/material.dart';

/// Same palette as LEO on Android.
class LeoColors {
  static const bg = Color(0xFF04190C);
  static const panel = Color(0xFF072514);
  static const panelHi = Color(0xFF0B321B);
  static const line = Color(0xFF134726);
  static const text = Color(0xFFE4FFEA);
  static const dim = Color(0xFF7CB08E);
  static const accent = Color(0xFF2EFF6E);
  static const amber = Color(0xFFFFC857);
  static const red = Color(0xFFFF5A5F);
}

ThemeData leoTheme() => ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: LeoColors.bg,
      colorScheme: const ColorScheme.dark(
        primary: LeoColors.accent,
        secondary: LeoColors.accent,
        secondaryContainer: LeoColors.panelHi,
        onSecondaryContainer: LeoColors.accent,
        surface: LeoColors.panel,
        error: LeoColors.red,
        onPrimary: LeoColors.bg,
        onSurface: LeoColors.text,
      ),
      cardTheme: const CardThemeData(
        color: LeoColors.panel,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)), side: BorderSide(color: LeoColors.line)),
        margin: EdgeInsets.zero,
      ),
      dividerColor: LeoColors.line,
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: LeoColors.panel,
        selectedIconTheme: IconThemeData(color: LeoColors.accent),
        indicatorColor: LeoColors.panelHi,
      ),
      fontFamily: 'Segoe UI',
    );
