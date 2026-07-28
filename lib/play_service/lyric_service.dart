import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/ttml.dart' show Ttml;
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/lyric/lyric_stripper.dart';
import 'package:pure_music/lyric/lyric_loader.dart';
import 'package:pure_music/core/matcher.dart' hide logger;
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/bass/bass_player.dart';
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

  Timer? _lineAdvanceTimer;
  double _lastPos = 0.0;
  Lyric? _currLyric;
  List<int> _lineRenderStartMs = const [];
  List<int> _lineEndMs = const [];
  bool _hasOverlappingActiveLines = false;
  int _lastEmittedLineIndex = -1;
  int _lastDesktopLyricLineIndex = -1;
  bool _desktopGapShown = false;
  int _lyricRequestToken = 0;
  int _prefetchGeneration = 0;
  String? _activeLyricPath;

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
    playService.playbackService.playerStateNotifier
        .addListener(_syncLineAdvanceTimer);
    _syncLineAdvanceTimer();
  }

  void _syncLineAdvanceTimer() {
    final isPlaying =
        playService.playbackService.playerState == PlayerState.playing;
    final lyric = _currLyric;
    _lineAdvanceTimer?.cancel();
    _lineAdvanceTimer = null;
    if (!isPlaying || lyric == null || lyric.lines.isEmpty) {
      return;
    }
    _advanceLyricLineAt(playService.playbackService.position);
    _scheduleNextLineAdvance();
  }

  void _scheduleNextLineAdvance() {
    if (playService.playbackService.playerState != PlayerState.playing) return;
    final lyric = _currLyric;
    if (lyric == null || lyric.lines.isEmpty) return;
    final posMs = (playService.playbackService.position * 1000).round();
    final nextBoundaryMs = _nextLyricBoundaryAfter(posMs);
    if (nextBoundaryMs == null) return;
    final speed = playService.playbackService.rate.value;
    if (speed <= 0) return;
    final delayMs = ((nextBoundaryMs - posMs) / speed).clamp(16, 1000).toInt();
    _lineAdvanceTimer?.cancel();
    _lineAdvanceTimer = Timer(Duration(milliseconds: delayMs), () {
      _lineAdvanceTimer = null;
      _advanceLyricLineAt(playService.playbackService.position);
      _scheduleNextLineAdvance();
    });
  }

  void _restartLineAdvanceTimer() {
    if (playService.playbackService.playerState != PlayerState.playing) return;
    _lineAdvanceTimer?.cancel();
    _lineAdvanceTimer = null;
    _scheduleNextLineAdvance();
  }

  int? _nextLyricBoundaryAfter(int posMs) {
    int? candidate;
    final nextStart = _lowerBoundGreater(_lineRenderStartMs, posMs);
    if (nextStart != -1) {
      candidate = _lineRenderStartMs[nextStart];
    }
    if (_hasOverlappingActiveLines) {
      for (final endMs in _lineEndMs) {
        if (endMs <= posMs) continue;
        if (candidate == null || endMs < candidate) {
          candidate = endMs;
        }
      }
    }
    return candidate;
  }

  void _advanceLyricLineAt(double pos) {
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
      if (_lineRenderStartMs.isEmpty || posMs > _lineRenderStartMs.last) {
        return;
      }
      findCurrLyricLineAt(pos);
      return;
    }
    while (_nextLyricLine < _lineRenderStartMs.length &&
        posMs >= _lineRenderStartMs[_nextLyricLine]) {
      _nextLyricLine += 1;
    }

    final currLineIndex = _nextLyricLine - 1;
    final activeIndices = _computeActiveLines(posMs);

    // 前奏/尾奏 fallback：currLineIndex 越界时仍发射更新，UI 才知道当前位置
    if (currLineIndex < 0) {
      if (0 != _lastEmittedLineIndex ||
          !listEquals(_lastEmittedActiveIndices, activeIndices)) {
        _lastEmittedLineIndex = 0;
        _lastEmittedLineIndexForHint = 0;
        _lastEmittedActiveIndices = activeIndices;
        _lyricLineStreamController.add(LyricLineUpdate(
          primaryIndex: 0,
          activeIndices: activeIndices,
        ));
      }
      return;
    }
    if (currLineIndex >= lyric.lines.length) {
      final p = lyric.lines.length - 1;
      if (p != _lastEmittedLineIndex ||
          !listEquals(_lastEmittedActiveIndices, activeIndices)) {
        _lastEmittedLineIndex = p;
        _lastEmittedLineIndexForHint = p;
        _lastEmittedActiveIndices = activeIndices;
        _lyricLineStreamController.add(LyricLineUpdate(
          primaryIndex: p,
          activeIndices: activeIndices,
        ));
      }
      return;
    }
    var primaryIndex = currLineIndex;
    if (activeIndices.isNotEmpty) {
      // 当前行指针还未推进但下一行已激活（posMs == nextStart 的边界），
      // 取最早激活行做 primaryIndex
      final minActive = activeIndices.first;
      if (minActive != currLineIndex) {
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
      _desktopGapShown = false;
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
    _sendDesktopGapIfNeeded(currLineIndex, posMs);
  }

  void _sendDesktopGapIfNeeded(int currLineIndex, int posMs) {
    final lyric = _currLyric;
    if (lyric == null) return;
    if (currLineIndex < 0 || currLineIndex >= lyric.lines.length) return;
    if (currLineIndex >= lyric.lines.length - 1) return;
    final line = lyric.lines[currLineIndex];
    if (line is! SyncLyricLine) return;
    final lineEnd = currLineIndex < _lineEndMs.length
        ? _lineEndMs[currLineIndex]
        : line.start.inMilliseconds + line.length.inMilliseconds;
    if (posMs < lineEnd) {
      _desktopGapShown = false;
      return;
    }
    if (_desktopGapShown) return;
    _desktopGapShown = true;
    final nextLine = currLineIndex + 1 < lyric.lines.length
        ? lyric.lines[currLineIndex + 1]
        : null;
    final gapDuration = nextLine != null
        ? nextLine.start.inMilliseconds - lineEnd
        : 6000;
    playService.desktopLyricService.canSendMessage.then((canSend) {
      if (!canSend) return;
      playService.desktopLyricService.sendLyricLineMessage(
        SyncLyricLine(
          Duration(milliseconds: lineEnd),
          Duration(milliseconds: gapDuration > 0 ? gapDuration : 6000),
          const [],
        ),
        nextLine: nextLine,
      );
    });
  }

  Audio? _getNowPlaying() => playService.playbackService.nowPlaying;

  String? _buildLyricLrcText(
    Lyric lyric, {
    required bool enhancedIfPossible,
  }) {
    if (lyric.lines.isEmpty) return null;

    String buildEnhancedLine(SyncLyricLine line) {
      final buffer = StringBuffer();
      buffer.write(line.start.toStringLrc());
      for (final w in line.words) {
        if (w.content.isEmpty) continue;
        buffer.write(w.start.toStringLrc(open: '<', close: '>'));
        buffer.write(w.content);
      }
      if (line.translation != null && line.translation!.trim().isNotEmpty) {
        buffer.write('┃');
        buffer.write(line.translation!.trim());
      }
      return buffer.toString();
    }

    String buildUnsyncLine(LrcLine line) {
      return '${line.start.toStringLrc()}${line.content}';
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

    await writeTextFileAtomically(outPath, lrcText);

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

  Stream<LyricLineUpdate> get lyricLineStream =>
      _lyricLineStreamController.stream;

  LyricLineUpdate? lineUpdateAt(double positionSeconds) {
    final lyric = _currLyric;
    if (lyric == null) return null;
    return lineUpdateForLyric(
      lyric,
      positionSeconds,
      hint: _lastEmittedLineIndexForHint,
    );
  }

  LyricLineUpdate? lineUpdateForLyric(
    Lyric lyric,
    double positionSeconds, {
    int hint = -1,
    bool preferUpcomingInGap = false,
  }) {
    if (lyric.lines.isEmpty) return null;
    final posMs = (positionSeconds * 1000).round();
    final useCurrentTables = identical(lyric, _currLyric);
    final renderStartMs =
        useCurrentTables ? _lineRenderStartMs : _buildLineStarts(lyric);
    final lineEndMs = useCurrentTables ? _lineEndMs : _buildLineEnds(lyric);
    final hasOverlaps = useCurrentTables
        ? _hasOverlappingActiveLines
        : _detectOverlappingActiveLinesFor(renderStartMs, lineEndMs);
    final next = _findLrcPosInTables(
      time: posMs,
      lines: lyric.lines,
      lineRenderStartMs: renderStartMs,
      lineEndMs: lineEndMs,
      hint: hint,
    );
    final currLineIndex = (next == -1 ? lyric.lines.length : next) - 1;
    final activeIndices = _computeActiveLinesFor(
      lyric: lyric,
      posMs: posMs,
      lineRenderStartMs: renderStartMs,
      lineEndMs: lineEndMs,
      hasOverlaps: hasOverlaps,
    );

    if (currLineIndex < 0) {
      return LyricLineUpdate(primaryIndex: 0, activeIndices: activeIndices);
    }
    if (currLineIndex >= lyric.lines.length) {
      return LyricLineUpdate(
        primaryIndex: lyric.lines.length - 1,
        activeIndices: activeIndices,
      );
    }

    if (activeIndices.isNotEmpty) {
      final minActive = activeIndices.first;
      return LyricLineUpdate(
        primaryIndex: minActive,
        activeIndices: activeIndices,
      );
    }

    final previewIndex = preferUpcomingInGap
        ? _upcomingLineIndexInGap(
            currLineIndex: currLineIndex,
            posMs: posMs,
            lines: lyric.lines,
            lineRenderStartMs: renderStartMs,
            lineEndMs: lineEndMs,
          )
        : null;
    final primaryIndex = previewIndex ?? currLineIndex;
    return LyricLineUpdate(
      primaryIndex: primaryIndex,
      activeIndices: activeIndices,
    );
  }

  int? _upcomingLineIndexInGap({
    required int currLineIndex,
    required int posMs,
    required List<LyricLine> lines,
    required List<int> lineRenderStartMs,
    required List<int> lineEndMs,
  }) {
    final nextIndex = currLineIndex + 1;
    if (currLineIndex < 0 || nextIndex >= lines.length) return null;
    if (currLineIndex >= lineEndMs.length ||
        nextIndex >= lineRenderStartMs.length) {
      return null;
    }
    final currEndMs = lineEndMs[currLineIndex];
    final nextStartMs = lineRenderStartMs[nextIndex];
    if (posMs >= currEndMs && posMs < nextStartMs) {
      return nextIndex;
    }
    return null;
  }

  LyricLineUpdate? currentLineUpdate() {
    return lineUpdateAt(playService.playbackService.position);
  }

  /// 强制发射当前行（绕过 _lastEmittedLineIndex 检查），
  /// 用于新创建的歌词 view 初始化时获取当前行
  void forceEmitCurrentLine() {
    final lyric = _currLyric;
    if (lyric == null) {
      final token = _lyricRequestToken;
      final path = _activeLyricPath;
      final future = currLyricFuture;
      future.then((value) {
        if (path == null || !_isCurrentLyricRequest(token, path, future)) {
          return;
        }
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
    final activeIndices = _computeActiveLines(posMs);

    if (currLineIndex < 0) {
      if (0 != _lastEmittedLineIndex ||
          !listEquals(_lastEmittedActiveIndices, activeIndices)) {
        _lastEmittedLineIndex = 0;
        _lastEmittedLineIndexForHint = 0;
        _lastEmittedActiveIndices = activeIndices;
        _lyricLineStreamController.add(LyricLineUpdate(
          primaryIndex: 0,
          activeIndices: activeIndices,
        ));
      }
      _restartLineAdvanceTimer();
      return;
    }
    if (currLineIndex >= lyric.lines.length) {
      final p = lyric.lines.length - 1;
      if (p != _lastEmittedLineIndex ||
          !listEquals(_lastEmittedActiveIndices, activeIndices)) {
        _lastEmittedLineIndex = p;
        _lastEmittedLineIndexForHint = p;
        _lastEmittedActiveIndices = activeIndices;
        _lyricLineStreamController.add(LyricLineUpdate(
          primaryIndex: p,
          activeIndices: activeIndices,
        ));
      }
      _restartLineAdvanceTimer();
      return;
    }
    var primaryIndex = currLineIndex;
    if (activeIndices.isNotEmpty) {
      final minActive = activeIndices.first;
      if (minActive != currLineIndex) {
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
      _desktopGapShown = false;
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
    _sendDesktopGapIfNeeded(currLineIndex, posMs);
  }

  void findCurrLyricLineAt(double positionSeconds) {
    final lyric = _currLyric;
    if (lyric == null) {
      final token = _lyricRequestToken;
      final path = _activeLyricPath;
      final future = currLyricFuture;
      future.then((value) {
        if (path == null || !_isCurrentLyricRequest(token, path, future)) {
          return;
        }
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
    final activeIndices = _computeActiveLines(posMs);

    if (currLineIndex < 0) {
      if (0 != _lastEmittedLineIndex ||
          !listEquals(_lastEmittedActiveIndices, activeIndices)) {
        _lastEmittedLineIndex = 0;
        _lastEmittedLineIndexForHint = 0;
        _lastEmittedActiveIndices = activeIndices;
        _lyricLineStreamController.add(LyricLineUpdate(
          primaryIndex: 0,
          activeIndices: activeIndices,
        ));
      }
      _restartLineAdvanceTimer();
      return;
    }
    if (currLineIndex >= lyric.lines.length) {
      final p = lyric.lines.length - 1;
      if (p != _lastEmittedLineIndex ||
          !listEquals(_lastEmittedActiveIndices, activeIndices)) {
        _lastEmittedLineIndex = p;
        _lastEmittedLineIndexForHint = p;
        _lastEmittedActiveIndices = activeIndices;
        _lyricLineStreamController.add(LyricLineUpdate(
          primaryIndex: p,
          activeIndices: activeIndices,
        ));
      }
      _restartLineAdvanceTimer();
      return;
    }
    var primaryIndex = currLineIndex;
    if (activeIndices.isNotEmpty) {
      final minActive = activeIndices.first;
      if (minActive != currLineIndex) {
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

    if (primaryIndex >= lyric.lines.length) {
      _restartLineAdvanceTimer();
      return;
    }
    if (primaryIndex != _lastDesktopLyricLineIndex) {
      _lastDesktopLyricLineIndex = primaryIndex;
      _desktopGapShown = false;
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
    _sendDesktopGapIfNeeded(currLineIndex, posMs);
    _restartLineAdvanceTimer();
  }

  /// hint 优先 + 二分搜索查找歌词位置
  /// 正常播放时 hint 命中率 >95%，时间复杂度接近 O(1)
  int _findLrcPos({
    required int time,
    required List<LyricLine> lines,
    required int hint,
  }) {
    return _findLrcPosInTables(
      time: time,
      lines: lines,
      lineRenderStartMs: _lineRenderStartMs,
      lineEndMs: _lineEndMs,
      hint: hint,
    );
  }

  int _findLrcPosInTables({
    required int time,
    required List<LyricLine> lines,
    required List<int> lineRenderStartMs,
    required List<int> lineEndMs,
    required int hint,
  }) {
    final n = lines.length;
    if (n == 0) return -1;

    if (hint >= 0 &&
        hint < n &&
        hint < lineRenderStartMs.length &&
        hint < lineEndMs.length) {
      final segStartMs = lineRenderStartMs[hint];
      final segEndMs = lineEndMs[hint];
      if (time >= segStartMs && time < segEndMs) {
        return hint + 1;
      }
      final nextIndex = hint + 1;
      if (nextIndex < n &&
          nextIndex < lineRenderStartMs.length &&
          nextIndex < lineEndMs.length) {
        final segNextStart = lineRenderStartMs[nextIndex];
        final segNextEnd = lineEndMs[nextIndex];
        if (time >= segNextStart && time < segNextEnd) {
          return nextIndex + 1;
        }
      }
    }

    return _lowerBoundGreater(lineRenderStartMs, time);
  }

  List<int> _computeActiveLines(int posMs) {
    final lyric = _currLyric;
    if (lyric == null) return const [];
    return _computeActiveLinesFor(
      lyric: lyric,
      posMs: posMs,
      lineRenderStartMs: _lineRenderStartMs,
      lineEndMs: _lineEndMs,
      hasOverlaps: _hasOverlappingActiveLines,
    );
  }

  List<int> _computeActiveLinesFor({
    required Lyric lyric,
    required int posMs,
    required List<int> lineRenderStartMs,
    required List<int> lineEndMs,
    required bool hasOverlaps,
  }) {
    if (!hasOverlaps) return const [];
    final active = <int>[];
    // 只有 TTML 有时间重叠行，用全扫描即可（行数通常 < 200）
    for (int i = 0; i < lyric.lines.length; i++) {
      final line = lyric.lines[i];
      final start = i < lineRenderStartMs.length
          ? lineRenderStartMs[i]
          : line.start.inMilliseconds;
      final end = i < lineEndMs.length
          ? lineEndMs[i]
          : line.start.inMilliseconds + line.length.inMilliseconds;
      if (posMs >= start && posMs < end) {
        active.add(i);
      }
    }
    return active.take(2).toList();
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

  List<int> _buildLineStarts(Lyric lyric) {
    return lyric.lines.map((line) {
      if (line is SyncLyricLine && line.words.isNotEmpty) {
        final wordStart = line.words.first.start.inMilliseconds;
        final bgStart = line.bgStart?.inMilliseconds ??
            line.bg?.start.inMilliseconds ??
            (line.bgWords.isNotEmpty
                ? line.bgWords.first.start.inMilliseconds
                : null);
        return bgStart == null
            ? wordStart
            : wordStart < bgStart
                ? wordStart
                : bgStart;
      }
      return line.start.inMilliseconds;
    }).toList();
  }

  List<int> _buildLineEnds(Lyric lyric) {
    return lyric.lines.map((line) {
      if (line is SyncLyricLine && line.words.isNotEmpty) {
        final lastWord = line.words.last;
        var end =
            lastWord.start.inMilliseconds + lastWord.length.inMilliseconds;
        final bgEnd = line.bgEnd?.inMilliseconds ??
            line.bg?.end.inMilliseconds ??
            (line.bgWords.isNotEmpty
                ? line.bgWords.last.start.inMilliseconds +
                    line.bgWords.last.length.inMilliseconds
                : null);
        if (bgEnd != null && bgEnd > end) end = bgEnd;
        return end;
      }
      return line.start.inMilliseconds + line.length.inMilliseconds;
    }).toList();
  }

  void _setCurrLyric(Lyric lyric) {
    // 先还原歌词中被 * 屏蔽的脏话词，避免星号/连字符干扰元数据检测
    applyProfanityUncensor(lyric);
    // 再对所有歌词统一将元数据行清空（保留时间戳结构，不影响前奏/间奏计算）
    blankMetadataLines(lyric.lines);

    _currLyric = lyric;
    _lineRenderStartMs = _buildLineStarts(lyric);
    _lineEndMs = _buildLineEnds(lyric);
    _hasOverlappingActiveLines = lyric is Ttml &&
        _detectOverlappingActiveLinesFor(_lineRenderStartMs, _lineEndMs);
    _lastEmittedLineIndexForHint = -1;
    _syncLineAdvanceTimer();
  }

  bool _detectOverlappingActiveLinesFor(
    List<int> lineRenderStartMs,
    List<int> lineEndMs,
  ) {
    if (lineRenderStartMs.length < 2 || lineEndMs.length < 2) return false;
    final intervals = <({int start, int end})>[];
    for (int i = 0; i < lineRenderStartMs.length; i++) {
      final start = lineRenderStartMs[i];
      final end = i < lineEndMs.length ? lineEndMs[i] : start;
      if (end > start) intervals.add((start: start, end: end));
    }
    if (intervals.length < 2) return false;
    intervals.sort((a, b) => a.start.compareTo(b.start));
    var previousEnd = intervals.first.end;
    for (int i = 1; i < intervals.length; i++) {
      final interval = intervals[i];
      if (interval.start < previousEnd) return true;
      if (interval.end > previousEnd) previousEnd = interval.end;
    }
    return false;
  }

  int _beginLyricRequest(String path) {
    currLyricFuture.ignore();
    _activeLyricPath = path;
    _lyricRequestToken += 1;
    _currLyric = null;
    _syncLineAdvanceTimer();
    _lineRenderStartMs = const [];
    _lineEndMs = const [];
    _hasOverlappingActiveLines = false;
    _lastEmittedLineIndex = -1;
    _lastDesktopLyricLineIndex = -1;
    _desktopGapShown = false;
    _nextLyricLine = 0;
    _lastEmittedActiveIndices = const [];
    return _lyricRequestToken;
  }

  bool _isCurrentLyricRequest(
    int token,
    String path,
    Future<Lyric?> future,
  ) {
    return token == _lyricRequestToken &&
        identical(currLyricFuture, future) &&
        _activeLyricPath == path &&
        playService.playbackService.nowPlaying?.path == path;
  }

  /// 根据默认歌词来源获取歌词：
  /// 1. 如果没有指定来源，按照现在的方式寻找歌词（本地优先或在线优先）
  /// 2. 如果指定来源，按照指定的来源获取
  void updateLyric() {
    _cancelLyricWritePrompt();

    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return;
    final audioPath = nowPlaying.path;

    final requestToken = _beginLyricRequest(audioPath);
    _lyricCache.remove(audioPath);

    final lyricSource = lyricSources[audioPath];
    final isFromWeb =
        lyricSource != null && lyricSource.source != LyricSourceType.local;

    if (lyricSource == null) {
      // 未指定单曲来源 → 使用全局「首选歌词来源」设置
      if (AppSettings.instance.localLyricFirst) {
        // 本地模式：只看内嵌/外置，绝不搜索网络
        logger.i('[updateLyric] local mode: loadLyricFromAudio only');
        currLyricFuture = loadLyricFromAudio(audioPath);
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
        currLyricFuture = loadLyricFromAudio(audioPath);
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

    final future = currLyricFuture;
    future.then((value) {
      if (!_isCurrentLyricRequest(requestToken, audioPath, future)) return;
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
      findCurrLyricLineAt(playService.playbackService.position);
      _notifyLyricChangeListeners();
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

  /// 用户选择写入标签 → 立即写入当前歌曲标签
  void _handlePromptWrite(String audioPath) {
    _addPromptedSong(audioPath);
    writeCurrentLyricToTag().then((_) {
      showTextOnSnackBar('歌词已写入标签', variant: ToastVariant.success);
    }).catchError((e) {
      showTextOnSnackBar('写入标签失败: $e', variant: ToastVariant.error);
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
    final generation = _prefetchGeneration;

    // 触发加载但不等待结果
    loadLyricFromAudio(audio.path).then((value) {
      if (value != null && generation == _prefetchGeneration) {
        _lyricCache.put(path, value);
      }
    }).ignore();
  }

  void useLocalLyric() {
    _cancelLyricWritePrompt();

    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return;
    final audioPath = nowPlaying.path;
    final requestToken = _beginLyricRequest(audioPath);

    currLyricFuture = loadLyricFromAudio(audioPath);
    final future = currLyricFuture;
    future.then((value) {
      if (!_isCurrentLyricRequest(requestToken, audioPath, future)) return;
      if (value != null) {
        _setCurrLyric(value);
      } else {
        _currLyric = null;
      }
      findCurrLyricLineAt(playService.playbackService.position);
      _notifyLyricChangeListeners();
    });

    notifyListeners();
  }

  void useOnlineLyric() {
    _cancelLyricWritePrompt();

    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return;
    final audioPath = nowPlaying.path;
    final requestToken = _beginLyricRequest(audioPath);

    // 优先使用已保存的指定来源，避免重新搜索导致加载失败
    final savedSource = lyricSources[audioPath];
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

    final future = currLyricFuture;
    future.then((value) {
      if (!_isCurrentLyricRequest(requestToken, audioPath, future)) return;
      if (value != null) {
        _setCurrLyric(value);
        _scheduleLyricWritePrompt(audioPath);
      } else {
        _currLyric = null;
      }
      findCurrLyricLineAt(playService.playbackService.position);
      _notifyLyricChangeListeners();
    });

    notifyListeners();
  }

  void useSpecificLyric(Lyric lyric) {
    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return;
    final audioPath = nowPlaying.path;
    final requestToken = _beginLyricRequest(audioPath);

    currLyricFuture = Future.value(lyric);
    final future = currLyricFuture;
    future.then((value) {
      if (!_isCurrentLyricRequest(requestToken, audioPath, future)) return;
      if (value != null) {
        _setCurrLyric(value);
      } else {
        _currLyric = null;
      }
      findCurrLyricLineAt(playService.playbackService.position);
      _notifyLyricChangeListeners();
    });

    notifyListeners();
  }

  void _notifyLyricChangeListeners() {
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelLyricWritePrompt();
    _lyricLineStreamController.close();
    playService.playbackService.playerStateNotifier
        .removeListener(_syncLineAdvanceTimer);
    _lineAdvanceTimer?.cancel();
    _lyricCache.clear();
    super.dispose();
  }

  void clearCache() {
    _prefetchGeneration++;
    _lyricCache.clear();
  }
}
