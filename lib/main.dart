import 'dart:async';
import 'dart:io';

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/matcher.dart' hide logger;
import 'package:path/path.dart' as path;
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/entry.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:pure_music/native/rust/api/logger.dart';
import 'package:pure_music/native/rust/frb_generated.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/native/bass/bass_player.dart';
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

  initRustLogger().listen((msg) {
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

  // 内存监控：每 60s 检查 RSS，仅在窗口未聚焦或 RSS 过高时触发清理
  // 播放中减少清理频率和强度，避免缓存频繁重建导致卡顿
  _startMemoryMonitor();

  runApp(Entry(welcome: welcome));
}

Timer? _memoryMonitorTimer;

/// 播放状态下仅做轻量清理，避免缓存重建开销导致音频卡顿
bool _isPlaying() {
  try {
    return PlayService.instance.playbackService.playerState ==
        PlayerState.playing;
  } catch (_) {
    return false;
  }
}

void _startMemoryMonitor() {
  _memoryMonitorTimer?.cancel();
  _memoryMonitorTimer = Timer.periodic(const Duration(seconds: 60), (_) {
    try {
      final rssMB = (ProcessInfo.currentRss / (1024 * 1024)).round();

      // 播放状态下调高阈值，避免频繁清理引起缓存重建和 GC 抖动
      final playing = _isPlaying();
      final tier3Threshold = playing ? 450 : 400;
      final tier2Threshold = playing ? 350 : 250;

      if (rssMB > tier3Threshold) {
        logger.w(
          '[mem] RSS ${rssMB}MB > $tier3Threshold, tier-3 emergency cleanup',
        );
        // 播放中不清空 ImageCache（避免图片重解码导致帧率抖动）
        if (!playing) {
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
        }
        CoverImageCache.instance.trimMemory();
        AudioLibrary.instance.evictAllCoversExcept(
          PlayService.instance.playbackService.nowPlaying?.path,
        );
        clearLyricCaches();
      } else if (rssMB > tier2Threshold) {
        logger.w(
          '[mem] RSS ${rssMB}MB > $tier2Threshold, tier-2 cleanup',
        );
        if (!playing) {
          PaintingBinding.instance.imageCache.clear();
        }
        CoverImageCache.instance.trimMemory();
      }
      // 移除原有的 100MB 级清理（过于频繁且无明显收益）
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
  CoverImageCache.instance.clear();
  AudioLibrary.instance.evictAllCoversExcept(
    PlayService.instance.playbackService.nowPlaying?.path,
  );
}


