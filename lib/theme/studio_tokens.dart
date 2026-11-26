import 'package:material_ui/material_ui.dart';

/// Semantic design tokens aligned with `ui-ux-pro-max`
/// (`Modern Dark Cinema Mobile` + `Apple Liquid Glass` + `Pro Rules`).
abstract final class StudioTokens {
  // ===========================================================================
  // OLED-Safe Cinema Surfaces (avoids pure #000000 OLED smear)
  // ===========================================================================
  static const Color bgDeep = Color(0xFF05070C);
  static const Color bgBase = Color(0xFF090E18);
  static const Color bgElevated = Color(0xFF101827);

  static const Color surfaceStage = Color(0xFF060911);
  static const Color surfaceConsole = Color(0x990D1422);
  static const Color surfacePill = Color(0xC20E1626);
  static const Color surfaceSubtle = Color(0x14FFFFFF);
  static const Color surfaceSubtlePressed = Color(0x26FFFFFF);

  // ===========================================================================
  // Optical Accents (Clean Cobalt & Ice Cyan — zero muddy yellow)
  // ===========================================================================
  static const Color accentPrimary = Color(0xFF0A84FF);
  static const Color accentCyan = Color(0xFF38BDF8);
  static const Color accentIce = Color(0xFF7DD3FC);
  static const Color accentIndigo = Color(0xFF6366F1);
  static const Color accentGlow = Color(0x420A84FF);
  static const Color accentActiveFill = Color(0x2E38BDF8);
  static const Color accentActiveBorder = Color(0x737DD3FC);

  // ===========================================================================
  // Accessible Dark-Mode Typography (>= 4.5:1 WCAG AA contrast)
  // ===========================================================================
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFFCBD5E1);
  static const Color textMuted = Color(0xFF94A3B8);

  // ===========================================================================
  // Translucent Hairline Borders (RGBA only, no harsh solid grey)
  // ===========================================================================
  static const Color borderSubtle = Color(0x1AFFFFFF);
  static const Color borderDefault = Color(0x29FFFFFF);
  static const Color borderStrong = Color(0x47FFFFFF);

  // ===========================================================================
  // Touch & Spacing Scale (4/8dp rhythm + >=48dp touch targets)
  // ===========================================================================
  static const double minTouchTarget = 48.0;
  static const double minCompactTouchTarget = 44.0;

  static const double radiusStage = 26.0;
  static const double radiusConsole = 22.0;
  static const double radiusControl = 14.0;
  static const double radiusPill = 999.0;

  // ===========================================================================
  // Context-Aware Motion Tokens (`Expo.out` arrival + snappy press)
  // ===========================================================================
  static const Duration pressDuration = Duration(milliseconds: 95);
  static const Duration releaseDuration = Duration(milliseconds: 210);
  static const Duration microDuration = Duration(milliseconds: 200);
  static const Duration stateDuration = Duration(milliseconds: 280);

  /// `Bezier(0.16, 1, 0.3, 1)` from UI/UX Pro Max Cinema Mobile spec.
  static const Curve curveOutExpo = Cubic(0.16, 1.0, 0.3, 1.0);
  static const Curve curveSpring = Curves.easeOutBack;
}
