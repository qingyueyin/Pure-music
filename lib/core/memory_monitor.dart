import 'dart:async';
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

/// 托盘整段时间都保持工作集上限。窗口打开后才放开。
bool traySessionKeepsWorkingSetCap({required bool trayResident}) =>
    trayResident;

/// 托盘上限还按着的时候，后续清理不能用「清空工作集配额」把它冲掉。
bool followUpTrimMayDropWorkingSetCap({required bool trayClampHeld}) =>
    !trayClampHeld;

/// 定时看 RSS，只回收冷封面；窗口不可见时不改工作集，也不清图片缓存和曲库。
class MemoryMonitorService {
  static final instance = MemoryMonitorService._();
  MemoryMonitorService._();

  Timer? _timer;
  DateTime? _lastTier1CleanupAt;
  DateTime? _lastTier2CleanupAt;
  DateTime? _lastTier3CleanupAt;
  DateTime? _lastPlayingLightCleanupAt;

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
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSize = 64;
    cache.maximumSizeBytes = 16 << 20;
  }

  /// 窗口回来时不再改进程工作集。
  void releaseTrayWorkingSetClamp() {}

  /// 托盘隐藏期间不再压工作集上限。
  void reclampTrayWorkingSetIfHidden() {}

  /// 托盘隐藏时只回收冷封面，当前曲和曲库留着。
  void trimTrayHidden() {
    void evict() {
      if (WindowRenderGate.instance.framesEnabled.value) return;
      final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
      AudioLibrary.instance.evictStaleCoverBytes();
      CoverImageCache.instance.trimMemory(keepPath: playingPath);
      AudioLibrary.instance.trimCollectionThumbnailRetention(32);
    }

    evict();
    // 界面卸掉后还有一小波收尾，落定后再做一次轻量瘦身。
    Timer(const Duration(seconds: 2), evict);
  }

  /// 最小化时只回收冷封面，当前这首留着。
  void trimWindowMinimized() {
    void trim() {
      final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
      AudioLibrary.instance.evictStaleCoverBytes();
      CoverImageCache.instance.trimMemory(keepPath: playingPath);
      AudioLibrary.instance.trimCollectionThumbnailRetention(32);
    }

    trim();
    // 最小化的头两秒还有收尾绘制，落定后再补一次；已经回到前台就不收。
    Timer(const Duration(seconds: 2), () {
      if (WindowRenderGate.instance.framesEnabled.value) return;
      trim();
    });
  }

  /// 只回收冷封面和多余缩略图，不清图片缓存，也不动曲库。
  void trimAll() {
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    AudioLibrary.instance.evictStaleCoverBytes();
    CoverImageCache.instance.trimMemory(keepPath: playingPath);
    AudioLibrary.instance.trimCollectionThumbnailRetention(64);
  }
}
