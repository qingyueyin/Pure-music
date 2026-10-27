import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/memory_monitor.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/sleep_blocker.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_render_gate.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/services/concert_session.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:go_router/go_router.dart';

class WindowLifecycleService with WindowListener, TrayListener {
  WindowLifecycleService._();

  static final instance = WindowLifecycleService._();

  bool _initialized = false;
  bool _isExiting = false;
  bool _closeRequestPending = false;
  bool _libraryReady = false;
  bool _trayReady = false;
  bool _playbackListenersBound = false;
  bool _desktopLyricListenersBound = false;
  Timer? _bindRetryTimer;
  Future<void> _trayOperation = Future<void>.value();
  Future<void> Function()? _disposeRuntimeResources;

  bool get isExiting => _isExiting;

  /// 关闭选择变了之后，设置页靠这个刷新，不用整页重开。
  final ValueNotifier<int> closeChoiceRevision = ValueNotifier<int>(0);

  Future<void> init({Future<void> Function()? disposeRuntimeResources}) async {
    _disposeRuntimeResources = disposeRuntimeResources;
    if (_initialized) return;
    _initialized = true;
    windowManager.addListener(this);
    trayManager.addListener(this);
    WindowRenderGate.instance.attach();
    await syncTrayIcon();
  }

  void markLibraryReady() {
    _libraryReady = true;
  }

  Future<bool> syncTrayIcon() async {
    final enabled =
        AppSettings.instance.windowCloseBehavior ==
        WindowCloseBehavior.minimizeToTray;
    final result = Completer<bool>();
    _trayOperation = _trayOperation.catchError((_) {}).then((_) async {
      try {
        result.complete(await _syncTrayIcon(enabled: enabled));
      } catch (error, trace) {
        log.window.warn('legacy', 'Syncing tray icon failed: $error', stackTrace: trace);
        result.complete(false);
      }
    });
    return result.future;
  }

  void _bindPlaybackListenersIfAvailable() {
    if (_playbackListenersBound) return;
    final playback = PlayService.existingPlaybackService;
    if (playback == null) {
      _scheduleBindRetry();
      return;
    }
    _playbackListenersBound = true;
    playback.nowPlayingNotifier.addListener(_refreshTrayContent);
    playback.playerStateNotifier.addListener(_refreshTrayContent);
    playback.shuffle.addListener(_refreshTrayContent);
    playback.playMode.addListener(_refreshTrayContent);
    ConcertSession.instance.addListener(_refreshTrayContent);
  }

