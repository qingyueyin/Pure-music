import 'dart:async';
import 'dart:math';
import 'dart:collection';
import 'dart:io';

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/lyric/lyric_stripper.dart';
import 'package:pure_music/lyric/lyric_loader.dart';
import 'package:pure_music/core/matcher.dart' hide logger;
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

const int _kLyricCacheCapacity = 32;

class LyricCache {
  final LinkedHashMap<String, Lyric> _cache = LinkedHashMap();

  Lyric? get(String path) {
    final lyric = _cache[path];
    if (lyric != null) {
      _cache.remove(path);
      _cache[path] = lyric;
    }
    return lyric;
  }

  bool containsKey(String path) => _cache.containsKey(path);

  void put(String path, Lyric lyric) {
    if (_cache.containsKey(path)) {
      _cache.remove(path);
    } else if (_cache.length >= _kLyricCacheCapacity) {
      _cache.remove(_cache.keys.first);
    }
    _cache[path] = lyric;
  }

  void remove(String path) {
    _cache.remove(path);
  }

  void clear() {
    _cache.clear();
  }
}

final LyricCache _lyricCache = LyricCache();

/// 只通知 lyric 变更
class LyricService extends ChangeNotifier {
  final PlayService playService;

  late StreamSubscription _positionStreamSubscription;
  double _lastPos = 0.0;
  Lyric? _currLyric;
  List<int> _lineStartMs = const [];
  int _lastEmittedLineIndex = -1;
  int _lastDesktopLyricLineIndex = -1;

  /// 已经提示过/忽略过的歌曲路径，避免重复提示
  /// LRU 集合，上限 2000 条防内存泄漏
  final LinkedHashSet<String> _promptedSongs = LinkedHashSet();
  static const int _kMaxPromptedSongs = 500;

  void _addPromptedSong(String path) {
    _promptedSongs.add(path);
    if (_promptedSongs.length > _kMaxPromptedSongs) {
      _promptedSongs.remove(_promptedSongs.first);
    }
  }

  Timer? _promptTimer;
  LyricService(this.playService) {
    _positionStreamSubscription =
        playService.playbackService.positionStream.listen((pos) {
      final jumped = (pos - _lastPos).abs() > 1.0;
      _lastPos = pos;
      final posMs = (pos * 1000).round();
      if (jumped) {
        findCurrLyricLineAt(pos);
        return;
      }
      final lyric = _currLyric;
      if (lyric == null) return;
      if (_nextLyricLine >= lyric.lines.length) {
        if (_lineStartMs.isEmpty || posMs > _lineStartMs.last) return;
        findCurrLyricLineAt(pos);
        return;
      }
      while (_nextLyricLine < _lineStartMs.length &&
          posMs > _lineStartMs[_nextLyricLine]) {
        _nextLyricLine += 1;
      }

      final currLineIndex = _nextLyricLine - 1;
      if (currLineIndex < 0 || currLineIndex >= lyric.lines.length) return;

      final activeIndices = _computeActiveLines(posMs);
      var primaryIndex = currLineIndex;
      if (activeIndices.isEmpty && currLineIndex + 1 < lyric.lines.length) {
        // 间奏：当前行已结束且下一行未开始，推进到下一行预览
        final currEnd = lyric.lines[currLineIndex].start.inMilliseconds +
            lyric.lines[currLineIndex].length.inMilliseconds;
        final nextStart = _lineStartMs[currLineIndex + 1];
        if (posMs >= currEnd && posMs < nextStart) {
          primaryIndex = currLineIndex + 1;
        }
      } else if (activeIndices.isNotEmpty) {
        // 当前行指针还未推进但下一行已激活（posMs == nextStart 的边界），
        // 取最早激活行做 primaryIndex
        final minActive = activeIndices.first;
        if (minActive > currLineIndex) {
          primaryIndex = minActive;
        }
      }
      if (primaryIndex != _lastEmittedLineIndex ||
          !listEquals(_lastEmittedActiveIndices, activeIndices)) {
        _lastEmittedLineIndex = primaryIndex;
        _lastEmittedLineIndexForHint = primaryIndex;
        _lastEmittedActiveIndices = activeIndices;
        _lyricLineStreamController.add(LyricLineUpdate(
          primaryIndex: primaryIndex,
          activeIndices: activeIndices,
        ));
      }

      if (primaryIndex != _lastDesktopLyricLineIndex) {
        _lastDesktopLyricLineIndex = primaryIndex;
        if (primaryIndex >= 0 && primaryIndex < lyric.lines.length) {
          final nextLine = primaryIndex + 1 < lyric.lines.length
              ? lyric.lines[primaryIndex + 1]
              : null;
          playService.desktopLyricService.canSendMessage.then((canSend) {
            if (!canSend) return;
            playService.desktopLyricService.sendLyricLineMessage(
              lyric.lines[primaryIndex],
              nextLine: nextLine,
            );
          });
        }
      }
    });
  }

