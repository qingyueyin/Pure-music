import 'dart:async';

import 'package:flutter/widgets.dart';

/// 窗口状态：前台、后台（失去焦点但窗口仍在）、最小化、托盘。
enum WindowRenderState {
  foreground,
  background,
  minimized,
  tray;

  /// 前台和后台都继续绘制；最小化和托盘停画。
  bool get keepsFrames => this == foreground || this == background;
}

WindowRenderState windowRenderStateFor({
  required bool trayHidden,
  required bool windowMinimized,
  required bool windowFocused,
}) {
  if (trayHidden) return WindowRenderState.tray;
  if (windowMinimized) return WindowRenderState.minimized;
  return windowFocused
      ? WindowRenderState.foreground
      : WindowRenderState.background;
}

/// 只有主窗口还看得见时才持续绘制。失去焦点但窗口仍在屏幕上时不冻结。
bool windowRenderShouldEnableFrames({
  required bool trayHidden,
  bool windowMinimized = false,
}) => !trayHidden && !windowMinimized;

bool shouldAcceptLyricUiUpdate({required bool windowFramesEnabled}) =>
    windowFramesEnabled;

void applyWindowSchedulerFrames(bool enabled) {
  // 不把生命周期改成 hidden，那会让回来的窗口点不动。
  // 停绘制靠卸掉背景和停掉不计 TickerMode 的动画。
  if (!enabled) return;
  final binding = WidgetsBinding.instance;
  if (binding.lifecycleState == AppLifecycleState.hidden ||
      binding.lifecycleState == AppLifecycleState.paused) {
    // ignore: invalid_use_of_protected_member
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
  binding.scheduleFrame();
}

class WindowRenderGate with WidgetsBindingObserver {
  WindowRenderGate({void Function(bool enabled)? applyFramesEnabled})
    : _applyFramesEnabled = applyFramesEnabled ?? applyWindowSchedulerFrames;

  static final instance = WindowRenderGate();

  final void Function(bool enabled) _applyFramesEnabled;
  final ValueNotifier<bool> framesEnabled = ValueNotifier(true);

  /// 只有真正藏进托盘才为 true。最小化不算，界面还留着。
  final ValueNotifier<bool> trayHidden = ValueNotifier(false);

  bool _trayHidden = false;
  bool _windowMinimized = false;
  bool _windowFocused = true;
  bool _schedulerFramesEnabled = true;
  bool _pauseScheduled = false;
  bool _attached = false;

  WindowRenderState get state => windowRenderStateFor(
    trayHidden: _trayHidden,
    windowMinimized: _windowMinimized,
    windowFocused: _windowFocused,
  );

  bool get shouldRender => state.keepsFrames;

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
    if (trayHidden.value != hidden) trayHidden.value = hidden;
    _sync();
  }

  void setWindowMinimized(bool minimized) {
    if (_windowMinimized == minimized) return;
    _windowMinimized = minimized;
    _sync();
  }

  /// 主窗口只要还在桌面上，就必须回到前台。
  void enterForeground() {
    final changed = _trayHidden || _windowMinimized;
    if (!changed) return;
    _trayHidden = false;
    _windowMinimized = false;
    if (trayHidden.value) trayHidden.value = false;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 只记录焦点：后台照常绘制，不停帧。
    _windowFocused = state == AppLifecycleState.resumed;
    switch (state) {
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        // 最小化或托盘时，系统焦点变化不能把窗口当成已经回到桌面。
        if (_trayHidden || _windowMinimized) return;
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
    // 这一帧画完再停调度。声音在原生播放线程，不靠这些帧。
    if (_schedulerFramesEnabled == false || _pauseScheduled) return;
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
