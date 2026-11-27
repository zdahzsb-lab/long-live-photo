import 'dart:io';

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../models/conversion_options.dart';
import '../theme/ui_tokens.dart';
import '../ui/pressable.dart';

/// Pure matte darkroom video viewport.
///
/// Features:
/// - Single-tap play/pause + hold-to-preview-Live gesture (`onLiveHoldStart`/`End`)
/// - Optional custom static cover image overlay with smooth crossfade
/// - Dedicated top-left audio switch (`>=112×48dp`) and bottom-right custom cover
///   switch (`>=104×48dp`), both placed last in Stack so taps never leak.
class VideoStageCard extends StatelessWidget {
  const VideoStageCard({
    super.key,
    required this.controller,
    required this.currentPosition,
    required this.totalDuration,
    required this.sourceSizeBytes,
    required this.keepAudio,
    required this.isConverting,
    required this.onTogglePlay,
    required this.onToggleAudio,
    this.customCoverPath,
    this.trimStartMs = 0,
    this.trimEndMs,
    this.isLivePreviewing = false,
    this.onPickCustomCover,
    this.onLiveHoldStart,
    this.onLiveHoldEnd,
  });

  final VideoPlayerController controller;
  final Duration currentPosition;
  final Duration totalDuration;
  final int sourceSizeBytes;
  final bool keepAudio;
  final bool isConverting;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleAudio;
  final String? customCoverPath;
  final int trimStartMs;
  final int? trimEndMs;
  final bool isLivePreviewing;
  final VoidCallback? onPickCustomCover;
  final VoidCallback? onLiveHoldStart;
  final VoidCallback? onLiveHoldEnd;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.size;
    final aspect = controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 9 / 16;
    final isPlaying = controller.value.isPlaying;
    final totalMs = totalDuration.inMilliseconds;
    final effectiveStartMs = trimStartMs.clamp(0, totalMs > 0 ? totalMs : 0);
    final effectiveEndMs =
        (trimEndMs ?? totalMs).clamp(effectiveStartMs, totalMs > 0 ? totalMs : 0);
    final spanMs = effectiveEndMs - effectiveStartMs;
    final isTrimmed = VideoTrimMath.isEffectivelyTrimmed(
      startMs: effectiveStartMs,
      endMs: effectiveEndMs,
      totalMs: totalMs,
    );

    final int displayCurrentMs;
    final int displayTotalMs;
    if (isTrimmed && spanMs > 0) {
      displayCurrentMs =
          (currentPosition.inMilliseconds - effectiveStartMs).clamp(0, spanMs);
      displayTotalMs = spanMs;
    } else {
      displayCurrentMs =
          currentPosition.inMilliseconds.clamp(0, totalMs > 0 ? totalMs : 0);
      displayTotalMs = totalMs;
    }

    final playRatio = displayTotalMs > 0
        ? (displayCurrentMs / displayTotalMs).clamp(0.0, 1.0)
        : 0.0;
    final fastDur = Ui.motion(context, Ui.fast);
    final hasCustomCover =
        customCoverPath != null && customCoverPath!.isNotEmpty;
    final showCustomCoverOverlay =
        hasCustomCover && !isPlaying && !isLivePreviewing;

