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
    this.height = Ui.minTarget,
    this.fontSize = 13.0,
    this.monospace = false,
  });

  final List<T> items;
  final int selectedIndex;
  final String Function(T item) labelBuilder;
  final ValueChanged<int> onChanged;
  final bool enabled;
  final double height;
  final double fontSize;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final count = items.length;
    if (count == 0) return const SizedBox.shrink();

    final safeIndex = selectedIndex.clamp(0, count - 1);
    final alignX = count == 1 ? 0.0 : -1.0 + (2.0 * safeIndex / (count - 1));
    final animDuration = Ui.motion(context, Ui.base);
    final hitHeight = height < Ui.minTarget ? Ui.minTarget : height;

    return SizedBox(
      height: hitHeight,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Container(
            height: height,
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
              ],
            ),
          ),

          // Interactive segment labels (always >=44pt touch height)
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Row(
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
                      minSize: Size(0, hitHeight),
                      onTap: () {
                        if (idx != safeIndex) {
                          onChanged(idx);
                        }
                      },
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: AnimatedDefaultTextStyle(
                              duration: Ui.motion(context, Ui.fast),
                              curve: Ui.easeOut,
                              style: DefaultTextStyle.of(context).style.merge(
                                    Ui.callout.copyWith(
                                      fontSize: fontSize,
                                      fontWeight: isSelected
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      fontFeatures: monospace ? Ui.tabular : null,
                                      color: isSelected
                                          ? Ui.textPrimary
                                          : Ui.textSecondary,
                                    ),
                                  ),
                              child: Text(
                                label,
                                maxLines: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
