import 'dart:async';

import 'package:flutter/widgets.dart';

/// 前台：主窗口在桌面上（含失焦、最小化到任务栏）。
/// 后台：只有「关闭主窗口，隐藏到通知区」这一条路径。
bool windowRenderShouldEnableFrames({required bool trayHidden}) => !trayHidden;

bool shouldAcceptLyricUiUpdate({required bool windowFramesEnabled}) =>
    windowFramesEnabled;

void applyWindowSchedulerFrames(bool enabled) {
  final binding = WidgetsBinding.instance;
  final next = enabled ? AppLifecycleState.resumed : AppLifecycleState.hidden;
  if (binding.lifecycleState == next) return;
  // ignore: invalid_use_of_protected_member
  binding.handleAppLifecycleStateChanged(next);
}

class WindowRenderGate with WidgetsBindingObserver {
  WindowRenderGate({void Function(bool enabled)? applyFramesEnabled})
    : _applyFramesEnabled = applyFramesEnabled ?? applyWindowSchedulerFrames;

  static final instance = WindowRenderGate();

  final void Function(bool enabled) _applyFramesEnabled;
  final ValueNotifier<bool> framesEnabled = ValueNotifier(true);

  bool _trayHidden = false;
  bool _schedulerFramesEnabled = true;
  bool _pauseScheduled = false;
  bool _attached = false;

  bool get shouldRender =>
      windowRenderShouldEnableFrames(trayHidden: _trayHidden);

  void attach() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// 仅由隐藏到托盘 / 重新显示主窗口调用。
  void setTrayHidden(bool hidden) {
    if (_trayHidden == hidden) return;
    _trayHidden = hidden;
    _sync();
  }

  /// 主窗口只要还在桌面上，就必须回到前台。
  void enterForeground() {
    setTrayHidden(false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        enterForeground();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _sync() {
    final enabled = shouldRender;
    if (enabled) {
      _pauseScheduled = false;
      if (!_schedulerFramesEnabled) {
        _applyFramesEnabled(true);
        _schedulerFramesEnabled = true;
      }
      if (!framesEnabled.value) {
        framesEnabled.value = true;
      }
      return;
    }

    if (framesEnabled.value) {
      framesEnabled.value = false;
    }
    if (!_schedulerFramesEnabled || _pauseScheduled) return;
    _pauseScheduled = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _pauseScheduled = false;
      if (shouldRender || !_schedulerFramesEnabled) return;
      _applyFramesEnabled(false);
      _schedulerFramesEnabled = false;
    });
    if (!binding.hasScheduledFrame) {
      binding.scheduleFrame();
    }
  }

  Future<void> waitForWarmup({
    Duration timeout = const Duration(milliseconds: 64),
  }) async {
    if (!shouldRender) return;
    final binding = WidgetsBinding.instance;
    binding.scheduleWarmUpFrame();
    try {
      await binding.endOfFrame.timeout(timeout);
    } on TimeoutException {
      return;
    }
  }
}
