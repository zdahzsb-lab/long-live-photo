import 'package:flutter_animate/flutter_animate.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

class EmptyStudioView extends StatelessWidget {
  const EmptyStudioView({
    super.key,
    required this.platformTag,
    required this.isBusy,
    required this.onPickGallery,
    required this.onPickFiles,
  });

  final String platformTag;
  final bool isBusy;
  final VoidCallback onPickGallery;
  final VoidCallback onPickFiles;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final outerRing = Container(
      width: 108,
      height: 108,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: const Color(0x3DF59E0B),
          width: 1.5,
        ),
      ),
    );

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        // Animated Live Photo optical viewfinder emblem
        SizedBox(
          width: 112,
          height: 112,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              if (reduceMotion)
                outerRing
              else
                outerRing
                    .animate(onPlay: (c) => c.repeat(reverse: true))
                    .scaleXY(
                      begin: 0.94,
                      end: 1.05,
                      duration: const Duration(milliseconds: 2200),
                      curve: Curves.easeInOutSine,
                    ),
              Container(
                width: 82,
                height: 82,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0x6638BDF8),
                    width: 1.5,
                  ),
                  gradient: const RadialGradient(
                    colors: <Color>[
                      Color(0x2E38BDF8),
                      Color(0x08F59E0B),
                    ],
                  ),
                ),
              ),
              const Icon(
                LucideIcons.aperture,
                size: 36,
                color: Color(0xFFF8FAFC),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          '导入任意长视频 · 凝成一张实况',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFFF8FAFC),
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '打破 3 秒限制，几秒到数十分钟完整保留原声与高帧画面，存入系统相册长按即播。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.45,
              color: Color(0x99E2E8F0),
            ),
          ),
        ),
        const SizedBox(height: 16),
        GlassChip(
          label: platformTag,
          icon: const Icon(LucideIcons.sparkles, size: 14),
          useOwnLayer: true,
          enabled: true,
        ),
        const SizedBox(height: 28),
        Row(
          children: <Widget>[
            Expanded(
              child: GlassButton.custom(
                key: const Key('pick_gallery_button'),
                height: 52,
                enabled: !isBusy,
                useOwnLayer: true,
                style: GlassButtonStyle.prominent,
                tintColor: const Color(0xFF0A84FF),
                shape: const LiquidRoundedSuperellipse(borderRadius: 20),
                onTap: onPickGallery,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(LucideIcons.images, size: 18, color: Colors.white),
                    SizedBox(width: 8),
                    Text(
                      '从相册选视频',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GlassButton.custom(
                key: const Key('pick_file_button'),
                height: 52,
                enabled: !isBusy,
                useOwnLayer: true,
                style: GlassButtonStyle.filled,
                shape: const LiquidRoundedSuperellipse(borderRadius: 20),
                onTap: onPickFiles,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      LucideIcons.folderOpen,
                      size: 18,
                      color: Color(0xFFF1F5F9),
                    ),
                    SizedBox(width: 8),
                    Text(
                      '从文件导入',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFF1F5F9),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
