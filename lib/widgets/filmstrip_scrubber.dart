import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../models/conversion_options.dart';
import '../theme/ui_tokens.dart';
import '../ui/buttons.dart';

/// Precision darkroom cover-frame & trim-range scrubber.
///
/// - Header carries cover timestamp (or external cover label) + 44pt step pills.
/// - Track supports dragging left/right trim brackets (`Key('trim_start_handle')`,
///   `Key('trim_end_handle')`) plus inner cover scrubbing within `[trimStart, trimEnd]`.
/// - When trimmed, a slim status bar cleanly slides open below the track with
///   exact range duration and a `重置` action (`Key('reset_trim_button')`).
class FilmstripScrubber extends StatefulWidget {
  const FilmstripScrubber({
    super.key,
    required this.thumbnails,
    required this.coverTimeMs,
    required this.totalDurationMs,
    required this.enabled,
    required this.onScrubToMs,
    required this.onUseCurrentFrame,
    this.trimStartMs = 0,
    this.trimEndMs,
    this.hasCustomCover = false,
    this.onTrimChanged,
    this.onResetTrim,
  });

  final List<Uint8List> thumbnails;
  final int coverTimeMs;
  final int totalDurationMs;
  final bool enabled;
  final ValueChanged<int> onScrubToMs;
  final VoidCallback onUseCurrentFrame;
  final int trimStartMs;
  final int? trimEndMs;
  final bool hasCustomCover;
  final void Function(int startMs, int endMs)? onTrimChanged;
  final VoidCallback? onResetTrim;

  @override
  State<FilmstripScrubber> createState() => _FilmstripScrubberState();
}

class _FilmstripScrubberState extends State<FilmstripScrubber> {
  static const double _handleWidth = 12.0;
  static const double _handleHitWidth = 36.0;

  bool _draggingCover = false;
  bool _draggingTrim = false;
  int _lastTickSecond = -1;

  int _dragOriginMs = 0;
  double _dragAccumDx = 0.0;

  void _scrubCoverDx(
    double dx,
    double usableWidth, {
    required int startMs,
    required int endMs,
    required bool fromDrag,
  }) {
    if (!widget.enabled ||
        widget.hasCustomCover ||
        usableWidth <= 0 ||
        widget.totalDurationMs <= 0) {
      return;
    }
    final localX = (dx - _handleWidth).clamp(0.0, usableWidth);
    final ratio = (localX / usableWidth).clamp(0.0, 1.0);
    final rawMs = (ratio * widget.totalDurationMs).round();
    final targetMs = VideoTrimMath.clampCoverToTrim(
      coverMs: rawMs,
      startMs: startMs,
      endMs: endMs,
    );
    if (fromDrag) {
      final sec = targetMs ~/ 1000;
      if (sec != _lastTickSecond) {
        _lastTickSecond = sec;
        HapticFeedback.selectionClick();
      }
    }
    widget.onScrubToMs(targetMs);
  }

  void _updateTrimByDelta({
    required bool isStart,
    required double deltaDx,
    required double usableWidth,
    required int currentStartMs,
    required int currentEndMs,
  }) {
    if (!widget.enabled ||
        widget.onTrimChanged == null ||
        usableWidth <= 0 ||
        widget.totalDurationMs <= 0) {
      return;
    }
    _dragAccumDx += deltaDx;
    final deltaMs = (_dragAccumDx / usableWidth * widget.totalDurationMs).round();
    final candidateStart = isStart ? (_dragOriginMs + deltaMs) : currentStartMs;
    final candidateEnd = isStart ? currentEndMs : (_dragOriginMs + deltaMs);

    final clamped = VideoTrimMath.clampTrimRange(
      startMs: isStart
          ? candidateStart.clamp(0, currentEndMs - VideoTrimMath.minClipMs)
          : currentStartMs,
      endMs: isStart
          ? currentEndMs
          : candidateEnd.clamp(
              currentStartMs + VideoTrimMath.minClipMs,
              widget.totalDurationMs,
            ),
      totalMs: widget.totalDurationMs,
    );
    if (clamped.startMs != currentStartMs || clamped.endMs != currentEndMs) {
      final sec = (isStart ? clamped.startMs : clamped.endMs) ~/ 1000;
      if (sec != _lastTickSecond) {
        _lastTickSecond = sec;
        HapticFeedback.selectionClick();
      }
      widget.onTrimChanged!(clamped.startMs, clamped.endMs);
    }
  }

