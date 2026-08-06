import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' show max, min;

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lrc_serializer.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_tag_word_format.dart';
import 'package:pure_music/lyric/ttml.dart' show Ttml;
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/lyric/lyric_stripper.dart';
import 'package:pure_music/lyric/lyric_loader.dart';
import 'package:pure_music/core/matcher.dart' hide logger;
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/lyric_write_prompt_history.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

const int _kLyricCacheCapacity = 32;
const int lyricWordPreSwitchMs = 320;
const int lyricHighlightCatchUpDurationMs = 260;
const int lyricHighlightFinishLeadMs = 32;

SyncLyricLine? desktopLyricPreludeLineAt(Lyric lyric, int positionMs) {
  if (lyric.lines.isEmpty) return null;
  final firstLine = lyric.lines.first;
  final firstStartMs = firstLine is SyncLyricLine && firstLine.words.isNotEmpty
      ? firstLine.words.first.start.inMilliseconds
      : firstLine.start.inMilliseconds;
  if (positionMs >= firstStartMs) return null;
  return SyncLyricLine(
    Duration.zero,
    Duration(milliseconds: firstStartMs),
    const [],
  );
}

int lyricLineSwitchStartMs({
  required int previousSwitchStartMs,
  required int previousLineEndMs,
  required int nextLineStartMs,
  required bool preserveSingleWordTiming,
}) {
  var switchStart = max(
    previousSwitchStartMs,
    nextLineStartMs - lyricWordPreSwitchMs,
  );
  if (preserveSingleWordTiming) {
    switchStart = max(switchStart, min(previousLineEndMs, nextLineStartMs));
  }
  return switchStart;
}

