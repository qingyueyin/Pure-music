import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/component/hotkey_ui_feedback.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/core/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:go_router/go_router.dart';

class HotkeysHelper {
  static final Map<HotKey, void Function(HotKey)> _hotKeys = {
    HotKey(key: PhysicalKeyboardKey.space, scope: HotKeyScope.inapp): (_) {
      final playbackService = PlayService.instance.playbackService;
      final state = playbackService.playerState;
      if (state == PlayerState.playing) {
        playbackService.pause();
        showHotkeyToast(text: "暂停", icon: Icons.pause);
      } else if (state == PlayerState.completed) {
        playbackService.playAgain();
        showHotkeyToast(text: "重播", icon: Icons.replay);
      } else {
        playbackService.start();
        showHotkeyToast(text: "播放", icon: Icons.play_arrow);
      }
    },
    HotKey(key: PhysicalKeyboardKey.escape, scope: HotKeyScope.inapp):
        (_) async {
      final routerContext = ROUTER_KEY.currentContext;
      if (routerContext == null) return;

      if (ImmersiveModeController.instance.enabled) {
        await ImmersiveModeController.instance.exit();
        final startIndex = AppPreference.instance.startPage
            .clamp(0, app_paths.START_PAGES.length - 1);
        GoRouter.of(routerContext).go(app_paths.START_PAGES[startIndex]);
        return;
      }

      // 先关闭弹窗，再返回上一级页面
      final navigator = Navigator.maybeOf(routerContext);
      if (navigator?.canPop() == true) {
        navigator?.pop();
      } else if (ROUTER_KEY.currentContext?.canPop() == true) {
        ROUTER_KEY.currentContext?.pop();
      }
    },
    HotKey(
      key: PhysicalKeyboardKey.arrowLeft,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    ): (_) {
      PlayService.instance.playbackService.lastAudio();
      HOTKEY_UI_FEEDBACK.emit(HotkeyUiAction.prev);
      showHotkeyToast(text: "上一曲", icon: Icons.skip_previous);
    },
    HotKey(
      key: PhysicalKeyboardKey.arrowRight,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    ): (_) {
      PlayService.instance.playbackService.nextAudio();
      HOTKEY_UI_FEEDBACK.emit(HotkeyUiAction.next);
      showHotkeyToast(text: "下一曲", icon: Icons.skip_next);
    },
    HotKey(
      key: PhysicalKeyboardKey.arrowUp,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    ): (_) {
      final playbackService = PlayService.instance.playbackService;
      final next = (playbackService.volumeDsp + 0.05).clamp(0.0, 1.0);
      playbackService.setVolumeDsp(next);
      HOTKEY_UI_FEEDBACK.emit(HotkeyUiAction.volumeStep);
      showHotkeyToast(
        text: "应用音量：${(next * 100).round()}%",
        icon: Icons.volume_up,
      );
    },
    HotKey(
      key: PhysicalKeyboardKey.arrowDown,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    ): (_) {
      final playbackService = PlayService.instance.playbackService;
      final next = (playbackService.volumeDsp - 0.05).clamp(0.0, 1.0);
      playbackService.setVolumeDsp(next);
      HOTKEY_UI_FEEDBACK.emit(HotkeyUiAction.volumeStep);
      showHotkeyToast(
        text: "应用音量：${(next * 100).round()}%",
        icon: Icons.volume_down,
      );
    },
    HotKey(key: PhysicalKeyboardKey.f1, scope: HotKeyScope.inapp): (_) async {
      await ImmersiveModeController.instance.toggle();
      showHotkeyToast(
        text: "沉浸：${ImmersiveModeController.instance.enabled ? "开" : "关"}",
        icon: Icons.fullscreen,
      );
    },
  };

  static void registerHotKeys() {
    for (var item in _hotKeys.entries) {
      hotKeyManager.register(
        item.key,
        keyDownHandler: item.value,
      );
    }
  }

  static Future<void> unregisterAll() => hotKeyManager.unregisterAll();

  static Future<void> onFocusChanges(focus) async {
    if (focus) {
      await unregisterAll();
    } else {
      registerHotKeys();
    }
  }
}
