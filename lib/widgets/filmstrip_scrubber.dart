import 'dart:typed_data';

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../models/conversion_options.dart';

class FilmstripScrubber extends StatelessWidget {
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

  void _handleLocalDx(double dx, double width) {
    if (!enabled || width <= 0 || totalDurationMs <= 0) return;
    final ratio = (dx / width).clamp(0.0, 1.0);
    onScrubToMs((ratio * totalDurationMs).round());
  }

  @override
  Widget build(BuildContext context) {
    final safeTotal = totalDurationMs > 0 ? totalDurationMs : 1;
    final ratio = (coverTimeMs / safeTotal).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Header row: Cover timestamp + fine-step micro pills
        Row(
          children: <Widget>[
            const Icon(
              LucideIcons.frame,
              size: 14,
              color: Color(0xFFF59E0B),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '封面 ${formatPreciseDuration(Duration(milliseconds: coverTimeMs))}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFF1F5F9),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _MicroStepPill(
              label: '-0.1s',
              enabled: enabled,
              onTap: () => onScrubToMs(coverTimeMs - 100),
            ),
            const SizedBox(width: 5),
            _MicroStepPill(
              label: '+0.1s',
              enabled: enabled,
              onTap: () => onScrubToMs(coverTimeMs + 100),
            ),
            const SizedBox(width: 5),
            _MicroStepPill(
              label: '当前帧',
              icon: LucideIcons.crosshair,
              highlight: true,
              enabled: enabled,
              onTap: onUseCurrentFrame,
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Interactive filmstrip track with glowing iOS-style cover loupe
        Semantics(
          slider: true,
          label: '拖动胶片轨道选择实况封面帧',
          value: formatPreciseDuration(Duration(milliseconds: coverTimeMs)),
          child: SizedBox(
            height: 54,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final trackWidth = constraints.maxWidth;
                const loupeWidth = 22.0;
                final usableTravel =
                    (trackWidth - loupeWidth).clamp(0.0, double.infinity);
                final loupeLeft = ratio * usableTravel;

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (TapDownDetails d) =>
                      _handleLocalDx(d.localPosition.dx, trackWidth),
                  onHorizontalDragUpdate: (DragUpdateDetails d) =>
                      _handleLocalDx(d.localPosition.dx, trackWidth),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      // Filmstrip frame tiles
                      Positioned.fill(
                        top: 3,
                        bottom: 3,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF131926),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(0x29FFFFFF),
                              width: 1,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: thumbnails.isEmpty
                              ? _buildPlaceholderStrip()
                              : Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: <Widget>[
                                    for (final bytes in thumbnails)
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

                      // Active iOS Photos-style cover viewfinder loupe
                      Positioned(
                        left: loupeLeft,
                        top: 0,
                        bottom: 0,
                        width: loupeWidth,
                        child: IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0x28FFFFFF),
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(
                                color: const Color(0xFFF8FAFC),
                                width: 2.2,
                              ),
                              boxShadow: const <BoxShadow>[
                                BoxShadow(
                                  color: Color(0x88000000),
                                  blurRadius: 8,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Container(
                                width: 2,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF59E0B),
                                  borderRadius: BorderRadius.circular(1),
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
    );
  }

  Widget _buildPlaceholderStrip() {
    return Row(
      children: List<Widget>.generate(
        8,
        (int idx) => Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 0.5),
            color: idx.isEven
                ? const Color(0xFF182030)
                : const Color(0xFF131A27),
            child: const Center(
              child: Icon(
                LucideIcons.film,
                size: 14,
                color: Color(0x3894A3B8),
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
    required this.enabled,
    required this.onTap,
    this.icon,
    this.highlight = false,
  });

  final String label;
  final IconData? icon;
  final bool highlight;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: highlight
                ? const Color(0x2838BDF8)
                : const Color(0x18FFFFFF),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: highlight
                  ? const Color(0x5538BDF8)
                  : const Color(0x22FFFFFF),
              width: 0.8,
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
                      ? const Color(0xFF7DD3FC)
                      : const Color(0xFFCBD5E1),
                ),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: highlight
                      ? const Color(0xFF7DD3FC)
                      : const Color(0xFFCBD5E1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
