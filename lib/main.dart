import 'dart:async';
import 'dart:io';

import 'package:pure_music/core/preference.dart';
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
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_single_instance/flutter_single_instance.dart';

Future<void> initWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  Size targetSize = AppSettings.instance.windowSize;
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final display = view.display;
  final displayW = display.size.width / display.devicePixelRatio;
  final displayH = display.size.height / display.devicePixelRatio;
  final maxW = (displayW - 16.0).clamp(1.0, double.infinity).toDouble();
  final maxH = (displayH - 16.0).clamp(1.0, double.infinity).toDouble();
  targetSize = Size(
    targetSize.width.clamp(1.0, maxW),
    targetSize.height.clamp(1.0, maxH),
  );

  WindowOptions windowOptions = WindowOptions(
    size: targetSize,
    center: true,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    if (AppSettings.instance.isWindowMaximized) {
      await windowManager.maximize();
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 优化 ImageCache：调小上限，大曲库下减少内存压力
  // 默认: maximumSize=100, maximumSizeBytes=100MB
  // 经 DevTools 实测 RSS 约 317MB，Dart Heap 仅 30MB，瓶颈在 Native 内存
  PaintingBinding.instance.imageCache.maximumSize = 15;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 12 << 20; // 12MB

  final singleInstance = FlutterSingleInstance();
  if (!await singleInstance.isFirstInstance()) {
    await singleInstance.focus();
    exit(0);
  }

  try {
    await RustLib.init();
  } catch (e, s) {
    logger.e('RustLib.init failed: $e\n$s');
  }

  _rustLoggerSub = initRustLogger().listen((msg) {
    logger.i('[rs]: $msg');
  });

  // For hot reload, `unregisterAll()` needs to be called.
  await HotkeysHelper.unregisterAll();
  HotkeysHelper.registerHotKeys();

  final supportPath = (await getAppDataDir()).path;
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
  await ImmersiveModeController.instance.init();

  MemoryMonitorService.instance.start();

  runApp(Entry(welcome: welcome));
}

StreamSubscription<String>? _rustLoggerSub;

void disposeMemoryMonitor() {
  MemoryMonitorService.instance.stop();
  _rustLoggerSub?.cancel();
  _rustLoggerSub = null;
}
