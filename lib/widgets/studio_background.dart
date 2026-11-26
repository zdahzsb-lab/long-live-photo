import 'package:material_ui/material_ui.dart';

/// Deep cinema obsidian background with restrained optical ambient light pools
/// so Liquid Glass chrome refracts subtle warm-amber and ice-blue depth.
class StudioBackground extends StatelessWidget {
  const StudioBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color(0xFF07090F),
            Color(0xFF0D1320),
            Color(0xFF090B11),
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned(
            top: -90,
            right: -60,
            child: IgnorePointer(
              child: Container(
                width: 280,
                height: 280,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: <Color>[
                      Color(0x2838BDF8),
                      Color(0x0038BDF8),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -100,
            left: -70,
            child: IgnorePointer(
              child: Container(
                width: 300,
                height: 300,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: <Color>[
                      Color(0x22F59E0B),
                      Color(0x00F59E0B),
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
