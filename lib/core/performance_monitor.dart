import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class PerformanceMonitor {
  static final PerformanceMonitor _instance = PerformanceMonitor._internal();
  factory PerformanceMonitor() => _instance;
  PerformanceMonitor._internal();

  int _frameCount = 0;
  int _droppedFrameCount = 0;
  final List<double> _frameTimes = [];
  Timer? _statsTimer;
  ValueChanged<PerformanceStats>? onStatsUpdate;

  void startMonitoring() {
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _calculateFrameRate();
    });

    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    for (var timing in timings) {
      _frameCount++;

      final buildDuration = timing.buildDuration.inMicroseconds / 1000;
      final rasterDuration = timing.rasterDuration.inMicroseconds / 1000;
      final totalDuration = buildDuration + rasterDuration;

      if (totalDuration > 16) {
        _droppedFrameCount++;
      }

      _frameTimes.add(totalDuration);
      if (_frameTimes.length > 100) {
        _frameTimes.removeAt(0);
      }
    }
  }

  void _calculateFrameRate() {
    if (_frameTimes.isEmpty) return;

    final avgFrameTime =
        _frameTimes.reduce((a, b) => a + b) / _frameTimes.length;
    final fps = 1000 / avgFrameTime;
    final droppedFrames = _droppedFrameCount;

    _frameCount = 0;
    _droppedFrameCount = 0;

    onStatsUpdate?.call(PerformanceStats(
      fps: fps,
      droppedFrames: droppedFrames,
      avgFrameTime: avgFrameTime,
    ));
  }

  void stopMonitoring() {
    _statsTimer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  static void triggerGC() {
    if (kDebugMode) {
      final temp = List.generate(1000000, (i) => i);
      temp.clear();
    }
  }
}

class PerformanceStats {
  final double fps;
  final int droppedFrames;
  final double avgFrameTime;

  const PerformanceStats({
    required this.fps,
    required this.droppedFrames,
    required this.avgFrameTime,
  });

  bool get isSmooth => fps > 55;
  bool get isAcceptable => fps > 30;
  bool get isPoor => fps <= 30;
}
