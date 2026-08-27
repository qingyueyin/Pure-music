import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

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
import 'package:pure_music/native/rust/api/logger.dart';
import 'package:pure_music/native/rust/frb_generated.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_lifecycle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_single_instance/flutter_single_instance.dart';

Future<void> initWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  final minimumSize = Size(
    minimumWindowSizeSetting.width,
    minimumWindowSizeSetting.height,
  );
  Size targetSize = AppSettings.instance.windowSize;
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final display = view.display;
  final displayW = display.size.width / display.devicePixelRatio;
  final displayH = display.size.height / display.devicePixelRatio;
  final maxW = (displayW - 16.0)
      .clamp(minimumSize.width, double.infinity)
      .toDouble();
  final maxH = (displayH - 16.0)
      .clamp(minimumSize.height, double.infinity)
      .toDouble();
  targetSize = Size(
    targetSize.width.clamp(minimumSize.width, maxW),
    targetSize.height.clamp(minimumSize.height, maxH),
  );

  WindowOptions windowOptions = WindowOptions(
    minimumSize: minimumSize,
    size: targetSize,
    center: true,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    if (WindowLifecycleService.instance.isExiting) return;
    await windowManager.show();
    if (WindowLifecycleService.instance.isExiting) return;
    if (AppSettings.instance.isWindowMaximized) {
      await windowManager.maximize();
      if (WindowLifecycleService.instance.isExiting) return;
    }
    await windowManager.focus();
  });
}

Future<void> loadPrefFont() async {
  final settings = AppSettings.instance;
  if (settings.fontFamily != null) {
    try {
      final fontLoader = FontLoader(settings.fontFamily!);

      fontLoader.addFont(
        File(settings.fontPath!).readAsBytes().then((value) {
          return ByteData.sublistView(value);
        }),
      );
      await fontLoader.load();
      ThemeProvider.instance.changeFontFamily(settings.fontFamily!);
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
    }
  }
}

void _installGlobalErrorLogging() {
  final previousFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    applicationLogOutput.recordUnhandledSync(
      source: 'flutter',
      error: details.exception,
      stackTrace: details.stack,
    );
    logger.e(
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
    logger.f(
      '[platform] unhandled asynchronous error',
      error: error,
      stackTrace: stackTrace,
    );
    return previousPlatformError?.call(error, stackTrace) ?? false;
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await logger.init;
  _installGlobalErrorLogging();
  try {
    await _runApplication();
  } catch (error, stackTrace) {
    applicationLogOutput.recordUnhandledSync(
      source: 'startup',
      error: error,
      stackTrace: stackTrace,
    );
    logger.f('[startup] unhandled error', error: error, stackTrace: stackTrace);
    await applicationLogOutput.flush();
    rethrow;
  }
}

Future<void> _runApplication() async {
  // 覆盖多屏缩略图，避免滚动回来时反复解码；内存监控仍会分级回收。
  PaintingBinding.instance.imageCache.maximumSize = 96;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 32 << 20;

  final singleInstance = FlutterSingleInstance();
  if (!await singleInstance.isFirstInstance()) {
    await singleInstance.focus();
    exit(0);
  }

  try {
    await RustLib.init();
  } catch (e, s) {
    logger.e('RustLib.init failed: $e\n$s');
    rethrow;
  }

  _rustLoggerSub = initRustLogger().listen((msg) {
    logger.i('[rs]: $msg');
  });

  // For hot reload, `unregisterAll()` needs to be called.
  await HotkeysHelper.unregisterAll();
  HotkeysHelper.registerHotKeys();

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
  await AlbumColorCache.instance.init();

  final welcome = !File(path.join(supportPath, 'index.json')).existsSync();

  await initWindow();
  await WindowLifecycleService.instance.init(
    disposeRuntimeResources: disposeRuntimeResources,
  );
  if (WindowLifecycleService.instance.isExiting) return;
  FlutterSingleInstance.onFocus = (_) =>
      WindowLifecycleService.instance.showWindow();
  await ImmersiveModeController.instance.init();
  if (WindowLifecycleService.instance.isExiting) return;

  MemoryMonitorService.instance.start();

  runApp(Entry(welcome: welcome));
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
