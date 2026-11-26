import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/studio_tokens.dart';

enum TactileHaptic {
  none,
  selection,
  light,
}

/// Interactive touch wrapper enforcing `ui-ux-pro-max` mobile rules:
/// - Guaranteed >= 44–48dp opaque hit area even when visual child is compact
/// - Immediate GPU-only scale & opacity press feedback (zero layout shift)
/// - Subtle native haptic confirmation and reduced-motion compliance
class TactilePressable extends StatefulWidget {
  const TactilePressable({
    super.key,
    required this.child,
    required this.onTap,
    this.semanticLabel,
    this.semanticSelected,
    this.enabled = true,
    this.minWidth = StudioTokens.minTouchTarget,
    this.minHeight = StudioTokens.minTouchTarget,
    this.alignment = Alignment.center,
    this.padding = EdgeInsets.zero,
    this.pressedScale = 0.95,
    this.haptic = TactileHaptic.selection,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final bool? semanticSelected;
  final bool enabled;
  final double minWidth;
  final double minHeight;
  final AlignmentGeometry alignment;
  final EdgeInsetsGeometry padding;
  final double pressedScale;
  final TactileHaptic haptic;

  @override
  State<TactilePressable> createState() => _TactilePressableState();
}

class _TactilePressableState extends State<TactilePressable> {
  bool _isPressed = false;

  bool get _interactive => widget.enabled && widget.onTap != null;

  void _setPressed(bool value) {
    if (_isPressed == value || !mounted) return;
    setState(() {
      _isPressed = value;
    });
  }

  void _triggerHaptic() {
    switch (widget.haptic) {
      case TactileHaptic.none:
        break;
      case TactileHaptic.selection:
        HapticFeedback.selectionClick();
      case TactileHaptic.light:
        HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final targetScale = (_isPressed && _interactive && !reduceMotion)
        ? widget.pressedScale
        : 1.0;
    final targetOpacity = !_interactive
        ? 0.45
        : (_isPressed ? 0.84 : 1.0);
    final animDuration = _isPressed
        ? StudioTokens.pressDuration
        : (reduceMotion ? Duration.zero : StudioTokens.releaseDuration);
    final animCurve = _isPressed
        ? Curves.easeOutCubic
        : StudioTokens.curveSpring;

    Widget content = AnimatedOpacity(
      duration: StudioTokens.pressDuration,
      opacity: targetOpacity,
      child: AnimatedScale(
        scale: targetScale,
        duration: animDuration,
        curve: animCurve,
        child: widget.child,
      ),
    );

    content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _interactive ? (_) => _setPressed(true) : null,
      onTapUp: _interactive ? (_) => _setPressed(false) : null,
      onTapCancel: _interactive ? () => _setPressed(false) : null,
      onTap: _interactive
          ? () {
              _setPressed(false);
              _triggerHaptic();
              widget.onTap?.call();
            }
          : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: widget.minWidth,
          minHeight: widget.minHeight,
        ),
        child: Padding(
          padding: widget.padding,
          child: Align(
            alignment: widget.alignment,
            widthFactor: 1.0,
            heightFactor: 1.0,
            child: content,
          ),
        ),
      ),
    );

    if (widget.semanticLabel != null) {
      return Semantics(
        button: true,
        enabled: _interactive,
        selected: widget.semanticSelected,
        label: widget.semanticLabel,
        excludeSemantics: true,
        child: content,
      );
    }

    return content;
  }
}
