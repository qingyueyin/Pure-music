import 'dart:math';
import 'package:flutter/animation.dart';

class ValueTransition<T extends num> {
  T value;
  T _start;
  T _target;
  final T Function(double t, T start, T end) _interpolator;
  final Duration duration;
  Duration _elapsed = Duration.zero;
  bool _active = false;

  ValueTransition({
    required T begin,
    required T Function(double t, T start, T end) interpolator,
    required this.duration,
  })  : value = begin,
        _start = begin,
        _target = begin,
        _interpolator = interpolator;

  bool get isActive => _active;

  void start(T target) {
    if (_active) {
      _start = value;
    } else {
      _start = value == target ? value : value;
    }
    _target = target;
    if (_start != _target) {
      _elapsed = Duration.zero;
      _active = true;
    }
  }

  void jumpTo(T value) {
    this.value = value;
    _start = value;
    _target = value;
    _elapsed = Duration.zero;
    _active = false;
  }

  void update(Duration elapsed) {
    if (!_active) return;
    _elapsed += elapsed;
    if (_elapsed >= duration) {
      value = _target;
      _active = false;
      return;
    }
    final t = _elapsed.inMicroseconds / duration.inMicroseconds;
    value = _interpolator(t.clamp(0.0, 1.0), _start, _target);
  }
}

double doubleEaseOutCubic(double t, double start, double end) {
  return start + (end - start) * Curves.easeOutCubic.transform(t);
}

double doubleEaseInOutSine(double t, double start, double end) {
  final transformed = -(cos(3.141592653589793 * t) - 1) / 2;
  return start + (end - start) * transformed;
}

double doubleEaseOutSine(double t, double start, double end) {
  return start + (end - start) * sin(t * 3.141592653589793 / 2);
}

double doubleEaseInSine(double t, double start, double end) {
  return start + (end - start) * (1 - cos(t * 3.141592653589793 / 2));
}