import 'dart:ui' show ImageFilter;

import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../models/conversion_options.dart';
import '../theme/studio_tokens.dart';
import 'tactile_pressable.dart';

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
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final totalMs = totalDuration.inMilliseconds;
    final playRatio = totalMs > 0
        ? (currentPosition.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      decoration: BoxDecoration(
        color: StudioTokens.surfaceStage,
        borderRadius: BorderRadius.circular(StudioTokens.radiusStage),
        border: Border.all(
          color: StudioTokens.borderDefault,
          width: 1,
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x73000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 1. Interactive Video Viewport
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

          // 2. Top & Bottom Subtle Cinema Scrims for HUD Contrast (>= 4.5:1)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 76,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Color(0x9903060C),
                      Color(0x0003060C),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 64,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: <Color>[
                      Color(0x9903060C),
                      Color(0x0003060C),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // 3. Top-Right Resolution & Source Size Badge (IgnorePointer so it never blocks)
          Positioned(
            top: 12,
            right: 12,
            child: IgnorePointer(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(StudioTokens.radiusPill),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: StudioTokens.surfacePill,
                      borderRadius: BorderRadius.circular(
                        StudioTokens.radiusPill,
                      ),
                      border: Border.all(
                        color: StudioTokens.borderSubtle,
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      '${size.width.toInt()}×${size.height.toInt()} · ${formatFileSize(sourceSizeBytes)}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontFeatures: <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                        fontWeight: FontWeight.w600,
                        color: StudioTokens.textSecondary,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 4. Center Play Button with Silky Scale + Opacity Transition (no 0ms pop)
          Center(
            child: IgnorePointer(
              ignoring: isPlaying || isConverting,
              child: AnimatedOpacity(
                duration: reduceMotion
                    ? Duration.zero
                    : StudioTokens.microDuration,
                curve: StudioTokens.curveOutExpo,
                opacity: (!isPlaying && !isConverting) ? 1.0 : 0.0,
                child: AnimatedScale(
                  duration: reduceMotion
                      ? Duration.zero
                      : StudioTokens.microDuration,
                  curve: StudioTokens.curveOutExpo,
                  scale: (!isPlaying && !isConverting) ? 1.0 : 0.86,
                  child: GlassIconButton(
                    size: 56,
                    iconSize: 24,
                    useOwnLayer: true,
                    semanticLabel: '播放视频预览',
                    icon: const Icon(LucideIcons.play, color: Colors.white),
                    onPressed: onTogglePlay,
                  ),
                ),
              ),
            ),
          ),

          // 5. Bottom-Left Tabular Timecode Capsule
          Positioned(
            bottom: 12,
            left: 12,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: StudioTokens.surfacePill,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: StudioTokens.borderSubtle,
                    width: 0.8,
                  ),
                ),
                child: Text(
                  '${formatPreciseDuration(currentPosition)} / ${formatPreciseDuration(totalDuration)}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                    color: StudioTokens.textPrimary,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),

          // 6. Bottom Edge Live Playback Progress Hairline
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 3,
            child: IgnorePointer(
              child: ColoredBox(
                color: const Color(0x26FFFFFF),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: playRatio,
                  child: const ColoredBox(color: StudioTokens.accentCyan),
                ),
              ),
            ),
          ),

          // 7. Top-Left Audio Toggle Pill — Placed LAST in Stack with >= 116x52dp
          // opaque hit target so finger taps NEVER miss or leak to video viewport!
          Positioned(
            top: 4,
            left: 4,
            child: TactilePressable(
              key: const Key('audio_toggle_button'),
              enabled: !isConverting,
              minWidth: 116,
              minHeight: 52,
              alignment: Alignment.topLeft,
              padding: const EdgeInsets.fromLTRB(8, 8, 12, 10),
              pressedScale: 0.93,
              haptic: TactileHaptic.light,
              semanticLabel: keepAudio ? '实况原声已开启，点击切换为静音' : '实况已静音，点击开启原声',
              semanticSelected: keepAudio,
              onTap: onToggleAudio,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(StudioTokens.radiusPill),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: AnimatedContainer(
                    duration: reduceMotion
                        ? Duration.zero
                        : StudioTokens.microDuration,
                    curve: StudioTokens.curveOutExpo,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: keepAudio
                          ? const Color(0xD90C1D36)
                          : StudioTokens.surfacePill,
                      borderRadius: BorderRadius.circular(
                        StudioTokens.radiusPill,
                      ),
                      border: Border.all(
                        color: keepAudio
                            ? StudioTokens.accentActiveBorder
                            : StudioTokens.borderDefault,
                        width: 1.0,
                      ),
                      boxShadow: keepAudio
                          ? const <BoxShadow>[
                              BoxShadow(
                                color: Color(0x3838BDF8),
                                blurRadius: 12,
                              ),
                            ]
                          : const <BoxShadow>[],
                    ),
                    child: AnimatedSwitcher(
                      duration: reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 170),
                      switchInCurve: StudioTokens.curveOutExpo,
                      transitionBuilder:
                          (Widget child, Animation<double> anim) {
                        return FadeTransition(opacity: anim, child: child);
                      },
                      child: Row(
                        key: ValueKey<bool>(keepAudio),
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: keepAudio
                                  ? StudioTokens.accentCyan
                                  : StudioTokens.textMuted,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            keepAudio
                                ? LucideIcons.volume2
                                : LucideIcons.volumeX,
                            size: 14,
                            color: keepAudio
                                ? StudioTokens.accentIce
                                : StudioTokens.textSecondary,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            keepAudio ? '实况有声' : '已静音',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                              color: keepAudio
                                  ? StudioTokens.textPrimary
                                  : StudioTokens.textSecondary,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
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
  }
}
