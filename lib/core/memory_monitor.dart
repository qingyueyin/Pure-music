import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_frame_probe.dart';
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
/// 失焦 30 秒（被完全挡住）做一次温和裁剪并换出工作集，不清图片缓存。
class MemoryMonitorService {
  static final instance = MemoryMonitorService._();
  MemoryMonitorService._() {
    // 门闩回到可见也算一次恢复，用来丢弃看门狗里过期的 await 结果。
    WindowRenderGate.instance.framesEnabled.addListener(
      _onFramesEnabledChanged,
    );
  }

  Timer? _timer;
  Timer? _settleTrimTimer;
  Timer? _settleTrimFollowUpTimer;
  Timer? _hiddenTrimTimer;
  Timer? _hiddenWatchdogTimer;
  Timer? _backgroundIdleRestoreTimer;
  bool _hiddenWatchdogBusy = false;
  int _hiddenTrimTicks = 0;
  int _hiddenEpoch = 0;
  DateTime? _lastTrimLogAt;
  DateTime? _lastTrimWarnAt;

  /// 头段快速换出的次数，以及掉幅低于多少就认为页立刻被拉回。
  static const _hiddenFastTrimTicks = 8;
  static const _minTrimDropBytes = 10 * 1024 * 1024;
  Listenable? _hiddenNowPlaying;
  String? _hiddenSongPath;
  DateTime? _lastTier1CleanupAt;
  DateTime? _lastTier2CleanupAt;
  DateTime? _lastTier3CleanupAt;
  DateTime? _lastPlayingLightCleanupAt;

  static ffi.DynamicLibrary? _kernel32;
  static _SetProcessWorkingSetSizeDart? _setProcessWorkingSetSize;