  Audio? _getNowPlaying() => playService.playbackService.nowPlaying;

  String? _buildLyricLrcText(
    Lyric lyric, {
    required bool enhancedIfPossible,
  }) {
    if (lyric.lines.isEmpty) return null;

    String formatTimeTag(Duration t) {
      final totalMs = max(0, t.inMilliseconds);
      final m = totalMs ~/ 60000;
      final s = (totalMs % 60000) / 1000.0;
      final mm = m.toString().padLeft(2, '0');
      final ss = s.toStringAsFixed(2).padLeft(5, '0');
      return '[$mm:$ss]';
    }

    String formatWordTag(Duration t) {
      final totalMs = max(0, t.inMilliseconds);
      final m = totalMs ~/ 60000;
      final s = (totalMs % 60000) / 1000.0;
      final mm = m.toString().padLeft(2, '0');
      final ss = s.toStringAsFixed(2).padLeft(5, '0');
      return '<$mm:$ss>';
    }

    String buildEnhancedLine(SyncLyricLine line) {
      final buffer = StringBuffer();
      buffer.write(formatTimeTag(line.start));
      for (final w in line.words) {
        if (w.content.isEmpty) continue;
        buffer.write(formatWordTag(w.start));
        buffer.write(w.content);
      }
      if (line.translation != null && line.translation!.trim().isNotEmpty) {
        buffer.write('┃');
        buffer.write(line.translation!.trim());
      }
      return buffer.toString();
    }

    String buildUnsyncLine(LrcLine line) {
      return '${formatTimeTag(line.start)}${line.content}';
    }

    final lines = <String>[];
    for (final line in lyric.lines) {
      if (enhancedIfPossible && line is SyncLyricLine) {
        lines.add(buildEnhancedLine(line));
      } else if (line is LrcLine) {
        lines.add(buildUnsyncLine(line));
      } else if (line is SyncLyricLine) {
        lines.add(buildEnhancedLine(line));
      }
    }
    if (lines.isEmpty) return null;
    return lines.join('\n');
  }

  Future<void> writeCurrentLyricToTag({bool enhancedIfPossible = true}) async {
    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return;

    final lyric = _currLyric ?? await currLyricFuture;
    if (lyric == null) return;

    // 优先使用原始未解析的 LRC 文本，避免重建丢失逐词时间戳
    final lrcText = lyric.rawText ??
        _buildLyricLrcText(lyric, enhancedIfPossible: enhancedIfPossible);
    if (lrcText == null || lrcText.trim().isEmpty) return;

    await writeLyricToPath(path: nowPlaying.path, lyric: lrcText);
  }

