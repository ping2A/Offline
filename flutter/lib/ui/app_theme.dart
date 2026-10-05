import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Built-in visual themes. Each is a full palette + backdrop, not just an accent.
enum OfflineThemeId {
  carbon,
  midnight,
  forest,
  paper,
  ember,
  terminal,
}

extension OfflineThemeIdX on OfflineThemeId {
  String get storageKey => name;

  static OfflineThemeId? tryParse(String? raw) {
    if (raw == null) return null;
    for (final id in OfflineThemeId.values) {
      if (id.name == raw) return id;
    }
    return null;
  }
}

/// One complete Offline look (surfaces, type, accents, backdrop).
class OfflinePalette {
  const OfflinePalette({
    required this.id,
    required this.label,
    required this.blurb,
    required this.brightness,
    required this.voidBlack,
    required this.canvas,
    required this.raised,
    required this.raisedHigh,
    required this.ink,
    required this.mist,
    required this.line,
    required this.moss,
    required this.leaf,
    required this.signal,
    required this.bubbleMine,
    required this.bubbleTheirs,
    required this.danger,
    required this.onAccent,
    required this.backdrop,
    required this.glowPrimary,
    required this.glowSecondary,
    required this.brandEnd,
  });

  final OfflineThemeId id;
  final String label;
  final String blurb;
  final Brightness brightness;

  final Color voidBlack;
  final Color canvas;
  final Color raised;
  final Color raisedHigh;
  final Color ink;
  final Color mist;
  final Color line;

  /// Primary accent (actions, selection).
  final Color moss;
  final Color leaf;
  final Color signal;
  final Color bubbleMine;
  final Color bubbleTheirs;
  final Color danger;
  final Color onAccent;

  final List<Color> backdrop;
  final Color glowPrimary;
  final Color glowSecondary;
  final Color brandEnd;

  Color get paper => canvas;
  Color get paperDeep => raised;
  Color get brandStart => moss;
}

/// Persisted theme selection. Call [load] once at startup.
class OfflineThemeController extends ChangeNotifier {
  OfflineThemeController._();
  static final OfflineThemeController instance = OfflineThemeController._();

  static const _prefsKey = 'ui.theme_id';

  OfflineThemeId _id = OfflineThemeId.carbon;
  OfflineThemeId get id => _id;
  OfflinePalette get palette => OfflineThemes.of(_id);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final parsed = OfflineThemeIdX.tryParse(prefs.getString(_prefsKey));
    if (parsed != null && parsed != _id) {
      _id = parsed;
      notifyListeners();
    }
  }

  Future<void> setTheme(OfflineThemeId id) async {
    if (id == _id) return;
    _id = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, id.storageKey);
  }
}

/// Catalog of built-in themes.
abstract final class OfflineThemes {
  static List<OfflinePalette> get all => [
        carbon,
        midnight,
        forest,
        paper,
        ember,
        terminal,
      ];

  static OfflinePalette of(OfflineThemeId id) => switch (id) {
        OfflineThemeId.carbon => carbon,
        OfflineThemeId.midnight => midnight,
        OfflineThemeId.forest => forest,
        OfflineThemeId.paper => paper,
        OfflineThemeId.ember => ember,
        OfflineThemeId.terminal => terminal,
      };

  /// Near-black void, bone type, amber radio signal (default).
  static const carbon = OfflinePalette(
    id: OfflineThemeId.carbon,
    label: 'Carbon',
    blurb: 'Amber radio on near-black',
    brightness: Brightness.dark,
    voidBlack: Color(0xFF050506),
    canvas: Color(0xFF0C0D0F),
    raised: Color(0xFF15171A),
    raisedHigh: Color(0xFF1C1F24),
    ink: Color(0xFFE8E6E1),
    mist: Color(0xFF8B9098),
    line: Color(0xFF2A2E35),
    moss: Color(0xFFD4A35C),
    leaf: Color(0xFFE8C07A),
    signal: Color(0xFF5DFFB0),
    bubbleMine: Color(0xFF22262C),
    bubbleTheirs: Color(0xFF171A1E),
    danger: Color(0xFFD4604E),
    onAccent: Color(0xFF12100C),
    backdrop: [Color(0xFF0A0B0D), Color(0xFF050506), Color(0xFF0E0C09)],
    glowPrimary: Color(0xFFD4A35C),
    glowSecondary: Color(0xFF5DFFB0),
    brandEnd: Color(0xFFA67A35),
  );