  @override
  Widget build(BuildContext context) {
    final safeTotal = widget.totalDurationMs > 0 ? widget.totalDurationMs : 1;
    final effectiveRange = VideoTrimMath.clampTrimRange(
      startMs: widget.trimStartMs,
      endMs: widget.trimEndMs ?? safeTotal,
      totalMs: safeTotal,
    );
    final startMs = effectiveRange.startMs;
    final endMs = effectiveRange.endMs;
    final isTrimmed = VideoTrimMath.isEffectivelyTrimmed(
      startMs: startMs,
      endMs: endMs,
      totalMs: widget.totalDurationMs,
    );

    final clampedCover = VideoTrimMath.clampCoverToTrim(
      coverMs: widget.coverTimeMs,
      startMs: startMs,
      endMs: endMs,
    );

    final startRatio = (startMs / safeTotal).clamp(0.0, 1.0);
    final endRatio = (endMs / safeTotal).clamp(startRatio, 1.0);
    final coverRatio = (clampedCover / safeTotal).clamp(startRatio, endRatio);

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final scaledPx = MediaQuery.textScalerOf(context).scale(14.0);
    final coverControlsEnabled = widget.enabled && !widget.hasCustomCover;

    final coverSummary = widget.hasCustomCover
        ? Text(
            '已用自选图片作封面',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Ui.caption.copyWith(color: Ui.textSecondary),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: Text(
                  '封面',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ui.caption.copyWith(color: Ui.textSecondary),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  formatPreciseDuration(Duration(milliseconds: clampedCover)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ui.mono.copyWith(fontSize: 13),
                ),
              ),
            ],
          );

    final stepButtons = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        PillAction(
          label: '-0.1s',
          semanticLabel: '封面时间后退 0.1 秒',
          enabled: coverControlsEnabled,
          onTap: () => widget.onScrubToMs(clampedCover - 100),
        ),
        const SizedBox(width: 4),
        PillAction(
          label: '+0.1s',
          semanticLabel: '封面时间前进 0.1 秒',
          enabled: coverControlsEnabled,
          onTap: () => widget.onScrubToMs(clampedCover + 100),
        ),
        const SizedBox(width: 4),
        PillAction(
          label: '当前帧',
          semanticLabel: '将当前播放画面设为封面',
          icon: LucideIcons.crosshair,
          emphasized: true,
          enabled: coverControlsEnabled,
          onTap: widget.onUseCurrentFrame,
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Header row: adapts cleanly on 375px + large Dynamic Type
        if (scaledPx > 15.5)
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 4,
            children: <Widget>[
              coverSummary,
              stepButtons,
            ],
          )
        else
          Row(
            children: <Widget>[
              Expanded(child: coverSummary),
              const SizedBox(width: 6),
              stepButtons,
            ],
          ),
        const SizedBox(height: 4),

