import 'package:pure_music/core/hotkey_binding.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/component/hotkey_ui_feedback.dart';
import 'package:pure_music/core/hotkey_focus_state.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/services/concert_session.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/now_playing_page/component/sleep_timer_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

class HotkeysHelper {
  static final List<HotKey> _systemKeys = [];
  static bool _windowToggleInProgress = false;
  static bool _inAppHandlerAttached = false;

  static bool _canHandlePlaybackHotkey() => canHandleInAppPlaybackHotkey(
    textInputFocused: isTextInputFocusedForHotkeys(),
  );

  static String inAppLabel(HotkeyAction action) =>
      (AppSettings.instance.inAppHotkeys[action] ?? defaultInAppBinding(action))
          .label;

  static Future<void> registerHotKeys() async {
    await _registerInApp();
    await _registerSystem();
  }

  static Future<void> reload() async {
    await unregisterAll();
    await registerHotKeys();
  }

  static Future<void> unregisterAll() async {
    await _unregisterInApp();
    await _unregisterSystem();
  }

  /// 输入框焦点改由按键处理时判断，这里不再卸载快捷键。
  static Future<void> onFocusChanges(bool _) async {}

  static Future<void> pauseForRecording() async {
    await _unregisterInApp();
    await _unregisterSystem();
  }

  static Future<void> resumeAfterRecording() async {
    await _registerInApp();
    await _registerSystem();
  }

  static Future<void> _registerInApp() async {
    if (_inAppHandlerAttached) return;
    HardwareKeyboard.instance.addHandler(_onInAppKey);
    _inAppHandlerAttached = true;
  }

  static Future<void> _unregisterInApp() async {
    if (!_inAppHandlerAttached) return;
    HardwareKeyboard.instance.removeHandler(_onInAppKey);
    _inAppHandlerAttached = false;
  }

  static bool _onInAppKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (isTextInputFocusedForHotkeys()) return false;

    final pressed = HardwareKeyboard.instance.physicalKeysPressed;
    final pressedModifiers = {
      for (final modifier in HotKeyModifier.values)
        if (modifier.physicalKeys.any(pressed.contains)) modifier,
    };

