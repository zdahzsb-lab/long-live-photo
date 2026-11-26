import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../models/conversion_options.dart';
import '../theme/studio_tokens.dart';
import 'tactile_pressable.dart';

class FilmstripScrubber extends StatefulWidget {
  const FilmstripScrubber({
    super.key,
    required this.thumbnails,
    required this.coverTimeMs,
    required this.totalDurationMs,
    required this.enabled,
    required this.onScrubToMs,
    required this.onUseCurrentFrame,
  });

  final List<Uint8List> thumbnails;
  final int coverTimeMs;
  final int totalDurationMs;
  final bool enabled;
  final ValueChanged<int> onScrubToMs;
  final VoidCallback onUseCurrentFrame;

  @override
  State<FilmstripScrubber> createState() => _FilmstripScrubberState();
}

class _FilmstripScrubberState extends State<FilmstripScrubber> {
  bool _isDragging = false;

  void _handleLocalDx(double dx, double width) {
    if (!widget.enabled || width <= 0 || widget.totalDurationMs <= 0) return;
    final ratio = (dx / width).clamp(0.0, 1.0);
    widget.onScrubToMs((ratio * widget.totalDurationMs).round());
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final safeTotal = widget.totalDurationMs > 0 ? widget.totalDurationMs : 1;
    final ratio = (widget.coverTimeMs / safeTotal).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 12),
      decoration: BoxDecoration(
        color: StudioTokens.surfaceConsole,
        borderRadius: BorderRadius.circular(StudioTokens.radiusControl + 4),
        border: Border.all(color: StudioTokens.borderSubtle, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Header row: Cover timestamp + 44dp-tall micro-step touch targets
          Row(
            children: <Widget>[
              const ExcludeSemantics(
                child: Icon(
                  LucideIcons.scan,
                  size: 15,
                  color: StudioTokens.accentCyan,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '封面 ${formatPreciseDuration(Duration(milliseconds: widget.coverTimeMs))}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                    color: StudioTokens.textPrimary,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              _MicroStepPill(
                label: '-0.1s',
                semanticLabel: '封面时间后退 0.1 秒',
                enabled: widget.enabled,
                onTap: () => widget.onScrubToMs(widget.coverTimeMs - 100),
              ),
              const SizedBox(width: 4),
              _MicroStepPill(
                label: '+0.1s',
                semanticLabel: '封面时间前进 0.1 秒',
                enabled: widget.enabled,
                onTap: () => widget.onScrubToMs(widget.coverTimeMs + 100),
              ),
              const SizedBox(width: 4),
              _MicroStepPill(
                label: '当前帧',
                semanticLabel: '将当前播放画面设为实况封面',
                icon: LucideIcons.crosshair,
                highlight: true,
                enabled: widget.enabled,
                onTap: widget.onUseCurrentFrame,
              ),
            ],
          ),
          const SizedBox(height: 4),

          // Interactive filmstrip track with fluid cover viewfinder loupe
          Semantics(
            slider: true,
            label: '拖动胶片轨道选择实况封面帧',
            value: formatPreciseDuration(
              Duration(milliseconds: widget.coverTimeMs),
            ),
            child: SizedBox(
              height: 54,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final trackWidth = constraints.maxWidth;
                  const loupeWidth = 24.0;
                  final usableTravel =
                      (trackWidth - loupeWidth).clamp(0.0, double.infinity);
                  final loupeLeft = ratio * usableTravel;

                  final loupeAnimDuration = (_isDragging || reduceMotion)
                      ? Duration.zero
                      : const Duration(milliseconds: 180);

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (TapDownDetails d) {
                      if (!widget.enabled) return;
                      HapticFeedback.selectionClick();
                      _handleLocalDx(d.localPosition.dx, trackWidth);
                    },
                    onHorizontalDragStart: (DragStartDetails d) {
                      if (!widget.enabled) return;
                      HapticFeedback.lightImpact();
                      setState(() => _isDragging = true);
                      _handleLocalDx(d.localPosition.dx, trackWidth);
                    },
                    onHorizontalDragUpdate: (DragUpdateDetails d) =>
                        _handleLocalDx(d.localPosition.dx, trackWidth),
                    onHorizontalDragEnd: (_) {
                      if (mounted) setState(() => _isDragging = false);
                    },
                    onHorizontalDragCancel: () {
                      if (mounted) setState(() => _isDragging = false);
                    },
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        // Filmstrip frame tiles with smooth crossfade arrival
                        Positioned.fill(
                          top: 4,
                          bottom: 4,
                          child: Container(
                            decoration: BoxDecoration(
                              color: StudioTokens.bgElevated,
                              borderRadius: BorderRadius.circular(11),
                              border: Border.all(
                                color: StudioTokens.borderSubtle,
                                width: 1,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: AnimatedSwitcher(
                              duration: reduceMotion
                                  ? Duration.zero
                                  : StudioTokens.stateDuration,
                              child: widget.thumbnails.isEmpty
                                  ? _buildPlaceholderStrip()
                                  : Row(
                                      key: ValueKey<int>(
                                        widget.thumbnails.length,
                                      ),
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: <Widget>[
                                        for (final bytes in widget.thumbnails)
                                          Expanded(
                                            child: Image.memory(
                                              bytes,
                                              fit: BoxFit.cover,
                                              gaplessPlayback: true,
                                            ),
                                          ),
                                      ],
                                    ),
                            ),
                          ),
                        ),

                        // Gliding Viewfinder Loupe (0ms lag on drag, smooth easeOutExpo on step/tap)
                        AnimatedPositioned(
                          duration: loupeAnimDuration,
                          curve: StudioTokens.curveOutExpo,
                          left: loupeLeft,
                          top: 0,
                          bottom: 0,
                          width: loupeWidth,
                          child: IgnorePointer(
                            child: AnimatedScale(
                              duration: StudioTokens.pressDuration,
                              scale: (_isDragging && !reduceMotion)
                                  ? 1.08
                                  : 1.0,
                              child: AnimatedContainer(
                                duration: StudioTokens.pressDuration,
                                decoration: BoxDecoration(
                                  color: _isDragging
                                      ? const Color(0x3838BDF8)
                                      : const Color(0x24FFFFFF),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: _isDragging
                                        ? StudioTokens.accentIce
                                        : StudioTokens.textPrimary,
                                    width: 2.0,
                                  ),
                                  boxShadow: const <BoxShadow>[
                                    BoxShadow(
                                      color: Color(0x99000000),
                                      blurRadius: 10,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Container(
                                    width: 2,
                                    height: 20,
                                    decoration: BoxDecoration(
                                      color: StudioTokens.accentCyan,
                                      borderRadius: BorderRadius.circular(1),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholderStrip() {
    return Row(
      key: const ValueKey<String>('placeholder_strip'),
      children: List<Widget>.generate(
        8,
        (int idx) => Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 0.5),
            color: idx.isEven
                ? const Color(0xFF151E2E)
                : const Color(0xFF101726),
            child: const Center(
              child: ExcludeSemantics(
                child: Icon(
                  LucideIcons.film,
                  size: 13,
                  color: Color(0x4094A3B8),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MicroStepPill extends StatelessWidget {
  const _MicroStepPill({
    required this.label,
    required this.semanticLabel,
    required this.enabled,
    required this.onTap,
    this.icon,
    this.highlight = false,
  });

  final String label;
  final String semanticLabel;
  final IconData? icon;
  final bool highlight;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TactilePressable(
      enabled: enabled,
      minWidth: 48,
      minHeight: StudioTokens.minCompactTouchTarget,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
      pressedScale: 0.92,
      haptic: TactileHaptic.selection,
      semanticLabel: semanticLabel,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: highlight
              ? StudioTokens.accentActiveFill
              : StudioTokens.surfaceSubtle,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: highlight
                ? StudioTokens.accentActiveBorder
                : StudioTokens.borderSubtle,
            width: 0.9,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(
                icon,
                size: 12,
                color: highlight
                    ? StudioTokens.accentIce
                    : StudioTokens.textSecondary,
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: highlight
                    ? StudioTokens.accentIce
                    : StudioTokens.textSecondary,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
