import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/core/window_frame_probe.dart';
import 'package:pure_music/core/window_occlusion.dart';

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

/// 被挡住太久（backgroundIdle）时连歌词、封面、进度这些 ticker 一起停；
/// 最小化/托盘由 framesEnabled 负责，调整窗口大小由 resizing 负责。
bool windowTickersEnabled({
  required bool resizing,
  required bool framesEnabled,
  required bool backgroundIdle,
}) => !resizing && framesEnabled && !backgroundIdle;

bool shouldAcceptLyricUiUpdate({required bool windowFramesEnabled}) =>
    windowFramesEnabled;

typedef WindowFramesApplier = void Function(bool enabled, {bool force});

void applyWindowSchedulerFrames(bool enabled, {bool force = false}) {
  // 不把生命周期改成 hidden，那会让回来的窗口点不动。
  // 停绘制靠卸掉背景和停掉不计 TickerMode 的动画。
  if (!enabled) return;
  final binding = WidgetsBinding.instance;
  if (binding.lifecycleState == AppLifecycleState.hidden ||
      binding.lifecycleState == AppLifecycleState.paused) {
    // ignore: invalid_use_of_protected_member
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
  if (force && binding.hasScheduledFrame) {
    // 上一次请求可能已经在窗口还不可见时被平台丢掉，_hasScheduledFrame 却还挂着。
    // 自驱帧会复位这个标记，否则窗口可见后也不会再排帧。
    binding.scheduleWarmUpFrame();
    return;
  }
  binding.scheduleFrame();
}

class WindowRenderGate with WidgetsBindingObserver {
  WindowRenderGate({WindowFramesApplier? applyFramesEnabled})
    : _applyFramesEnabled = applyFramesEnabled ?? applyWindowSchedulerFrames;

  static final instance = WindowRenderGate();

  final WindowFramesApplier _applyFramesEnabled;
  final ValueNotifier<bool> framesEnabled = ValueNotifier(true);

  /// 只有真正藏进托盘才为 true。最小化不算，界面还留着。
  final ValueNotifier<bool> trayHidden = ValueNotifier(false);

  /// 失焦 30 秒后确认前台窗口真把本窗口完全盖住才为 true，
  /// 装饰动画停掉、缓存做一次温和裁剪；前台窗口移开或回焦点立刻复位。
  final ValueNotifier<bool> backgroundIdle = ValueNotifier(false);

  bool _trayHidden = false;
  bool _windowMinimized = false;
  bool _windowFocused = true;
  bool _schedulerFramesEnabled = true;
  bool _pauseScheduled = false;
  bool _attached = false;
  Timer? _backgroundIdleTimer;

  static const _backgroundIdleDelay = Duration(seconds: 30);
  static const _backgroundIdleRecheck = Duration(seconds: 15);

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
    _backgroundIdleTimer?.cancel();
    _backgroundIdleTimer = null;
  }

  /// 仅由隐藏到托盘 / 重新显示主窗口调用。
  void setTrayHidden(bool hidden) {
    if (_trayHidden == hidden) return;
    _trayHidden = hidden;
    if (trayHidden.value != hidden) trayHidden.value = hidden;
    if (!hidden) WindowFrameProbe.countFrames('trayHidden:false');
    _syncBackgroundIdle();
    _sync(forceFrame: !hidden);
  }

  void setWindowMinimized(bool minimized) {
    if (_windowMinimized == minimized) return;
    _windowMinimized = minimized;
    if (!minimized) WindowFrameProbe.countFrames('minimized:false');
    _syncBackgroundIdle();
    _sync(forceFrame: !minimized);
  }

  /// 主窗口只要还在桌面上，就必须回到前台。
  void enterForeground() {
    final wasHidden = _trayHidden || _windowMinimized || trayHidden.value;
    _trayHidden = false;
    _windowMinimized = false;
    if (trayHidden.value) trayHidden.value = false;
    if (wasHidden) WindowFrameProbe.countFrames('enterForeground');
    _sync(forceFrame: wasHidden);
  }

  /// 原生 blur/focus 事件：window_manager 的 WM_NCACTIVATE 比框架
  /// AppLifecycle 更准更快，用它驱动 backgroundIdle 计时。
  void setWindowFocused(bool focused) {
    final changed = _windowFocused != focused;
    _windowFocused = focused;
    if (changed) {
      log.window.info(
        'legacy',
        '[focus] ${focused ? 'foreground' : 'background'}',
      );
    }
    // 值没变也要重新核对：托盘/最小化恢复后可能停在 false，
    // 只靠变化回调会永远起不来闲时计时。
    if (changed || !focused) _syncBackgroundIdle();
  }

  /// 窗口真正可见后调用：清掉所有隐藏标记，并强制复位排帧门闩。
  /// 系统事件可能漏发，恢复路径必须以真实窗口状态为准。
  void resumeVisible() {
    final wasHidden = _trayHidden || _windowMinimized || trayHidden.value;
    _trayHidden = false;
    _windowMinimized = false;
    if (trayHidden.value) trayHidden.value = false;
    if (wasHidden) WindowFrameProbe.countFrames('resumeVisible');
    _sync(forceFrame: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    log.window.info('legacy', '[focus] lifecycle=${state.name}');
    // 焦点只由原生 blur/focus 和 watchdog 驱动；AppLifecycle 在 Windows 上
    // 对失焦判定含糊，resumed 会把被挡住时的 idle 计时取消。
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

  /// 失焦且窗口仍在桌面时启动 30 秒计时，到点确认是否真被盖住；
  /// 焦点回来或窗口隐藏立即取消。
  /// 从闲时恢复时必须主动排一帧：闲时装饰动画全停，引擎可能没有任何
  /// 在途帧，只改状态不排帧画面就停在旧帧上，看起来像卡死。
  void _syncBackgroundIdle() {
    final shouldCount = !_windowFocused && !_trayHidden && !_windowMinimized;
    if (!shouldCount) {
      final hadTimer = _backgroundIdleTimer != null;
      _backgroundIdleTimer?.cancel();
      _backgroundIdleTimer = null;
      if (hadTimer) {
        log.window.info(
          'legacy',
          '[focus] idle-timer cancel focused=$_windowFocused '
          'tray=$_trayHidden min=$_windowMinimized',
        );
      }
      if (backgroundIdle.value) {
        backgroundIdle.value = false;
        if (shouldRender && !WidgetsBinding.instance.hasScheduledFrame) {
          WidgetsBinding.instance.scheduleFrame();
        }
      }
      return;
    }
    if (_backgroundIdleTimer != null) return;
    log.window.info('legacy', '[focus] idle-timer start');
    _backgroundIdleTimer = Timer(_backgroundIdleDelay, _checkBackgroundIdle);
  }

  Future<void> _checkBackgroundIdle() async {
    _backgroundIdleTimer = null;
    if (!_attached || _windowFocused || _trayHidden || _windowMinimized) {
      return;
    }
    final covered = await isWindowCoveredByForeground();
    if (!_attached || _windowFocused || _trayHidden || _windowMinimized) {
      return;
    }
    if (covered != backgroundIdle.value) {
      backgroundIdle.value = covered;
      log.window.info(
        'legacy',
        '[focus] idle=$covered focused=$_windowFocused '
        'tray=$_trayHidden min=$_windowMinimized',
      );
      if (!covered &&
          shouldRender &&
          !WidgetsBinding.instance.hasScheduledFrame) {
        WidgetsBinding.instance.scheduleFrame();
      }
    }
    // 遮挡状态变化不一定再给焦点事件，继续复查；露出后立即恢复渲染。
    _backgroundIdleTimer = Timer(_backgroundIdleRecheck, _checkBackgroundIdle);
  }

  void _sync({bool forceFrame = false}) {
    final enabled = shouldRender;
    if (enabled) {
      _pauseScheduled = false;
      _schedulerFramesEnabled = true;
      if (!framesEnabled.value) {
        framesEnabled.value = true;
      }
      _applyFramesEnabled(true, force: forceFrame);
      WindowFrameProbe.gate(
        'enable',
        framesEnabled: framesEnabled.value,
        schedulerFramesEnabled: _schedulerFramesEnabled,
        trayHidden: _trayHidden,
        minimized: _windowMinimized,
        hasScheduledFrame: WidgetsBinding.instance.hasScheduledFrame,
      );
      return;
    }

    if (framesEnabled.value) {
      framesEnabled.value = false;
    }
    WindowFrameProbe.gate(
      'disable',
      framesEnabled: framesEnabled.value,
      schedulerFramesEnabled: _schedulerFramesEnabled,
      trayHidden: _trayHidden,
      minimized: _windowMinimized,
      hasScheduledFrame: WidgetsBinding.instance.hasScheduledFrame,
    );
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
