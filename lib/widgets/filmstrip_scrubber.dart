import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../models/conversion_options.dart';
import '../theme/ui_tokens.dart';
import '../ui/buttons.dart';

/// Precision darkroom cover-frame scrubber.
///
/// - Micro-step buttons (`-0.1s`, `+0.1s`, `当前帧`) each carry a full 44pt
///   touch box with instant spring feedback.
/// - Finger drag updates at 0ms latency with gentle whole-second haptic ticks;
///   tap/step clicks glide smoothly via `Ui.easeOut`.
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
  bool _dragging = false;
  int _lastTickSecond = -1;

  void _scrubDx(double dx, double width, {required bool fromDrag}) {
    if (!widget.enabled || width <= 0 || widget.totalDurationMs <= 0) return;
    final ratio = (dx / width).clamp(0.0, 1.0);
    final targetMs = (ratio * widget.totalDurationMs).round();
    if (fromDrag) {
      final sec = targetMs ~/ 1000;
      if (sec != _lastTickSecond) {
        _lastTickSecond = sec;
        HapticFeedback.selectionClick();
      }
    }
    widget.onScrubToMs(targetMs);
  }

  @override
  Widget build(BuildContext context) {
    final safeTotal = widget.totalDurationMs > 0 ? widget.totalDurationMs : 1;
    final ratio = (widget.coverTimeMs / safeTotal).clamp(0.0, 1.0);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Header row: Cover timestamp + 44pt micro-step pills
        Row(
          children: <Widget>[
            Text(
              '封面',
              style: Ui.caption.copyWith(color: Ui.textSecondary),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                formatPreciseDuration(
                  Duration(milliseconds: widget.coverTimeMs),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ui.mono.copyWith(fontSize: 13.5),
              ),
            ),
            PillAction(
              label: '-0.1s',
              semanticLabel: '封面时间后退 0.1 秒',
              enabled: widget.enabled,
              onTap: () => widget.onScrubToMs(widget.coverTimeMs - 100),
            ),
            const SizedBox(width: 4),
            PillAction(
              label: '+0.1s',
              semanticLabel: '封面时间前进 0.1 秒',
              enabled: widget.enabled,
              onTap: () => widget.onScrubToMs(widget.coverTimeMs + 100),
            ),
            const SizedBox(width: 4),
            PillAction(
              label: '当前帧',
              semanticLabel: '将当前播放画面设为封面',
              icon: LucideIcons.crosshair,
              emphasized: true,
              enabled: widget.enabled,
              onTap: widget.onUseCurrentFrame,
            ),
          ],
        ),
        const SizedBox(height: 4),

        // Interactive 8-frame filmstrip track
        Semantics(
          slider: true,
          label: '拖动胶片轨道选择实况封面帧',
          value: formatPreciseDuration(
            Duration(milliseconds: widget.coverTimeMs),
          ),
          child: SizedBox(
            height: 52,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final trackWidth = constraints.maxWidth;
                const loupeWidth = 22.0;
                final travel =
                    (trackWidth - loupeWidth).clamp(0.0, double.infinity);
                final loupeLeft = ratio * travel;
                final loupeDur = (_dragging || reduceMotion)
                    ? Duration.zero
                    : const Duration(milliseconds: 170);

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (TapDownDetails d) {
                    if (!widget.enabled) return;
                    HapticFeedback.selectionClick();
                    _scrubDx(d.localPosition.dx, trackWidth, fromDrag: false);
                  },
                  onHorizontalDragStart: (DragStartDetails d) {
                    if (!widget.enabled) return;
                    HapticFeedback.lightImpact();
                    _lastTickSecond = widget.coverTimeMs ~/ 1000;
                    setState(() => _dragging = true);
                    _scrubDx(d.localPosition.dx, trackWidth, fromDrag: true);
                  },
                  onHorizontalDragUpdate: (DragUpdateDetails d) =>
                      _scrubDx(d.localPosition.dx, trackWidth, fromDrag: true),
                  onHorizontalDragEnd: (_) {
                    if (mounted) setState(() => _dragging = false);
                  },
                  onHorizontalDragCancel: () {
                    if (mounted) setState(() => _dragging = false);
                  },
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      // Frame strip
                      Positioned.fill(
                        top: 4,
                        bottom: 4,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Ui.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Ui.hairline),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: AnimatedSwitcher(
                            duration: Ui.motion(context, Ui.base),
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

                      // Crisp monochrome viewfinder playhead
                      AnimatedPositioned(
                        duration: loupeDur,
                        curve: Ui.easeOut,
                        left: loupeLeft,
                        top: 0,
                        bottom: 0,
                        width: loupeWidth,
                        child: IgnorePointer(
                          child: AnimatedScale(
                            duration: const Duration(milliseconds: 110),
                            scale: (_dragging && !reduceMotion) ? 1.07 : 1.0,
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0x1FFFFFFF),
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: Ui.accent,
                                  width: 2.0,
                                ),
                              ),
                              child: Center(
                                child: Container(
                                  width: 2,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    color: Ui.accent,
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
    );
  }

  Widget _buildPlaceholderStrip() {
    return Row(
      key: const ValueKey<String>('placeholder_strip'),
      children: List<Widget>.generate(
        8,
        (int idx) => Expanded(
          child: ColoredBox(
            color: idx.isEven ? Ui.surface : Ui.surfaceRaised,
          ),
        ),
      ),
    );
  }
}