  void _scheduleBindRetry() {
    if (_bindRetryTimer != null) return;
    _bindRetryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isExiting || !_trayReady) {
        _bindRetryTimer?.cancel();
        _bindRetryTimer = null;
        return;
      }
      final playback = PlayService.existingPlaybackService;
      if (playback == null) return;
      _bindRetryTimer?.cancel();
      _bindRetryTimer = null;
      _bindPlaybackListenersIfAvailable();
      _refreshTrayContent();
    });
  }

  void _bindDesktopLyricListenersIfAvailable() {
    if (_desktopLyricListenersBound) return;
    final desktopLyric = PlayService.existingDesktopLyricService;
    if (desktopLyric == null) return;
    _desktopLyricListenersBound = true;
    desktopLyric.addListener(_refreshTrayContent);
  }

  String _trayModeText(bool shuffle, PlayMode? playMode) {
    return switch (true) {
      _ when shuffle => '随机播放',
      _ when playMode == PlayMode.singleLoop => '单曲循环',
      _ when playMode == PlayMode.listOnce => '顺序播放',
      _ => '列表循环',
    };
  }

  String _trayStatusText(Audio? nowPlaying) {
    if (nowPlaying == null) {
      return '未在播放';
    }
    return '${nowPlaying.title} - ${nowPlaying.artist}';
  }

  String _trayToolTip(bool hasSession, String statusText) {
    if (!hasSession) return 'Pure Music';
    if (statusText.length <= 127) return statusText;
    return '${statusText.substring(0, 126)}…';
  }

  Menu _trayMenu({
    required String statusText,
    required bool hasSession,
    required bool isPlaying,
    required bool desktopLyricRunning,
    required bool desktopLyricLocked,
    required String modeText,
    required bool concertLocked,
  }) {
    return Menu(
      items: [
      MenuItem(key: 'now_playing', label: statusText, disabled: !hasSession),
      MenuItem.separator(),
      MenuItem(key: 'show_window', label: '显示主窗口'),
      MenuItem(
        key: 'toggle_desktop_lyric',
        label: desktopLyricRunning ? '关闭桌面歌词' : '打开桌面歌词',
      ),
      if (desktopLyricRunning && desktopLyricLocked)
        MenuItem(key: 'unlock_desktop_lyric', label: '解锁桌面歌词'),
      MenuItem(
        key: 'cycle_play_mode',
        label: '播放模式：$modeText',
        // 演出模式靠固定队列推进，期间不接受切换播放顺序
        disabled: !hasSession || concertLocked,
      ),
      MenuItem(key: 'prev', label: '上一曲', disabled: !hasSession),
      MenuItem(
        key: 'play_pause',
        label: isPlaying ? '暂停' : '播放',
        disabled: !hasSession,
      ),
      MenuItem(key: 'next', label: '下一曲', disabled: !hasSession),
      MenuItem.separator(),
      MenuItem(key: 'exit_app', label: '退出'),
      ],
    );
  }

  void _refreshTrayContent({bool popUpMenu = false}) {
    _bindPlaybackListenersIfAvailable();
    _bindDesktopLyricListenersIfAvailable();
    final playback = PlayService.existingPlaybackService;
    final nowPlaying = playback?.nowPlaying;
    final hasSession = nowPlaying != null;
    final isPlaying = playback?.playerState == PlayerState.playing;
    final desktopLyric = PlayService.existingDesktopLyricService;
    final desktopLyricRunning = desktopLyric?.isRunning ?? false;
    final desktopLyricLocked = desktopLyric?.isLocked ?? false;
    final statusText = _trayStatusText(nowPlaying);
    final modeText = _trayModeText(
      playback?.shuffle.value ?? false,
      playback?.playMode.value,
    );
    final toolTip = _trayToolTip(hasSession, statusText);
    final menu = _trayMenu(
      statusText: statusText,
      hasSession: hasSession,
      isPlaying: isPlaying,
      desktopLyricRunning: desktopLyricRunning,
      desktopLyricLocked: desktopLyricLocked,
      modeText: modeText,
      concertLocked: ConcertSession.instance.isActive,
    );
    _trayOperation = _trayOperation.catchError((_) {}).then((_) async {
      try {
        await trayManager.setToolTip(toolTip);
        await trayManager.setContextMenu(menu);
      } catch (error, trace) {
        log.window.warn('legacy', 'Updating tray content failed: $error', stackTrace: trace);
      }
      // 独立 try 保证菜单一定会弹出，否则插件侧 menu_visible 不会复位
      if (popUpMenu) {
        try {
          await trayManager.popUpContextMenu();
        } catch (error, trace) {
          log.window.warn('legacy', 'Popping up tray menu failed: $error', stackTrace: trace);
        }
      }
    });
  }

  Future<bool> _syncTrayIcon({required bool enabled}) async {
    if (!enabled) {
      try {
        if (_trayReady) {
          await trayManager.destroy();
          _trayReady = false;
        }
        return true;
      } catch (error, trace) {
        log.window.warn('legacy', 'Removing tray icon failed: $error', stackTrace: trace);
        return false;
      }
    }

    try {
      await trayManager.setIcon('app_icon.ico');
      _refreshTrayContent();
      _trayReady = true;
      return true;
    } catch (error, trace) {
      _trayReady = false;
      log.window.warn('legacy', 'Creating tray icon failed: $error', stackTrace: trace);
      try {
        await trayManager.destroy();
      } catch (cleanupError, cleanupTrace) {
        log.window.warn('legacy', 'Cleaning up tray icon failed: $cleanupError', stackTrace: cleanupTrace,);
      }
      return false;
    }
  }

  Future<void> requestClose() async {
    if (_isExiting || _closeRequestPending) return;
    _closeRequestPending = true;
    try {
      if (!AppSettings.instance.windowCloseBehaviorChosen) {
        final prompt = _promptCloseBehavior();
        if (prompt != null) {
          final WindowCloseBehavior? choice;
          try {
            choice = await prompt;
          } catch (error, trace) {
            log.window.warn('legacy', 'Close choice dialog failed: $error', stackTrace: trace);
            return;
          }
          // 取消就留在窗口里，下次再问。没有界面可弹时不会进这里，沿用已保存的行为。
          if (_isExiting || choice == null) return;
          final saved = await _rememberCloseBehavior(choice);
          if (!saved || _isExiting) return;
        }
      }
      if (AppSettings.instance.windowCloseBehavior ==
          WindowCloseBehavior.minimizeToTray) {
        final trayReady = await syncTrayIcon();
        if (_isExiting) return;
        if (trayReady &&
            AppSettings.instance.windowCloseBehavior ==
                WindowCloseBehavior.minimizeToTray) {
          if (await _hideToTray()) return;
        }
      }
      await exitApp();
    } finally {
      _closeRequestPending = false;
    }
  }

  Future<WindowCloseBehavior?>? _promptCloseBehavior() {
    final context = routerKey.currentContext;
    if (context == null || !context.mounted) return null;
    return showDialog<WindowCloseBehavior>(
      context: context,
      builder: (context) => const _CloseChoiceDialog(),
    );
  }

  Future<bool> _rememberCloseBehavior(WindowCloseBehavior behavior) async {
    final settings = AppSettings.instance;
    final previous = settings.windowCloseBehavior;
    final previousChosen = settings.windowCloseBehaviorChosen;
    settings.windowCloseBehavior = behavior;
    settings.windowCloseBehaviorChosen = true;
    final trayUpdated = await syncTrayIcon();
    if (!trayUpdated && behavior == WindowCloseBehavior.minimizeToTray) {
      settings.windowCloseBehavior = previous;
      settings.windowCloseBehaviorChosen = previousChosen;
      await syncTrayIcon();
      showTextOnSnackBar('通知区初始化失败', variant: ToastVariant.error);
      return false;
    }
    if (!await settings.saveSettings()) {
      settings.windowCloseBehavior = previous;
      settings.windowCloseBehaviorChosen = previousChosen;
      await syncTrayIcon();
      showTextOnSnackBar('关闭行为保存失败', variant: ToastVariant.error);
      return false;
    }
    closeChoiceRevision.value++;
    return true;
  }

  void _cyclePlayMode() {
    final playback = PlayService.instance.playbackService;
    final shuffle = playback.shuffle.value;
    final playMode = playback.playMode.value;
    if (shuffle) {
      playback.useShuffle(false);
      playback.setPlayMode(PlayMode.forward);
    } else {
      switch (playMode) {
        case PlayMode.forward:
        case PlayMode.loop:
          playback.setPlayMode(PlayMode.listOnce);
          break;
        case PlayMode.listOnce:
          playback.setPlayMode(PlayMode.singleLoop);
          break;
        case PlayMode.singleLoop:
          playback.useShuffle(true);
          break;
      }
    }
  }

  Future<bool> _hideToTray() async {
    await AppSettings.instance.saveSettings();
    if (_isExiting ||
        AppSettings.instance.windowCloseBehavior !=
            WindowCloseBehavior.minimizeToTray) {
      return false;
    }
    final trayReady = await syncTrayIcon();
    if (_isExiting ||
        !trayReady ||
        AppSettings.instance.windowCloseBehavior !=
            WindowCloseBehavior.minimizeToTray) {
      return false;
    }
    // 只隐藏并停绘制，播放和系统媒体心跳继续。
    await windowManager.hide();
    if (_isExiting ||
        AppSettings.instance.windowCloseBehavior !=
            WindowCloseBehavior.minimizeToTray) {
      return false;
    }
    WindowRenderGate.instance.setTrayHidden(true);
    SleepBlocker.instance.setMainWindowVisible(false);
    PlayService.existingPlaybackService?.startSmtcKeepAlive();
    MemoryMonitorService.instance.trimTrayHidden();
    return true;
  }

  Future<void> showWindow() async {
    if (_isExiting) return;
    // 先让窗口回到屏幕上，再恢复绘制。藏太久后画面表面已经失效，提前画会得到白屏。
    await windowManager.show();
    if (_isExiting) return;
    await windowManager.setSkipTaskbar(false);
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    if (_isExiting) return;
    WindowRenderGate.instance.enterForeground();
    MemoryMonitorService.instance.restoreForegroundImageCache();
    SleepBlocker.instance.setMainWindowVisible(true);
    WidgetsBinding.instance.scheduleFrame();
    await WindowRenderGate.instance.waitForWarmup(
      timeout: const Duration(milliseconds: 500),
    );
    if (_isExiting) return;
    if (WindowRenderGate.instance.shouldRender) {
      WidgetsBinding.instance.scheduleFrame();
    }
    await windowManager.focus();
    PlayService.existingPlaybackService?.stopSmtcKeepAlive();
  }

  /// [skipSave] 用于备份导入后重启：内存中仍是旧状态，写回会覆盖刚导入的文件。
  Future<void> exitApp({bool skipSave = false}) async {
    if (_isExiting) return;
    _isExiting = true;

    if (!skipSave) {
      await _run('saveSettings', AppSettings.instance.saveSettings());
    }
    await _run('windowManager.hide', windowManager.hide());
    await _run('HotkeysHelper.unregisterAll', HotkeysHelper.unregisterAll());
    if (_libraryReady && !skipSave) {
      await _run('savePlaylists', savePlaylists());
      await _run('saveLyricSources', saveLyricSources());
      await _run(
        'waitForPageOrderCache',
        AudioLibrary.instance.waitForPreferredPageOrderCacheWrite(),
      );
    }
    if (!skipSave) {
      final playback = PlayService.existingPlaybackService;
      if (playback != null) {
        await _run(
          'persistPlaybackPositionForExit',
          playback.persistPlaybackPositionForExit(),
        );
      }
      await _run('savePreference', AppPreference.instance.save());
    }
    if (PlayService.isInitialized) {
      await _run(
        'PlayService.close',
        PlayService.instance.close(),
        timeout: null,
      );
    }
    final disposeRuntimeResources = _disposeRuntimeResources;
    if (disposeRuntimeResources != null) {
      await _run('disposeRuntimeResources', disposeRuntimeResources());
    }
    MemoryMonitorService.instance.stop();
    WindowRenderGate.instance.detach();
    _bindRetryTimer?.cancel();
    _bindRetryTimer = null;
    await _run(
      'trayManager.destroy',
      _trayOperation.then((_) => trayManager.destroy()),
    );
    _trayReady = false;
    await _run('windowManager.destroy', windowManager.destroy());
  }

  Future<void> _run(
    String name,
    Future<Object?> future, {
    Duration? timeout = const Duration(seconds: 3),
  }) async {
    try {
      await (timeout == null ? future : future.timeout(timeout));
    } catch (error, trace) {
      log.window.warn('legacy', '$name failed: $error', stackTrace: trace);
    }
  }

  @override
  void onWindowClose() {
    requestClose();
  }

  @override
  void onWindowFocus() {
    unawaited(_resumeIfWindowActuallyVisible());
  }

  /// 最小化时系统也会送焦点。先看窗口是不是真的在，避免绘制被立刻打开。
  Future<void> _resumeIfWindowActuallyVisible() async {
    if (WindowRenderGate.instance.trayHidden.value) return;
    final minimized = await windowManager.isMinimized();
    if (WindowRenderGate.instance.trayHidden.value) return;
    final visible = await windowManager.isVisible();
    if (WindowRenderGate.instance.trayHidden.value) return;
    if (minimized || !visible) return;
    WindowRenderGate.instance.setWindowMinimized(false);
  }

  @override
  void onWindowRestore() {
    // 等系统回调结束再恢复。在回调里立刻打开绘制会卡死。
    Timer.run(() {
      WindowRenderGate.instance.setWindowMinimized(false);
      if (WindowRenderGate.instance.trayHidden.value) {
        WindowRenderGate.instance.enterForeground();
      }
    });
  }

  @override
  void onTrayIconMouseDown() {
    showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    _refreshTrayContent(popUpMenu: true);
  }

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'now_playing':
        await _trayOperation.catchError((_) {});
        if (_isExiting) return;
        final routerContext = routerKey.currentContext;
        if (routerContext == null || !routerContext.mounted) return;
        final router = GoRouter.of(routerContext);
        if (router.state.uri.path != app_paths.NOW_PLAYING_PAGE) {
          unawaited(router.push<void>(app_paths.NOW_PLAYING_PAGE));
        }
        await showWindow();
        return;
      case 'show_window':
        await _trayOperation.catchError((_) {});
        await showWindow();
        return;
      case 'toggle_desktop_lyric':
        final desktopLyric = PlayService.instance.desktopLyricService;
        if (desktopLyric.isRunning) {
          await desktopLyric.killDesktopLyric();
        } else {
          await desktopLyric.startDesktopLyric();
        }
        return;
      case 'unlock_desktop_lyric':
        PlayService.instance.desktopLyricService.sendUnlockMessage();
        return;
      case 'cycle_play_mode':
        // 菜单可能还是切换前的旧内容，点击时再校验一次
        if (ConcertSession.instance.isActive) return;
        _cyclePlayMode();
        return;
      case 'prev':
        PlayService.instance.playbackService.lastAudio();
        return;
      case 'play_pause':
        final playback = PlayService.instance.playbackService;
        if (playback.playerState == PlayerState.playing) {
          playback.pause();
        } else {
          playback.start();
        }
        return;
      case 'next':
        PlayService.instance.playbackService.nextAudio();
        return;
      case 'exit_app':
        await exitApp();
        return;
    }
  }
}

class _CloseChoiceDialog extends StatelessWidget {
  const _CloseChoiceDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('关闭主窗口'),
      content: const Text('要最小化到通知区继续播放，还是直接退出？\n选择会记住，之后也可以在设置里改。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, WindowCloseBehavior.exit),
          child: const Text('退出程序'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, WindowCloseBehavior.minimizeToTray),
          child: const Text('最小化到通知区'),
        ),
      ],
    );
  }
}
