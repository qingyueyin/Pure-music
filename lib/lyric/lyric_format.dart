import 'dart:math';

import 'package:pure_music/lyric/lyric.dart';

// ── 格式类型 ──

enum LrcFormatType { line, wordByWord, enhanced }

// ── 正则 ──

final _metaTagRe = RegExp(r'^\[[a-z]+:', caseSensitive: false);
final _timeTagRe = RegExp(r'\[(\d{1,3}):(\d{2})\.(\d{1,3})\]', caseSensitive: false);
final _enhTimeTagRe = RegExp(r'<(\d{1,3}):(\d{2})\.(\d{1,3})>', caseSensitive: false);
final _lineTimeRe = RegExp(r'^\[(\d{1,3}):(\d{2})\.(\d{1,3})\]', caseSensitive: false);

const _defaultWordDurationMs = 1000;
const _alignToleranceMs = 300;

// ── 工具 ──

int _parseTimeToMs(String min, String sec, String ms) {
  final minutes = int.tryParse(min) ?? 0;
  final seconds = int.tryParse(sec) ?? 0;
  final msNorm = ms.padRight(3, '0').substring(0, 3);
  final msInt = int.tryParse(msNorm) ?? 0;
  return minutes * 60000 + seconds * 1000 + msInt;
}

SyncLyricWord _makeWord(String text, int startMs, int endMs) {
  return SyncLyricWord(
    Duration(milliseconds: startMs),
    Duration(milliseconds: max(endMs - startMs, 0)),
    text,
  );
}

SyncLyricLine _makeLine(List<SyncLyricWord> words, int startMs, int endMs,
    [String? trans, String? roma]) {
  final line = SyncLyricLine(
    Duration(milliseconds: startMs),
    Duration(milliseconds: max(endMs - startMs, 0)),
    words,
    trans,
    roma,
  );
  return line;
}

// ── 格式检测 ──

LrcFormatType detectLrcFormat(String content) {
  for (final raw in content.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || _metaTagRe.hasMatch(line)) continue;
    if (_enhTimeTagRe.hasMatch(line)) return LrcFormatType.enhanced;
    final matches = _timeTagRe.allMatches(line).toList();
    if (matches.length > 1) return LrcFormatType.wordByWord;
  }
  return LrcFormatType.line;
}

// ── 逐字 LRC 解析 ──
// 格式：[00:28.850]曲[00:32.455]：[00:36.060]钱

List<SyncLyricLine> parseWordByWordLrc(String content) {
  final result = <SyncLyricLine>[];
  SyncLyricLine? prevLine;
  final wordByWordRe = RegExp(r'\[(\d{1,3}):(\d{2})\.(\d{1,3})\]([^\[\]]*)');

  for (final raw in content.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || _metaTagRe.hasMatch(line)) continue;

    final words = <SyncLyricWord>[];
    var lineStartMs = 0x7FFFFFFFFFFFFFFF;
    SyncLyricWord? prevWord;

    for (final m in wordByWordRe.allMatches(line)) {
      final startMs = _parseTimeToMs(m.group(1)!, m.group(2)!, m.group(3)!);
      final wordText = m.group(4)!;

      if (wordText.isEmpty && words.isEmpty) continue;
      lineStartMs = min(lineStartMs, startMs);

      if (prevWord != null) {
        prevWord.length = Duration(milliseconds: startMs - prevWord.start.inMilliseconds);
      }

      if (wordText.isNotEmpty) {
        final w = SyncLyricWord(Duration(milliseconds: startMs), Duration.zero, wordText);
        words.add(w);
        prevWord = w;
      }
    }

    if (prevWord != null) {
      prevWord.length = const Duration(milliseconds: _defaultWordDurationMs);
    }

    if (words.isNotEmpty) {
      final actualStart = lineStartMs == 0x7FFFFFFFFFFFFFFF ? 0 : lineStartMs;
      var endMs = words.last.start.inMilliseconds + words.last.length.inMilliseconds;

      // 修正上一行的结束时间
      if (prevLine != null && prevLine.words.isNotEmpty) {
        final prevLast = prevLine.words.last;
        if (actualStart > prevLast.start.inMilliseconds) {
          prevLast.length = Duration(
            milliseconds: min(
              prevLast.length.inMilliseconds,
              actualStart - prevLast.start.inMilliseconds,
            ),
          );
        }
      }

      final lineObj = _makeLine(words, actualStart, endMs);

      // 更新 prevLine.endTime
      if (words.isNotEmpty) {
        endMs = words.last.start.inMilliseconds + words.last.length.inMilliseconds;
        lineObj.length = Duration(milliseconds: endMs - actualStart);
      }

      result.add(lineObj);
      prevLine = lineObj;
    }
  }

  return result;
}