  /// Deep navy hull, cyan beacon.
  static const midnight = OfflinePalette(
    id: OfflineThemeId.midnight,
    label: 'Midnight',
    blurb: 'Navy hull, cyan beacon',
    brightness: Brightness.dark,
    voidBlack: Color(0xFF04060C),
    canvas: Color(0xFF0A1018),
    raised: Color(0xFF121A26),
    raisedHigh: Color(0xFF1A2433),
    ink: Color(0xFFE2E8F0),
    mist: Color(0xFF8494A8),
    line: Color(0xFF243044),
    moss: Color(0xFF3DB8E8),
    leaf: Color(0xFF7DD3F0),
    signal: Color(0xFF5EEAD4),
    bubbleMine: Color(0xFF1A2838),
    bubbleTheirs: Color(0xFF111820),
    danger: Color(0xFFE07070),
    onAccent: Color(0xFF041018),
    backdrop: [Color(0xFF08121C), Color(0xFF04060C), Color(0xFF0A1420)],
    glowPrimary: Color(0xFF3DB8E8),
    glowSecondary: Color(0xFF5EEAD4),
    brandEnd: Color(0xFF1F7FA8),
  );

  /// Pine canopy, lime trail markers.
  static const forest = OfflinePalette(
    id: OfflineThemeId.forest,
    label: 'Forest',
    blurb: 'Pine dark, lime trail',
    brightness: Brightness.dark,
    voidBlack: Color(0xFF050806),
    canvas: Color(0xFF0B110D),
    raised: Color(0xFF141C16),
    raisedHigh: Color(0xFF1B261E),
    ink: Color(0xFFE4EBE4),
    mist: Color(0xFF859388),
    line: Color(0xFF273229),
    moss: Color(0xFF7CB87A),
    leaf: Color(0xFFA8D4A0),
    signal: Color(0xFFC8F06A),
    bubbleMine: Color(0xFF1C261E),
    bubbleTheirs: Color(0xFF121814),
    danger: Color(0xFFD4785C),
    onAccent: Color(0xFF0A120C),
    backdrop: [Color(0xFF0A120E), Color(0xFF050806), Color(0xFF0C140C)],
    glowPrimary: Color(0xFF7CB87A),
    glowSecondary: Color(0xFFC8F06A),
    brandEnd: Color(0xFF4A8A48),
  );

  /// Cool daylight paper — slate ink, cobalt actions (not cream/terracotta).
  static const paper = OfflinePalette(
    id: OfflineThemeId.paper,
    label: 'Paper',
    blurb: 'Cool daylight, cobalt marks',
    brightness: Brightness.light,
    voidBlack: Color(0xFFD8DEE6),
    canvas: Color(0xFFE8ECF1),
    raised: Color(0xFFF4F6F8),
    raisedHigh: Color(0xFFFFFFFF),
    ink: Color(0xFF1A222C),
    mist: Color(0xFF5C6B7A),
    line: Color(0xFFC5CDD8),
    moss: Color(0xFF2F6FED),
    leaf: Color(0xFF1E4FBF),
    signal: Color(0xFF0D9488),
    bubbleMine: Color(0xFFDCE6F8),
    bubbleTheirs: Color(0xFFE4E8EE),
    danger: Color(0xFFC23B3B),
    onAccent: Color(0xFFF7F9FC),
    backdrop: [Color(0xFFE4E9F0), Color(0xFFDCE2EA), Color(0xFFE8ECF2)],
    glowPrimary: Color(0xFF2F6FED),
    glowSecondary: Color(0xFF0D9488),
    brandEnd: Color(0xFF1E4FBF),
  );

  /// Charcoal deck, ember signal.
  static const ember = OfflinePalette(
    id: OfflineThemeId.ember,
    label: 'Ember',
    blurb: 'Charcoal deck, ember glow',
    brightness: Brightness.dark,
    voidBlack: Color(0xFF080605),
    canvas: Color(0xFF100E0C),
    raised: Color(0xFF1A1614),
    raisedHigh: Color(0xFF24201C),
    ink: Color(0xFFF0E8E0),
    mist: Color(0xFF9A8E84),
    line: Color(0xFF322C28),
    moss: Color(0xFFE07040),
    leaf: Color(0xFFF0A070),
    signal: Color(0xFFFFB454),
    bubbleMine: Color(0xFF261E18),
    bubbleTheirs: Color(0xFF161210),
    danger: Color(0xFFE05050),
    onAccent: Color(0xFF140C08),
    backdrop: [Color(0xFF120E0A), Color(0xFF080605), Color(0xFF160E0A)],
    glowPrimary: Color(0xFFE07040),
    glowSecondary: Color(0xFFFFB454),
    brandEnd: Color(0xFFB04828),
  );

