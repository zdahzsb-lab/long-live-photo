import 'package:flutter_animate/flutter_animate.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/studio_tokens.dart';

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

    Widget pulseHalo = Container(
      width: 116,
      height: 116,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: const Color(0x3838BDF8),
          width: 1.2,
        ),
      ),
    );

    if (!reduceMotion) {
      pulseHalo = pulseHalo
          .animate(onPlay: (AnimationController c) => c.repeat(reverse: true))
          .scaleXY(
            begin: 0.92,
            end: 1.06,
            duration: const Duration(milliseconds: 2600),
            curve: Curves.easeInOutSine,
          )
          .fade(
            begin: 0.45,
            end: 0.95,
            duration: const Duration(milliseconds: 2600),
            curve: Curves.easeInOutSine,
          );
    }

    Widget heroContent = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          // Platform status pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: StudioTokens.surfaceSubtle,
              borderRadius: BorderRadius.circular(StudioTokens.radiusPill),
              border: Border.all(color: StudioTokens.borderSubtle, width: 0.8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ExcludeSemantics(
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: StudioTokens.accentCyan,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    platformTag,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: StudioTokens.textSecondary,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // Optical Live Photo Viewfinder Emblem
          ExcludeSemantics(
            child: SizedBox(
              width: 120,
              height: 120,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  pulseHalo,
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: StudioTokens.accentActiveBorder,
                        width: 1.4,
                      ),
                      gradient: const RadialGradient(
                        colors: <Color>[
                          Color(0x360A84FF),
                          Color(0x0D38BDF8),
                          Color(0x000A84FF),
                        ],
                      ),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x330A84FF),
                          blurRadius: 28,
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0x24FFFFFF),
                      border: Border.all(
                        color: StudioTokens.borderDefault,
                        width: 1,
                      ),
                    ),
                    child: const Icon(
                      LucideIcons.aperture,
                      size: 28,
                      color: StudioTokens.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          const Text(
            '导入长视频，凝成一张实况',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              height: 1.3,
              letterSpacing: -0.3,
              color: StudioTokens.textPrimary,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 10),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '突破 3 秒束缚，数秒至数十分钟视频原声直入系统相册，指尖按住即可完整回放。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.55,
                color: StudioTokens.textMuted,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Capability Pills (4/8dp rhythm)
          const Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _FeatureBadge(icon: LucideIcons.infinity, label: '全长不截断'),
              _FeatureBadge(icon: LucideIcons.zap, label: '原画秒级直通'),
              _FeatureBadge(icon: LucideIcons.volume2, label: '原生有声实况'),
            ],
          ),
          const SizedBox(height: 32),

          // Primary CTA with subtle cobalt ambient glow
          DecoratedBox(
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.all(Radius.circular(28)),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: StudioTokens.accentGlow,
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: GlassButton.custom(
              key: const Key('pick_gallery_button'),
              height: 54,
              enabled: !isBusy,
              useOwnLayer: true,
              style: GlassButtonStyle.prominent,
              tintColor: StudioTokens.accentPrimary,
              shape: const LiquidRoundedSuperellipse(borderRadius: 27),
              onTap: onPickGallery,
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  ExcludeSemantics(
                    child: Icon(
                      LucideIcons.images,
                      size: 19,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: 8),
                  Text(
                    '从相册选视频',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Subordinate Secondary Action (per Apple HIG / ui-ux-pro-max primary-action rule)
          GlassButton.custom(
            key: const Key('pick_file_button'),
            height: 48,
            enabled: !isBusy,
            useOwnLayer: true,
            style: GlassButtonStyle.filled,
            shape: const LiquidRoundedSuperellipse(borderRadius: 24),
            onTap: onPickFiles,
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                ExcludeSemantics(
                  child: Icon(
                    LucideIcons.folderOpen,
                    size: 17,
                    color: StudioTokens.textSecondary,
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  '从文件导入',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: StudioTokens.textSecondary,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (!reduceMotion) {
      heroContent = heroContent
          .animate()
          .fadeIn(
            duration: StudioTokens.stateDuration,
            curve: StudioTokens.curveOutExpo,
          )
          .slideY(
            begin: 0.03,
            end: 0,
            duration: StudioTokens.stateDuration,
            curve: StudioTokens.curveOutExpo,
          );
    }

    return Center(child: heroContent);
  }
}

class _FeatureBadge extends StatelessWidget {
  const _FeatureBadge({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x12FFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: StudioTokens.borderSubtle, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ExcludeSemantics(
            child: Icon(
              icon,
              size: 13,
              color: StudioTokens.accentIce,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: StudioTokens.textSecondary,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}
