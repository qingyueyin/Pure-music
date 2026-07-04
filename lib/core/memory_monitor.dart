
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/matcher.dart' hide logger;
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';

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
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      try {
        final rssMB = (ProcessInfo.currentRss / (1024 * 1024)).round();

        // 播放状态下调高阈值，避免频繁清理引起缓存重建和 GC 抖动
        final playing = _isPlaying();
        // 起始 RSS ~230MB，阈值从低到高逐级清理
        final tier1Threshold = playing ? 290 : 250;
        final tier2Threshold = playing ? 330 : 280;
        final tier3Threshold = playing ? 390 : 330;

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
        } else if (rssMB > tier1Threshold) {
          // tier-1 轻量清理：仅清 ImageCache（不碰 CoverImageCache 和歌词缓存）
          if (!playing) {
            PaintingBinding.instance.imageCache.clear();
          }
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

  /// 强制释放可回收内存，用于窗口最小化/低内存通知等场景
  void trimAll() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    CoverImageCache.instance.trimMemory();
    CoverImageCache.instance.clear();
    AudioLibrary.instance.evictAllCoversExcept(
      PlayService.instance.playbackService.nowPlaying?.path,
    );
  }
}
