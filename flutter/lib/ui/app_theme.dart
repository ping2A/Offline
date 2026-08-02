import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Carbon radio — near-black void, bone type, amber signal. No purple chrome.
abstract final class OfflineColors {
  static const voidBlack = Color(0xFF050506);
  static const canvas = Color(0xFF0C0D0F);
  static const raised = Color(0xFF15171A);
  static const raisedHigh = Color(0xFF1C1F24);

  /// Primary readable text (bone).
  static const ink = Color(0xFFE8E6E1);
  static const mist = Color(0xFF8B9098);
  static const line = Color(0xFF2A2E35);

  /// Amber radio signal — accents & primary actions.
  static const moss = Color(0xFFD4A35C);
  static const leaf = Color(0xFFE8C07A);
  static const signal = Color(0xFF5DFFB0);

  static const paper = canvas;
  static const paperDeep = raised;
  static const bubbleMine = Color(0xFF22262C);
  static const bubbleTheirs = Color(0xFF171A1E);
  static const danger = Color(0xFFD4604E);

  static const onAccent = Color(0xFF12100C);
}

ThemeData buildOfflineTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: const ColorScheme.dark(
      primary: OfflineColors.moss,
      onPrimary: OfflineColors.onAccent,
      secondary: OfflineColors.leaf,
      onSecondary: OfflineColors.onAccent,
      surface: OfflineColors.raised,
      onSurface: OfflineColors.ink,
      outline: OfflineColors.line,
      error: OfflineColors.danger,
      onError: OfflineColors.ink,
    ),
  );

  final display = GoogleFonts.spaceGroteskTextTheme(base.textTheme);
  final body = GoogleFonts.sourceSans3TextTheme(base.textTheme);

  return base.copyWith(
    textTheme: body.copyWith(
      displayLarge: display.displayLarge?.copyWith(
        color: OfflineColors.ink,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
      ),
      displayMedium: display.displayMedium?.copyWith(
        color: OfflineColors.ink,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
      ),
      headlineLarge: display.headlineLarge?.copyWith(
        color: OfflineColors.ink,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
      ),
      headlineMedium: display.headlineMedium?.copyWith(
        color: OfflineColors.ink,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.5,
        fontSize: 28,
      ),
      headlineSmall: display.headlineSmall?.copyWith(
        color: OfflineColors.ink,
        fontWeight: FontWeight.w600,
      ),
      titleLarge: display.titleLarge?.copyWith(
        color: OfflineColors.ink,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: body.titleMedium?.copyWith(
        color: OfflineColors.ink,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: body.bodyLarge?.copyWith(
        color: OfflineColors.ink,
        height: 1.45,
        fontSize: 16,
      ),
      bodyMedium: body.bodyMedium?.copyWith(
        color: OfflineColors.ink.withValues(alpha: 0.78),
        height: 1.4,
      ),
      bodySmall: body.bodySmall?.copyWith(
        color: OfflineColors.mist,
        height: 1.35,
      ),
      labelLarge: body.labelLarge?.copyWith(
        color: OfflineColors.mist,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: OfflineColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: GoogleFonts.spaceGrotesk(
        color: OfflineColors.ink,
        fontWeight: FontWeight.w700,
        fontSize: 20,
        letterSpacing: -0.3,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: OfflineColors.moss,
        foregroundColor: OfflineColors.onAccent,
        elevation: 0,
        disabledBackgroundColor: OfflineColors.raisedHigh,
        disabledForegroundColor: OfflineColors.mist,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: GoogleFonts.spaceGrotesk(
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: OfflineColors.ink,
        side: const BorderSide(color: OfflineColors.line, width: 1.2),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: GoogleFonts.spaceGrotesk(
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: OfflineColors.leaf,
        textStyle: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: ChipThemeData(
      selectedColor: OfflineColors.moss.withValues(alpha: 0.22),
      checkmarkColor: OfflineColors.moss,
      labelStyle: GoogleFonts.spaceGrotesk(
        fontWeight: FontWeight.w600,
        color: OfflineColors.ink,
      ),
      side: const BorderSide(color: OfflineColors.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      backgroundColor: OfflineColors.raised,
      secondarySelectedColor: OfflineColors.moss.withValues(alpha: 0.22),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: OfflineColors.raised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: OfflineColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: OfflineColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: OfflineColors.moss, width: 1.4),
      ),
      hintStyle: GoogleFonts.sourceSans3(color: OfflineColors.mist),
      labelStyle: GoogleFonts.sourceSans3(color: OfflineColors.mist),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: OfflineColors.raisedHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: OfflineColors.raisedHigh,
      contentTextStyle: GoogleFonts.sourceSans3(color: OfflineColors.ink),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dividerColor: OfflineColors.line,
    iconTheme: const IconThemeData(color: OfflineColors.mist),
  );
}

/// Atmospheric black backdrop with a quiet amber wash and fine grain.
class OfflineBackdrop extends StatelessWidget {
  const OfflineBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF0A0B0D),
            Color(0xFF050506),
            Color(0xFF0E0C09),
          ],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: -120,
            right: -60,
            width: 340,
            height: 340,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      OfflineColors.moss.withValues(alpha: 0.11),
                      OfflineColors.moss.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -80,
            left: -40,
            width: 280,
            height: 280,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      OfflineColors.signal.withValues(alpha: 0.05),
                      OfflineColors.signal.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _GrainPainter()),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _GrainPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x0AFFFFFF)
      ..strokeWidth = 1;
    const step = 32.0;
    for (var x = -size.height; x < size.width + size.height; x += step) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
