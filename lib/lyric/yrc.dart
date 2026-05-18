import 'package:pure_music/lyric/lyric.dart';
import 'dart:math';

class Yrc extends Lyric {
  Yrc(super.lines);

  static Yrc fromYrcText(String yrc, [String? transRawStr]) {
    final List<YrcLine> lines = [];
    final splited = yrc.split('\n');

    int? offsetInMilliseconds;
    final offsetPattern = RegExp(r'\[\s*offset\s*:\s*([+-]?\d+)\s*\]');
    for (final line in splited) {
      final matched = offsetPattern.firstMatch(line);
      if (matched == null) continue;
      offsetInMilliseconds = int.tryParse(matched.group(1) ?? '');
      break;
    }
    final offset = offsetInMilliseconds ?? 0;

    for (final item in splited) {
      final yrcLine = YrcLine.fromLine(item, null, offset);
      if (yrcLine == null) continue;
      lines.add(yrcLine);
    }

    if (transRawStr != null) {
      int lineIt = 0;
      final splitedTrans = transRawStr.split('\n');
      for (var transLine in splitedTrans) {
        if (lineIt > lines.length - 1) break;

        final bracketStart = transLine.indexOf('[');
        final bracketEnd = transLine.indexOf(']');
        if (bracketStart == -1 || bracketEnd == -1 || bracketEnd <= bracketStart) continue;

        final timeStr = transLine.substring(bracketStart + 1, bracketEnd);
        if (int.tryParse(timeStr.split(':').first) != null) {
          final t = transLine.replaceAll(RegExp(r'\[\d{2}:\d{2}\.\d{2,}\]'), '');
          if (t.isNotEmpty) {
            lines[lineIt].translation = t;
            lineIt += 1;
          }
        }
      }
    }

    final List<YrcLine> fommatedLines = [];
    final firstLine = lines.firstOrNull;
    if (firstLine != null && firstLine.start > const Duration(seconds: 5)) {
      fommatedLines.add(YrcLine._createBlank(Duration.zero, firstLine.start));
    }
    for (int i = 0; i < lines.length - 1; ++i) {
      fommatedLines.add(lines[i]);
      final transitionStart = lines[i].start + lines[i].length;
      final transitionLength = lines[i + 1].start - transitionStart;
      if (transitionLength > const Duration(seconds: 5)) {
        fommatedLines.add(YrcLine._createBlank(transitionStart, transitionLength));
      }
    }
    final lastLine = lines.lastOrNull;
    if (lastLine != null) {
      fommatedLines.add(lastLine);
    }

    return Yrc(fommatedLines);
  }

  @override
  String toString() {
    return (lines as List<SyncLyricLine>).toString();
  }
}

class YrcLine extends SyncLyricLine {
  YrcLine(super.start, super.length, super.words, [super.translation]);

  factory YrcLine._createBlank(Duration start, Duration length) {
    return YrcLine(start, length, []);
  }

  static YrcLine? fromLine(String line, [String? translation, int offset = 0]) {
    final splitedLine = line.split(']');
    if (splitedLine.isEmpty) return null;

    final from = splitedLine[0].indexOf('[') + 1;
    final splitedTime = splitedLine[0].substring(from).split(',');

    if (splitedTime.length != 2) return null;

    final Duration start = Duration(
      milliseconds: max((int.tryParse(splitedTime[0]) ?? 0) - offset, 0),
    );
    final Duration length = Duration(
      milliseconds: int.tryParse(splitedTime[1]) ?? 0,
    );

    final splitedContent = splitedLine[1];
    final List<YrcWord> words = _parseWords(splitedContent, offset);

    return YrcLine(start, length, words, translation);
  }

  static List<YrcWord> _parseWords(String content, [int offset = 0]) {
    final List<YrcWord> words = [];
    final wordRegex = RegExp(r'\((\d+),(\d+),\d+\)([^(]*?)');

    for (final match in wordRegex.allMatches(content)) {
      final startMs = int.tryParse(match.group(1) ?? '') ?? 0;
      final durationMs = int.tryParse(match.group(2) ?? '') ?? 0;
      final text = match.group(3) ?? '';

      if (text.isEmpty) continue;

      // YRC 单词时间戳是绝对时间，不需要 +lineStart
      final wordStart = Duration(milliseconds: max(startMs - offset, 0));
      final newWord = YrcWord(wordStart, Duration(milliseconds: durationMs), text);

      if (words.isNotEmpty && _shouldMergeWords(newWord, words.last)) {
        final last = words.last;
        final mergedEnd = last.start + last.length;
        if (mergedEnd >= newWord.start) {
          words[words.length - 1] = _mergeWords(last, newWord);
          continue;
        }
      }

      words.add(newWord);
    }

    if (words.isEmpty && content.isNotEmpty) {
      // YRC 单词时间戳是绝对时间，无单词时使用行起始时间
    }

    return words;
  }

  static bool _shouldMergeWords(YrcWord curr, YrcWord last) {
    return curr.start == last.start ||
        (curr.length.inMilliseconds <= 60 && last.start > Duration.zero) ||
        (last.length.inMilliseconds <= 60 && last.start > Duration.zero);
  }

  static YrcWord _mergeWords(YrcWord last, YrcWord curr) {
    return YrcWord(
      last.start,
      Duration(milliseconds: last.length.inMilliseconds + curr.length.inMilliseconds),
      last.content + curr.content,
    );
  }
}

class YrcWord extends SyncLyricWord {
  YrcWord(super.start, super.length, super.content);
}