int? lyricHighlightDeadlineMsForLine(Lyric lyric, int lineIndex) {
  final lines = lyric.lines;
  if (lineIndex < 0 || lineIndex >= lines.length) return null;
  final currentLine = lines[lineIndex];
  if (lyric is! Ttml &&
      currentLine is SyncLyricLine &&
      currentLine.words.length == 1) {
    return null;
  }

  int lineEndMs(LyricLine line) {
    if (line is SyncLyricLine && line.words.isNotEmpty) {
      final lastWord = line.words.last;
      return lastWord.start.inMilliseconds + lastWord.length.inMilliseconds;
    }
    return line.start.inMilliseconds + line.length.inMilliseconds;
  }

  int lineStartMs(LyricLine line) {
    if (line is SyncLyricLine && line.words.isNotEmpty) {
      return line.words.first.start.inMilliseconds;
    }
    return line.start.inMilliseconds;
  }

  bool isBlankFiltered(LyricLine line) {
    if (line is SyncLyricLine) {
      return line.words.isEmpty && line.length <= const Duration(seconds: 3);
    }
    if (line is LrcLine) {
      return line.isBlank &&
          (line.length <= const Duration(seconds: 3) ||
              line.start > Duration.zero);
    }
    return false;
  }

  bool formsParallelGroup(int firstIndex, int secondIndex) {
    final first = lines[firstIndex];
    final second = lines[secondIndex];
    final overlapMs = min(lineEndMs(first), lineEndMs(second)) -
        max(lineStartMs(first), lineStartMs(second));
    return overlapMs > lyricWordPreSwitchMs;
  }

  int? parallelGroupEnd;
  Set<int>? parallelGroupLines;
  if (lyric is Ttml) {
    final groupMembers = <int>[0];
    var groupEnd = lineEndMs(lines.first);
    for (var i = 1; i < lines.length; i++) {
      if (groupMembers.any((member) => formsParallelGroup(member, i))) {
        groupMembers.add(i);
        groupEnd = max(groupEnd, lineEndMs(lines[i]));
        continue;
      }
      if (groupMembers.contains(lineIndex)) {
        if (groupMembers.length > 1) {
          parallelGroupEnd = groupEnd;
          parallelGroupLines = groupMembers.toSet();
        }
        break;
      }
      groupMembers
        ..clear()
        ..add(i);
      groupEnd = lineEndMs(lines[i]);
    }
    if (parallelGroupEnd == null && groupMembers.contains(lineIndex)) {
      if (groupMembers.length > 1) {
        parallelGroupEnd = groupEnd;
        parallelGroupLines = groupMembers.toSet();
      }
    }
  }

  for (var i = lineIndex + 1; i < lines.length; i++) {
    if (parallelGroupLines?.contains(i) == true) continue;
    final nextLine = lines[i];
    if (isBlankFiltered(nextLine)) continue;
    final nextStart = lineStartMs(nextLine);
    if (nextLine is SyncLyricLine && nextLine.words.isNotEmpty) {
      return parallelGroupEnd == null
          ? nextStart - lyricWordPreSwitchMs
          : max(parallelGroupEnd, nextStart - lyricWordPreSwitchMs);
    }
    return nextStart;
  }
  return null;
}

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
  List<int> _lineSwitchStartMs = const [];
  List<int> _lineEndMs = const [];
  bool _hasOverlappingActiveLines = false;
  int _lastEmittedLineIndex = -1;
  int _lastDesktopLyricLineIndex = -1;
  bool _desktopGapShown = false;
  bool _desktopPreludeShown = false;
  int _lyricRequestToken = 0;
  int _prefetchGeneration = 0;
  final Map<String, Future<Lyric?>> _lyricPrefetches = {};
  String? _activeLyricPath;

  final LyricWritePromptHistory _lyricWritePromptHistory =
      LyricWritePromptHistory();
  Timer? _promptTimer;
  int _promptGeneration = 0;
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
    final nextStart = _lowerBoundGreater(_lineSwitchStartMs, posMs);
    if (nextStart != -1) {
      candidate = _lineSwitchStartMs[nextStart];
    }
    if (_hasOverlappingActiveLines) {
      for (final startMs in _lineRenderStartMs) {
        final entryMs = startMs - lyricWordPreSwitchMs;
        if (entryMs <= posMs) continue;
        if (candidate == null || entryMs < candidate) {
          candidate = entryMs;
        }
      }
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
      if (_lineSwitchStartMs.isEmpty || posMs > _lineSwitchStartMs.last) {
        return;
      }
      findCurrLyricLineAt(pos);
      return;
    }
    while (_nextLyricLine < _lineSwitchStartMs.length &&
        posMs >= _lineSwitchStartMs[_nextLyricLine]) {
      _nextLyricLine += 1;
    }

    final currLineIndex = _nextLyricLine - 1;
    final activity = _lineActivityForSwitchPosition(currLineIndex, posMs);
    final activeIndices = activity.activeIndices;
    final layoutIndices = activity.layoutIndices;

    // 前奏/尾奏 fallback：currLineIndex 越界时仍发射更新，UI 才知道当前位置
    if (currLineIndex < 0) {
      if (0 != _lastEmittedLineIndex ||
          !listEquals(_lastEmittedActiveIndices, activeIndices) ||
          !listEquals(_lastEmittedLayoutIndices, layoutIndices)) {
        _lastEmittedLineIndex = 0;
        _lastEmittedLineIndexForHint = 0;
        _lastEmittedActiveIndices = activeIndices;
        _lastEmittedLayoutIndices = layoutIndices;
        _lyricLineStreamController.add(LyricLineUpdate(
          primaryIndex: 0,
          activeIndices: activeIndices,
          layoutIndices: layoutIndices,
        ));
      }
      _sendDesktopPreludeIfNeeded(posMs);
      return;
    }
    if (currLineIndex >= lyric.lines.length) {
      final p = lyric.lines.length - 1;
      if (p != _lastEmittedLineIndex ||
          !listEquals(_lastEmittedActiveIndices, activeIndices) ||
          !listEquals(_lastEmittedLayoutIndices, layoutIndices)) {
        _lastEmittedLineIndex = p;
        _lastEmittedLineIndexForHint = p;
        _lastEmittedActiveIndices = activeIndices;
        _lastEmittedLayoutIndices = layoutIndices;
        _lyricLineStreamController.add(LyricLineUpdate(
          primaryIndex: p,
          activeIndices: activeIndices,
          layoutIndices: layoutIndices,
        ));
      }
      return;
    }
    var primaryIndex = currLineIndex;
    if (layoutIndices.isNotEmpty) {
      // 当前行指针还未推进但下一行已激活（posMs == nextStart 的边界），
      // 取最早激活行做 primaryIndex
      final minActive = layoutIndices.first;
      if (minActive != currLineIndex) {
        primaryIndex = minActive;
      }
    }
    if (primaryIndex != _lastEmittedLineIndex ||
        !listEquals(_lastEmittedActiveIndices, activeIndices) ||
        !listEquals(_lastEmittedLayoutIndices, layoutIndices)) {
      _lastEmittedLineIndex = primaryIndex;
      _lastEmittedLineIndexForHint = primaryIndex;
      _lastEmittedActiveIndices = activeIndices;
      _lastEmittedLayoutIndices = layoutIndices;
      _lyricLineStreamController.add(LyricLineUpdate(
        primaryIndex: primaryIndex,
        activeIndices: activeIndices,
        layoutIndices: layoutIndices,
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
            isWordByWord: lyric.isWordByWord,
            highlightDeadlineMs:
                lyricHighlightDeadlineMsForLine(lyric, primaryIndex),
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
    final gapDuration =
        nextLine != null ? nextLine.start.inMilliseconds - lineEnd : 6000;
    playService.desktopLyricService.canSendMessage.then((canSend) {
      if (!canSend) return;
      playService.desktopLyricService.sendLyricLineMessage(
        SyncLyricLine(
          Duration(milliseconds: lineEnd),
          Duration(milliseconds: gapDuration > 0 ? gapDuration : 6000),
          const [],
        ),
        nextLine: nextLine,
        isWordByWord: lyric.isWordByWord,
      );
    });
  }

  /// 第一行歌词开始前给桌面歌词发送完整前奏，保持中途启动时的进度一致。
  void _sendDesktopPreludeIfNeeded(int posMs) {
    final lyric = _currLyric;
    if (lyric == null || lyric.lines.isEmpty) return;
    final firstLine = lyric.lines[0];
    final preludeLine = desktopLyricPreludeLineAt(lyric, posMs);
    if (preludeLine == null) {
      _desktopPreludeShown = false;
      return;
    }
    if (_desktopPreludeShown) return;
    _desktopPreludeShown = true;
    playService.desktopLyricService.canSendMessage.then((canSend) {
      if (!canSend) return;
      playService.desktopLyricService.sendLyricLineMessage(
        preludeLine,
        nextLine: firstLine,
        isWordByWord: lyric.isWordByWord,
      );
    });
  }

  Audio? _getNowPlaying() => playService.playbackService.nowPlaying;

  Future<void> writeCurrentLyricToTag({
    LyricTagWordFormat? wordFormat,
    String? expectedPath,
  }) async {
    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) throw StateError('当前没有正在播放的歌曲');
    final audioPath = nowPlaying.path;
    if (expectedPath != null && expectedPath != audioPath) {
      throw StateError('当前歌曲已切换');
    }

    final lyric = _currLyric ?? await currLyricFuture;
    if (lyric == null) throw StateError('当前歌曲没有可写入的歌词');

    final lrcText = serializeLyricToLrc(
      lyric,
      wordFormat: wordFormat ?? AppSettings.instance.lyricTagWordFormat,
    );
    if (lrcText.trim().isEmpty) {
      throw StateError('当前歌词内容为空');
    }
    if (_getNowPlaying()?.path != audioPath) {
      throw StateError('当前歌曲已切换');
    }

    await writeLyricToPath(path: audioPath, lyric: lrcText);
  }

  Future<String?> saveCurrentLyricAsLrc(
      {LyricTagWordFormat? wordFormat}) async {
    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return null;

    final lyric = _currLyric ?? await currLyricFuture;
    if (lyric == null) return null;

    final lrcText = serializeLyricToLrc(
      lyric,
      wordFormat: wordFormat ?? AppSettings.instance.lyricTagWordFormat,
    );
    if (lrcText.trim().isEmpty) return null;

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
  LyricSourceType _activeLyricSourceType = LyricSourceType.local;

  /// 当前歌词是否已加载
  bool get hasLyric => _currLyric != null;

  /// 下一行歌词
  int _nextLyricLine = 0;
  int _lastEmittedLineIndexForHint = -1;
  List<int> _lastEmittedActiveIndices = const [];
  List<int> _lastEmittedLayoutIndices = const [];

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
  }) {
    if (lyric.lines.isEmpty) return null;
    final posMs = (positionSeconds * 1000).round();
    final useCurrentTables = identical(lyric, _currLyric);
    final renderStartMs =
        useCurrentTables ? _lineRenderStartMs : _buildLineStarts(lyric);
    final lineEndMs = useCurrentTables ? _lineEndMs : _buildLineEnds(lyric);
    final switchStartMs = useCurrentTables
        ? _lineSwitchStartMs
        : _buildLineSwitchStarts(lyric, renderStartMs, lineEndMs);
    final hasOverlaps = useCurrentTables
        ? _hasOverlappingActiveLines
        : _detectOverlappingActiveLinesFor(renderStartMs, lineEndMs);
    final next = _findLrcPosInTables(
      time: posMs,
      lines: lyric.lines,
      lineRenderStartMs: switchStartMs,
      lineEndMs: lineEndMs,
      hint: hint,
    );
    final currLineIndex = (next == -1 ? lyric.lines.length : next) - 1;
    var activeIndices = _computeActiveLinesFor(
      lyric: lyric,
      posMs: posMs,
      lineRenderStartMs: renderStartMs,
      lineEndMs: lineEndMs,
      hasOverlaps: hasOverlaps,
    );
    var layoutIndices = _computeLayoutLinesFor(
      lyric: lyric,
      posMs: posMs,
      lineRenderStartMs: renderStartMs,
      lineEndMs: lineEndMs,
      activeIndices: activeIndices,
      preferredIndex: currLineIndex,
    );
    if (currLineIndex >= 0 &&
        currLineIndex < renderStartMs.length &&
        posMs < renderStartMs[currLineIndex]) {
      activeIndices = const [];
      layoutIndices = const [];
    }

    if (currLineIndex < 0) {
      return LyricLineUpdate(
        primaryIndex: 0,
        activeIndices: activeIndices,
        layoutIndices: layoutIndices,
      );
    }
    if (currLineIndex >= lyric.lines.length) {
      return LyricLineUpdate(
        primaryIndex: lyric.lines.length - 1,
        activeIndices: activeIndices,
        layoutIndices: layoutIndices,
      );
    }

    if (layoutIndices.isNotEmpty) {
      final minActive = layoutIndices.first;
      return LyricLineUpdate(
        primaryIndex: minActive,
        activeIndices: activeIndices,
        layoutIndices: layoutIndices,
      );
    }

    final primaryIndex = currLineIndex;
    return LyricLineUpdate(
      primaryIndex: primaryIndex,
      activeIndices: activeIndices,
      layoutIndices: layoutIndices,
    );
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
    final activity = _lineActivityForSwitchPosition(currLineIndex, posMs);
    final activeIndices = activity.activeIndices;
    final layoutIndices = activity.layoutIndices;

    if (currLineIndex < 0) {
      if (0 != _lastEmittedLineIndex ||
          !listEquals(_lastEmittedActiveIndices, activeIndices) ||
          !listEquals(_lastEmittedLayoutIndices, layoutIndices)) {
        _lastEmittedLineIndex = 0;
        _lastEmittedLineIndexForHint = 0;
        _lastEmittedActiveIndices = activeIndices;
        _lastEmittedLayoutIndices = layoutIndices;
        _lyricLineStreamController.add(LyricLineUpdate(
          primaryIndex: 0,
          activeIndices: activeIndices,
          layoutIndices: layoutIndices,
        ));
      }
      _sendDesktopPreludeIfNeeded(posMs);
      _restartLineAdvanceTimer();
      return;
    }
    if (currLineIndex >= lyric.lines.length) {
      final p = lyric.lines.length - 1;
      if (p != _lastEmittedLineIndex ||
          !listEquals(_lastEmittedActiveIndices, activeIndices) ||
          !listEquals(_lastEmittedLayoutIndices, layoutIndices)) {
        _lastEmittedLineIndex = p;
        _lastEmittedLineIndexForHint = p;
        _lastEmittedActiveIndices = activeIndices;
        _lastEmittedLayoutIndices = layoutIndices;
        _lyricLineStreamController.add(LyricLineUpdate(
          primaryIndex: p,
          activeIndices: activeIndices,
          layoutIndices: layoutIndices,
        ));
      }
      _restartLineAdvanceTimer();
      return;
    }
    var primaryIndex = currLineIndex;
    if (layoutIndices.isNotEmpty) {
      final minActive = layoutIndices.first;
      if (minActive != currLineIndex) {
        primaryIndex = minActive;
      }
    }
    _lastEmittedLineIndex = primaryIndex;
    _lastEmittedLineIndexForHint = primaryIndex;
    _lastEmittedActiveIndices = activeIndices;
    _lastEmittedLayoutIndices = layoutIndices;
    _lyricLineStreamController.add(LyricLineUpdate(
      primaryIndex: primaryIndex,
      activeIndices: activeIndices,
      layoutIndices: layoutIndices,
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
            isWordByWord: lyric.isWordByWord,
            highlightDeadlineMs:
                lyricHighlightDeadlineMsForLine(lyric, primaryIndex),
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
    final activity = _lineActivityForSwitchPosition(currLineIndex, posMs);
    final activeIndices = activity.activeIndices;
    final layoutIndices = activity.layoutIndices;

    if (currLineIndex < 0) {
      if (0 != _lastEmittedLineIndex ||
          !listEquals(_lastEmittedActiveIndices, activeIndices) ||
          !listEquals(_lastEmittedLayoutIndices, layoutIndices)) {
        _lastEmittedLineIndex = 0;
        _lastEmittedLineIndexForHint = 0;
        _lastEmittedActiveIndices = activeIndices;
        _lastEmittedLayoutIndices = layoutIndices;
        _lyricLineStreamController.add(LyricLineUpdate(
          primaryIndex: 0,
          activeIndices: activeIndices,
          layoutIndices: layoutIndices,
        ));
      }
      _sendDesktopPreludeIfNeeded(posMs);
      _restartLineAdvanceTimer();
      return;
    }
    if (currLineIndex >= lyric.lines.length) {
      final p = lyric.lines.length - 1;
      if (p != _lastEmittedLineIndex ||
          !listEquals(_lastEmittedActiveIndices, activeIndices) ||
          !listEquals(_lastEmittedLayoutIndices, layoutIndices)) {
        _lastEmittedLineIndex = p;
        _lastEmittedLineIndexForHint = p;
        _lastEmittedActiveIndices = activeIndices;
        _lastEmittedLayoutIndices = layoutIndices;
        _lyricLineStreamController.add(LyricLineUpdate(
          primaryIndex: p,
          activeIndices: activeIndices,
          layoutIndices: layoutIndices,
        ));
      }
      _restartLineAdvanceTimer();
      return;
    }
    var primaryIndex = currLineIndex;
    if (layoutIndices.isNotEmpty) {
      final minActive = layoutIndices.first;
      if (minActive != currLineIndex) {
        primaryIndex = minActive;
      }
    }
    if (primaryIndex != _lastEmittedLineIndex ||
        !listEquals(_lastEmittedActiveIndices, activeIndices) ||
        !listEquals(_lastEmittedLayoutIndices, layoutIndices)) {
      _lastEmittedLineIndex = primaryIndex;
      _lastEmittedLineIndexForHint = primaryIndex;
      _lastEmittedActiveIndices = activeIndices;
      _lastEmittedLayoutIndices = layoutIndices;
      _lyricLineStreamController.add(LyricLineUpdate(
        primaryIndex: primaryIndex,
        activeIndices: activeIndices,
        layoutIndices: layoutIndices,
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
            isWordByWord: lyric.isWordByWord,
            highlightDeadlineMs:
                lyricHighlightDeadlineMsForLine(lyric, primaryIndex),
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
      lineRenderStartMs: _lineSwitchStartMs,
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
      final segStartMs = lineRenderStartMs[hint];
      final segEndMs = lineEndMs[hint];
      if (time >= segStartMs && time < segEndMs) {
        return hint + 1;
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

  List<int> _activeLinesForSwitchPosition(
    List<int> activeIndices,
    int lineIndex,
    int posMs,
  ) {
    if (lineIndex >= 0 &&
        lineIndex < _lineRenderStartMs.length &&
        posMs < _lineRenderStartMs[lineIndex]) {
      return const [];
    }
    return activeIndices;
  }

  ({List<int> activeIndices, List<int> layoutIndices})
      _lineActivityForSwitchPosition(int lineIndex, int posMs) {
    final lyric = _currLyric;
    if (lyric == null) {
      return (activeIndices: const [], layoutIndices: const []);
    }
    final activeIndices = _activeLinesForSwitchPosition(
      _computeActiveLines(posMs),
      lineIndex,
      posMs,
    );
    final layoutIndices = _computeLayoutLinesFor(
      lyric: lyric,
      posMs: posMs,
      lineRenderStartMs: _lineRenderStartMs,
      lineEndMs: _lineEndMs,
      activeIndices: activeIndices,
      preferredIndex: lineIndex,
    );
    return (activeIndices: activeIndices, layoutIndices: layoutIndices);
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
    return active;
  }

  List<int> _computeLayoutLinesFor({
    required Lyric lyric,
    required int posMs,
    required List<int> lineRenderStartMs,
    required List<int> lineEndMs,
    required List<int> activeIndices,
    required int preferredIndex,
  }) {
    if (lyric is! Ttml || activeIndices.isEmpty) return activeIndices;
    final anchor = activeIndices.contains(preferredIndex)
        ? preferredIndex
        : activeIndices.last;
    final layout = <int>{anchor};
    final pending = Queue<int>()..add(anchor);
    while (pending.isNotEmpty) {
      final member = pending.removeFirst();
      for (int candidate = 0; candidate < lyric.lines.length; candidate++) {
        if (layout.contains(candidate)) continue;
        final candidateStart = candidate < lineRenderStartMs.length
            ? lineRenderStartMs[candidate]
            : lyric.lines[candidate].start.inMilliseconds;
        if (candidateStart - posMs > lyricWordPreSwitchMs) continue;
        final formsParallelGroup = _formsParallelGroup(
          firstIndex: member,
          secondIndex: candidate,
          lineRenderStartMs: lineRenderStartMs,
          lineEndMs: lineEndMs,
        );
        if (!formsParallelGroup) continue;
        layout.add(candidate);
        pending.add(candidate);
      }
    }
    return layout.toList()..sort();
  }

  bool _formsParallelGroup({
    required int firstIndex,
    required int secondIndex,
    required List<int> lineRenderStartMs,
    required List<int> lineEndMs,
  }) {
    final firstStart = lineRenderStartMs[firstIndex];
    final secondStart = lineRenderStartMs[secondIndex];
    final firstEnd = lineEndMs[firstIndex];
    final secondEnd = lineEndMs[secondIndex];
    final overlapMs = min(firstEnd, secondEnd) - max(firstStart, secondStart);
    return overlapMs > lyricWordPreSwitchMs;
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
        return line.words.first.start.inMilliseconds;
      }
      return line.start.inMilliseconds;
    }).toList();
  }

  List<int> _buildLineEnds(Lyric lyric) {
    return lyric.lines.map((line) {
      var end = line.start.inMilliseconds + line.length.inMilliseconds;
      if (line is SyncLyricLine && line.words.isNotEmpty) {
        final lastWord = line.words.last;
        final wordEnd =
            lastWord.start.inMilliseconds + lastWord.length.inMilliseconds;
        if (lyric is! Ttml) return wordEnd;
        end = max(end, wordEnd);
      }
      if (lyric is Ttml && line is SyncLyricLine) {
        if (line.bgEnd != null) {
          end = max(end, line.bgEnd!.inMilliseconds);
        }
        if (line.bgWords.isNotEmpty) {
          final lastBgWord = line.bgWords.last;
          end = max(
            end,
            lastBgWord.start.inMilliseconds + lastBgWord.length.inMilliseconds,
          );
        }
      }
      return end;
    }).toList();
  }

  List<int> _buildLineSwitchStarts(
    Lyric lyric,
    List<int> renderStartMs,
    List<int> lineEndMs,
  ) {
    final switchStarts = List<int>.of(renderStartMs);
    var overlapGroupEnd = lineEndMs.isEmpty ? 0 : lineEndMs.first;
    final overlapGroupMembers = <int>[0];
    for (int i = 1; i < lyric.lines.length; i++) {
      final line = lyric.lines[i];
      final start = renderStartMs[i];
      final end = i < lineEndMs.length ? lineEndMs[i] : start;
      final joinsParallelGroup = lyric is Ttml &&
          overlapGroupMembers.any(
            (member) => _formsParallelGroup(
              firstIndex: member,
              secondIndex: i,
              lineRenderStartMs: renderStartMs,
              lineEndMs: lineEndMs,
            ),
          );
      if (joinsParallelGroup) {
        overlapGroupMembers.add(i);
        overlapGroupEnd = max(overlapGroupEnd, end);
        continue;
      }
      if (line is SyncLyricLine && line.words.isNotEmpty) {
        final previousLine = lyric.lines[i - 1];
        switchStarts[i] = lyricLineSwitchStartMs(
          previousSwitchStartMs: lyric is Ttml && overlapGroupMembers.length > 1
              ? overlapGroupEnd
              : switchStarts[i - 1],
          previousLineEndMs: lineEndMs[i - 1],
          nextLineStartMs: start,
          preserveSingleWordTiming: lyric is! Ttml &&
              previousLine is SyncLyricLine &&
              previousLine.words.length == 1,
        );
      }
      overlapGroupEnd = end;
      overlapGroupMembers
        ..clear()
        ..add(i);
    }
    return switchStarts;
  }

  void _setCurrLyric(Lyric lyric) {
    // 先还原歌词中被 * 屏蔽的脏话词，避免星号/连字符干扰元数据检测
    applyProfanityUncensor(lyric);
    if (lyric is Ttml && _activeLyricSourceType == LyricSourceType.amll) {
      blankAmllTtmlCreatorLines(lyric.lines);
    } else {
      final nowPlaying = _getNowPlaying();
      final artists = nowPlaying == null
          ? const <String>[]
          : <String>{...nowPlaying.splitedArtists, nowPlaying.artist}
              .where((artist) => artist.trim().isNotEmpty)
              .toList(growable: false);
      blankMetadataLines(
        lyric.lines,
        StripOptions(
          matchTitle: nowPlaying?.title,
          matchArtists: artists,
        ),
      );
    }

    _currLyric = lyric;
    _lineRenderStartMs = _buildLineStarts(lyric);
    _lineEndMs = _buildLineEnds(lyric);
    _lineSwitchStartMs =
        _buildLineSwitchStarts(lyric, _lineRenderStartMs, _lineEndMs);
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
    _lineSwitchStartMs = const [];
    _lineEndMs = const [];
    _hasOverlappingActiveLines = false;
    _lastEmittedLineIndex = -1;
    _lastDesktopLyricLineIndex = -1;
    _desktopGapShown = false;
    _desktopPreludeShown = false;
    _nextLyricLine = 0;
    _lastEmittedActiveIndices = const [];
    _lastEmittedLayoutIndices = const [];
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

  Future<Lyric?> _loadLocalLyric(String path) {
    final cached = _lyricCache.get(path);
    return cached != null
        ? SynchronousFuture<Lyric?>(cached)
        : _lyricPrefetches[path] ?? loadLyricFromAudio(path);
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
    _activeLyricSourceType = LyricSourceType.local;

    final lyricSource = lyricSources[audioPath];
    final isFromWeb =
        lyricSource != null && lyricSource.source != LyricSourceType.local;
    final usesLocalLyric = lyricSource?.source == LyricSourceType.local ||
        (lyricSource == null && AppSettings.instance.localLyricFirst);

    if (lyricSource == null) {
      // 未指定单曲来源 → 使用全局「首选歌词来源」设置
      if (AppSettings.instance.localLyricFirst) {
        // 本地模式：只看内嵌/外置，绝不搜索网络
        logger.i('[updateLyric] local mode: loadLyricFromAudio only');
        currLyricFuture = _loadLocalLyric(audioPath);
      } else {
        // 在线模式：只看用户选的那个源，不看内嵌/外置
        final preferredSource = AppSettings.instance.preferredOnlineSource;
        final rs = switch (preferredSource) {
          LyricSourceType.qq => ResultSource.qq,
          LyricSourceType.kugou => ResultSource.kugou,
          LyricSourceType.ne => ResultSource.ne,
          LyricSourceType.amll => ResultSource.amll,
          LyricSourceType.local =>
            ResultSource.qq, // unreachable in online mode
        };
        _activeLyricSourceType = switch (rs) {
          ResultSource.qq => LyricSourceType.qq,
          ResultSource.kugou => LyricSourceType.kugou,
          ResultSource.ne => LyricSourceType.ne,
          ResultSource.amll => LyricSourceType.amll,
        };
        logger.i('[updateLyric] online mode: preferred=$rs');
        currLyricFuture = getLyricFromPreferredSource(nowPlaying, rs);
      }
    } else {
      _activeLyricSourceType = lyricSource.source;
      if (lyricSource.source == LyricSourceType.local) {
        logger.i('[updateLyric] source=local, using loadLyricFromAudio');
        currLyricFuture = _loadLocalLyric(audioPath);
      } else {
        logger.i(
            '[updateLyric] source=${lyricSource.source.name}, using getOnlineLyric');
        currLyricFuture = getOnlineLyric(
          qqSongId: lyricSource.qqSongId,
          kugouSongHash: lyricSource.kugouSongHash,
          neSongId: lyricSource.neSongId,
          amllTtmlFile: lyricSource.amllTtmlFile,
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
        if (usesLocalLyric) {
          _lyricCache.put(audioPath, value);
        }
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
    _promptGeneration += 1;
    _promptTimer?.cancel();
    _promptTimer = null;
    hideLyricWritePrompt();
  }

  /// 网络歌词加载成功后，延迟弹出写入标签提示或自动写入
  void _scheduleLyricWritePrompt(String audioPath) {
    _cancelLyricWritePrompt();
    if (!enableOnlineLyricTagWriting) return;

    // 已提示过/忽略过，不再提示
    if (!_lyricWritePromptHistory.shouldPrompt(audioPath)) return;

    final settings = AppSettings.instance;
    if (!settings.promptWriteLyricToTag) return;

    final useAutoWrite = settings.autoWriteLyricToTag;
    final delay = Duration(
      seconds: useAutoWrite
          ? settings.autoWriteLyricToTagDelay
          : settings.promptWriteLyricToTagDelay,
    );

    final generation = _promptGeneration;
    _promptTimer = Timer(delay, () {
      if (generation != _promptGeneration) return;
      // 倒计时结束时检查是否还是同一首歌
      final nowPlaying = _getNowPlaying();
      if (nowPlaying == null || nowPlaying.path != audioPath) return;

      // 异步检查是否已有内嵌歌词
      getLyricFromPath(path: audioPath).then((existing) {
        if (generation != _promptGeneration ||
            _getNowPlaying()?.path != audioPath ||
            !settings.promptWriteLyricToTag) {
          return;
        }
        if (existing != null && existing.trim().isNotEmpty) {
          // 已有歌词，不再提示
          _lyricWritePromptHistory.markEmbeddedLyricFound(audioPath);
          return;
        }

        if (useAutoWrite) {
          // 自动写入模式：直接写入，不弹窗
          _handleAutoWrite(audioPath);
        } else {
          // 手动模式：弹窗询问
          final shown = showLyricWritePrompt(
            title: nowPlaying.title,
            onWrite: () => _handlePromptWrite(audioPath),
            onDismiss: () => _handlePromptDismiss(audioPath),
          );
          if (shown) {
            _lyricWritePromptHistory.markPromptShown(audioPath);
          }
        }
      });
    });
  }

  /// 用户选择写入标签 → 立即写入当前歌曲标签
  void _handlePromptWrite(String audioPath) {
    _lyricWritePromptHistory.markPromptShown(audioPath);
    writeCurrentLyricToTag(expectedPath: audioPath).then((_) {
      showTextOnSnackBar('歌词已写入标签', variant: ToastVariant.success);
    }).catchError((e, trace) {
      _lyricWritePromptHistory.markWriteFailed(audioPath);
      logger.e('写入歌词标签失败', error: e, stackTrace: trace);
      showTextOnSnackBar('写入标签失败，请查看日志', variant: ToastVariant.error);
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
    _lyricWritePromptHistory.markPromptShown(audioPath);

    writeCurrentLyricToTag(expectedPath: audioPath).then((_) {
      // 静默成功，不打扰用户
    }).catchError((e) {
      _lyricWritePromptHistory.markWriteFailed(audioPath);
      logger.e('自动写入歌词标签失败: $e');
    });
  }

  /// 重置写入标签提示状态（刷新已提示列表）
  void resetLyricWritePrompts() {
    _cancelLyricWritePrompt();
    _lyricWritePromptHistory.clear();
  }

  /// 预加载歌词（不影响当前播放）
  /// 下一首切换时直接使用缓存
  void prefetchLyric(Audio audio) {
    final path = audio.path;
    final lyricSource = lyricSources[path];
    final usesLocalLyric = lyricSource?.source == LyricSourceType.local ||
        (lyricSource == null && AppSettings.instance.localLyricFirst);
    if (!usesLocalLyric) return;
    // 如果已缓存，跳过
    if (_lyricCache.containsKey(path) || _lyricPrefetches.containsKey(path)) {
      return;
    }
    final generation = _prefetchGeneration;

    // 触发加载但不等待结果
    late final Future<Lyric?> future;
    future = (() async {
      try {
        final value = await loadLyricFromAudio(audio.path);
        if (value != null && generation == _prefetchGeneration) {
          _lyricCache.put(path, value);
        }
        return value;
      } finally {
        if (identical(_lyricPrefetches[path], future)) {
          _lyricPrefetches.remove(path);
        }
      }
    })();
    _lyricPrefetches[path] = future;
    future.ignore();
  }

  void useLocalLyric() {
    _cancelLyricWritePrompt();

    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return;
    final audioPath = nowPlaying.path;
    final requestToken = _beginLyricRequest(audioPath);
    _activeLyricSourceType = LyricSourceType.local;

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
      _activeLyricSourceType = savedSource.source;
      logger
          .i('[useOnlineLyric] using saved source: ${savedSource.source.name}');
      currLyricFuture = getOnlineLyric(
        qqSongId: savedSource.qqSongId,
        kugouSongHash: savedSource.kugouSongHash,
        neSongId: savedSource.neSongId,
        amllTtmlFile: savedSource.amllTtmlFile,
      );
    } else {
      // 无指定来源 → 使用首选在线源（单源搜索，不三源并行）
      final rs = switch (AppSettings.instance.preferredOnlineSource) {
        LyricSourceType.qq => ResultSource.qq,
        LyricSourceType.kugou => ResultSource.kugou,
        LyricSourceType.ne => ResultSource.ne,
        LyricSourceType.amll => ResultSource.amll,
        LyricSourceType.local => ResultSource.qq,
      };
      _activeLyricSourceType = switch (rs) {
        ResultSource.qq => LyricSourceType.qq,
        ResultSource.kugou => LyricSourceType.kugou,
        ResultSource.ne => LyricSourceType.ne,
        ResultSource.amll => LyricSourceType.amll,
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
    _activeLyricSourceType = LyricSourceType.local;

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
    _lyricPrefetches.clear();
    _lyricCache.clear();
    super.dispose();
  }

  void clearCache() {
    _prefetchGeneration++;
    _lyricPrefetches.clear();
    _lyricCache.clear();
  }
}
