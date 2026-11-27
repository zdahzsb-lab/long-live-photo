import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../models/conversion_options.dart';
import '../theme/ui_tokens.dart';
import '../ui/pressable.dart';

/// Pure matte darkroom video viewport.
///
/// Zero `BackdropFilter` shaders — runs at native 120fps on all devices.
/// The top-left audio switch sits in a dedicated `>=112×48dp` opaque [Pressable]
/// placed last in the Stack so taps respond at 0ms and never leak to play/pause.
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
  });

  final VideoPlayerController controller;
  final Duration currentPosition;
  final Duration totalDuration;
  final int sourceSizeBytes;
  final bool keepAudio;
  final bool isConverting;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleAudio;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.size;
    final aspect = controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 9 / 16;
    final isPlaying = controller.value.isPlaying;
    final totalMs = totalDuration.inMilliseconds;
    final playRatio = totalMs > 0
        ? (currentPosition.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    final fastDur = Ui.motion(context, Ui.fast);

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
          // 1. Video viewport tap-to-play/pause
          GestureDetector(
            key: const Key('video_viewport_tap'),
            behavior: HitTestBehavior.opaque,
            onTap: isConverting ? null : onTogglePlay,
            child: Center(
              child: AspectRatio(
                aspectRatio: aspect,
                child: VideoPlayer(controller),
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

          // 3. Center Minimalist Play Indicator (smooth fade + scale, zero blur)
          Center(
            child: IgnorePointer(
              ignoring: isPlaying || isConverting,
              child: AnimatedOpacity(
                duration: fastDur,
                curve: Ui.easeOut,
                opacity: (!isPlaying && !isConverting) ? 1.0 : 0.0,
                child: AnimatedScale(
                  duration: fastDur,
                  curve: Ui.easeOut,
                  scale: (!isPlaying && !isConverting) ? 1.0 : 0.88,
                  child: Pressable(
                    enabled: !isPlaying && !isConverting,
                    semanticLabel: '播放视频预览',
                    haptic: Haptic.selection,
                    maxInsetPx: 4.0,
                    minSize: const Size(56, 56),
                    onTap: onTogglePlay,
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
          ),

          // 4. Bottom-Left Tabular Timecode Readout
          Positioned(
            bottom: Ui.s3,
            left: Ui.s3,
            child: IgnorePointer(
              child: Container(
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 9),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Ui.hudScrim,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: Ui.hairline),
                ),
                child: Text(
                  '${formatPreciseDuration(currentPosition)} / ${formatPreciseDuration(totalDuration)}',
                  style: Ui.mono.copyWith(fontSize: 11.5),
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

          // 6. Top-Left Audio Switch — Placed LAST with >=112×48dp opaque hit area
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
