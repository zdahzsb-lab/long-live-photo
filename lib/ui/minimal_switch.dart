import 'package:material_ui/material_ui.dart';

import '../theme/ui_tokens.dart';
import 'pressable.dart';

/// Restrained monochrome darkroom toggle switch with >=44pt touch target.
class MinimalSwitch extends StatelessWidget {
  const MinimalSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    this.enabled = true,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String semanticLabel;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final fastDur = Ui.motion(context, Ui.fast);

    return Pressable(
      toggled: value,
      enabled: enabled,
      haptic: Haptic.selection,
      maxInsetPx: 3.5,
      minSize: const Size(48, Ui.minTarget),
      semanticLabel: semanticLabel,
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: fastDur,
        curve: Ui.easeOut,
        width: 44,
        height: 26,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: value ? const Color(0x2B34D399) : Ui.bg,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: value ? const Color(0x8034D399) : Ui.hairlineStrong,
          ),
        ),
        child: AnimatedAlign(
          duration: fastDur,
          curve: Ui.easeOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: AnimatedContainer(
            duration: fastDur,
            curve: Ui.easeOut,
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value ? Ui.liveActive : Ui.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}
