import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/utils.dart';

enum SleepTimerState { idle, counting, extending }

class SleepTimerService {
  static SleepTimerService? _instance;
  static SleepTimerService get instance => _instance ??= SleepTimerService._();
  SleepTimerService._();

  Timer? _timer;
  DateTime? _endTime;
  VoidCallback? _onExpired;
  VoidCallback? _onEnterExtending;
  VoidCallback? _onCancelExtending;

  SleepTimerState _state = SleepTimerState.idle;
  final stateNotifier = ValueNotifier<SleepTimerState>(SleepTimerState.idle);
  final remainingNotifier = ValueNotifier<Duration>(Duration.zero);
  final autoExtendNotifier = ValueNotifier<bool>(true);

  SleepTimerState get state => _state;
  bool get isActive => _state != SleepTimerState.idle;
  bool get isExtending => _state == SleepTimerState.extending;

  void setOnExpired(VoidCallback callback) {
    _onExpired = callback;
  }

  void setOnEnterExtending(VoidCallback callback) {
    _onEnterExtending = callback;
  }

  void setOnCancelExtending(VoidCallback callback) {
    _onCancelExtending = callback;
  }

  Duration? get remaining {
    final end = _endTime;
    if (end == null) return null;
    final left = end.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  void start(Duration duration) {
    cancel();
    _endTime = DateTime.now().add(duration);
    _setState(SleepTimerState.counting);
    _updateRemaining();
    showTextOnSnackBar('睡眠定时 ${formatDuration(duration)}');

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = remaining;
      if (left == null || left <= Duration.zero) {
        _timer?.cancel();
        _timer = null;
        if (autoExtendNotifier.value) {
          logger.i('[sleep_timer] expired, entering extending state');
          _setState(SleepTimerState.extending);
          _onEnterExtending?.call();
          showTextOnSnackBar('睡眠定时结束，等待当前歌曲播完');
        } else {
          logger.i('[sleep_timer] expired, pausing playback');
          _setState(SleepTimerState.idle);
          _onExpired?.call();
          showTextOnSnackBar('睡眠定时结束，已暂停播放');
        }
      } else {
        _updateRemaining();
      }
    });
  }

  /// 歌曲自然播完时调用（由 PlaybackService 在 extending 状态下调用）
  void onSongCompleted() {
    if (!isExtending) return;
    logger.i('[sleep_timer] song completed while extending, pausing');
    _cancel();
    _onExpired?.call();
    showTextOnSnackBar('睡眠定时结束，已暂停播放');
  }

  /// 用户手动暂停时调用
  void onManualPause() {
    if (!isExtending) return;
    logger.i('[sleep_timer] manual pause while extending, cancelling');
    _cancel();
  }

  /// 切歌时调用
  void onSongChanged(String newPath) {
    if (!isExtending) return;
    logger.i('[sleep_timer] song changed while extending, cancelling');
    _cancel();
  }

  void cancel() {
    final wasExtending = isExtending;
    _cancel();
    if (wasExtending) _onCancelExtending?.call();
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _endTime = null;
    remainingNotifier.value = Duration.zero;
    _setState(SleepTimerState.idle);
  }

  void _setState(SleepTimerState newState) {
    _state = newState;
    stateNotifier.value = newState;
  }

  void _updateRemaining() {
    final left = remaining;
    remainingNotifier.value = left ?? Duration.zero;
  }

  static String formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '$h时${m.toString().padLeft(2, '0')}分';
    return '$m分${s.toString().padLeft(2, '0')}秒';
  }
}
