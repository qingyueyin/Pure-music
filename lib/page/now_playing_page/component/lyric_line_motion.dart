import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'package:pure_music/core/lyric_render_config.dart';

@immutable
class LyricLineVisualState {
  final double opacity;
  final double blurSigma;
  final double scale;
  final double offsetY;

  const LyricLineVisualState({
    required this.opacity,
    required this.blurSigma,
    required this.scale,
    this.offsetY = 0.0,
  });

  static LyricLineVisualState lerp(
    LyricLineVisualState a,
    LyricLineVisualState b,
    double t,
  ) {
    return LyricLineVisualState(
      opacity: lerpDouble(a.opacity, b.opacity, t) ?? b.opacity,
      blurSigma: lerpDouble(a.blurSigma, b.blurSigma, t) ?? b.blurSigma,
      scale: lerpDouble(a.scale, b.scale, t) ?? b.scale,
      offsetY: lerpDouble(a.offsetY, b.offsetY, t) ?? b.offsetY,
    );
  }

  bool isCloseTo(LyricLineVisualState other, {double epsilon = 1e-3}) {
    return (opacity - other.opacity).abs() <= epsilon &&
        (blurSigma - other.blurSigma).abs() <= epsilon &&
        (scale - other.scale).abs() <= epsilon &&
        (offsetY - other.offsetY).abs() <= epsilon;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LyricLineVisualState &&
        other.opacity == opacity &&
        other.blurSigma == blurSigma &&
        other.scale == scale &&
        other.offsetY == offsetY;
  }

  @override
  int get hashCode => Object.hash(opacity, blurSigma, scale, offsetY);
}

class LyricLineVisualStateTween extends Tween<LyricLineVisualState> {
  LyricLineVisualStateTween({
    required super.begin,
    required super.end,
  });

  @override
  LyricLineVisualState lerp(double t) {
    return LyricLineVisualState.lerp(begin!, end!, t);
  }
}

class LyricLineSpringMotion extends StatefulWidget {
  const LyricLineSpringMotion({
    super.key,
    required this.targetState,
    required this.spring,
    required this.alignment,
    this.enabled = true,
    this.staggerDelay = Duration.zero,
    required this.child,
  });

  final LyricLineVisualState targetState;
  final LyricSpringDescription spring;
  final Alignment alignment;
  final bool enabled;
  final Duration staggerDelay;
  final Widget child;

  @override
  State<LyricLineSpringMotion> createState() => _LyricLineSpringMotionState();
}

class _LyricLineSpringMotionState extends State<LyricLineSpringMotion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late LyricLineVisualStateTween _stateTween;
  Timer? _staggerTimer;

  SpringDescription get _spring => SpringDescription(
        mass: widget.spring.mass,
        stiffness: widget.spring.stiffness,
        damping: widget.spring.damping,
      );

  LyricLineVisualState get _currentState {
    return _stateTween.lerp(_controller.value.clamp(0.0, 1.0));
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, value: 1.0);
    _stateTween = LyricLineVisualStateTween(
      begin: widget.targetState,
      end: widget.targetState,
    );
  }

  @override
  void didUpdateWidget(covariant LyricLineSpringMotion oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (_currentState.isCloseTo(widget.targetState) &&
        oldWidget.spring == widget.spring &&
        oldWidget.enabled == widget.enabled &&
        oldWidget.alignment == widget.alignment &&
        oldWidget.staggerDelay == widget.staggerDelay) {
      _stateTween = LyricLineVisualStateTween(
        begin: widget.targetState,
        end: widget.targetState,
      );
      _controller.value = 1.0;
      return;
    }

    final beginState = _currentState;
    _stateTween = LyricLineVisualStateTween(
      begin: beginState,
      end: widget.targetState,
    );

    if (beginState.isCloseTo(widget.targetState)) {
      _controller.value = 1.0;
      return;
    }

    if (!widget.enabled) {
      _controller
        ..stop()
        ..value = 1.0;
      _staggerTimer?.cancel();
      return;
    }

    _staggerTimer?.cancel();

    if (widget.staggerDelay.inMilliseconds > 0) {
      _staggerTimer = Timer(widget.staggerDelay, () {
        if (!mounted || !widget.enabled) return;
        _controller
          ..stop()
          ..value = 0.0
          ..animateWith(SpringSimulation(_spring, 0.0, 1.0, 0.0));
      });
    } else {
      _controller
        ..stop()
        ..value = 0.0
        ..animateWith(SpringSimulation(_spring, 0.0, 1.0, 0.0));
    }
  }

  @override
  void dispose() {
    _staggerTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final visualState = widget.enabled ? _currentState : widget.targetState;
        Widget current = child!;

        if (visualState.offsetY.abs() > 0.01) {
          current = Transform.translate(
            offset: Offset(0, visualState.offsetY),
            child: current,
          );
        }

        if (visualState.scale != 1.0) {
          current = Transform.scale(
            scale: visualState.scale,
            alignment: widget.alignment,
            child: current,
          );
        }

        if (visualState.blurSigma > 0.01) {
          current = ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: visualState.blurSigma,
              sigmaY: visualState.blurSigma,
            ),
            child: current,
          );
        }

        return Opacity(
          opacity: visualState.opacity.clamp(0.0, 1.0),
          child: current,
        );
      },
    );
  }
}