  Future<String?> saveCurrentLyricAsLrc(
      {bool enhancedIfPossible = true}) async {
    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return null;

    final lyric = _currLyric ?? await currLyricFuture;
    if (lyric == null) return null;

    final lrcText = lyric.rawText ??
        _buildLyricLrcText(lyric, enhancedIfPossible: enhancedIfPossible);
    if (lrcText == null) return null;

    final dir = p.dirname(nowPlaying.path);
    final base = p.basenameWithoutExtension(nowPlaying.path);
    final outPath = p.join(dir, '$base.lrc');
    final outFile = File(outPath);

    if (outFile.existsSync()) {
      final bakPath = p.join(dir, '$base.lrc.bak');
      try {
        await outFile.copy(bakPath);
      } catch (_) {}
    }

    await outFile.writeAsString(lrcText, flush: true);

    return outPath;
  }

  /// 供 widget 使用
  Future<Lyric?> currLyricFuture = Future.value(null);

  /// 当前歌词是否已加载
  bool get hasLyric => _currLyric != null;

  /// 下一行歌词
  int _nextLyricLine = 0;
  int _lastEmittedLineIndexForHint = -1;
  List<int> _lastEmittedActiveIndices = const [];

  late final StreamController<LyricLineUpdate> _lyricLineStreamController =
      StreamController.broadcast(onListen: () {
    forceEmitCurrentLine();
  });

  Stream<LyricLineUpdate> get lyricLineStream => _lyricLineStreamController.stream;

  /// 强制发射当前行（绕过 _lastEmittedLineIndex 检查），
  /// 用于新创建的歌词 view 初始化时获取当前行
  void forceEmitCurrentLine() {
    final lyric = _currLyric;
    if (lyric == null) {
      currLyricFuture.then((value) {
        if (value == null) return;
        _setCurrLyric(value);
        forceEmitCurrentLine();
      });
      return;
    }
    final posMs = (playService.playbackService.position * 1000).round();
    final next = _findLrcPos(
        time: posMs, lines: lyric.lines, hint: _lastEmittedLineIndexForHint);
    _nextLyricLine = next == -1 ? lyric.lines.length : next;
    final currLineIndex = _nextLyricLine - 1;
    if (currLineIndex < 0) return;
    if (currLineIndex >= lyric.lines.length) return;

    final activeIndices = _computeActiveLines(posMs);
    var primaryIndex = currLineIndex;
    if (activeIndices.isEmpty && currLineIndex + 1 < lyric.lines.length) {
      final currEnd = lyric.lines[currLineIndex].start.inMilliseconds +
          lyric.lines[currLineIndex].length.inMilliseconds;
      final nextStart = _lineStartMs[currLineIndex + 1];
      if (posMs >= currEnd && posMs < nextStart) {
        primaryIndex = currLineIndex + 1;
      }
    } else if (activeIndices.isNotEmpty) {
      final minActive = activeIndices.first;
      if (minActive > currLineIndex) {
        primaryIndex = minActive;
      }
    }
    _lastEmittedLineIndex = primaryIndex;
    _lastEmittedLineIndexForHint = primaryIndex;
    _lastEmittedActiveIndices = activeIndices;
      _lyricLineStreamController.add(LyricLineUpdate(
        primaryIndex: primaryIndex,
        activeIndices: activeIndices,
      ));

    if (primaryIndex != _lastDesktopLyricLineIndex) {
      _lastDesktopLyricLineIndex = primaryIndex;
      if (primaryIndex >= 0 && primaryIndex < lyric.lines.length) {
        final nextLine = primaryIndex + 1 < lyric.lines.length
            ? lyric.lines[primaryIndex + 1]
            : null;
        playService.desktopLyricService.canSendMessage.then((canSend) {
          if (!canSend) return;
          playService.desktopLyricService.sendLyricLineMessage(
            lyric.lines[primaryIndex],
            nextLine: nextLine,
          );
        });
      }
    }
  }

  /// 重新计算歌词进行到第几行
  void findCurrLyricLine() {
    findCurrLyricLineAt(playService.playbackService.position);
  }