        // Interactive 8-frame filmstrip track with trim brackets + cover loupe
        Semantics(
          slider: true,
          label: '拖动胶片轨道选择实况封面帧或首尾裁剪范围',
          value: formatPreciseDuration(Duration(milliseconds: clampedCover)),
          child: SizedBox(
            height: 54,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final trackWidth = constraints.maxWidth;
                final usableWidth =
                    (trackWidth - _handleWidth * 2).clamp(1.0, double.infinity);

                final startLeft = startRatio * usableWidth;
                final trimContentLeft = startLeft + _handleWidth;
                final trimContentRight = _handleWidth + endRatio * usableWidth;
                final rightCurtainLeft = trimContentRight + _handleWidth;

                const loupeWidth = 20.0;
                final loupeMin = trimContentLeft;
                final loupeMax =
                    (trimContentRight - loupeWidth).clamp(loupeMin, trackWidth);
                final rawLoupeCenter = _handleWidth + coverRatio * usableWidth;
                final loupeLeft =
                    (rawLoupeCenter - loupeWidth / 2).clamp(loupeMin, loupeMax);

                final loupeDur =
                    (_draggingCover || _draggingTrim || reduceMotion)
                        ? Duration.zero
                        : const Duration(milliseconds: 170);

                return Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    // 1. Filmstrip background & inner cover scrubber
                    Positioned.fill(
                      child: GestureDetector(
                        key: const Key('filmstrip_track_gesture'),
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (TapDownDetails d) {
                          if (!coverControlsEnabled) return;
                          HapticFeedback.selectionClick();
                          _scrubCoverDx(
                            d.localPosition.dx,
                            usableWidth,
                            startMs: startMs,
                            endMs: endMs,
                            fromDrag: false,
                          );
                        },
                        onHorizontalDragStart: (DragStartDetails d) {
                          if (!coverControlsEnabled) return;
                          HapticFeedback.lightImpact();
                          _lastTickSecond = clampedCover ~/ 1000;
                          setState(() => _draggingCover = true);
                          _scrubCoverDx(
                            d.localPosition.dx,
                            usableWidth,
                            startMs: startMs,
                            endMs: endMs,
                            fromDrag: true,
                          );
                        },
                        onHorizontalDragUpdate: (DragUpdateDetails d) =>
                            _scrubCoverDx(
                          d.localPosition.dx,
                          usableWidth,
                          startMs: startMs,
                          endMs: endMs,
                          fromDrag: true,
                        ),
                        onHorizontalDragEnd: (_) {
                          if (mounted) setState(() => _draggingCover = false);
                        },
                        onHorizontalDragCancel: () {
                          if (mounted) setState(() => _draggingCover = false);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: _handleWidth,
                            vertical: 4,
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Ui.surface,
                              borderRadius: BorderRadius.circular(8),
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
                      ),
                    ),

                    // 2. Left & Right trimmed-out curtains
                    if (startLeft > 0.5)
                      Positioned(
                        left: _handleWidth,
                        top: 4,
                        bottom: 4,
                        width: startLeft.clamp(0.0, usableWidth),
                        child: const IgnorePointer(
                          child: ColoredBox(color: Color(0xBA09090B)),
                        ),
                      ),
                    if (trackWidth - _handleWidth - trimContentRight > 0.5)
                      Positioned(
                        left: trimContentRight,
                        right: _handleWidth,
                        top: 4,
                        bottom: 4,
                        child: const IgnorePointer(
                          child: ColoredBox(color: Color(0xBA09090B)),
                        ),
                      ),

                    // 3. Top & Bottom active trim frame rails
                    Positioned(
                      left: trimContentLeft,
                      width: (trimContentRight - trimContentLeft)
                          .clamp(0.0, trackWidth),
                      top: 4,
                      height: 1.5,
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: isTrimmed ? Ui.accent : Ui.hairlineStrong,
                        ),
                      ),
                    ),
                    Positioned(
                      left: trimContentLeft,
                      width: (trimContentRight - trimContentLeft)
                          .clamp(0.0, trackWidth),
                      bottom: 4,
                      height: 1.5,
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: isTrimmed ? Ui.accent : Ui.hairlineStrong,
                        ),
                      ),
                    ),

                    // 4. Active Cover Frame Loupe (hidden when custom static photo overrides)
                    if (!widget.hasCustomCover)
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
                            scale: (_draggingCover && !reduceMotion)
                                ? 1.07
                                : 1.0,
                            child: Container(
                              key: const Key('filmstrip_cover_loupe'),
                              decoration: BoxDecoration(
                                color: const Color(0x1FFFFFFF),
                                borderRadius: BorderRadius.circular(6),
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

                    // 5. Left Trim Handle (placed above track so drag never conflicts)
                    if (widget.onTrimChanged != null)
                      Positioned(
                        left: (startLeft + _handleWidth / 2 - _handleHitWidth / 2)
                            .clamp(0.0, trackWidth - _handleHitWidth),
                        top: 0,
                        bottom: 0,
                        width: _handleHitWidth,
                        child: Semantics(
                          label: '拖动设置视频起点',
                          value: formatPreciseDuration(
                            Duration(milliseconds: startMs),
                          ),
                          child: GestureDetector(
                            key: const Key('trim_start_handle'),
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragStart: (_) {
                              if (!widget.enabled) return;
                              HapticFeedback.lightImpact();
                              _dragOriginMs = startMs;
                              _dragAccumDx = 0.0;
                              _lastTickSecond = startMs ~/ 1000;
                              setState(() => _draggingTrim = true);
                            },
                            onHorizontalDragUpdate: (DragUpdateDetails d) =>
                                _updateTrimByDelta(
                              isStart: true,
                              deltaDx: d.delta.dx,
                              usableWidth: usableWidth,
                              currentStartMs: startMs,
                              currentEndMs: endMs,
                            ),
                            onHorizontalDragEnd: (_) {
                              if (mounted) setState(() => _draggingTrim = false);
                            },
                            onHorizontalDragCancel: () {
                              if (mounted) setState(() => _draggingTrim = false);
                            },
                            child: Center(
                              child: _TrimHandleBracket(
                                isStart: true,
                                highlighted: isTrimmed || _draggingTrim,
                              ),
                            ),
                          ),
                        ),
                      ),

                    // 6. Right Trim Handle
                    if (widget.onTrimChanged != null)
                      Positioned(
                        left: (rightCurtainLeft -
                                _handleWidth / 2 -
                                _handleHitWidth / 2)
                            .clamp(0.0, trackWidth - _handleHitWidth),
                        top: 0,
                        bottom: 0,
                        width: _handleHitWidth,
                        child: Semantics(
                          label: '拖动设置视频终点',
                          value: formatPreciseDuration(
                            Duration(milliseconds: endMs),
                          ),
                          child: GestureDetector(
                            key: const Key('trim_end_handle'),
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragStart: (_) {
                              if (!widget.enabled) return;
                              HapticFeedback.lightImpact();
                              _dragOriginMs = endMs;
                              _dragAccumDx = 0.0;
                              _lastTickSecond = endMs ~/ 1000;
                              setState(() => _draggingTrim = true);
                            },
                            onHorizontalDragUpdate: (DragUpdateDetails d) =>
                                _updateTrimByDelta(
                              isStart: false,
                              deltaDx: d.delta.dx,
                              usableWidth: usableWidth,
                              currentStartMs: startMs,
                              currentEndMs: endMs,
                            ),
                            onHorizontalDragEnd: (_) {
                              if (mounted) setState(() => _draggingTrim = false);
                            },
                            onHorizontalDragCancel: () {
                              if (mounted) setState(() => _draggingTrim = false);
                            },
                            child: Center(
                              child: _TrimHandleBracket(
                                isStart: false,
                                highlighted: isTrimmed || _draggingTrim,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),

        // Slim animated trim summary + Reset action (only visible when trimmed)
        AnimatedSize(
          duration: Ui.motion(context, Ui.fast),
          curve: Ui.easeOut,
          child: isTrimmed
              ? Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '截取 ${formatPreciseDuration(Duration(milliseconds: startMs))} – ${formatPreciseDuration(Duration(milliseconds: endMs))} · ${((endMs - startMs) / 1000).toStringAsFixed(1)}s',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Ui.mono.copyWith(
                            fontSize: 11.5,
                            color: Ui.textSecondary,
                          ),
                        ),
                      ),
                      if (widget.onResetTrim != null)
                        PillAction(
                          key: const Key('reset_trim_button'),
                          label: '重置',
                          semanticLabel: '恢复整段完整时长',
                          enabled: widget.enabled,
                          onTap: widget.onResetTrim,
                        ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
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

class _TrimHandleBracket extends StatelessWidget {
  const _TrimHandleBracket({
    required this.isStart,
    required this.highlighted,
  });

  final bool isStart;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 46,
      decoration: BoxDecoration(
        color: highlighted ? Ui.accent : Ui.surfaceThumb,
        borderRadius: BorderRadius.horizontal(
          left: isStart ? const Radius.circular(6) : Radius.zero,
          right: isStart ? Radius.zero : const Radius.circular(6),
        ),
        border: Border.all(
          color: highlighted ? Ui.accent : Ui.hairlineStrong,
          width: 0.8,
        ),
      ),
      child: Center(
        child: Container(
          width: 2,
          height: 16,
          decoration: BoxDecoration(
            color: highlighted ? Ui.onAccent : Ui.textSecondary,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ),
    );
  }
}