  /// 把工作集页换出到备用列表。只动内存页，不碰音频缓冲，也不丢缓存数据。
  /// 返回本次 RSS 掉幅（字节）；换出失败返回 -1。
  int _trimWorkingSet() {
    final watch = Stopwatch()..start();
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
      final after = ProcessInfo.currentRss;
      watch.stop();
      _logTrim(ok, before, after, watch.elapsedMilliseconds);
      return ok == 0 ? -1 : before - after;
    } catch (e) {
      watch.stop();
      _setProcessWorkingSetSize = null;
      _logTrimWarn('trim failed: $e');
      return -1;
    }
  }

  /// 换出后立刻回读 RSS。成功路径 30 秒最多一条；失败必须留痕。
  void _logTrim(int ok, int before, int after, int elapsedMs) {
    final now = DateTime.now();
    final last = _lastTrimLogAt;
    if (ok != 0 &&
        last != null &&
        now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastTrimLogAt = now;
    const mb = 1024 * 1024;
    log.memory.info(
      'legacy',
      '[mem] trim ok=$ok rss ${before ~/ mb}→${after ~/ mb}MB ${elapsedMs}ms',
    );
  }

  /// 换出失败、看门狗异常各留一条，30 秒节流。
  void _logTrimWarn(String message) {
    final now = DateTime.now();
    final last = _lastTrimWarnAt;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastTrimWarnAt = now;
    log.memory.warn('legacy', '[mem] $message');
  }

  /// 隐藏期间换出工作集。只换一次会被帧循环重新拉回，先每 3 秒补几次，
  /// 掉幅变小或补够次数就退到 15 秒。
  void _holdWorkingSetWhileHidden() {
    _armSettleTrim();
    _scheduleHiddenTrim();
    _watchHiddenSongChange();
  }

  void _scheduleHiddenTrim() {
    _hiddenTrimTimer?.cancel();
    _hiddenTrimTicks = 0;
    _hiddenTrimTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (WindowRenderGate.instance.framesEnabled.value) return;
      final drop = _trimWorkingSet();
      _hiddenTrimTicks++;
      // 掉幅 <10MB 说明页立刻被拉回，再快也没用，直接退到长间隔。
      if (drop >= 0 && drop < _minTrimDropBytes) {
        _startSlowHiddenTrim();
        return;
      }
      if (_hiddenTrimTicks < _hiddenFastTrimTicks) return;
      // 落定后回到长间隔，别一直每 3 秒打扰系统。
      _startSlowHiddenTrim();
    });
  }

  void _startSlowHiddenTrim() {
    _hiddenTrimTimer?.cancel();
    _hiddenTrimTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (WindowRenderGate.instance.framesEnabled.value) return;
      _trimWorkingSet();
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
  /// 最小化期间每 5 秒核对真实窗口状态。
  void _startHiddenWatchdog() {
    _hiddenWatchdogTimer?.cancel();
    _hiddenWatchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_reconcileHiddenWindow());
    });
  }

  void _onFramesEnabledChanged() {
    // 门闩任何一次变化都作废看门狗里在途的判定，避免把刚恢复的窗口按回隐藏。
    _hiddenEpoch++;
  }

  Future<void> _reconcileHiddenWindow() async {
    if (_hiddenWatchdogBusy) return;
    _hiddenWatchdogBusy = true;
    final epoch = _hiddenEpoch;
    try {
      final gate = WindowRenderGate.instance;
      if (gate.trayHidden.value) {
        // 转托盘后由托盘节奏负责，看门狗自停。
        _hiddenWatchdogTimer?.cancel();
        _hiddenWatchdogTimer = null;
        return;
      }
      final minimized = await windowManager.isMinimized();
      // 等结果期间已经恢复：epoch 变了就丢掉过期结果，别把门闩按回去。
      final stale = epoch != _hiddenEpoch || gate.trayHidden.value;
      WindowFrameProbe.watchdog(
        epoch: epoch,
        currentEpoch: _hiddenEpoch,
        minimized: minimized,
        stale: stale,
      );
      if (stale) return;
      if (minimized) {
        gate.setWindowMinimized(true);
        return;
      }
      gate.setWindowMinimized(false);
      stopHiddenTrim();
    } catch (e) {
      // 没有窗口插件（测试环境）时不再尝试。
      _logTrimWarn('watchdog failed: $e');
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
    _hiddenEpoch++;
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
    WindowRenderGate.instance.backgroundIdle.addListener(
      _onBackgroundIdleChanged,
    );
  }

  /// 失焦闲时做一次温和裁剪 + 换出；回前台后停掉跟进换出。
  void _onBackgroundIdleChanged() {
    final idle = WindowRenderGate.instance.backgroundIdle.value;
    if (idle) {
      final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
      AudioLibrary.instance.evictStaleCoverBytes();
      AudioLibrary.instance.trimCollectionThumbnailRetention(96);
      CoverImageCache.instance.trimMemory(keepPath: playingPath);
      LyricsLineWidget.clearBlurFilterCache();
      _trimWorkingSet();
      // 被挡住期间还会切歌解码新封面，一次清理压不住；闲时每分钟复查一次。
      _backgroundIdleRestoreTimer?.cancel();
      _backgroundIdleRestoreTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => _trimBackgroundIdle(),
      );
      log.memory.info('legacy', '[mem] background idle trim');
      return;
    }
    _backgroundIdleRestoreTimer?.cancel();
    _backgroundIdleRestoreTimer = null;
  }

  void _trimBackgroundIdle() {
    if (!WindowRenderGate.instance.backgroundIdle.value) {
      _backgroundIdleRestoreTimer?.cancel();
      _backgroundIdleRestoreTimer = null;
      return;
    }
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    AudioLibrary.instance.evictStaleCoverBytes();
    AudioLibrary.instance.trimCollectionThumbnailRetention(64);
    CoverImageCache.instance.trimMemory(keepPath: playingPath);
    _trimWorkingSet();
  }

  void _checkMemoryPressure() {
    // 窗口看不见时只是不画，这里不做瘦身，也不卡工作集。
    if (!WindowRenderGate.instance.framesEnabled.value) return;
    final now = DateTime.now();
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    const tier1Threshold = 220;
    const tier2Threshold = 260;
    const tier3Threshold = 320;
    if (_isPlaying()) {
      // 播放中的常规轻清理：只回收过期封面。
      if (_cleanupDue(
        now,
        _lastPlayingLightCleanupAt,
        const Duration(minutes: 2),
      )) {
        _lastPlayingLightCleanupAt = now;
        AudioLibrary.instance.evictStaleCoverBytes();
        AudioLibrary.instance.trimCollectionThumbnailRetention(96);
      }
      // 播放中同样要按阈值兜底，否则一场长播下来只涨不落。
      // 播放本身就要占 300MB 左右，阈值必须高于正常占用，
      // 否则每分钟都会误触发；不清 imageCache，歌词对象池只做限额裁剪。
      const playingTier1Threshold = 180;
      const playingTier2Threshold = 240;
      const playingTier3Threshold = 280;
      final playingRssMB = (ProcessInfo.currentRss / (1024 * 1024)).round();
      if (playingRssMB > playingTier3Threshold &&
          _cleanupDue(now, _lastTier3CleanupAt, const Duration(minutes: 5))) {
        _runTier3Cleanup(now, playingPath, playingRssMB, playingTier3Threshold);
        // 最后一道兜底：把工作集页换出到备用列表，不动音频缓冲。
        _trimWorkingSet();
      } else if (playingRssMB > playingTier2Threshold &&
          _cleanupDue(now, _lastTier2CleanupAt, const Duration(minutes: 10))) {
        _runTier2Cleanup(now, playingPath, playingRssMB, playingTier2Threshold);
      } else if (playingRssMB > playingTier1Threshold &&
          _cleanupDue(now, _lastTier1CleanupAt, const Duration(minutes: 2))) {
        _runTier1Cleanup(now);
        // 播放中一直渲染，工作集会一路涨到 tier-3 的 280MB 才回落；
        // 一级就把页换出，峰值压在 180MB 附近，省下的都是看得见的那一段。
        _trimWorkingSet();
      }
      if (Platform.environment['CP_MEMORY_LOG'] == '1') {
        CoverImageCache.instance.logStats();
      }
      return;
    }
    final rssMB = (ProcessInfo.currentRss / (1024 * 1024)).round();
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
    WindowRenderGate.instance.backgroundIdle.removeListener(
      _onBackgroundIdleChanged,
    );
    _backgroundIdleRestoreTimer?.cancel();
    _backgroundIdleRestoreTimer = null;
    stopHiddenTrim();
  }

  void trimAfterSongChange() {
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    AudioLibrary.instance.evictStaleCoverBytes();
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
    cache.maximumSize = 128;
    cache.maximumSizeBytes = 48 << 20;
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
  /// 歌词排版池隐藏时用不到，先收掉，少一块要换出的页。
  void trimWindowMinimized() {
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    AudioLibrary.instance.evictStaleCoverBytes();
    CoverImageCache.instance.trimMemory(keepPath: playingPath);
    AudioLibrary.instance.trimCollectionThumbnailRetention(32);
    LyricsLinePainter.trimPool();
    _holdWorkingSetWhileHidden();
    _startHiddenWatchdog();
  }

  /// 只回收冷封面和多余缩略图，不清图片缓存，也不动曲库。
  void trimAll() {
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    AudioLibrary.instance.evictStaleCoverBytes();
    CoverImageCache.instance.trimMemory(keepPath: playingPath);
    AudioLibrary.instance.trimCollectionThumbnailRetention(64);
  }
}
