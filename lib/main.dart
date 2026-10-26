import 'dart:async';
import 'dart:io';
import 'dart:ui' show FlutterView, PlatformDispatcher;

import 'package:pure_music/core/application_log.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/cache.dart';
import 'package:path/path.dart' as path;
import 'package:pure_music/entry.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:pure_music/core/memory_monitor.dart';
import 'package:pure_music/core/now_playing_perf_auto.dart';
import 'package:pure_music/core/sidebar_perf_auto.dart';
import 'package:pure_music/native/rust/api/logger.dart';
import 'package:pure_music/native/rust/frb_generated.dart';
import 'package:pure_music/core/app_fonts.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/log/rust_log_line.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_lifecycle.dart';
import 'package:pure_music/remote/remote_library.dart';
import 'package:pure_music/core/window_placement.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_single_instance/flutter_single_instance.dart';

const _browserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36';

class _BrowserHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)..userAgent = _browserUserAgent;
  }
}

Future<void> initWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  final minimumSize = Size(
    minimumWindowSizeSetting.width,
    minimumWindowSizeSetting.height,
  );
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final targetSize = _clampWindowSize(
    AppSettings.instance.windowSize,
    minimumSize,
    view,
  );
  final restorePlacementPx = _restoreWindowPhysicalRect();
  final restorePosition = restorePlacementPx == null
      ? _restoreWindowPosition(targetSize, view)
      : null;

  WindowOptions windowOptions = WindowOptions(
    minimumSize: minimumSize,
    size: targetSize,
    center: restorePosition == null && restorePlacementPx == null,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );
  unawaited(
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      if (WindowLifecycleService.instance.isExiting) return;
      if (restorePlacementPx != null) {
        await _applyWindowPhysicalRect(restorePlacementPx);
        if (WindowLifecycleService.instance.isExiting) return;
      } else if (restorePosition != null) {
        await windowManager.setPosition(restorePosition);
        if (WindowLifecycleService.instance.isExiting) return;
      }
      await windowManager.show();
      if (WindowLifecycleService.instance.isExiting) return;
      if (AppSettings.instance.isWindowMaximized) {
        await windowManager.maximize();
        if (WindowLifecycleService.instance.isExiting) return;
      }
      if (AppSettings.instance.windowAlwaysOnTop) {
        await windowManager.setAlwaysOnTop(true);
        if (WindowLifecycleService.instance.isExiting) return;
      }
      await windowManager.focus();
    }),
  );
}

Size _clampWindowSize(Size target, Size minimumSize, FlutterView view) {
  final dpr = view.display.devicePixelRatio;
  final virtual = windowsVirtualScreen();
  final maxW = virtual != null
      ? virtual.width / dpr
      : view.display.size.width / dpr - 16.0;
  final maxH = virtual != null
      ? virtual.height / dpr
      : view.display.size.height / dpr - 16.0;
  return Size(
    target.width
        .clamp(
          minimumSize.width,
          maxW.clamp(minimumSize.width, double.infinity),
        )
        .toDouble(),
    target.height
        .clamp(
          minimumSize.height,
          maxH.clamp(minimumSize.height, double.infinity),
        )
        .toDouble(),
  );
}

Offset? _restoreWindowPosition(Size targetSize, FlutterView view) {
  final saved = AppSettings.instance.windowPosition;
  if (saved == null) return null;
  final screen = windowsVirtualScreen();
  if (screen == null) return saved;
  if (windowPlacementIsOnscreen(
    position: saved,
    size: targetSize,
    devicePixelRatio: view.display.devicePixelRatio,
    screen: screen,
  )) {
    return saved;
  }
  return null;
}

WindowPhysicalRect? _restoreWindowPhysicalRect() {
  final saved = AppSettings.instance.windowPlacementPx;
  if (saved == null) return null;
  final screen = windowsVirtualScreen();
  if (screen == null) return null;
  // 宽高超出虚拟屏视为坏数据，防止超大整数经 FFI 的 Int32 截断后摆出畸形窗口
  if (saved.width > screen.width || saved.height > screen.height) {
    return null;
  }
  if (windowPhysicalRectIsOnscreen(rect: saved, screen: screen)) {
    return saved;
  }
  return null;
}

Future<void> _applyWindowPhysicalRect(WindowPhysicalRect rect) async {
  try {
    final hwnd = await windowManager.getId();
    if (hwnd <= 0) return;
    if (!setWindowsWindowPhysicalRect(hwnd: hwnd, rect: rect)) return;
    // 跨屏移动会触发 WM_DPICHANGED，引擎按建议矩形重设窗口，
    // 让出一个事件循环回合后再按保存值摆放一次兜底
    await Future<void>.delayed(Duration.zero);
    setWindowsWindowPhysicalRect(hwnd: hwnd, rect: rect);
  } catch (_) {
    // 句柄或 FFI 不可用时保持系统默认位置
  }
}

