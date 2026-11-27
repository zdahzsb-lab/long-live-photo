import 'package:material_ui/material_ui.dart';

import '../theme/ui_tokens.dart';
import 'pressable.dart';

/// Full-width high-contrast primary action (crisp white on near-black).
///
/// Morphs seamlessly into an inline sweep progress indicator when [progress]
/// is non-null, keeping visual focus anchored in one place during export.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.enabled = true,
    this.progress,
    this.progressLabel,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool enabled;
  final double? progress;
  final String? progressLabel;

  @override
  Widget build(BuildContext context) {
    final busy = progress != null;
    final duration = Ui.motion(context, Ui.base);

    return Pressable(
      onTap: busy ? null : onTap,
      enabled: enabled || busy,
      expandWidth: true,
      haptic: Haptic.medium,
      maxInsetPx: 6.0,
      pressedOpacity: 0.88,
      semanticLabel: busy ? (progressLabel ?? label) : label,
      child: AnimatedContainer(
        duration: duration,
        curve: Ui.easeOut,
        height: Ui.buttonHeight,
        width: double.infinity,
        decoration: BoxDecoration(
          color: busy ? Ui.surfaceRaised : Ui.accent,
          borderRadius: BorderRadius.circular(Ui.rMd + 2),
          border: busy ? Border.all(color: Ui.hairlineStrong) : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (busy)
              TweenAnimationBuilder<double>(
                tween: Tween<double>(end: progress!.clamp(0.0, 1.0)),
                duration: Ui.motion(context, Ui.slow),
                curve: Ui.easeOut,
                builder: (BuildContext context, double v, Widget? _) {
                  return FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: v,
                    child: const ColoredBox(color: Color(0x26FFFFFF)),
                  );
                },
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Ui.s4),
              child: Center(
                child: AnimatedSwitcher(
                  duration: Ui.motion(context, Ui.fast),
                  switchInCurve: Ui.easeOut,
                  switchOutCurve: Ui.easeIn,
                  child: Row(
                    key: ValueKey<bool>(busy),
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (!busy && icon != null) ...<Widget>[
                        Icon(icon, size: 18, color: Ui.onAccent),
                        const SizedBox(width: Ui.s2),
                      ],
                      Flexible(
                        child: Text(
                          busy ? (progressLabel ?? label) : label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Ui.label.copyWith(
                            color: busy ? Ui.textPrimary : Ui.onAccent,
                            fontFeatures: Ui.tabular,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Subordinate full-width surface button with 1px hairline border.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.enabled = true,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      enabled: enabled,
      expandWidth: true,
      maxInsetPx: 6.0,
      semanticLabel: label,
      child: Container(
        height: Ui.buttonHeight,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: Ui.s4),
        decoration: BoxDecoration(
          color: Ui.surface,
          borderRadius: BorderRadius.circular(Ui.rMd + 2),
          border: Border.all(color: Ui.hairline),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 17, color: Ui.textSecondary),
              const SizedBox(width: Ui.s2),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ui.label.copyWith(color: Ui.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 44×44pt accessible icon action.
class IconAction extends StatelessWidget {
  const IconAction({
    super.key,
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
    this.enabled = true,
    this.filled = false,
    this.size = 19,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onTap;
  final bool enabled;
  final bool filled;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      enabled: enabled,
      semanticLabel: semanticLabel,
      maxInsetPx: 3.5,
      child: Container(
        width: Ui.minTarget,
        height: Ui.minTarget,
        decoration: filled
            ? BoxDecoration(
                color: Ui.surface,
                borderRadius: BorderRadius.circular(Ui.rMd),
                border: Border.all(color: Ui.hairline),
              )
            : null,
        child: Icon(icon, size: size, color: Ui.textPrimary),
      ),
    );
  }
}

/// Compact pill control whose visual height is 30pt while its touch box is >=44pt.
class PillAction extends StatelessWidget {
  const PillAction({
    super.key,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    this.icon,
    this.enabled = true,
    this.emphasized = false,
  });

  final String label;
  final String semanticLabel;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool enabled;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      enabled: enabled,
      semanticLabel: semanticLabel,
      maxInsetPx: 3.5,
      minSize: const Size(48, Ui.minTarget),
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: emphasized ? Ui.surfaceRaised : Ui.surface,
          borderRadius: BorderRadius.circular(Ui.rSm),
          border: Border.all(
            color: emphasized ? Ui.hairlineStrong : Ui.hairline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(
                icon,
                size: 13,
                color: emphasized ? Ui.textPrimary : Ui.textSecondary,
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: Ui.callout.copyWith(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                fontFeatures: Ui.tabular,
                color: emphasized ? Ui.textPrimary : Ui.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
