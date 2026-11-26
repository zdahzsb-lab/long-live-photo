import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/studio_tokens.dart';

/// Deep OLED cinema canvas with gentle breathing ambient light pools
/// (`ui-ux-pro-max` Modern Dark Cinema Mobile pattern) so Liquid Glass
/// controls refract living cool-cyan and cobalt depth without harsh contrast.
class StudioBackground extends StatelessWidget {
  const StudioBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    Widget topOrb = Container(
      width: 320,
      height: 320,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: <Color>[
            Color(0x2B38BDF8),
            Color(0x0038BDF8),
          ],
        ),
      ),
    );

    Widget bottomOrb = Container(
      width: 340,
      height: 340,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: <Color>[
            Color(0x266366F1),
            Color(0x006366F1),
          ],
        ),
      ),
    );

    if (!reduceMotion) {
      topOrb = topOrb
          .animate(onPlay: (AnimationController c) => c.repeat(reverse: true))
          .move(
            begin: const Offset(-10, -8),
            end: const Offset(14, 12),
            duration: const Duration(milliseconds: 6800),
            curve: Curves.easeInOutSine,
          )
          .scaleXY(
            begin: 0.96,
            end: 1.06,
            duration: const Duration(milliseconds: 6800),
            curve: Curves.easeInOutSine,
          );

      bottomOrb = bottomOrb
          .animate(onPlay: (AnimationController c) => c.repeat(reverse: true))
          .move(
            begin: const Offset(12, 10),
            end: const Offset(-14, -10),
            duration: const Duration(milliseconds: 7600),
            curve: Curves.easeInOutSine,
          );
    }

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            StudioTokens.bgDeep,
            StudioTokens.bgBase,
            Color(0xFF060912),
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned(
            top: -100,
            right: -70,
            child: IgnorePointer(child: topOrb),
          ),
          Positioned(
            bottom: -110,
            left: -80,
            child: IgnorePointer(child: bottomOrb),
          ),
        ],
      ),
    );
  }
}