Future<void> loadPrefFont() async {
  final settings = AppSettings.instance;
  Future<void> load(String? family, String? path) async {
    if (family == null || path == null) return;
    try {
      await loadAppFontFile(family: family, path: path);
    } catch (err, trace) {
      log.app.error('legacy', err.toString(), stackTrace: trace);
    }
  }

  await load(settings.fontFamily, settings.fontPath);
  await load(settings.lyricFontFamily, settings.lyricFontPath);
  ThemeProvider.instance.applyLoadedFonts();
}

void _installGlobalErrorLogging() {
  final previousFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    applicationLogOutput.recordUnhandledSync(
      source: 'flutter',
      error: details.exception,
      stackTrace: details.stack,
    );
    log.app.error(
      'legacy',
      '[flutter] unhandled framework error',
      error: details.exception,
      stackTrace: details.stack,
    );
    previousFlutterError?.call(details);
  };
  final previousPlatformError = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    applicationLogOutput.recordUnhandledSync(
      source: 'platform',
      error: error,
      stackTrace: stackTrace,
    );
    log.app.fatal(
      'legacy',
      '[platform] unhandled asynchronous error',
      error: error,
      stackTrace: stackTrace,
    );
    return previousPlatformError?.call(error, stackTrace) ?? false;
  };
}

Future<void> main() async {
  HttpOverrides.global = _BrowserHttpOverrides();
  WidgetsFlutterBinding.ensureInitialized();
  await applicationLogOutput.init();
  _installGlobalErrorLogging();
  try {
    await _runApplication();
  } catch (error, stackTrace) {
    applicationLogOutput.recordUnhandledSync(
      source: 'startup',
      error: error,
      stackTrace: stackTrace,
    );
    log.app.fatal(
      'legacy',
      '[startup] unhandled error',
      error: error,
      stackTrace: stackTrace,
    );
    await applicationLogOutput.flush();
    rethrow;
  }
}

Future<void> _runApplication() async {
  PaintingBinding.instance.imageCache.maximumSize = 64;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 16 << 20;
  final singleInstance = FlutterSingleInstance();
  if (!await singleInstance.isFirstInstance()) {
    await singleInstance.focus();
    exit(0);
  }
  try {
    await RustLib.init();
  } catch (e, s) {
    log.app.error('legacy', 'RustLib.init failed: $e\n$s');
    rethrow;
  }
  _listenRustLogger();
  await HotkeysHelper.unregisterAll();
  final welcome = await _loadSettingsAndCaches();
  if (!await _initWindowShell()) return;
  MemoryMonitorService.instance.start();
  runApp(Entry(welcome: welcome));
  NowPlayingPerfAuto.schedule();
  SidebarPerfAuto.schedule();
}

void _listenRustLogger() {
  _rustLoggerSub = initRustLogger().listen((line) {
    final parsed = parseRustLogLine(line);
    if (parsed == null) {
      log.rust.info('legacy', line);
      return;
    }
    log.write(parsed);
  });
}

Future<bool> _loadSettingsAndCaches() async {
  final supportPath = (await getAppDataDir()).path;
  CoverImageCache.instance.configure(indexPath: supportPath);
  final settingsDir = await getSettingsDir();
  if (File(path.join(settingsDir.path, 'settings.json')).existsSync()) {
    await AppSettings.readFromJson();
    await loadPrefFont();
  }
  if (File(path.join(settingsDir.path, 'app_preference.json')).existsSync()) {
    await AppPreference.read();
  }
  await HotkeysHelper.registerHotKeys();
  await AlbumColorCache.instance.init();
  try {
    await RemoteLibrary.instance.init();
  } catch (e, s) {
    log.app.error('legacy', 'RemoteLibrary.init failed: $e\n$s');
  }
  return !File(path.join(supportPath, 'index.json')).existsSync();
}

Future<bool> _initWindowShell() async {
  await initWindow();
  await WindowLifecycleService.instance.init(
    disposeRuntimeResources: disposeRuntimeResources,
  );
  if (WindowLifecycleService.instance.isExiting) return false;
  FlutterSingleInstance.onFocus = (_) =>
      WindowLifecycleService.instance.showWindow();
  await ImmersiveModeController.instance.init();
  if (WindowLifecycleService.instance.isExiting) return false;
  if (AppSettings.instance.appWindowTransparent) {
    await windowManager.setBackgroundColor(Colors.transparent);
  }
  return true;
}

StreamSubscription<String>? _rustLoggerSub;

Future<void> disposeRuntimeResources() async {
  MemoryMonitorService.instance.stop();
  final rustLoggerSub = _rustLoggerSub;
  _rustLoggerSub = null;
  if (rustLoggerSub != null) {
    unawaited(rustLoggerSub.cancel().catchError((_) {}));
  }
  await applicationLogOutput.flush();
}
