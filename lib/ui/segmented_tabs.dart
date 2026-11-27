import 'package:material_ui/material_ui.dart';

import '../theme/ui_tokens.dart';
import 'pressable.dart';

/// Minimalist sliding segmented control (Forui / Shadcn Zinc style).
///
/// Every segment is a >=44pt tall [Pressable] target; the active indicator
/// glides smoothly across segments with zero backdrop-blur cost.
class SegmentedTabs<T> extends StatelessWidget {
  const SegmentedTabs({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.labelBuilder,
    required this.onChanged,
    this.enabled = true,
  });

  final List<T> items;
  final int selectedIndex;
  final String Function(T item) labelBuilder;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final count = items.length;
    if (count == 0) return const SizedBox.shrink();

    final safeIndex = selectedIndex.clamp(0, count - 1);
    final alignX = count == 1 ? 0.0 : -1.0 + (2.0 * safeIndex / (count - 1));
    final animDuration = Ui.motion(context, Ui.base);

    return Container(
      height: Ui.minTarget,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Ui.surface,
        borderRadius: BorderRadius.circular(Ui.rMd),
        border: Border.all(color: Ui.hairline),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // Gliding thumb indicator
          AnimatedAlign(
            duration: animDuration,
            curve: Ui.easeOut,
            alignment: Alignment(alignX, 0),
            child: FractionallySizedBox(
              widthFactor: 1 / count,
              heightFactor: 1.0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Ui.surfaceThumb,
                  borderRadius: BorderRadius.circular(Ui.rSm + 1),
                  border: Border.all(color: Ui.hairlineStrong, width: 0.8),
                ),
              ),
            ),
          ),

          // Interactive segment labels
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: List<Widget>.generate(count, (int idx) {
              final isSelected = idx == safeIndex;
              final label = labelBuilder(items[idx]);

              return Expanded(
                child: Pressable(
                  enabled: enabled,
                  selected: isSelected,
                  semanticLabel: label,
                  haptic: Haptic.selection,
                  maxInsetPx: 2.5,
                  pressedOpacity: 0.85,
                  minSize: const Size(0, Ui.minTarget - 6),
                  onTap: () {
                    if (idx != safeIndex) {
                      onChanged(idx);
                    }
                  },
                  child: Center(
                    child: AnimatedDefaultTextStyle(
                      duration: Ui.motion(context, Ui.fast),
                      curve: Ui.easeOut,
                      style: DefaultTextStyle.of(context).style.merge(
                            Ui.callout.copyWith(
                              fontSize: 13,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: isSelected
                                  ? Ui.textPrimary
                                  : Ui.textSecondary,
                            ),
                          ),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}
