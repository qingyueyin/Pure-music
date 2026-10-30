import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_render_gate.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:window_manager/window_manager.dart';

/// 托盘整段时间都保持工作集上限。窗口打开后才放开。
bool traySessionKeepsWorkingSetCap({required bool trayResident}) =>
    trayResident;

/// 托盘上限还按着的时候，后续清理不能用「清空工作集配额」把它冲掉。
bool followUpTrimMayDropWorkingSetCap({required bool trayClampHeld}) =>
    !trayClampHeld;

typedef _SetProcessWorkingSetSizeNative =
    ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr, ffi.IntPtr);
typedef _SetProcessWorkingSetSizeDart = int Function(int, int, int);

/// 定时看 RSS，只回收冷封面；窗口不可见时不按 RSS 瘦身。
/// 最小化只换出工作集页，托盘隐藏额外卸界面并清图片/排版缓存。
class MemoryMonitorService {
  static final instance = MemoryMonitorService._();
  MemoryMonitorService._();

  Timer? _timer;
  Timer? _settleTrimTimer;
  Timer? _settleTrimFollowUpTimer;
  Timer? _hiddenTrimTimer;
  Timer? _hiddenWatchdogTimer;
  bool _hiddenWatchdogBusy = false;
  int _hiddenTrimTicks = 0;
  DateTime? _lastTrimLogAt;
  Listenable? _hiddenNowPlaying;
  String? _hiddenSongPath;
  DateTime? _lastTier1CleanupAt;
  DateTime? _lastTier2CleanupAt;
  DateTime? _lastTier3CleanupAt;
  DateTime? _lastPlayingLightCleanupAt;

  static ffi.DynamicLibrary? _kernel32;
  static _SetProcessWorkingSetSizeDart? _setProcessWorkingSetSize;

  /// 把工作集页换出到备用列表。只动内存页，不碰音频缓冲，也不丢缓存数据。
  void _trimWorkingSet() {
    try {
      _kernel32 ??= ffi.DynamicLibrary.open('kernel32.dll');
      _setProcessWorkingSetSize ??= _kernel32!
          .lookupFunction<
            _SetProcessWorkingSetSizeNative,
            _SetProcessWorkingSetSizeDart
          >('SetProcessWorkingSetSize');
      final before = ProcessInfo.currentRss;
      // 传 -1/-1 等于 EmptyWorkingSet。
      final ok = _setProcessWorkingSetSize!(-1, -1, -1);
      _logTrim(ok, before, ProcessInfo.currentRss);
    } catch (_) {
      _setProcessWorkingSetSize = null;
    }
  }

  /// 换出后立刻回读 RSS。窗口隐藏期间 30 秒最多一条，方便核对有没有真的掉。
  void _logTrim(int ok, int before, int after) {
    final now = DateTime.now();
    final last = _lastTrimLogAt;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastTrimLogAt = now;
    const mb = 1024 * 1024;
    log.memory.info(
      'legacy',
      '[mem] trim ok=$ok rss ${before ~/ mb}→${after ~/ mb}MB',
    );
  }

  /// 隐藏期间换出工作集。只换一次会被帧循环重新拉回，头一分钟每 3 秒补一次。
  void _holdWorkingSetWhileHidden() {
    _armSettleTrim();
    _scheduleHiddenTrim();
    _watchHiddenSongChange();
    _startHiddenWatchdog();
  }

