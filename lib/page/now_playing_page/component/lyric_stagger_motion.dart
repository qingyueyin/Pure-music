import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

const lyricSmoothTransitionDuration = Duration(milliseconds: 700);
const lyricSmoothTransitionCurve = Cubic(0.25, 0.0, 0.2, 1.0);

double lyricSmoothTransitionInterpolator(double t, double start, double end) {
  final progress = lyricSmoothTransitionCurve.transform(t);
  return start + (end - start) * progress;
}

int lyricStaggerDelayMs({
  required int itemIndex,
  required int visibleStartIndex,
}) {
  final distance = (itemIndex - visibleStartIndex).abs();
  var step = 50.0;
  var total = 0.0;
  for (var i = 0; i < distance; i++) {
    total += step;
    step /= 1.05;
  }
  return total.toInt();
}

bool canStartLyricStagger({
  required bool enabled,
  required int previousIndex,
  required int nextIndex,
  required bool isUserDragging,
  required bool skipNextAfterDrag,
}) {
  if (!enabled || isUserDragging || skipNextAfterDrag) return false;
  if (previousIndex < 0 || nextIndex < 0 || previousIndex == nextIndex) {
    return false;
  }
  return (nextIndex - previousIndex).abs() <= 10;
}

enum LyricUserScrollPhase { ignored, started, updated, ended }

class LyricUserScrollTracker {
  bool _isActive = false;

  bool get isActive => _isActive;

  LyricUserScrollPhase start() {
    if (_isActive) return LyricUserScrollPhase.updated;
    _isActive = true;
    return LyricUserScrollPhase.started;
  }

  LyricUserScrollPhase update() => start();

  LyricUserScrollPhase end() {
    if (!_isActive) return LyricUserScrollPhase.ignored;
    _isActive = false;
    return LyricUserScrollPhase.ended;
  }
}

class LyricStaggerTransition extends StatefulWidget {
  const LyricStaggerTransition({
    super.key,
    required this.enabled,
    required this.generation,
    required this.shiftY,
    required this.delay,
    required this.child,
  });

  final bool enabled;
  final int generation;
  final double shiftY;
  final Duration delay;
  final Widget child;

  @override
  State<LyricStaggerTransition> createState() => _LyricStaggerTransitionState();
}

class _LyricStaggerTransitionState extends State<LyricStaggerTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this);
    _scheduleTransition();
  }

  @override
  void didUpdateWidget(covariant LyricStaggerTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled) {
      _scheduleTransition();
      return;
    }
    if (widget.generation != oldWidget.generation) {
      // 只在新的补偿到来时接上当前位移，shiftY 被清零不能把弹簧打回 0。
      _scheduleTransition(composeCurrent: widget.shiftY.abs() >= 0.5);
    }
  }

  void _scheduleTransition({bool composeCurrent = false}) {
    if (!widget.enabled ||
        widget.generation <= 0 ||
        (!composeCurrent && widget.shiftY.abs() < 0.5)) {
      _delayTimer?.cancel();
      _controller.stop();
      _controller.value = 0;
      return;
    }

    final velocity = composeCurrent ? _controller.velocity : 0.0;
    final start = composeCurrent
        ? _controller.value + widget.shiftY
        : widget.shiftY;
    final springRunning =
        composeCurrent && _delayTimer == null && _controller.isAnimating;
    _delayTimer?.cancel();
    _controller.stop();
    _controller.value = start;
    final generation = widget.generation;
    if (springRunning || widget.delay <= Duration.zero) {
      _startSpring(generation, velocity: velocity);
      return;
    }
    _delayTimer = Timer(widget.delay, () => _startSpring(generation));
  }

  void _startSpring(int generation, {double velocity = 0}) {
    if (!mounted || !widget.enabled || generation != widget.generation) return;
    final spring = SpringDescription.withDampingRatio(
      mass: 1,
      stiffness: 200,
      ratio: 1.1,
    );
    _controller.animateWith(
      SpringSimulation(
        spring,
        _controller.value,
        0,
        velocity,
        tolerance: const Tolerance(distance: 0.5, velocity: 0.1),
      ),
    );
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) =>
        Transform.translate(offset: Offset(0, _controller.value), child: child),
    child: widget.child,
  );
}
