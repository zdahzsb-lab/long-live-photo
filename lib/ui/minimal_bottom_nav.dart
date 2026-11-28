import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/ui_tokens.dart';
import 'pressable.dart';

enum StudioTab { home, tools, settings }

/// Minimal monochrome bottom navigation bar for the 3-tab outer shell.
///
/// Automatically hidden when entering the full-screen darkroom editor so the
/// video viewport and scrubber keep full vertical breathing room.
class MinimalBottomNav extends StatelessWidget {
  const MinimalBottomNav({
    super.key,
    required this.currentTab,
    required this.onChanged,
    this.enabled = true,
  });

  final StudioTab currentTab;
  final ValueChanged<StudioTab> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final fastDur = Ui.motion(context, Ui.fast);

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Ui.bg,
        border: Border(
          top: BorderSide(color: Ui.hairline),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1.0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Row(
              children: <Widget>[
                _NavItem(
                  key: const Key('nav_tab_home'),
                  icon: LucideIcons.aperture,
                  label: '首页',
                  selected: currentTab == StudioTab.home,
                  enabled: enabled,
                  duration: fastDur,
                  onTap: () => onChanged(StudioTab.home),
                ),
                _NavItem(
                  key: const Key('nav_tab_tools'),
                  icon: LucideIcons.layers,
                  label: '工具',
                  selected: currentTab == StudioTab.tools,
                  enabled: enabled,
                  duration: fastDur,
                  onTap: () => onChanged(StudioTab.tools),
                ),
                _NavItem(
                  key: const Key('nav_tab_settings'),
                  icon: LucideIcons.slidersHorizontal,
                  label: '设置',
                  selected: currentTab == StudioTab.settings,
                  enabled: enabled,
                  duration: fastDur,
                  onTap: () => onChanged(StudioTab.settings),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.duration,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final Duration duration;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Ui.textPrimary : Ui.textTertiary;

    return Expanded(
      child: Pressable(
        enabled: enabled,
        selected: selected,
        expandWidth: true,
        haptic: Haptic.selection,
        maxInsetPx: 3.0,
        pressedOpacity: 0.82,
        minSize: const Size(0, 56),
        semanticLabel: label,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AnimatedContainer(
                duration: duration,
                curve: Ui.easeOut,
                width: selected ? 18 : 6,
                height: 2,
                decoration: BoxDecoration(
                  color: selected ? Ui.accent : const Color(0x00000000),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              const SizedBox(height: 5),
              Icon(icon, size: 19, color: color),
              const SizedBox(height: 3),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: AnimatedDefaultTextStyle(
                  duration: duration,
                  curve: Ui.easeOut,
                  style: DefaultTextStyle.of(context).style.merge(
                        Ui.callout.copyWith(
                          fontSize: 11,
                          height: 1.25,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w500,
                          color: color,
                        ),
                      ),
                  child: Text(label, maxLines: 1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