  void _scheduleHiddenTrim() {
    _hiddenTrimTimer?.cancel();
    _hiddenTrimTicks = 0;
    _hiddenTrimTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (WindowRenderGate.instance.framesEnabled.value) return;
      _trimWorkingSet();
      _hiddenTrimTicks++;
      if (_hiddenTrimTicks < 20) return;
      // 落定后回到长间隔，别一直每 3 秒打扰系统。
      timer.cancel();
      _hiddenTrimTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (WindowRenderGate.instance.framesEnabled.value) return;
        _trimWorkingSet();
      });
    });
  }

  void _armSettleTrim() {
    _settleTrimTimer?.cancel();
    _settleTrimTimer = Timer(const Duration(milliseconds: 1200), () {
      _settleTrimTimer = null;
      if (WindowRenderGate.instance.framesEnabled.value) return;
      _trimWorkingSet();
    });
  }

  /// 最小化事件可能被焦点/恢复回调抢先，门闩会卡在可见而一次都不换出。
  /// 隐藏期间每 5 秒核对真实窗口状态，该藏就藏、该回就回。
  void _startHiddenWatchdog() {
    _hiddenWatchdogTimer?.cancel();
    _hiddenWatchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_reconcileHiddenWindow());
    });
  }

  Future<void> _reconcileHiddenWindow() async {
    if (_hiddenWatchdogBusy) return;
    _hiddenWatchdogBusy = true;
    try {
      final gate = WindowRenderGate.instance;
      if (gate.trayHidden.value) return;
      final minimized = await windowManager.isMinimized();
      // 等结果期间已经恢复：别把门闩按回去，否则窗口回来不画。
      if (gate.trayHidden.value || _hiddenWatchdogTimer == null) return;
      if (minimized) {
        gate.setWindowMinimized(true);
        if (_hiddenTrimTimer == null) {
          // 最小化事件漏了：补上换出节奏。
          _scheduleHiddenTrim();
          _watchHiddenSongChange();
          _trimWorkingSet();
        }
        return;
      }
      gate.setWindowMinimized(false);
      stopHiddenTrim();
    } catch (_) {
      // 没有窗口插件（测试环境）时不再尝试。
      _hiddenWatchdogTimer?.cancel();
      _hiddenWatchdogTimer = null;
    } finally {
      _hiddenWatchdogBusy = false;
    }
  }

  /// 隐藏时切歌会重新分配歌词、封面和缩略图，等 3 秒再补一次换出，把刚涨上来的页推回备用列表。
  void _watchHiddenSongChange() {
    final notifier = PlayService.existingPlaybackService?.nowPlayingNotifier;
    if (identical(notifier, _hiddenNowPlaying)) return;
    _hiddenNowPlaying?.removeListener(_onHiddenSongChanged);
    _hiddenNowPlaying = notifier;
    _hiddenSongPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    notifier?.addListener(_onHiddenSongChanged);
  }

  void _onHiddenSongChanged() {
    final path = PlayService.existingPlaybackService?.nowPlaying?.path;
    if (path == _hiddenSongPath) return;
    _hiddenSongPath = path;
    if (WindowRenderGate.instance.framesEnabled.value) return;
    _armSettleTrim();
    // 切歌后的分配会持续几秒，3 秒那次之后再补一次。
    _settleTrimFollowUpTimer?.cancel();
    _settleTrimFollowUpTimer = Timer(const Duration(seconds: 8), () {
      _settleTrimFollowUpTimer = null;
      if (WindowRenderGate.instance.framesEnabled.value) return;
      _trimWorkingSet();
    });
  }

  /// 回到前台：停掉隐藏期间的换出，缓存和页面都不动。
  void stopHiddenTrim() {
    _settleTrimTimer?.cancel();
    _settleTrimTimer = null;
    _settleTrimFollowUpTimer?.cancel();
    _settleTrimFollowUpTimer = null;
    _hiddenTrimTimer?.cancel();
    _hiddenTrimTimer = null;
    _hiddenWatchdogTimer?.cancel();
    _hiddenWatchdogTimer = null;
    _hiddenNowPlaying?.removeListener(_onHiddenSongChanged);
    _hiddenNowPlaying = null;
    _hiddenSongPath = null;
  }

  bool _cleanupDue(DateTime now, DateTime? lastRun, Duration cooldown) =>
      lastRun == null || now.difference(lastRun) >= cooldown;

  /// 播放中的画面会持续复用图片、文字和图形缓存，不能按 RSS 周期清空。
  bool _isPlaying() {
    try {
      final state = PlayService.existingPlaybackService?.playerState;
      return state == PlayerState.playing || state == PlayerState.stalled;
    } catch (_) {
      return false;
    }
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      try {
        _checkMemoryPressure();
      } catch (e, trace) {
        log.memory.error('legacy', '[mem] monitor error: $e\n$trace');
      }
    });
  }

  void _checkMemoryPressure() {
    // 窗口看不见时只是不画，这里不做瘦身，也不卡工作集。
    if (!WindowRenderGate.instance.framesEnabled.value) return;
    final now = DateTime.now();
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    if (_isPlaying()) {
      // 播放中只回收过期封面，前台可见时不清图片缓存。
      if (_cleanupDue(
        now,
        _lastPlayingLightCleanupAt,
        const Duration(minutes: 2),
      )) {
        _lastPlayingLightCleanupAt = now;
        AudioLibrary.instance.evictStaleCoverBytes();
        AudioLibrary.instance.trimCollectionThumbnailRetention(96);
      }
      if (Platform.environment['CP_MEMORY_LOG'] == '1') {
        CoverImageCache.instance.logStats();
      }
      return;
    }
    final rssMB = (ProcessInfo.currentRss / (1024 * 1024)).round();
    const tier1Threshold = 220;
    const tier2Threshold = 260;
    const tier3Threshold = 320;
    if (rssMB > tier3Threshold &&
        _cleanupDue(now, _lastTier3CleanupAt, const Duration(minutes: 1))) {
      _runTier3Cleanup(now, playingPath, rssMB, tier3Threshold);
    } else if (rssMB > tier2Threshold &&
        _cleanupDue(now, _lastTier2CleanupAt, const Duration(minutes: 3))) {
      _runTier2Cleanup(now, playingPath, rssMB, tier2Threshold);
    } else if (rssMB > tier1Threshold &&
        _cleanupDue(now, _lastTier1CleanupAt, const Duration(minutes: 1))) {
      _runTier1Cleanup(now);
    }
    if (Platform.environment['CP_MEMORY_LOG'] == '1') {
      CoverImageCache.instance.logStats();
    }
  }

  void _reclaimColdCovers(String? playingPath, int thumbnailRetention) {
    CoverImageCache.instance.trimMemory(keepPath: playingPath);
    CoverImageCache.instance.trimSmall(keepEntries: 64);
    AudioLibrary.instance.trimCollectionThumbnailRetention(thumbnailRetention);
    LyricsLinePainter.trimPool();
    LyricsLineWidget.clearBlurFilterCache();
    AudioLibrary.instance.evictStaleCoverBytes();
  }

  void _runTier3Cleanup(
    DateTime now,
    String? playingPath,
    int rssMB,
    int tier3Threshold,
  ) {
    _lastTier1CleanupAt = now;
    _lastTier2CleanupAt = now;
    _lastTier3CleanupAt = now;
    log.memory.warn(
      'legacy',
      '[mem] RSS ${rssMB}MB > $tier3Threshold, tier-3 emergency cleanup',
    );
    // 三档和二档一样，只回收用不到的封面，不清歌词缓存。
    _reclaimColdCovers(playingPath, 80);
  }

  void _runTier2Cleanup(
    DateTime now,
    String? playingPath,
    int rssMB,
    int tier2Threshold,
  ) {
    _lastTier1CleanupAt = now;
    _lastTier2CleanupAt = now;
    log.memory.warn(
      'legacy',
      '[mem] RSS ${rssMB}MB > $tier2Threshold, tier-2 cleanup',
    );
    _reclaimColdCovers(playingPath, 80);
  }

  void _runTier1Cleanup(DateTime now) {
    _lastTier1CleanupAt = now;
    AudioLibrary.instance.trimCollectionThumbnailRetention(128);
    LyricsLinePainter.trimPool();
    AudioLibrary.instance.evictStaleCoverBytes();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    stopHiddenTrim();
  }

  void trimAfterSongChange() {
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    AudioLibrary.instance.evictStaleCoverBytes();
    AudioLibrary.instance.trimCollectionThumbnailRetention(96);
    CoverImageCache.instance.trimMemory(keepPath: playingPath);
    CoverImageCache.instance.trimSmall(keepEntries: 64);
  }

  /// 离开播放页时只收当前用不到的大封面，歌词和曲库留着。
  void trimLeftNowPlayingPage() {
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    CoverImageCache.instance.trimMemory(keepPath: playingPath);
    LyricsLineWidget.clearBlurFilterCache();
  }

  /// 从托盘回到窗口后，恢复前台能用的图片缓存额度。
  void restoreForegroundImageCache() {
    stopHiddenTrim();
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSize = 64;
    cache.maximumSizeBytes = 16 << 20;
  }

  /// 托盘隐藏：界面树已整棵卸掉，图片和排版缓存一并清，再按间隔换出工作集。
  void trimTrayHidden() {
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    AudioLibrary.instance.evictStaleCoverBytes();
    CoverImageCache.instance.trimMemory(keepPath: playingPath);
    AudioLibrary.instance.trimCollectionThumbnailRetention(16);
    PaintingBinding.instance.imageCache.clear();
    LyricsLinePainter.trimPool();
    LyricsLineWidget.clearBlurFilterCache();
    _holdWorkingSetWhileHidden();
  }

  /// 最小化：界面留着以便秒回，只换出工作集页，图片缓存不清。
  /// 歌词排版池和模糊滤镜隐藏时用不到，先收掉，少一块要换出的页。
  void trimWindowMinimized() {
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    AudioLibrary.instance.evictStaleCoverBytes();
    CoverImageCache.instance.trimMemory(keepPath: playingPath);
    AudioLibrary.instance.trimCollectionThumbnailRetention(32);
    LyricsLinePainter.trimPool();
    LyricsLineWidget.clearBlurFilterCache();
    _holdWorkingSetWhileHidden();
  }

  /// 只回收冷封面和多余缩略图，不清图片缓存，也不动曲库。
  void trimAll() {
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    AudioLibrary.instance.evictStaleCoverBytes();
    CoverImageCache.instance.trimMemory(keepPath: playingPath);
    AudioLibrary.instance.trimCollectionThumbnailRetention(64);
  }
}
