import 'package:flutter/material.dart';
import 'package:pure_music/component/motion.dart';

/// Collapses [child] to zero layout height when hidden, so siblings can
/// reclaim the space. The child is still laid out for the size animation.
class NowPlayingCollapsibleChrome extends StatelessWidget {
  const NowPlayingCollapsibleChrome({
    super.key,
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return ClipRect(
      child: AnimatedAlign(
        duration: reduceMotion ? Duration.zero : MotionDuration.base,
        curve: MotionCurve.standard,
        alignment: Alignment.topCenter,
        heightFactor: visible ? 1.0 : 0.0,
        child: IgnorePointer(ignoring: !visible, child: child),
      ),
    );
  }
}