  void findCurrLyricLineAt(double positionSeconds) {
    final lyric = _currLyric;
    if (lyric == null) {
      currLyricFuture.then((value) {
        if (value == null) return;
        _setCurrLyric(value);
        findCurrLyricLineAt(positionSeconds);
      });
      return;
    }

    final posMs = (positionSeconds * 1000).round();
    final hint = _lastEmittedLineIndexForHint;
    final next = _findLrcPos(time: posMs, lines: lyric.lines, hint: hint);
    _nextLyricLine = next == -1 ? lyric.lines.length : next;
    final currLineIndex = _nextLyricLine - 1;

    if (currLineIndex < 0) return;

    final activeIndices = _computeActiveLines(posMs);
    var primaryIndex = currLineIndex;
    if (activeIndices.isEmpty && currLineIndex + 1 < lyric.lines.length) {
      final currEnd = lyric.lines[currLineIndex].start.inMilliseconds +
          lyric.lines[currLineIndex].length.inMilliseconds;
      final nextStart = lyric.lines[currLineIndex + 1].start.inMilliseconds;
      if (posMs >= currEnd && posMs < nextStart) {
        primaryIndex = currLineIndex + 1;
      }
    } else if (activeIndices.isNotEmpty) {
      final minActive = activeIndices.first;
      if (minActive > currLineIndex) {
        primaryIndex = minActive;
      }
    }
    if (primaryIndex != _lastEmittedLineIndex ||
        !listEquals(_lastEmittedActiveIndices, activeIndices)) {
      _lastEmittedLineIndex = primaryIndex;
      _lastEmittedLineIndexForHint = primaryIndex;
      _lastEmittedActiveIndices = activeIndices;
      _lyricLineStreamController.add(LyricLineUpdate(
        primaryIndex: primaryIndex,
        activeIndices: activeIndices,
      ));
    }

    if (primaryIndex >= lyric.lines.length) return;
    if (primaryIndex != _lastDesktopLyricLineIndex) {
      _lastDesktopLyricLineIndex = primaryIndex;
      if (primaryIndex >= 0 && primaryIndex < lyric.lines.length) {
        final nextLine = primaryIndex + 1 < lyric.lines.length
            ? lyric.lines[primaryIndex + 1]
            : null;
        playService.desktopLyricService.canSendMessage.then((canSend) {
          if (!canSend) return;
          playService.desktopLyricService.sendLyricLineMessage(
            lyric.lines[primaryIndex],
            nextLine: nextLine,
          );
        });
      }
    }
  }

  /// hint 优先 + 二分搜索查找歌词位置
  /// 正常播放时 hint 命中率 >95%，时间复杂度接近 O(1)
  int _findLrcPos({
    required int time,
    required List<LyricLine> lines,
    required int hint,
  }) {
    final n = lines.length;
    if (n == 0) return -1;

    if (hint >= 0 && hint < n) {
      final seg = lines[hint];
      final segEndMs = seg.start.inMilliseconds + seg.length.inMilliseconds;
      if (time >= seg.start.inMilliseconds && time < segEndMs) {
        return hint + 1;
      }
      final nextIndex = hint + 1;
      if (nextIndex < n) {
        final segNext = lines[nextIndex];
        final segNextEnd =
            segNext.start.inMilliseconds + segNext.length.inMilliseconds;
        if (time >= segNext.start.inMilliseconds && time < segNextEnd) {
          return nextIndex + 1;
        }
      }
    }

    return _lowerBoundGreater(_lineStartMs, time);
  }

  List<int> _computeActiveLines(int posMs) {
    final lyric = _currLyric;
    if (lyric == null) return const [];
    final active = <int>[];
    // 只有 TTML 有时间重叠行，用全扫描即可（行数通常 < 200）
    for (int i = 0; i < lyric.lines.length; i++) {
      final line = lyric.lines[i];
      final start = line.start.inMilliseconds;
      final end = start + line.length.inMilliseconds;
      if (posMs >= start && posMs < end) {
        active.add(i);
      }
    }
    return active;
  }

