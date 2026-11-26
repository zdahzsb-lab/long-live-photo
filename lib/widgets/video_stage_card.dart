import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../models/conversion_options.dart';

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
    final aspect =
        controller.value.aspectRatio > 0 ? controller.value.aspectRatio : 9 / 16;
    final isPlaying = controller.value.isPlaying;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF05070B),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: const Color(0x22FFFFFF),
          width: 1,
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // Video viewport
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: isConverting ? null : onTogglePlay,
            child: Center(
              child: AspectRatio(
                aspectRatio: aspect,
                child: VideoPlayer(controller),
              ),
            ),
          ),

          // Top subtle vignette for HUD legibility
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 64,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Color(0x88000000),
                      Color(0x00000000),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Top-left iPhone-style LIVE audio toggle pill
          Positioned(
            top: 12,
            left: 12,
            child: Semantics(
              button: true,
              label: keepAudio ? '实况原声已开启，点击静音' : '实况已静音，点击开启原声',
              child: GestureDetector(
                onTap: isConverting ? null : onToggleAudio,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: keepAudio
                        ? const Color(0xD9F59E0B)
                        : const Color(0x801E293B),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0x33FFFFFF),
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        keepAudio ? LucideIcons.volume2 : LucideIcons.volumeX,
                        size: 13,
                        color: keepAudio
                            ? const Color(0xFF090B10)
                            : const Color(0xFFE2E8F0),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        keepAudio ? 'LIVE 有声' : 'LIVE 静音',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                          color: keepAudio
                              ? const Color(0xFF090B10)
                              : const Color(0xFFE2E8F0),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Top-right resolution & file size pill
          Positioned(
            top: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0x780F172A),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0x28FFFFFF), width: 0.8),
              ),
              child: Text(
                '${size.width.toInt()}×${size.height.toInt()} · ${formatFileSize(sourceSizeBytes)}',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFE2E8F0),
                ),
              ),
            ),
          ),

          // Center floating Liquid Glass Play button when paused
          if (!isPlaying && !isConverting)
            Center(
              child: GlassIconButton(
                size: 54,
                iconSize: 24,
                useOwnLayer: true,
                semanticLabel: '播放视频预览',
                icon: const Icon(LucideIcons.play, color: Colors.white),
                onPressed: onTogglePlay,
              ),
            ),

          // Bottom-left live timecode readout
          Positioned(
            bottom: 10,
            left: 12,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0x88090B10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${formatPreciseDuration(currentPosition)} / ${formatPreciseDuration(totalDuration)}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFF1F5F9),
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