// ── 增强型 LRC 解析 ──
// 格式：[01:37.305]<01:37.624>怕<01:37.943>你

List<SyncLyricLine> parseEnhancedLrc(String content) {
  final result = <SyncLyricLine>[];
  SyncLyricLine? prevLine;
  final enhWordRe = RegExp(r'<(\d{1,3}):(\d{2})\.(\d{1,3})>([^<]*)');

  for (final raw in content.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || _metaTagRe.hasMatch(line)) continue;

    final lineMatch = _lineTimeRe.firstMatch(line);
    if (lineMatch == null) continue;

    final lineStartMs = _parseTimeToMs(lineMatch.group(1)!, lineMatch.group(2)!, lineMatch.group(3)!);
    final afterTime = line.substring(lineMatch.group(0)!.length);

    final words = <SyncLyricWord>[];

    if (_enhTimeTagRe.hasMatch(afterTime)) {
      SyncLyricWord? prevWord;

      for (final m in enhWordRe.allMatches(afterTime)) {
        final startMs = _parseTimeToMs(m.group(1)!, m.group(2)!, m.group(3)!);
        final wordText = m.group(4)!;

        if (prevWord != null) {
          prevWord.length = Duration(milliseconds: startMs - prevWord.start.inMilliseconds);
        }

        if (wordText.isNotEmpty) {
          final w = SyncLyricWord(Duration(milliseconds: startMs), Duration.zero, wordText);
          words.add(w);
          prevWord = w;
        }
      }

      if (prevWord != null) {
        prevWord.length = const Duration(milliseconds: _defaultWordDurationMs);
      }
    } else {
      final text = afterTime.trim();
      if (text.isNotEmpty) {
        words.add(_makeWord(text, lineStartMs, lineStartMs + _defaultWordDurationMs));
      }
    }

    if (words.isNotEmpty) {
      var endMs = words.last.start.inMilliseconds + words.last.length.inMilliseconds;

      if (prevLine != null && prevLine.words.isNotEmpty) {
        final prevLast = prevLine.words.last;
        if (lineStartMs > prevLast.start.inMilliseconds) {
          prevLast.length = Duration(
            milliseconds: min(
              prevLast.length.inMilliseconds,
              lineStartMs - prevLast.start.inMilliseconds,
            ),
          );
        }
      }

      final lineObj = _makeLine(words, lineStartMs, endMs);
      result.add(lineObj);
      prevLine = lineObj;
    }
  }

  return result;
}

// ── 智能解析 ──

({LrcFormatType format, List<SyncLyricLine> lines}) parseSmartLrc(String content) {
  final format = detectLrcFormat(content);
  late List<SyncLyricLine> lines;

  switch (format) {
    case LrcFormatType.wordByWord:
      lines = parseWordByWordLrc(content);
    case LrcFormatType.enhanced:
      lines = parseEnhancedLrc(content);
    case LrcFormatType.line:
      lines = _parseBasicLrc(content);
  }

  return (format: format, lines: lines);
}

// ── 基础 LRC 解析 ──