    final bindings = AppSettings.instance.inAppHotkeys;
    for (final action in inAppHotkeyActions) {
      final binding = bindings[action] ?? defaultInAppBinding(action);
      if (!binding.matchesPressed(
        key: event.physicalKey,
        pressedModifiers: pressedModifiers,
      )) {
        continue;
      }
      _handle(action, isGlobal: false);
      return true;
    }
    return false;
  }

  static Future<void> _registerSystem() async {
    if (_systemKeys.isNotEmpty) return;
    if (!AppSettings.instance.globalHotkeysEnabled) return;
    final bindings = AppSettings.instance.globalHotkeys;
    for (final action in globalHotkeyActions) {
      final binding = bindings[action] ?? HotkeyBinding.unbound;
      final hotKey = binding.toHotKey(
        scope: HotKeyScope.system,
        identifier: 'global.${action.name}',
      );
      if (hotKey == null) continue;
      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (_) => _handle(action, isGlobal: true),
      );
      _systemKeys.add(hotKey);
    }
  }

  static Future<void> _unregisterSystem() async {
    for (final key in _systemKeys) {
      await hotKeyManager.unregister(key);
    }
    _systemKeys.clear();
  }

  static void _handle(HotkeyAction action, {required bool isGlobal}) {
    if (!isGlobal &&
        action != HotkeyAction.escape &&
        action != HotkeyAction.fullscreen &&
        !_canHandlePlaybackHotkey()) {
      return;
    }
    switch (action) {
      case HotkeyAction.playPause:
        _togglePlayback();
      case HotkeyAction.previous:
        _skipPrevious();
      case HotkeyAction.next:
        _skipNext();
      case HotkeyAction.volumeUp:
        _changeVolume(0.05);
      case HotkeyAction.volumeDown:
        _changeVolume(-0.05);
      case HotkeyAction.shuffle:
        _toggleShuffle();
      case HotkeyAction.desktopLyric:
        _toggleDesktopLyric();
      case HotkeyAction.sleepTimer:
        _openSleepTimer();
      case HotkeyAction.immersive:
        _toggleImmersive();
      case HotkeyAction.fullscreen:
        _toggleFullscreen();
      case HotkeyAction.escape:
        _handleEscape();
    }
  }

  static void _togglePlayback() {
    final playbackService = PlayService.existingPlaybackService;
    if (playbackService == null) return;
    final state = playbackService.playerState;
    if (state == PlayerState.playing) {
      playbackService.pause();
      showHotkeyToast(text: '暂停', icon: Icons.pause);
    } else if (state == PlayerState.completed) {
      playbackService.playAgain();
      showHotkeyToast(text: '重播', icon: Icons.replay);
    } else {
      playbackService.start();
      showHotkeyToast(text: '播放', icon: Icons.play_arrow);
    }
  }

  static void _skipPrevious() {
    final playbackService = PlayService.existingPlaybackService;
    if (playbackService == null) return;
    playbackService.lastAudio();
    hotkeyUiFeedback.emit(HotkeyUiAction.prev);
    showHotkeyToast(text: '上一曲', icon: Icons.skip_previous);
  }

  static void _skipNext() {
    final playbackService = PlayService.existingPlaybackService;
    if (playbackService == null) return;
    playbackService.nextAudio();
    hotkeyUiFeedback.emit(HotkeyUiAction.next);
    showHotkeyToast(text: '下一曲', icon: Icons.skip_next);
  }

  static void _changeVolume(double delta) {
    final playbackService = PlayService.existingPlaybackService;
    if (playbackService == null) return;
    final next = (playbackService.volumeDsp + delta).clamp(0.0, 1.0);
    playbackService.setVolumeDsp(next);
    hotkeyUiFeedback.emit(HotkeyUiAction.volumeStep);
    showHotkeyToast(
      text: '应用音量：${(next * 100).round()}%',
      icon: delta > 0 ? Icons.volume_up : Icons.volume_down,
    );
  }

  static void _toggleShuffle() {
    final playbackService = PlayService.existingPlaybackService;
    if (playbackService == null) return;
    if (playbackService.nowPlaying == null) {
      showHotkeyToast(text: '没有正在播放的歌曲', icon: Icons.shuffle);
      return;
    }
    // 演出模式靠固定队列推进，期间不接受切换随机
    if (ConcertSession.instance.isActive) {
      showHotkeyToast(text: '有处于演出模式，不要切换啦', icon: Icons.shuffle);
      return;
    }
    final enabled = !playbackService.shuffle.value;
    playbackService.useShuffle(enabled);
    showHotkeyToast(
      text: enabled ? '随机：开' : '随机：关',
      icon: Icons.shuffle,
    );
  }

  static Future<void> _toggleDesktopLyric() async {
    if (!PlayService.isInitialized) return;
    final desktopLyric = PlayService.instance.desktopLyricService;
    if (desktopLyric.isRunning) {
      await desktopLyric.killDesktopLyric();
      showHotkeyToast(text: '桌面歌词：关', icon: Icons.lyrics_outlined);
    } else {
      await desktopLyric.startDesktopLyric();
      showHotkeyToast(text: '桌面歌词：开', icon: Icons.lyrics);
    }
  }

  static void _openSleepTimer() {
    final context = routerKey.currentContext;
    if (context == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => const SleepTimerDialog(),
    );
  }

  static Future<void> _toggleImmersive() async {
    await ImmersiveModeController.instance.toggle();
    showHotkeyToast(
      text: "沉浸：${ImmersiveModeController.instance.enabled ? "开" : "关"}",
      icon: Icons.fullscreen,
    );
  }

  static Future<void> _toggleFullscreen() async {
    if (_windowToggleInProgress) return;
    _windowToggleInProgress = true;
    try {
      final isFullScreen = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!isFullScreen);
      showHotkeyToast(
        text: isFullScreen ? '退出全屏' : '全屏',
        icon: isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
      );
    } catch (err, trace) {
      log.hotkey.error('legacy', '全屏切换失败', error: err, stackTrace: trace);
    } finally {
      _windowToggleInProgress = false;
    }
  }

  static Future<void> _handleEscape() async {
    final routerContext = routerKey.currentContext;
    if (routerContext == null) return;

    final router = GoRouter.of(routerContext);
    if (ImmersiveModeController.instance.enabled) {
      await ImmersiveModeController.instance.exit();
      final startIndex = AppPreference.instance.startPage.clamp(
        0,
        app_paths.START_PAGES.length - 1,
      );
      router.go(app_paths.START_PAGES[startIndex]);
      return;
    }

    final navigator = Navigator.maybeOf(routerContext);
    if (navigator?.canPop() == true) {
      navigator?.pop();
    } else if (routerKey.currentContext?.canPop() == true) {
      routerKey.currentContext?.pop();
    }
  }
}
