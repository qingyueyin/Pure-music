import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

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
    this.lineDuration,
    this.transitionDuration,
    required this.child,
  });

  final LyricLineVisualState targetState;
  final LyricSpringDescription spring;
  final Alignment alignment;
  final bool enabled;
  final Duration staggerDelay;
  final Duration? lineDuration;

  /// 若设置，覆盖 [lineDuration] 和默认 380ms 的过渡动画时长。
  /// 用于在程序化滚动时与滚动动画同步（例如同时 300ms 完成）。
  final Duration? transitionDuration;

  final Widget child;

  @override
  State<LyricLineSpringMotion> createState() => _LyricLineSpringMotionState();
}

class _LyricLineSpringMotionState extends State<LyricLineSpringMotion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late CurvedAnimation _curvedAnimation;
  late LyricLineVisualStateTween _stateTween;
  Timer? _staggerTimer;

  static const int _blurFilterCacheMaxSize = 20;
  static final Map<double, ImageFilter> _blurFilterCache = {};

  static double _roundSigma(double sigma) {
    return (sigma * 2).roundToDouble() / 2;
  }

  static ImageFilter _getBlurFilter(double sigma) {
    final key = _roundSigma(sigma);
    if (_blurFilterCache.length >= _blurFilterCacheMaxSize &&
        !_blurFilterCache.containsKey(key)) {
      _blurFilterCache.remove(_blurFilterCache.keys.first);
    }
    return _blurFilterCache.putIfAbsent(
      key,
      () => ImageFilter.blur(sigmaX: key, sigmaY: key),
    );
  }


  Duration get _floatingDuration {
    if (widget.transitionDuration != null) {
      return widget.transitionDuration!;
    }
    if (widget.lineDuration != null && widget.lineDuration!.inMilliseconds > 0) {
      final dura = widget.lineDuration!.inMilliseconds / 1000.0;
      final ms = dura * 1000 * 1.8 + 50;
      return Duration(milliseconds: ms.round().clamp(200, 5000));
    }
    return const Duration(milliseconds: 380);
  }

  Duration get _floatingDelay {
    // transitionDuration 生效时取消 stagger 延迟，确保所有行同时开始过渡
    if (widget.transitionDuration != null) {
      return Duration.zero;
    }
    if (widget.lineDuration != null && widget.lineDuration!.inMilliseconds > 0) {
      final dura = widget.lineDuration!.inMilliseconds / 1000.0;
      final ms = dura * 1000 * 0.2;
      return Duration(milliseconds: ms.round().clamp(0, 1000));
    }
    return widget.staggerDelay;
  }

  LyricLineVisualState get _currentState {
    return _stateTween.lerp(_curvedAnimation.value.clamp(0.0, 1.0));
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _floatingDuration,
      value: 1.0,
    );
    _curvedAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _stateTween = LyricLineVisualStateTween(
      begin: widget.targetState,
      end: widget.targetState,
    );
  }

  @override
  void didUpdateWidget(covariant LyricLineSpringMotion oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 过渡动画时用 easeOutSine 匹配滚动动画的 sineOut 曲线
    if (widget.transitionDuration != null) {
      _curvedAnimation.curve = Curves.easeOutSine;
    } else {
      _curvedAnimation.curve = Curves.easeOutCubic;
    }

    final shouldSkip = _currentState.isCloseTo(widget.targetState) &&
        oldWidget.spring == widget.spring &&
        oldWidget.enabled == widget.enabled &&
        oldWidget.alignment == widget.alignment &&
        oldWidget.staggerDelay == widget.staggerDelay &&
        oldWidget.lineDuration == widget.lineDuration;

    if (shouldSkip) {
      _stateTween = LyricLineVisualStateTween(
        begin: widget.targetState,
        end: widget.targetState,
      );
      _controller.value = 1.0;
      return;
    }

    _controller.duration = _floatingDuration;

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

    final delay = _floatingDelay;
    if (delay.inMilliseconds > 0) {
      _staggerTimer = Timer(delay, () {
        if (!mounted || !widget.enabled) return;
        _controller.value = 0.0;
        _controller.forward();
      });
    } else {
      _controller.value = 0.0;
      _controller.forward();
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
            filterQuality: FilterQuality.low,
            child: current,
          );
        }

        if (visualState.scale != 1.0) {
          current = Transform.scale(
            scale: visualState.scale,
            alignment: widget.alignment,
            filterQuality: FilterQuality.low,
            child: current,
          );
        }

        if (visualState.blurSigma > 0.01) {
          current = ImageFiltered(
            imageFilter: _getBlurFilter(visualState.blurSigma),
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
