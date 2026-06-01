import 'dart:async';
import 'dart:io';

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/matcher.dart' hide logger;
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/entry.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:pure_music/native/rust/api/logger.dart';
import 'package:pure_music/native/rust/frb_generated.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/play_service/play_service.dart';
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

  runApp(Entry(welcome: welcome));
}

Timer? _memoryMonitorTimer;

void _startMemoryMonitor() {
  _memoryMonitorTimer?.cancel();
  _memoryMonitorTimer = Timer.periodic(const Duration(seconds: 30), (_) {
    try {
      final rssMB = (ProcessInfo.currentRss / (1024 * 1024)).round();
      if (rssMB > 250) {
        logger.w('[mem] RSS ${rssMB}MB > 250, tier-3 emergency cleanup');
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        CoverImageCache.instance.clear();
        AudioLibrary.instance.evictAllCoversExcept(
          PlayService.instance.playbackService.nowPlaying?.path,
        );
        clearLyricCaches();
      } else if (rssMB > 180) {
        logger.w('[mem] RSS ${rssMB}MB > 180, tier-2 cleanup');
        PaintingBinding.instance.imageCache.clear();
        CoverImageCache.instance.clear();
        AudioLibrary.instance.evictAllCoversExcept(
          PlayService.instance.playbackService.nowPlaying?.path,
        );
      } else if (rssMB > 120) {
        PaintingBinding.instance.imageCache.clear();
      }
    } catch (_) {}
  });
}

void disposeMemoryMonitor() {
  _memoryMonitorTimer?.cancel();
  _memoryMonitorTimer = null;
}

/// 强制释放可回收内存，用于窗口最小化/低内存通知等场景
void trimAllMemory() {
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
  CoverImageCache.instance.trimMemory();
  AudioLibrary.instance.evictAllCoversExcept(
    PlayService.instance.playbackService.nowPlaying?.path,
  );
}