  /// CRT phosphor green on pure black.
  static const terminal = OfflinePalette(
    id: OfflineThemeId.terminal,
    label: 'Terminal',
    blurb: 'Phosphor green on black',
    brightness: Brightness.dark,
    voidBlack: Color(0xFF000000),
    canvas: Color(0xFF050805),
    raised: Color(0xFF0C120C),
    raisedHigh: Color(0xFF141C14),
    ink: Color(0xFFC8F0C8),
    mist: Color(0xFF5A8A5A),
    line: Color(0xFF1E301E),
    moss: Color(0xFF33CC66),
    leaf: Color(0xFF66EE88),
    signal: Color(0xFFAAFF44),
    bubbleMine: Color(0xFF102010),
    bubbleTheirs: Color(0xFF080E08),
    danger: Color(0xFFFF5544),
    onAccent: Color(0xFF021006),
    backdrop: [Color(0xFF040804), Color(0xFF000000), Color(0xFF060A04)],
    glowPrimary: Color(0xFF33CC66),
    glowSecondary: Color(0xFFAAFF44),
    brandEnd: Color(0xFF1A8840),
  );
}

/// Live color accessors used across the UI. Values follow the active theme.
abstract final class OfflineColors {
  static OfflinePalette get _p => OfflineThemeController.instance.palette;

  static Color get voidBlack => _p.voidBlack;
  static Color get canvas => _p.canvas;
  static Color get raised => _p.raised;
  static Color get raisedHigh => _p.raisedHigh;
  static Color get ink => _p.ink;
  static Color get mist => _p.mist;
  static Color get line => _p.line;
  static Color get moss => _p.moss;
  static Color get leaf => _p.leaf;
  static Color get signal => _p.signal;
  static Color get paper => _p.paper;
  static Color get paperDeep => _p.paperDeep;
  static Color get bubbleMine => _p.bubbleMine;
  static Color get bubbleTheirs => _p.bubbleTheirs;
  static Color get danger => _p.danger;
  static Color get onAccent => _p.onAccent;
}

