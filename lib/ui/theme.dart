import 'package:flutter/material.dart';

import '../orchestrator/jarvis_orchestrator.dart';

/// LEO design tokens — taken from the landing page (website/src/app/globals.css):
/// electric "volt" green on deep green-black, mint text, Space Grotesk / Geist / Geist Mono.
class JColors {
  // Landing-page palette
  static const ink = Color(0xFF04190C); // page background
  static const coal = Color(0xFF072514); // cards
  static const coal2 = Color(0xFF0B321B); // raised surfaces, bubbles
  static const line = Color(0xFF134726); // borders
  static const bone = Color(0xFFE4FFEA); // text
  static const mute = Color(0xFF7CB08E); // secondary text
  static const volt = Color(0xFF2EFF6E); // accent
  static const voltDeep = Color(0xFF12C24F);
  static const mint = Color(0xFFB4FFCB);

  // Names used throughout the app, mapped onto the palette.
  static const bg = ink;
  static const navy = Color(0xFF051F0F);
  static const panel = coal;
  static const panelHi = coal2;
  static const cyan = volt; // primary accent
  static const blue = voltDeep;
  static const ice = mint;
  static const text = bone;
  static const dim = mute;
  static const green = volt;
  static const violet = Color(0xFF7DFFB0); // "thinking" — a lighter mint so it reads differently
  // Semantic colours kept for safety-critical states (approval / stop / errors).
  static const amber = Color(0xFFFFC857);
  static const red = Color(0xFFFF5A5F);
}

class JFonts {
  static const display = 'SpaceGrotesk';
  static const sans = 'Geist';
  static const mono = 'GeistMono';
}

/// Small uppercase mono label like the landing page's "LEO HEARD" / "LEO · ANSWER".
TextStyle monoLabel({Color color = JColors.volt, double size = 10}) =>
    TextStyle(fontFamily: JFonts.mono, fontSize: size, letterSpacing: 2.2, color: color, fontWeight: FontWeight.w500);

ThemeData jarvisTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final text = base.textTheme
      .apply(bodyColor: JColors.bone, displayColor: JColors.bone, fontFamily: JFonts.sans)
      .copyWith(
        displayLarge: const TextStyle(fontFamily: JFonts.display, fontWeight: FontWeight.w700, letterSpacing: -2),
        headlineMedium: const TextStyle(fontFamily: JFonts.display, fontWeight: FontWeight.w700, letterSpacing: -1),
        titleLarge: const TextStyle(fontFamily: JFonts.display, fontWeight: FontWeight.w600),
        titleMedium: const TextStyle(fontFamily: JFonts.display, fontWeight: FontWeight.w600),
      );
  return base.copyWith(
    scaffoldBackgroundColor: JColors.ink,
    colorScheme: const ColorScheme.dark(
      primary: JColors.volt,
      secondary: JColors.voltDeep,
      surface: JColors.coal,
      error: JColors.red,
      onPrimary: JColors.ink,
      onSecondary: JColors.ink,
      onSurface: JColors.bone,
    ),
    textTheme: text,
    appBarTheme: const AppBarTheme(
      backgroundColor: JColors.ink,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontFamily: JFonts.display, color: JColors.bone, fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.5),
    ),
    cardTheme: CardThemeData(
      color: JColors.coal,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: JColors.line)),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: JColors.coal2,
      hintStyle: const TextStyle(color: JColors.mute, fontFamily: JFonts.sans),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide(color: JColors.volt.withValues(alpha: 0.12))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide(color: JColors.volt.withValues(alpha: 0.12))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: const BorderSide(color: JColors.volt)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: JColors.volt,
        foregroundColor: JColors.ink,
        textStyle: const TextStyle(fontFamily: JFonts.display, fontWeight: FontWeight.w600),
        shape: const StadiumBorder(),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: JColors.bone,
        side: BorderSide(color: JColors.volt.withValues(alpha: 0.25)),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontFamily: JFonts.sans, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: JColors.volt)),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: JColors.navy,
      indicatorColor: JColors.volt,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
          fontFamily: JFonts.mono,
          fontSize: 10,
          letterSpacing: 1.2,
          color: s.contains(WidgetState.selected) ? JColors.volt : JColors.mute)),
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? JColors.ink : JColors.mute)),
    ),
    dividerColor: JColors.line,
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? JColors.ink : JColors.bone.withValues(alpha: 0.8)),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? JColors.volt : JColors.line),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: const SliderThemeData(activeTrackColor: JColors.volt, thumbColor: JColors.volt, inactiveTrackColor: JColors.line),
    snackBarTheme: const SnackBarThemeData(backgroundColor: JColors.coal2, contentTextStyle: TextStyle(color: JColors.bone)),
  );
}

extension DisplayStateStyle on DisplayState {
  String get label => switch (this) {
        DisplayState.offline => 'STANDBY',
        DisplayState.waiting => 'SAY "LEO"',
        DisplayState.listening => 'LISTENING',
        DisplayState.thinking => 'THINKING',
        DisplayState.speaking => 'SPEAKING',
        DisplayState.executing => 'WORKING ON IT',
        DisplayState.approval => 'WAITING FOR YOU',
        DisplayState.paused => 'PAUSED',
      };

  /// Green family for normal states; amber only where the user must act.
  Color get color => switch (this) {
        DisplayState.offline => JColors.mute,
        DisplayState.waiting => JColors.voltDeep,
        DisplayState.listening => JColors.volt,
        DisplayState.thinking => JColors.violet,
        DisplayState.speaking => JColors.mint,
        DisplayState.executing => JColors.volt,
        DisplayState.approval => JColors.amber,
        DisplayState.paused => JColors.amber,
      };
}