    return Container(
      decoration: BoxDecoration(
        color: Ui.stage,
        borderRadius: BorderRadius.circular(Ui.rXl),
        border: Border.all(color: Ui.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 1. Video viewport (tap to play/pause, long-press to simulate Live playback)
          Semantics(
            button: true,
            label: isPlaying ? '暂停视频预览' : '播放视频预览，长按可预览实况效果',
            child: GestureDetector(
              key: const Key('video_viewport_tap'),
              behavior: HitTestBehavior.opaque,
              onTap: isConverting ? null : onTogglePlay,
              onLongPressStart: isConverting || onLiveHoldStart == null
                  ? null
                  : (_) => onLiveHoldStart!(),
              onLongPressEnd: isConverting || onLiveHoldEnd == null
                  ? null
                  : (_) => onLiveHoldEnd!(),
              onLongPressCancel: isConverting ? null : onLiveHoldEnd,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Center(
                    child: AspectRatio(
                      aspectRatio: aspect,
                      child: VideoPlayer(controller),
                    ),
                  ),
                  if (hasCustomCover)
                    AnimatedOpacity(
                      duration: fastDur,
                      curve: Ui.easeOut,
                      opacity: showCustomCoverOverlay ? 1.0 : 0.0,
                      child: Image.file(
                        File(customCoverPath!),
                        key: const Key('custom_cover_overlay_image'),
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // 2. Top-Right Resolution & Size Readout
          Positioned(
            top: Ui.s3,
            right: Ui.s3,
            child: IgnorePointer(
              child: Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Ui.hudScrim,
                  borderRadius: BorderRadius.circular(Ui.rSm),
                  border: Border.all(color: Ui.hairline),
                ),
                child: Text(
                  '${size.width.toInt()}×${size.height.toInt()} · ${formatFileSize(sourceSizeBytes)}',
                  style: Ui.mono.copyWith(
                    fontSize: 11.5,
                    color: Ui.textSecondary,
                  ),
                ),
              ),
            ),
          ),

          // 3. Center Minimalist Play Indicator (non-blocking so tap & hold work anywhere on stage)
          Center(
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: fastDur,
                curve: Ui.easeOut,
                opacity: (!isPlaying && !isConverting && !isLivePreviewing)
                    ? 1.0
                    : 0.0,
                child: AnimatedScale(
                  duration: fastDur,
                  curve: Ui.easeOut,
                  scale: (!isPlaying && !isConverting && !isLivePreviewing)
                      ? 1.0
                      : 0.88,
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Ui.hudScrim,
                      shape: BoxShape.circle,
                      border: Border.all(color: Ui.hairlineStrong),
                    ),
                    child: const Icon(
                      LucideIcons.play,
                      size: 21,
                      color: Ui.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 4. Bottom-Left Tabular Timecode Readout (+ Live Hold indicator)
          Positioned(
            bottom: Ui.s3,
            left: Ui.s3,
            child: IgnorePointer(
              child: Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Ui.hudScrim,
                  borderRadius: BorderRadius.circular(Ui.rSm),
                  border: Border.all(
                    color: isLivePreviewing ? Ui.hairlineStrong : Ui.hairline,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (isLivePreviewing) ...<Widget>[
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Ui.liveActive,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '实况预览',
                        style: Ui.caption.copyWith(
                          fontSize: 11,
                          color: Ui.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      '${formatPreciseDuration(Duration(milliseconds: displayCurrentMs))} / ${formatPreciseDuration(Duration(milliseconds: displayTotalMs))}',
                      style: Ui.mono.copyWith(fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 5. Bottom 2px Live Playback Progress Line
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 2,
            child: IgnorePointer(
              child: ColoredBox(
                color: Ui.hairline,
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: playRatio,
                  child: const ColoredBox(color: Ui.accent),
                ),
              ),
            ),
          ),

          // 6. Bottom-Right Custom Cover Button (>=104×48dp opaque hit area)
          if (onPickCustomCover != null)
            Positioned(
              bottom: 2,
              right: 2,
              child: Pressable(
                key: const Key('custom_cover_button'),
                enabled: !isConverting,
                minSize: const Size(104, 48),
                alignment: Alignment.bottomRight,
                hitPadding: const EdgeInsets.fromLTRB(12, 8, 10, 10),
                haptic: Haptic.selection,
                maxInsetPx: 4.5,
                toggled: hasCustomCover,
                semanticLabel:
                    hasCustomCover ? '已更换自定义封面，点击修改或还原' : '从相册自选图片作为实况封面',
                onTap: onPickCustomCover,
                child: AnimatedContainer(
                  duration: fastDur,
                  curve: Ui.easeOut,
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Ui.hudScrim,
                    borderRadius: BorderRadius.circular(Ui.rSm),
                    border: Border.all(
                      color: hasCustomCover ? Ui.hairlineStrong : Ui.hairline,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (hasCustomCover) ...<Widget>[
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Ui.liveActive,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Icon(
                        hasCustomCover
                            ? LucideIcons.image
                            : LucideIcons.imagePlus,
                        size: 13.5,
                        color:
                            hasCustomCover ? Ui.textPrimary : Ui.textSecondary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        hasCustomCover ? '已换封面' : '自选封面',
                        style: Ui.callout.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color:
                              hasCustomCover ? Ui.textPrimary : Ui.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 7. Top-Left Audio Switch — Placed LAST with >=112×48dp opaque hit area
          Positioned(
            top: 2,
            left: 2,
            child: Pressable(
              key: const Key('audio_toggle_button'),
              enabled: !isConverting,
              minSize: const Size(112, 48),
              alignment: Alignment.topLeft,
              hitPadding: const EdgeInsets.fromLTRB(10, 10, 14, 8),
              haptic: Haptic.light,
              maxInsetPx: 4.5,
              toggled: keepAudio,
              semanticLabel: keepAudio ? '实况原声已开启，点击切换为静音' : '实况已静音，点击开启原声',
              onTap: onToggleAudio,
              child: AnimatedContainer(
                duration: fastDur,
                curve: Ui.easeOut,
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                decoration: BoxDecoration(
                  color: Ui.hudScrim,
                  borderRadius: BorderRadius.circular(Ui.rSm),
                  border: Border.all(
                    color: keepAudio ? Ui.hairlineStrong : Ui.hairline,
                  ),
                ),
                child: AnimatedSwitcher(
                  duration: fastDur,
                  switchInCurve: Ui.easeOut,
                  switchOutCurve: Ui.easeIn,
                  child: Row(
                    key: ValueKey<bool>(keepAudio),
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: keepAudio ? Ui.liveActive : Ui.textTertiary,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        keepAudio ? LucideIcons.volume2 : LucideIcons.volumeX,
                        size: 13.5,
                        color: keepAudio ? Ui.textPrimary : Ui.textSecondary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        keepAudio ? '实况有声' : '已静音',
                        style: Ui.callout.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: keepAudio ? Ui.textPrimary : Ui.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
