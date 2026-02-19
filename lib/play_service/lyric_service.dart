import 'dart:async';
import 'dart:math';
import 'dart:io';

import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/core/matcher.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 只通知 lyric 变更
class LyricService extends ChangeNotifier {
  final PlayService playService;

  late StreamSubscription _positionStreamSubscription;
  double _lastPos = 0.0;
  Lyric? _currLyric;
  List<int> _lineStartMs = const [];
  int _lastEmittedLineIndex = -1;
  int _lastDesktopLyricLineIndex = -1;
  LyricService(this.playService) {
    _positionStreamSubscription =
        playService.playbackService.positionStream.listen((pos) {
      final jumped = (pos - _lastPos).abs() > 1.0;
      _lastPos = pos;
      if (jumped) {
        findCurrLyricLineAt(pos);
        return;
      }
      final lyric = _currLyric;
      if (lyric == null) return;
      if (_nextLyricLine >= lyric.lines.length) return;

      final posMs = (pos * 1000).round();
      while (_nextLyricLine < _lineStartMs.length &&
          posMs > _lineStartMs[_nextLyricLine]) {
        _nextLyricLine += 1;
      }

      final currLineIndex = _nextLyricLine - 1;
      if (currLineIndex < 0 || currLineIndex >= lyric.lines.length) return;
      if (currLineIndex != _lastEmittedLineIndex) {
        _lastEmittedLineIndex = currLineIndex;
        _lyricLineStreamController.add(currLineIndex);
      }

      if (currLineIndex != _lastDesktopLyricLineIndex) {
        _lastDesktopLyricLineIndex = currLineIndex;
        playService.desktopLyricService.canSendMessage.then((canSend) {
          if (!canSend) return;
          playService.desktopLyricService.sendLyricLineMessage(
            lyric.lines[currLineIndex],
          );
        });
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

    List<String> buildCrcLines(SyncLyricLine line) {
      final end = line.start + line.length;
      final primary = StringBuffer();
      primary.write(formatTimeTag(line.start));
      for (final w in line.words) {
        if (w.content.isEmpty) continue;
        primary.write(formatWordTag(w.start));
        primary.write(w.content);
      }
      primary.write(formatWordTag(end));

      final out = <String>[primary.toString()];
      final trans = line.translation;
      if (trans != null && trans.trim().isNotEmpty) {
        final t = StringBuffer();
        t.write(formatTimeTag(line.start));
        t.write(formatWordTag(line.start));
        t.write(trans.trim());
        t.write(formatWordTag(end));
        out.add(t.toString());
      }
      return out;
    }

    String buildUnsyncLine(LrcLine line) {
      return '${formatTimeTag(line.start)}${line.content}';
    }

    final lines = <String>[];
    for (final line in lyric.lines) {
      if (enhancedIfPossible && lyric is Crc && line is SyncLyricLine) {
        lines.addAll(buildCrcLines(line));
      } else if (enhancedIfPossible && line is SyncLyricLine) {
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

    final lrcText =
        _buildLyricLrcText(lyric, enhancedIfPossible: enhancedIfPossible);
    if (lrcText == null || lrcText.trim().isEmpty) return;

    await writeLyricToPath(path: nowPlaying.path, lyric: lrcText);
  }

  Future<String?> saveCurrentLyricAsLrc({bool enhancedIfPossible = true}) async {
    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return null;

    final lyric = _currLyric ?? await currLyricFuture;
    if (lyric == null) return null;

    final lrcText =
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

  /// 下一行歌词
  int _nextLyricLine = 0;

  late final StreamController<int> _lyricLineStreamController =
      StreamController.broadcast(onListen: () {
    findCurrLyricLineAt(playService.playbackService.position);
  });

  Stream<int> get lyricLineStream => _lyricLineStreamController.stream;

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
    final next = _lowerBoundGreater(_lineStartMs, posMs);
    _nextLyricLine = next == -1 ? lyric.lines.length : next;
    final currLineIndex = max(_nextLyricLine - 1, 0);
    if (currLineIndex != _lastEmittedLineIndex) {
      _lastEmittedLineIndex = currLineIndex;
      _lyricLineStreamController.add(currLineIndex);
    }

    if (currLineIndex < 0 || currLineIndex >= lyric.lines.length) return;
    if (currLineIndex != _lastDesktopLyricLineIndex) {
      _lastDesktopLyricLineIndex = currLineIndex;
      playService.desktopLyricService.canSendMessage.then((canSend) {
        if (!canSend) return;
        playService.desktopLyricService.sendLyricLineMessage(
          lyric.lines[currLineIndex],
        );
      });
    }
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
    _currLyric = lyric;
    _lineStartMs = lyric.lines.map((e) => e.start.inMilliseconds).toList();
  }

  Future<Lyric?> _getLyricDefault(bool localFirst) async {
    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return Future.value(null);

    if (localFirst) {
      return (await Lrc.fromAudioPath(nowPlaying)) ??
          (await getMostMatchedLyric(nowPlaying));
    }
    return (await getMostMatchedLyric(nowPlaying)) ??
        (await Lrc.fromAudioPath(nowPlaying));
  }

  /// 根据默认歌词来源获取歌词：
  /// 1. 如果没有指定来源，按照现在的方式寻找歌词（本地优先或在线优先）
  /// 2. 如果指定来源，按照指定的来源获取
  void updateLyric() {
    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return;

    currLyricFuture.ignore();
    _currLyric = null;
    _lineStartMs = const [];
    _lastEmittedLineIndex = -1;
    _lastDesktopLyricLineIndex = -1;

    final lyricSource = LYRIC_SOURCES[nowPlaying.path];
    if (lyricSource == null) {
      currLyricFuture = _getLyricDefault(AppSettings.instance.localLyricFirst);
    } else {
      if (lyricSource.source == LyricSourceType.local) {
        currLyricFuture = Lrc.fromAudioPath(nowPlaying);
      } else {
        currLyricFuture = getOnlineLyric(
          qqSongId: lyricSource.qqSongId,
          kugouSongHash: lyricSource.kugouSongHash,
          neteaseSongId: lyricSource.neteaseSongId,
        );
      }
    }

    currLyricFuture.then((value) {
      if (value == null) return;
      _nextLyricLine = 0;
      _setCurrLyric(value);
      findCurrLyricLineAt(playService.playbackService.position);
    });

    notifyListeners();
  }

  void useLocalLyric() {
    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return;

    currLyricFuture.ignore();
    _currLyric = null;
    _lineStartMs = const [];
    _lastEmittedLineIndex = -1;
    _lastDesktopLyricLineIndex = -1;

    currLyricFuture = Lrc.fromAudioPath(nowPlaying);
    currLyricFuture.then((value) {
      if (value == null) return;
      _setCurrLyric(value);
      findCurrLyricLine();
    });

    notifyListeners();
  }

  void useOnlineLyric() {
    final nowPlaying = _getNowPlaying();
    if (nowPlaying == null) return;

    currLyricFuture.ignore();
    _currLyric = null;
    _lineStartMs = const [];
    _lastEmittedLineIndex = -1;
    _lastDesktopLyricLineIndex = -1;

    currLyricFuture = getMostMatchedLyric(nowPlaying);
    currLyricFuture.then((value) {
      if (value == null) return;
      _setCurrLyric(value);
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
      if (value == null) return;
      _setCurrLyric(value);
      findCurrLyricLine();
    });

    notifyListeners();
  }

  @override
  void dispose() {
    _lyricLineStreamController.close();
    _positionStreamSubscription.cancel();
    super.dispose();
  }
}