List<SyncLyricLine> _parseBasicLrc(String content) {
  final events = <_Event>[];
  var globalIdx = 0;

  for (final raw in content.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    final text = line.replaceAll(_timeTagRe, '').trim();
    final matches = _timeTagRe.allMatches(line);

    for (final m in matches) {
      final ms = _parseTimeToMs(m.group(1)!, m.group(2)!, m.group(3)!);
      events.add(_Event(ms, text, globalIdx++));
    }
  }

  events.sort((a, b) => a.time != b.time ? a.time.compareTo(b.time) : a.index.compareTo(b.index));

  final result = <SyncLyricLine>[];
  var i = 0;

  while (i < events.length) {
    final curTime = events[i].time;
    final group = <_Event>[];
    while (i < events.length && events[i].time == curTime) {
      group.add(events[i]);
      i++;
    }

    final nextMs = i < events.length ? events[i].time : curTime + 10000;
    final textEvents = group.where((e) => e.text.isNotEmpty).toList();
    if (textEvents.isEmpty) continue;

    final mainLine = _makeLine(
      [SyncLyricWord(Duration(milliseconds: curTime), Duration(milliseconds: nextMs - curTime), textEvents[0].text)],
      curTime, nextMs,
      textEvents.length > 1 ? textEvents[1].text : null,
      textEvents.length > 2 ? textEvents[2].text : null,
    );

    result.add(mainLine);
  }

  return result;
}

// ── 歌词对齐 ──

/// 双指针法对齐翻译/罗马音
List<SyncLyricLine> alignLyrics(
  List<SyncLyricLine> mainLines,
  List<SyncLyricLine> otherLines,
  bool isTranslation,
) {
  if (mainLines.isEmpty || otherLines.isEmpty) {
    return mainLines.map((l) => SyncLyricLine(l.start, l.length, List.from(l.words), l.translation, l.romanLyric)).toList();
  }

  final result = mainLines.map((l) =>
    SyncLyricLine(l.start, l.length, List.from(l.words), l.translation, l.romanLyric)
  ).toList();

  var mi = 0, oi = 0;
  while (mi < result.length && oi < otherLines.length) {
    final diff = result[mi].start.inMilliseconds - otherLines[oi].start.inMilliseconds;

    if (diff.abs() <= _alignToleranceMs) {
      final text = otherLines[oi].words.map((w) => w.content).join();
      if (isTranslation) {
        result[mi].translation = text;
      } else {
        result[mi].romanLyric = text;
      }
      mi++;
      oi++;
    } else if (diff < 0) {
      mi++;
    } else {
      oi++;
    }
  }

  return result;
}

/// 按开始时间分组，自动识别主句/翻译/音译
List<SyncLyricLine> alignLyricLines(
  List<SyncLyricLine> lines, {
  int maxTimeDiff = 0,
}) {
  if (lines.isEmpty) return [];

  int toMs(SyncLyricLine l) => l.start.inMilliseconds;
  String toText(SyncLyricLine l) => l.words.map((w) => w.content).join().trim();

  bool isMatch(SyncLyricLine? a, SyncLyricLine? b) {
    if (a == null || b == null) return false;
    return (toMs(a) - toMs(b)).abs() <= maxTimeDiff;
  }

  final sorted = lines.sublist(0)..sort((a, b) => toMs(a).compareTo(toMs(b)));
  final groups = <List<SyncLyricLine>>[];

  for (final line in sorted) {
    final last = groups.isNotEmpty ? groups.last.first : null;
    if (isMatch(last, line)) {
      groups.last.add(line);
    } else {
      groups.add([line]);
    }
  }

  return groups.map((g) {
    final base = SyncLyricLine(g[0].start, g[0].length, List.from(g[0].words), null, null);
    if (g.length > 1) {
      final tranText = toText(g[1]);
      if (tranText.isNotEmpty) base.translation = tranText;
    }
    if (g.length > 2) {
      final romaText = toText(g[2]);
      if (romaText.isNotEmpty) base.romanLyric = romaText;
    }
    return base;
  }).toList();
}

// ── 括号替换格式化 ──

enum BracketPreset {
  dash,
  angleBrackets,
  cornerBrackets,
  custom,
}

class BracketConfig {
  final String startStr;
  final String endStr;
  final bool isEnclosure;

  const BracketConfig({
    this.startStr = ' - ',
    this.endStr = ' ',
    this.isEnclosure = false,
  });
}

