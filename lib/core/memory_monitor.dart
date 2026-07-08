import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/color_extraction.dart';
import 'package:pure_music/core/matcher.dart' hide logger;
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';
import 'package:pure_music/play_service/play_service.dart';

typedef _GetCurrentProcessNative = ffi.IntPtr Function();
typedef _GetCurrentProcessDart = int Function();
typedef _SetProcessWorkingSetSizeNative = ffi.Int32 Function(
  ffi.IntPtr process,
  ffi.IntPtr minimumWorkingSetSize,
  ffi.IntPtr maximumWorkingSetSize,
);
typedef _SetProcessWorkingSetSizeDart = int Function(
  int process,
  int minimumWorkingSetSize,
  int maximumWorkingSetSize,
);

class _WindowsWorkingSetTrimmer {
  static bool _loaded = false;
  static _GetCurrentProcessDart? _getCurrentProcess;
  static _SetProcessWorkingSetSizeDart? _setProcessWorkingSetSize;

  static bool trim() {
    if (!Platform.isWindows) return false;
    try {
      _load();
      final getCurrentProcess = _getCurrentProcess;
      final setProcessWorkingSetSize = _setProcessWorkingSetSize;
      if (getCurrentProcess == null || setProcessWorkingSetSize == null) {
        return false;
      }
      return setProcessWorkingSetSize(getCurrentProcess(), -1, -1) != 0;
    } catch (e, trace) {
      logger.w('[mem] Windows working set trim failed: $e\n$trace');
      return false;
    }
  }

  static void _load() {
    if (_loaded) return;
    _loaded = true;
    final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    _getCurrentProcess = kernel32.lookupFunction<_GetCurrentProcessNative,
        _GetCurrentProcessDart>('GetCurrentProcess');
    _setProcessWorkingSetSize = kernel32.lookupFunction<
        _SetProcessWorkingSetSizeNative,
        _SetProcessWorkingSetSizeDart>('SetProcessWorkingSetSize');
  }
}

/// 内存监控服务：定时检查 RSS，分级清理缓存
class MemoryMonitorService {
  static final instance = MemoryMonitorService._();
  MemoryMonitorService._();

  Timer? _timer;

  /// 播放状态下仅做轻量清理，避免缓存重建开销导致音频卡顿
  bool _isPlaying() {
    try {
      return PlayService.instance.playbackService.playerState ==
          PlayerState.playing;
    } catch (_) {
      return false;
    }
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      try {
        final rssMB = (ProcessInfo.currentRss / (1024 * 1024)).round();

        final playing = _isPlaying();
        // 播放中贴近 140-160MB 目标区间，越界后从轻到重逐级清理。
        final tier1Threshold = playing ? 185 : 220;
        final tier2Threshold = playing ? 240 : 270;
        final tier3Threshold = playing ? 300 : 330;

        if (rssMB > tier3Threshold) {
          logger.w(
            '[mem] RSS ${rssMB}MB > $tier3Threshold, tier-3 emergency cleanup',
          );
          // clear() only removes non-live decoded images, so it is safe during playback.
          PaintingBinding.instance.imageCache.clear();
          if (!playing) {
            PaintingBinding.instance.imageCache.clearLiveImages();
          }
          CoverImageCache.instance.trimMemory();
          ColorExtractionService().clear();
          LyricsLinePainter.clearPool();
          LyricsLineWidget.clearBlurFilterCache();
          AudioLibrary.instance.evictAllCoversExcept(
            PlayService.instance.playbackService.nowPlaying?.path,
            includeCollectionCovers: true,
          );
          clearLyricCaches();
          _WindowsWorkingSetTrimmer.trim();
        } else if (rssMB > tier2Threshold) {
          logger.w(
            '[mem] RSS ${rssMB}MB > $tier2Threshold, tier-2 cleanup',
          );
          PaintingBinding.instance.imageCache.clear();
          CoverImageCache.instance.trimMemory();
          LyricsLinePainter.trimPool();
          LyricsLineWidget.clearBlurFilterCache();
          AudioLibrary.instance.evictStaleCoverBytes();
        } else if (rssMB > tier1Threshold) {
          // tier-1: keep playback smooth; avoid forcing image reloads or OS working-set trim.
          LyricsLinePainter.trimPool();
          AudioLibrary.instance.evictStaleCoverBytes();
        }

        if (Platform.environment['CP_MEMORY_LOG'] == '1') {
          CoverImageCache.instance.logStats();
        }
      } catch (e, trace) {
        logger.e('[mem] monitor error: $e\n$trace');
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void trimAfterSongChange() {
    final rssMB = (ProcessInfo.currentRss / (1024 * 1024)).round();
    if (rssMB < 190) return;

    // Song changes are latency-sensitive. Do the lightest useful cleanup first
    // and leave OS working-set trimming to the emergency path.
    AudioLibrary.instance.evictStaleCoverBytes();
    if (rssMB >= 220) {
      PaintingBinding.instance.imageCache.clear();
      LyricsLinePainter.trimPool();
    }
    if (rssMB >= 260) {
      CoverImageCache.instance.trimMemory();
    }
  }

  /// 强制释放可回收内存，用于窗口最小化/低内存通知等场景
  void trimAll() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    CoverImageCache.instance.trimMemory();
    CoverImageCache.instance.clear();
    ColorExtractionService().clear();
    LyricsLinePainter.clearPool();
    LyricsLineWidget.clearBlurFilterCache();
    AudioLibrary.instance.evictAllCoversExcept(
      PlayService.instance.playbackService.nowPlaying?.path,
      includeCollectionCovers: true,
    );
    _WindowsWorkingSetTrimmer.trim();
  }
}
