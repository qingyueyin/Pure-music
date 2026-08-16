import 'dart:async';

import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/memory_monitor.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';
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
  Timer? _trayTrimTimer;
  Future<void> _trayOperation = Future<void>.value();
  Future<void> Function()? _disposeRuntimeResources;

  bool get isExiting => _isExiting;

  Future<void> init({Future<void> Function()? disposeRuntimeResources}) async {
    _disposeRuntimeResources = disposeRuntimeResources;
    if (_initialized) return;
    _initialized = true;
    windowManager.addListener(this);
    trayManager.addListener(this);
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
        logger.w('Syncing tray icon failed: $error', stackTrace: trace);
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
    final shuffle = playback?.shuffle.value ?? false;
    final playMode = playback?.playMode.value;
    final modeText = switch (true) {
      _ when shuffle => '随机播放',
      _ when playMode == PlayMode.singleLoop => '单曲循环',
      _ => '顺序播放',
    };
    final statusText = nowPlaying == null
        ? '未在播放'
        : '${nowPlaying.title} - ${nowPlaying.artist}';
    final toolTip = hasSession
        ? (statusText.length <= 127
              ? statusText
              : '${statusText.substring(0, 126)}…')
        : 'Pure Music';
    final menu = Menu(
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
          disabled: !hasSession,
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
    _trayOperation = _trayOperation.catchError((_) {}).then((_) async {
      try {
        await trayManager.setToolTip(toolTip);
        await trayManager.setContextMenu(menu);
      } catch (error, trace) {
        logger.w('Updating tray content failed: $error', stackTrace: trace);
      }
      // 独立 try 保证菜单一定会弹出，否则插件侧 menu_visible 不会复位
      if (popUpMenu) {
        try {
          await trayManager.popUpContextMenu();
        } catch (error, trace) {
          logger.w('Popping up tray menu failed: $error', stackTrace: trace);
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
        logger.w('Removing tray icon failed: $error', stackTrace: trace);
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
      logger.w('Creating tray icon failed: $error', stackTrace: trace);
      try {
        await trayManager.destroy();
      } catch (cleanupError, cleanupTrace) {
        logger.w(
          'Cleaning up tray icon failed: $cleanupError',
          stackTrace: cleanupTrace,
        );
      }
      return false;
    }
  }

  Future<void> requestClose() async {
    if (_isExiting || _closeRequestPending) return;
    _closeRequestPending = true;
    try {
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
          playback.setPlayMode(PlayMode.singleLoop);
          break;
        case PlayMode.singleLoop:
          playback.useShuffle(true);
          break;
      }
    }
  }

  void _scheduleTrayTrim() {
    _trayTrimTimer?.cancel();
    _trayTrimTimer = Timer(const Duration(minutes: 2), () async {
      _trayTrimTimer = null;
      if (_isExiting) return;
      // 清理前再确认窗口仍处于隐藏状态，避免用户已恢复窗口导致清理闪烁
      if (await windowManager.isVisible()) return;
      if (_isExiting) return;
      MemoryMonitorService.instance.trimTrayHidden();
      logger.i('[mem] tray-hidden - trimmed invisible caches');
    });
  }

  void _cancelTrayTrim() {
    _trayTrimTimer?.cancel();
    _trayTrimTimer = null;
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
    await windowManager.hide();
    if (_isExiting ||
        AppSettings.instance.windowCloseBehavior !=
            WindowCloseBehavior.minimizeToTray) {
      return false;
    }
    PlayService.existingPlaybackService?.startSmtcKeepAlive();
    _scheduleTrayTrim();
    return true;
  }

  Future<void> showWindow() async {
    if (_isExiting) return;
    _cancelTrayTrim();
    await windowManager.show();
    if (_isExiting) return;
    await windowManager.setSkipTaskbar(false);
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.focus();
    PlayService.existingPlaybackService?.stopSmtcKeepAlive();
  }

  Future<void> exitApp() async {
    if (_isExiting) return;
    _isExiting = true;

    await _run('saveSettings', AppSettings.instance.saveSettings());
    await _run('windowManager.hide', windowManager.hide());
    await _run('HotkeysHelper.unregisterAll', HotkeysHelper.unregisterAll());
    if (_libraryReady) {
      await _run('savePlaylists', savePlaylists());
      await _run('saveLyricSources', saveLyricSources());
    }
    await _run('savePreference', AppPreference.instance.save());
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
    _bindRetryTimer?.cancel();
    _bindRetryTimer = null;
    _cancelTrayTrim();
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
      logger.w('$name failed: $error', stackTrace: trace);
    }
  }

  @override
  void onWindowClose() {
    requestClose();
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
          desktopLyric.killDesktopLyric();
        } else {
          desktopLyric.startDesktopLyric();
        }
        return;
      case 'unlock_desktop_lyric':
        PlayService.instance.desktopLyricService.sendUnlockMessage();
        return;
      case 'cycle_play_mode':
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
        exitApp();
        return;
    }
  }
}