BracketConfig _getBracketConfig(BracketPreset preset, [String customChar = '-']) {
  switch (preset) {
    case BracketPreset.angleBrackets:
      return const BracketConfig(startStr: '〔', endStr: '〕', isEnclosure: true);
    case BracketPreset.cornerBrackets:
      return const BracketConfig(startStr: '「', endStr: '」', isEnclosure: true);
    case BracketPreset.custom:
      final trimmed = customChar.trim();
      if (trimmed.length == 2 && trimmed[0] != trimmed[1] && !trimmed.contains('-')) {
        return BracketConfig(startStr: trimmed[0], endStr: trimmed[1], isEnclosure: true);
      }
      final sep = ' $trimmed '.replaceAll(RegExp(r'\s+'), ' ');
      return BracketConfig(startStr: sep, endStr: ' ', isEnclosure: false);
    case BracketPreset.dash:
      return const BracketConfig();
  }
}

final _fullBracketRe = RegExp(r'^\s*[(（][^()（）]*[)）]\s*$');
final _leftBracketRe = RegExp(r'[(（]');
final _rightBracketRe = RegExp(r'[)）]');

String _processString(String str, BracketConfig cfg) {
  if (str.isEmpty) return str;

  if (!cfg.isEnclosure && _fullBracketRe.hasMatch(str)) {
    return str.replaceFirst(RegExp(r'^\s*[(（]'), '').replaceFirst(RegExp(r'[)）]\s*$'), '').trim();
  }

  var res = str.replaceAll(_leftBracketRe, cfg.startStr);
  if (cfg.isEnclosure) {
    res = res.replaceAll(_rightBracketRe, cfg.endStr);
  } else {
    res = res.replaceAllMapped(_rightBracketRe, (m) {
      final after = str.substring(m.start + 1);
      return RegExp(r'^\s*$').hasMatch(after) ? '' : cfg.endStr;
    });
    if (cfg.startStr.contains('-')) {
      res = res.replaceAll(RegExp(r'(?:\s*-\s*){2,}'), ' - ');
    }
  }

  return res;
}

List<SyncLyricLine> applyBracketReplacement(List<SyncLyricLine> lines,
    {BracketPreset preset = BracketPreset.dash, String customChar = '-'}) {
  final cfg = _getBracketConfig(preset, customChar);

  return lines.map((line) {
    final fullText = line.words.map((w) => w.content).join();
    final isFullBracket = _fullBracketRe.hasMatch(fullText);
    final newWords = <SyncLyricWord>[];

    if (isFullBracket && !cfg.isEnclosure) {
      var removedStart = false;
      var removedEnd = false;
      for (final w in line.words) {
        var c = w.content;
        if (!removedStart && _leftBracketRe.hasMatch(c)) {
          c = c.replaceFirst(_leftBracketRe, '');
          removedStart = true;
        }
        newWords.add(SyncLyricWord(w.start, w.length, c));
      }
      if (!removedEnd) {
        for (int i = newWords.length - 1; i >= 0; i--) {
          final c = newWords[i].content;
          final lastIdx = max(c.lastIndexOf(')'), c.lastIndexOf('）'));
          if (lastIdx != -1) {
            final newC = c.substring(0, lastIdx) + c.substring(lastIdx + 1);
            newWords[i] = SyncLyricWord(newWords[i].start, newWords[i].length, newC);
            removedEnd = true;
            break;
          }
        }
      }
    } else {
      for (final w in line.words) {
        var c = w.content.replaceAll(_leftBracketRe, cfg.startStr);
        if (cfg.isEnclosure) {
          c = c.replaceAll(_rightBracketRe, cfg.endStr);
        } else {
          c = c.replaceAllMapped(_rightBracketRe, (m) {
            return m.start == c.length - 1 ? '' : cfg.endStr;
          });
        }
        if (!cfg.isEnclosure && cfg.startStr.contains('-')) {
          c = c.replaceAll(RegExp(r'(?:\s*-\s*){2,}'), ' - ');
        }
        newWords.add(SyncLyricWord(w.start, w.length, c));
      }
    }

    final newLine = SyncLyricLine(
      line.start, line.length, newWords,
      line.translation != null ? _processString(line.translation!, cfg) : null,
      line.romanLyric != null ? _processString(line.romanLyric!, cfg) : null,
    );

    return newLine;
  }).toList();
}

// ── 内部模型 ──

class _Event {
  final int time;
  final String text;
  final int index;
  _Event(this.time, this.text, this.index);
}
