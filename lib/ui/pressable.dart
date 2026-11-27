import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/ui_tokens.dart';

enum Haptic { none, selection, light, medium }

void playHaptic(Haptic haptic) {
  switch (haptic) {
    case Haptic.none:
      break;
    case Haptic.selection:
      HapticFeedback.selectionClick();
    case Haptic.light:
      HapticFeedback.lightImpact();
    case Haptic.medium:
      HapticFeedback.mediumImpact();
  }
}

/// Velocity-continuous spring touch primitive inspired by `duobaseio/forui`
/// (`FTappable` + `RenderBounce`) and `ui-ux-pro-max` touch guidelines.
///
/// Key guarantees:
/// 1. Zero tap-arena delay: reacts on raw `Listener.onPointerDown` (0ms).
/// 2. Continuous `SpringSimulation`: interrupting a press mid-flight or flicking
///    in <30ms still produces a perceptible tactile dip and organic rebound
///    without velocity discontinuities or pending `Timer`s.
/// 3. Proportional travel (`maxInsetPx`): wide buttons and compact icon pills
///    displace by a consistent physical pixel amount (~4–5px) without layout shift.
/// 4. Minimum hit box >= [minSize] (`44×44pt` default) with opaque hit-testing.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    required this.onTap,
    this.enabled = true,
    this.semanticLabel,
    this.selected,
    this.toggled,
    this.haptic = Haptic.selection,
    this.maxInsetPx = 5.0,
    this.pressedOpacity = 0.78,
    this.minSize = const Size(Ui.minTarget, Ui.minTarget),
    this.expandWidth = false,
    this.alignment = Alignment.center,
    this.hitPadding = EdgeInsets.zero,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool enabled;
  final String? semanticLabel;
  final bool? selected;
  final bool? toggled;
  final Haptic haptic;
  final double maxInsetPx;
  final double pressedOpacity;
  final Size minSize;
  final bool expandWidth;
  final AlignmentGeometry alignment;
  final EdgeInsetsGeometry hitPadding;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable>
    with SingleTickerProviderStateMixin {
  static const SpringDescription _pressSpring = SpringDescription(
    mass: 1.0,
    stiffness: 950.0,
    damping: 46.0,
  );

  static const SpringDescription _releaseSpring = SpringDescription(
    mass: 1.0,
    stiffness: 420.0,
    damping: 26.0,
  );

  late final AnimationController _pressCtrl;
  bool _pointerDown = false;
  bool _reduceMotion = false;
  bool _inactive = false;

  bool get _active => widget.enabled && widget.onTap != null;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController.unbounded(vsync: this, value: 0.0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void activate() {
    super.activate();
    _inactive = false;
  }

  @override
  void deactivate() {
    _inactive = true;
    super.deactivate();
  }

  @override
  void didUpdateWidget(covariant Pressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_active && (_pointerDown || _pressCtrl.value != 0.0)) {
      _pointerDown = false;
      _pressCtrl.value = 0.0;
    }
  }

  @override
  void dispose() {
    _inactive = true;
    _pressCtrl.dispose();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent _) {
    if (_inactive || !mounted || !_active) return;
    _pointerDown = true;
    if (_reduceMotion) {
      _pressCtrl.value = 1.0;
      return;
    }
    final startVel = _pressCtrl.velocity > 5.0 ? _pressCtrl.velocity : 5.0;
    _pressCtrl.animateWith(
      SpringSimulation(_pressSpring, _pressCtrl.value, 1.0, startVel),
    );
  }

  void _release({required bool giveTapImpulse}) {
    if (_inactive || !mounted) return;
    if (!_pointerDown && _pressCtrl.value == 0.0) return;
    _pointerDown = false;
    if (_reduceMotion) {
      _pressCtrl.value = 0.0;
      return;
    }
    // For ultra-fast taps (<40ms) where the spring hasn't reached half depth yet,
    // inject forward velocity so the button visibly dips before rebounding to 0.
    final double launchVelocity =
        (giveTapImpulse && _pressCtrl.value < 0.45) ? 11.0 : _pressCtrl.velocity;
    _pressCtrl.animateWith(
      SpringSimulation(_releaseSpring, _pressCtrl.value, 0.0, launchVelocity),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    Widget content = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final refSpan = constraints.hasBoundedWidth && constraints.maxWidth > 0
            ? constraints.maxWidth
            : 120.0;
        final shrinkDelta = (widget.maxInsetPx / refSpan).clamp(0.018, 0.075);

        return AnimatedBuilder(
          animation: _pressCtrl,
          child: widget.child,
          builder: (BuildContext context, Widget? child) {
            final t = _pressCtrl.value.clamp(0.0, 1.25);
            final scale = (!widget.enabled || reduceMotion)
                ? 1.0
                : (1.0 - shrinkDelta * t);
            final double opacity = !widget.enabled
                ? 0.38
                : (1.0 - (1.0 - widget.pressedOpacity) * t.clamp(0.0, 1.0));

            return Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: scale,
                child: child,
              ),
            );
          },
        );
      },
    );

    content = ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: widget.expandWidth ? double.infinity : widget.minSize.width,
        minHeight: widget.minSize.height,
      ),
      child: Padding(
        padding: widget.hitPadding,
        child: Align(
          alignment: widget.alignment,
          widthFactor: widget.expandWidth ? null : 1.0,
          heightFactor: 1.0,
          child: content,
        ),
      ),
    );

    return Semantics(
      button: true,
      enabled: _active,
      selected: widget.selected,
      toggled: widget.toggled,
      label: widget.semanticLabel,
      excludeSemantics: widget.semanticLabel != null,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _active ? _handlePointerDown : null,
        onPointerUp: _active ? (_) => _release(giveTapImpulse: true) : null,
        onPointerCancel: _active ? (_) => _release(giveTapImpulse: false) : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _active
              ? () {
                  playHaptic(widget.haptic);
                  widget.onTap!.call();
                }
              : null,
          child: content,
        ),
      ),
    );
  }
}