  int _lowerBoundGreater(List<int> arr, int x) {
    if (arr.isEmpty) return -1;
    int lo = 0;
    int hi = arr.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (arr[mid] > x) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo >= arr.length ? -1 : lo;
  }

  void _setCurrLyric(Lyric lyric) {
    // 先还原歌词中被 * 屏蔽的脏话词，避免星号/连字符干扰元数据检测
    applyProfanityUncensor(lyric);
    // 再对所有歌词统一将元数据行清空（保留时间戳结构，不影响前奏/间奏计算）
    blankMetadataLines(lyric.lines);

    _currLyric = lyric;
    _lineStartMs = lyric.lines.map((line) {
      // 逐字歌词：用第一个词的 start 作为有效行开始时间，
      // 避免行切换先于逐词高亮触发，导致"上抬比高亮快"的视觉错位
      if (line is SyncLyricLine && line.words.isNotEmpty) {
        return line.words.first.start.inMilliseconds;
      }
      return line.start.inMilliseconds;
    }).toList();
    _lastEmittedLineIndexForHint = -1;
  }

  /// 根据默认歌词来源获取歌词：
  /// 1. 如果没有指定来源，按照现在的方式寻找歌词（本地优先或在线优先）
  /// 2. 如果指定来源，按照指定的来源获取
  void updateLyric() {
    _cancelLyricWritePrompt();

    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return;
    final audioPath = nowPlaying.path;

    // 歌曲切换时，写入上一首待写入的歌词
    final prevPath = _getNowPlaying()?.path;
    if (prevPath != null && prevPath != audioPath) {
      _flushPendingWrite(prevPath);
    }

    currLyricFuture.ignore();
    _currLyric = null;
    _lineStartMs = const [];
    _lastEmittedLineIndex = -1;
    _lastDesktopLyricLineIndex = -1;
    _lyricCache.remove(audioPath);

    final lyricSource = lyricSources[audioPath];
    final isFromWeb =
        lyricSource != null && lyricSource.source != LyricSourceType.local;

    if (lyricSource == null) {
      // 未指定单曲来源 → 使用全局「首选歌词来源」设置
      if (AppSettings.instance.localLyricFirst) {
        // 本地模式：只看内嵌/外置，绝不搜索网络
        logger.i('[updateLyric] local mode: loadLyricFromAudio only');
        currLyricFuture = loadLyricFromAudio(nowPlaying.path);
      } else {
        // 在线模式：只看用户选的那个源，不看内嵌/外置
        final preferredSource = AppSettings.instance.preferredOnlineSource;
        final rs = switch (preferredSource) {
          LyricSourceType.qq => ResultSource.qq,
          LyricSourceType.kugou => ResultSource.kugou,
          LyricSourceType.ne => ResultSource.ne,
          LyricSourceType.local =>
            ResultSource.qq, // unreachable in online mode
        };
        logger.i('[updateLyric] online mode: preferred=$rs');
        currLyricFuture = getLyricFromPreferredSource(nowPlaying, rs);
      }
    } else {
      if (lyricSource.source == LyricSourceType.local) {
        logger.i('[updateLyric] source=local, using loadLyricFromAudio');
        currLyricFuture = loadLyricFromAudio(nowPlaying.path);
      } else {
        logger.i(
            '[updateLyric] source=${lyricSource.source.name}, using getOnlineLyric');
        currLyricFuture = getOnlineLyric(
          qqSongId: lyricSource.qqSongId,
          kugouSongHash: lyricSource.kugouSongHash,
          neSongId: lyricSource.neSongId,
        );
      }
    }

    currLyricFuture.then((value) {
      logger.d('[lyric_service] then: value=${value?.lines.length ?? "null"}');
      if (value != null) {
        _nextLyricLine = 0;
        _setCurrLyric(value);
        _lyricCache.put(audioPath, value);
        // 网络歌词加载成功后，安排写入标签提示
        if (isFromWeb || value.source == LyricFormat.web) {
          _scheduleLyricWritePrompt(audioPath);
        }
      } else {
        _currLyric = null;
      }
      _notifyLyricChangeListeners();
      findCurrLyricLineAt(playService.playbackService.position);
    });

    notifyListeners();
  }

