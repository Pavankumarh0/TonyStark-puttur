import 'package:flutter/material.dart';

import '../orchestrator/jarvis_orchestrator.dart';

class JColors {
  static const bg = Color(0xFF02040A);
  static const navy = Color(0xFF060F24);
  static const panel = Color(0xFF0A1630);
  static const panelHi = Color(0xFF0F2142);
  static const line = Color(0xFF1A3260);
  static const cyan = Color(0xFF1FD8FF);
  static const blue = Color(0xFF2A7BFF);
  static const ice = Color(0xFF9FEFFF);
  static const text = Color(0xFFDDE9FF);
  static const dim = Color(0xFF7A8DB3);
  static const amber = Color(0xFFFFB547);
  static const red = Color(0xFFFF4D5E);
  static const green = Color(0xFF3CE6A0);
  static const violet = Color(0xFF8E7BFF);
}

ThemeData jarvisTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: JColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: JColors.cyan,
      secondary: JColors.blue,
      surface: JColors.panel,
      error: JColors.red,
      onPrimary: JColors.bg,
      onSurface: JColors.text,
    ),
    textTheme: base.textTheme.apply(bodyColor: JColors.text, displayColor: JColors.text),
    appBarTheme: const AppBarTheme(
      backgroundColor: JColors.bg,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(color: JColors.text, fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: 2),
    ),
    cardTheme: CardThemeData(
      color: JColors.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: JColors.line)),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: JColors.panel,
      hintStyle: const TextStyle(color: JColors.dim),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: const BorderSide(color: JColors.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: const BorderSide(color: JColors.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: const BorderSide(color: JColors.cyan)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: JColors.navy,
      indicatorColor: JColors.cyan.withValues(alpha: 0.18),
      labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11, color: JColors.dim)),
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? JColors.cyan : JColors.dim)),
    ),
    dividerColor: JColors.line,
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? JColors.cyan : JColors.dim),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? JColors.cyan.withValues(alpha: 0.35) : JColors.panelHi),
    ),
  );
}

extension DisplayStateStyle on DisplayState {
  String get label => switch (this) {
        DisplayState.offline => 'STANDBY',
        DisplayState.waiting => 'WAITING FOR "LEO"',
        DisplayState.listening => 'LISTENING',
        DisplayState.thinking => 'THINKING',
        DisplayState.speaking => 'SPEAKING',
        DisplayState.executing => 'EXECUTING TASK',
        DisplayState.approval => 'WAITING FOR YOU',
        DisplayState.paused => 'PAUSED',
      };

  Color get color => switch (this) {
        DisplayState.offline => JColors.dim,
        DisplayState.waiting => JColors.blue,
        DisplayState.listening => JColors.cyan,
        DisplayState.thinking => JColors.violet,
        DisplayState.speaking => JColors.ice,
        DisplayState.executing => JColors.green,
        DisplayState.approval => JColors.amber,
        DisplayState.paused => JColors.amber,
      };
}
