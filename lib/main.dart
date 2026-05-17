import 'dart:async';
import 'dart:io';

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/entry.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/immersive.dart';
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
  const minimumSize = Size(507, 507);
  Size targetSize = AppSettings.instance.windowSize;
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final display = view.display;
  final displayW = display.size.width / display.devicePixelRatio;
  final displayH = display.size.height / display.devicePixelRatio;
  final maxW = (displayW - 16.0).clamp(minimumSize.width, double.infinity).toDouble();
  final maxH = (displayH - 16.0).clamp(minimumSize.height, double.infinity).toDouble();
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
    await windowManager.show();
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
  PaintingBinding.instance.imageCache.maximumSize = 30;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 24 << 20; // 24MB

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

  initRustLogger().listen((msg) {
    logger.i('[rs]: $msg');
  });

  // For hot reload, `unregisterAll()` needs to be called.
  await HotkeysHelper.unregisterAll();
  HotkeysHelper.registerHotKeys();

  final supportPath = (await getAppDataDir()).path;
  final settingsDir = await getSettingsDir();
  if (File('${settingsDir.path}\\settings.json').existsSync()) {
    await AppSettings.readFromJson();
    await loadPrefFont();
  }
  if (File('${settingsDir.path}\\app_preference.json').existsSync()) {
    await AppPreference.read();
  }
  await AlbumColorCache.instance.init();

  final welcome = !File('$supportPath\\index.json').existsSync();

  await initWindow();
  await ImmersiveModeController.instance.init();

  // 内存监控：每 30s 记录 RSS，超过 250MB 触发紧急清理
  _startMemoryMonitor();
  // 低频保底：每 30 分钟清一次 Flutter ImageCache（防止碎片化堆积）
  _startGentlePeriodicCleanup();

  runApp(Entry(welcome: welcome));
}

/// 定时记录进程物理内存，超阈值时紧急清理
void _startMemoryMonitor() {
  Timer.periodic(const Duration(seconds: 30), (_) {
    try {
      final rssMB = (ProcessInfo.currentRss / (1024 * 1024)).round();
      if (rssMB > 250) {
        logger.w('[mem] RSS ${rssMB}MB > 250, emergency cleanup');
        PaintingBinding.instance.imageCache.clear();
        CoverImageCache.instance.clear();
        AudioLibrary.instance.evictStaleCoverBytes();
      }
    } catch (_) {}
  });
}

/// 低频被动清理：仅清 Flutter ImageCache（碎片整理），不动 LRU 缓存
void _startGentlePeriodicCleanup() {
  Timer.periodic(const Duration(minutes: 15), (_) {
    try {
      PaintingBinding.instance.imageCache.clear();
    } catch (_) {}
  });
}
