import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:pure_music/core/utils.dart';

/// 窗口恢复期排帧诊断。设置环境变量 PURE_MUSIC_FRAME_PROBE=1 才记录，默认关闭。
class WindowFrameProbe {
  WindowFrameProbe._();

  static final bool enabled =
      Platform.environment['PURE_MUSIC_FRAME_PROBE'] == '1';

  static bool _timingsHooked = false;
  static int _frames = 0;
  static String _reason = '';

  static void event(String message) {
    if (!enabled) return;
    log.window.info('legacy', '[probe] $message');
  }

  /// 记录门闩每次判定，串起来就是 framesEnabled 的变化序列。
  static void gate(
    String source, {
    required bool framesEnabled,
    required bool schedulerFramesEnabled,
    required bool trayHidden,
    required bool minimized,
    required bool hasScheduledFrame,
  }) {
    if (!enabled) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState?.name ?? 'null';
    event(
      'gate $source frames=$framesEnabled armed=$schedulerFramesEnabled '
      'tray=$trayHidden min=$minimized pending=$hasScheduledFrame '
      'lifecycle=$lifecycle',
    );
  }

  static void watchdog({
    required int epoch,
    required int currentEpoch,
    required bool minimized,
    required bool stale,
  }) {
    if (!enabled) return;
    event(
      'watchdog minimized=$minimized stale=$stale epoch=$epoch/$currentEpoch '
      'pending=${WidgetsBinding.instance.hasScheduledFrame}',
    );
  }

  /// 从恢复时刻起数 3 秒内真正提交的帧，用来判断「窗口可见但不再排帧」。
  static void countFrames(String reason) {
    if (!enabled) return;
    if (!_timingsHooked) {
      _timingsHooked = true;
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    }
    _frames = 0;
    _reason = reason;
    event('restore begin $reason');
    Timer(const Duration(seconds: 3), () {
      event('restore frames in 3s after $_reason: $_frames');
    });
  }

  static void _onTimings(List<FrameTiming> timings) {
    _frames += timings.length;
  }
}
