import 'package:material_ui/material_ui.dart';

/// Minimal monochrome design system for Unclip.
///
/// Synthesized from `ui-ux-pro-max` ("Minimalism & Swiss Style" +
/// "Apple Native Experience"), `duobaseio/forui` Zinc dark tokens, and `taste.md`:
/// - Neutral OLED-safe Zinc palette, single high-contrast white accent,
///   1px translucent hairlines, zero blur, zero decorative gradients.
/// - >= 44pt touch targets, instant pointer-down spring physics, >= 4.5:1 contrast.
abstract final class Ui {
  // ---------------------------------------------------------------------------
  // Colour (Zinc dark studio — avoids #000000 smear on surfaces)
  // ---------------------------------------------------------------------------
  static const Color bg = Color(0xFF09090B);
  static const Color surface = Color(0xFF121215);
  static const Color surfaceRaised = Color(0xFF1A1A1F);
  static const Color surfaceThumb = Color(0xFF27272E);
  static const Color stage = Color(0xFF000000);
  static const Color hudScrim = Color(0xD6121215);

  static const Color hairline = Color(0x16FFFFFF);
  static const Color hairlineStrong = Color(0x2BFFFFFF);

  /// Contrast on [bg]: primary ~19:1, secondary ~8.1:1, tertiary ~4.8:1.
  static const Color textPrimary = Color(0xFFFAFAFA);
  static const Color textSecondary = Color(0xFFA1A1AA);
  static const Color textTertiary = Color(0xFF787882);

  /// Single high-contrast accent: crisp white on near-black.
  static const Color accent = Color(0xFFFAFAFA);
  static const Color onAccent = Color(0xFF09090B);

  /// Functional status colours (used only alongside icon + label).
  static const Color liveActive = Color(0xFF34D399);
  static const Color danger = Color(0xFFFF6961);

  // ---------------------------------------------------------------------------
  // Spacing (4/8dp rhythm) & Radii
  // ---------------------------------------------------------------------------
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s8 = 32;

  static const double rSm = 8;
  static const double rMd = 12;
  static const double rLg = 16;
  static const double rXl = 20;

  static const double minTarget = 44;
  static const double buttonHeight = 52;

  // ---------------------------------------------------------------------------
  // Motion tokens
  // ---------------------------------------------------------------------------
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration base = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);

  static const Curve easeOut = Cubic(0.22, 1.0, 0.36, 1.0);
  static const Curve easeIn = Cubic(0.55, 0.0, 1.0, 0.45);

  static Duration motion(BuildContext context, Duration d) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : d;

  // ---------------------------------------------------------------------------
  // Typography (platform system font, explicit TextDecoration.none everywhere)
  // ---------------------------------------------------------------------------
  static const List<FontFeature> tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  static const TextStyle largeTitle = TextStyle(
    fontSize: 26,
    height: 1.24,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    color: textPrimary,
    decoration: TextDecoration.none,
  );

  static const TextStyle title = TextStyle(
    fontSize: 19,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    color: textPrimary,
    decoration: TextDecoration.none,
  );

  static const TextStyle wordmark = TextStyle(
    fontSize: 17,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    color: textPrimary,
    decoration: TextDecoration.none,
  );

  static const TextStyle body = TextStyle(
    fontSize: 14.5,
    height: 1.5,
    fontWeight: FontWeight.w400,
    color: textSecondary,
    decoration: TextDecoration.none,
  );

  static const TextStyle label = TextStyle(
    fontSize: 15,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: textPrimary,
    decoration: TextDecoration.none,
  );

  static const TextStyle callout = TextStyle(
    fontSize: 13.5,
    height: 1.35,
    fontWeight: FontWeight.w500,
    color: textPrimary,
    decoration: TextDecoration.none,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 12.5,
    height: 1.35,
    fontWeight: FontWeight.w500,
    color: textTertiary,
    decoration: TextDecoration.none,
  );

  static const TextStyle mono = TextStyle(
    fontSize: 12.5,
    height: 1.3,
    fontWeight: FontWeight.w600,
    fontFeatures: tabular,
    color: textPrimary,
    decoration: TextDecoration.none,
  );

  static ThemeData theme() {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      splashFactory: NoSplash.splashFactory,
      highlightColor: const Color(0x00000000),
      colorScheme: const ColorScheme.dark(
        primary: accent,
        onPrimary: onAccent,
        surface: surface,
        onSurface: textPrimary,
        error: danger,
      ),
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
        decoration: TextDecoration.none,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: textPrimary,
        linearTrackColor: surfaceRaised,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        modalBackgroundColor: surface,
        surfaceTintColor: Color(0x00000000),
        showDragHandle: true,
        dragHandleColor: hairlineStrong,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surfaceRaised,
        elevation: 0,
        insetPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(rMd)),
          side: BorderSide(color: hairlineStrong),
        ),
        contentTextStyle: callout,
      ),
    );
  }
}