  /// 取消待处理的写入标签提示
  void _cancelLyricWritePrompt() {
    _promptTimer?.cancel();
    _promptTimer = null;
  }

  /// 网络歌词加载成功后，延迟弹出写入标签提示或自动写入
  void _scheduleLyricWritePrompt(String audioPath) {
    _cancelLyricWritePrompt();

    // 已提示过/忽略过，不再提示
    if (_promptedSongs.contains(audioPath)) return;

    final settings = AppSettings.instance;
    if (!settings.promptWriteLyricToTag) return;

    final useAutoWrite = settings.autoWriteLyricToTag;
    final delay = Duration(
      seconds: useAutoWrite
          ? settings.autoWriteLyricToTagDelay
          : settings.promptWriteLyricToTagDelay,
    );

    _promptTimer = Timer(delay, () {
      // 倒计时结束时检查是否还是同一首歌
      final nowPlaying = _getNowPlaying();
      if (nowPlaying == null || nowPlaying.path != audioPath) return;

      // 异步检查是否已有内嵌歌词
      getLyricFromPath(path: audioPath).then((existing) {
        if (existing != null && existing.trim().isNotEmpty) {
          // 已有歌词，不再提示
          _addPromptedSong(audioPath);
          return;
        }

        if (useAutoWrite) {
          // 自动写入模式：直接写入，不弹窗
          _handleAutoWrite(audioPath);
        } else {
          // 手动模式：弹窗询问
          showLyricWritePrompt(
            title: nowPlaying.title,
            onWrite: () => _handlePromptWrite(audioPath),
            onDismiss: () => _handlePromptDismiss(audioPath),
          );
        }
      });
    });
  }

  String? _pendingWriteAudioPath;

  /// 用户选择写入标签 → 延迟到播放结束后再写入，避免 BASS 流重置
  void _handlePromptWrite(String audioPath) {
    _addPromptedSong(audioPath);
    _pendingWriteAudioPath = audioPath;
    showTextOnSnackBar('歌词将在播放结束后自动写入标签');
  }

  /// 检查是否有待写入的歌词（歌曲切换时调用）
  void _flushPendingWrite(String oldAudioPath) {
    if (_pendingWriteAudioPath == null) return;
    if (_pendingWriteAudioPath != oldAudioPath) return;
    _pendingWriteAudioPath = null;
    writeCurrentLyricToTag().then((_) {
      showTextOnSnackBar('歌词已写入标签');
    }).catchError((e) {
      showTextOnSnackBar('写入标签失败: $e');
    });
  }

  /// 用户选择忽略 → 关闭整个提示功能，直到用户手动在设置页重新开启
  void _handlePromptDismiss(String audioPath) {
    final settings = AppSettings.instance;
    settings.promptWriteLyricToTag = false;
    settings.saveSettings();
    resetLyricWritePrompts();
    showTextOnSnackBar('歌词写入提示已关闭，可在设置中重新开启');
  }

  /// 自动写入：静默写入，不弹窗
  void _handleAutoWrite(String audioPath) {
    _addPromptedSong(audioPath);

    writeCurrentLyricToTag().then((_) {
      // 静默成功，不打扰用户
    }).catchError((e) {
      // 写入失败也不弹窗，避免打扰
    });
  }

  /// 重置写入标签提示状态（刷新已提示列表）
  void resetLyricWritePrompts() {
    _cancelLyricWritePrompt();
    _promptedSongs.clear();
  }