ThemeData buildOfflineTheme(OfflinePalette p) {
  final dark = p.brightness == Brightness.dark;
  final base = ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: (dark ? const ColorScheme.dark() : const ColorScheme.light())
        .copyWith(
      primary: p.moss,
      onPrimary: p.onAccent,
      secondary: p.leaf,
      onSecondary: p.onAccent,
      surface: p.raised,
      onSurface: p.ink,
      outline: p.line,
      error: p.danger,
      onError: p.ink,
    ),
  );

  final display = GoogleFonts.spaceGroteskTextTheme(base.textTheme);
  final body = GoogleFonts.sourceSans3TextTheme(base.textTheme);

  return base.copyWith(
    textTheme: body.copyWith(
      displayLarge: display.displayLarge?.copyWith(
        color: p.ink,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
      ),
      displayMedium: display.displayMedium?.copyWith(
        color: p.ink,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
      ),
      headlineLarge: display.headlineLarge?.copyWith(
        color: p.ink,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
      ),
      headlineMedium: display.headlineMedium?.copyWith(
        color: p.ink,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.5,
        fontSize: 28,
      ),
      headlineSmall: display.headlineSmall?.copyWith(
        color: p.ink,
        fontWeight: FontWeight.w600,
      ),
      titleLarge: display.titleLarge?.copyWith(
        color: p.ink,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: body.titleMedium?.copyWith(
        color: p.ink,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: body.bodyLarge?.copyWith(
        color: p.ink,
        height: 1.45,
        fontSize: 16,
      ),
      bodyMedium: body.bodyMedium?.copyWith(
        color: p.ink.withValues(alpha: 0.78),
        height: 1.4,
      ),
      bodySmall: body.bodySmall?.copyWith(
        color: p.mist,
        height: 1.35,
      ),
      labelLarge: body.labelLarge?.copyWith(
        color: p.mist,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: GoogleFonts.spaceGrotesk(
        color: p.ink,
        fontWeight: FontWeight.w700,
        fontSize: 20,
        letterSpacing: -0.3,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.moss,
        foregroundColor: p.onAccent,
        elevation: 0,
        disabledBackgroundColor: p.raisedHigh,
        disabledForegroundColor: p.mist,
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
        foregroundColor: p.ink,
        side: BorderSide(color: p.line, width: 1.2),
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
        foregroundColor: p.leaf,
        textStyle: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: ChipThemeData(
      selectedColor: p.moss.withValues(alpha: 0.22),
      checkmarkColor: p.moss,
      labelStyle: GoogleFonts.spaceGrotesk(
        fontWeight: FontWeight.w600,
        color: p.ink,
      ),
      side: BorderSide(color: p.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      backgroundColor: p.raised,
      secondarySelectedColor: p.moss.withValues(alpha: 0.22),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.raised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: p.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: p.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: p.moss, width: 1.4),
      ),
      hintStyle: GoogleFonts.sourceSans3(color: p.mist),
      labelStyle: GoogleFonts.sourceSans3(color: p.mist),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.raisedHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.raisedHigh,
      contentTextStyle: GoogleFonts.sourceSans3(color: p.ink),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dividerColor: p.line,
    iconTheme: IconThemeData(color: p.mist),
  );
}

/// Atmospheric backdrop that follows the active palette.
class OfflineBackdrop extends StatelessWidget {
  const OfflineBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = OfflineThemeController.instance.palette;
    final colors = p.backdrop.length >= 3
        ? p.backdrop
        : [p.canvas, p.voidBlack, p.canvas];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
          stops: const [0.0, 0.55, 1.0],
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
                      p.glowPrimary.withValues(alpha: 0.11),
                      p.glowPrimary.withValues(alpha: 0),
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
                      p.glowSecondary.withValues(alpha: 0.05),
                      p.glowSecondary.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _GrainPainter(
                  light: p.brightness == Brightness.light,
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _GrainPainter extends CustomPainter {
  _GrainPainter({required this.light});

  final bool light;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = light ? const Color(0x0A000000) : const Color(0x0AFFFFFF)
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
  bool shouldRepaint(covariant _GrainPainter oldDelegate) =>
      oldDelegate.light != light;
}

/// Compact control that opens the theme picker sheet.
class OfflineThemeButton extends StatelessWidget {
  const OfflineThemeButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: OfflineThemeController.instance,
      builder: (context, _) {
        final p = OfflineThemeController.instance.palette;
        return Tooltip(
          message: 'Theme · ${p.label}',
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => showOfflineThemePicker(context),
              borderRadius: BorderRadius.circular(8),
              child: Ink(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: OfflineColors.line),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [p.moss, p.brandEnd],
                  ),
                ),
                child: Icon(
                  Icons.palette_outlined,
                  size: 16,
                  color: p.onAccent,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

Future<void> showOfflineThemePicker(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: OfflineColors.raisedHigh,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return ListenableBuilder(
        listenable: OfflineThemeController.instance,
        builder: (context, _) {
          final active = OfflineThemeController.instance.id;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: OfflineColors.line,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Theme',
                    style: GoogleFonts.spaceGrotesk(
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                      color: OfflineColors.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Looks apply instantly and are remembered.',
                    style: GoogleFonts.sourceSans3(
                      fontSize: 13,
                      color: OfflineColors.mist,
                    ),
                  ),
                  const SizedBox(height: 14),
                  for (final palette in OfflineThemes.all) ...[
                    _ThemeChoiceTile(
                      palette: palette,
                      selected: palette.id == active,
                      onTap: () async {
                        await OfflineThemeController.instance
                            .setTheme(palette.id);
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

class _ThemeChoiceTile extends StatelessWidget {
  const _ThemeChoiceTile({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  final OfflinePalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? OfflineColors.moss.withValues(alpha: 0.14)
          : OfflineColors.raised,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? OfflineColors.moss : OfflineColors.line,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              _ThemeSwatch(palette: palette),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      palette.label,
                      style: GoogleFonts.spaceGrotesk(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: OfflineColors.ink,
                      ),
                    ),
                    Text(
                      palette.blurb,
                      style: GoogleFonts.sourceSans3(
                        fontSize: 12,
                        color: OfflineColors.mist,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle, size: 20, color: OfflineColors.moss)
              else
                Icon(Icons.circle_outlined,
                    size: 20, color: OfflineColors.line),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({required this.palette});

  final OfflinePalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: OfflineColors.line),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            palette.canvas,
            palette.raised,
            palette.moss,
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: Align(
        alignment: Alignment.bottomRight,
        child: Container(
          width: 14,
          height: 14,
          margin: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: palette.signal,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: palette.onAccent.withValues(alpha: 0.35)),
          ),
        ),
      ),
    );
  }
}