  /// 预加载歌词（不影响当前播放）
  /// 下一首切换时直接使用缓存
  void prefetchLyric(Audio audio) {
    final path = audio.path;
    // 如果已缓存，跳过
    if (_lyricCache.containsKey(path)) return;

    // 触发加载但不等待结果
    loadLyricFromAudio(audio.path).then((value) {
      if (value != null) {
        _lyricCache.put(path, value);
      }
    }).ignore();
  }

  void useLocalLyric() {
    _cancelLyricWritePrompt();

    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return;

    currLyricFuture.ignore();
    _currLyric = null;
    _lineStartMs = const [];
    _lastEmittedLineIndex = -1;
    _lastDesktopLyricLineIndex = -1;

    currLyricFuture = loadLyricFromAudio(nowPlaying.path);
    currLyricFuture.then((value) {
      if (value != null) {
        _setCurrLyric(value);
      } else {
        _currLyric = null;
      }
      _notifyLyricChangeListeners();
      findCurrLyricLine();
    });

    notifyListeners();
  }

  void useOnlineLyric() {
    _cancelLyricWritePrompt();

    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return;

    currLyricFuture.ignore();
    _currLyric = null;
    _lineStartMs = const [];
    _lastEmittedLineIndex = -1;
    _lastDesktopLyricLineIndex = -1;

    // 优先使用已保存的指定来源，避免重新搜索导致加载失败
    final savedSource = lyricSources[nowPlaying.path];
    if (savedSource != null && savedSource.source != LyricSourceType.local) {
      logger
          .i('[useOnlineLyric] using saved source: ${savedSource.source.name}');
      currLyricFuture = getOnlineLyric(
        qqSongId: savedSource.qqSongId,
        kugouSongHash: savedSource.kugouSongHash,
        neSongId: savedSource.neSongId,
      );
    } else {
      // 无指定来源 → 使用首选在线源（单源搜索，不三源并行）
      final rs = switch (AppSettings.instance.preferredOnlineSource) {
        LyricSourceType.qq => ResultSource.qq,
        LyricSourceType.kugou => ResultSource.kugou,
        LyricSourceType.ne => ResultSource.ne,
        LyricSourceType.local => ResultSource.qq,
      };
      logger.i('[useOnlineLyric] no saved source, searching preferred: $rs');
      currLyricFuture = getLyricFromPreferredSource(nowPlaying, rs);
    }

    currLyricFuture.then((value) {
      if (value != null) {
        _setCurrLyric(value);
        _scheduleLyricWritePrompt(nowPlaying.path);
      } else {
        _currLyric = null;
      }
      _notifyLyricChangeListeners();
      findCurrLyricLine();
    });

    notifyListeners();
  }

  void useSpecificLyric(Lyric lyric) {
    currLyricFuture.ignore();
    _lastEmittedLineIndex = -1;
    _lastDesktopLyricLineIndex = -1;

    currLyricFuture = Future.value(lyric);
    currLyricFuture.then((value) {
      if (value != null) {
        _setCurrLyric(value);
      } else {
        _currLyric = null;
      }
      _notifyLyricChangeListeners();
      findCurrLyricLine();
    });

    notifyListeners();
  }

  final _lyricChangeListeners = <VoidCallback>{};

  @override
  void addListener(VoidCallback listener) =>
      _lyricChangeListeners.add(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _lyricChangeListeners.remove(listener);

  void _notifyLyricChangeListeners() {
    for (final listener in _lyricChangeListeners) {
      listener();
    }
    super.notifyListeners();
  }

  @override
  void dispose() {
    _cancelLyricWritePrompt();
    _lyricLineStreamController.close();
    _positionStreamSubscription.cancel();
    _lyricCache.clear();
    super.dispose();
  }

  void clearCache() {
    _lyricCache.clear();
  }
}
