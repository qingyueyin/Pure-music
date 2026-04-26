import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/word_emphasis_helper.dart';
import 'dart:math';

class Qrc extends Lyric {
  Qrc(super.lines);

  static Qrc fromQrcText(String qrc, [String? transRawStr]) {
    final List<QrcLine> lines = [];
    final splited = qrc.split("\n");

    int? offsetInMilliseconds;
    final offsetPattern = RegExp(r'\[\s*offset\s*:\s*([+-]?\d+)\s*\]');
    for (final line in splited) {
      final matched = offsetPattern.firstMatch(line);
      if (matched == null) continue;
      offsetInMilliseconds = int.tryParse(matched.group(1) ?? "");
      break;
    }
    final offset = offsetInMilliseconds ?? 0;

    for (final item in splited) {
      final qrcLine = QrcLine.fromLine(item, null, offset);

      if (qrcLine == null) continue;

      lines.add(qrcLine);
    }

    if (transRawStr != null) {
      int lineIt = 0;
      final splitedTrans = transRawStr.split("\n");
      for (var transLine in splitedTrans) {
        if (lineIt > lines.length - 1) {
          break;
        }

        final timeStr = transLine.substring(
          transLine.indexOf("[") + 1,
          transLine.indexOf("]"),
        );
        // 如果是翻译行就加到歌词去
        if (int.tryParse(timeStr.split(":").first) != null) {
          final t =
              transLine.replaceAll(RegExp(r"\[\d{2}:\d{2}\.\d{2,}\]"), "");
          if (t.isNotEmpty) {
            lines[lineIt].translation = t;
            lineIt += 1;
          }
        }
      }
    }

    // 添加空白
    final List<QrcLine> fommatedLines = [];
    final firstLine = lines.firstOrNull;
    if (firstLine != null && firstLine.start > const Duration(seconds: 5)) {
      fommatedLines.add(QrcLine(Duration.zero, firstLine.start, []));
    }
    for (int i = 0; i < lines.length - 1; ++i) {
      fommatedLines.add(lines[i]);
      final transitionStart = lines[i].start + lines[i].length;
      final transitionLength = lines[i + 1].start - transitionStart;
      if (transitionLength > const Duration(seconds: 5)) {
        fommatedLines.add(QrcLine(transitionStart, transitionLength, []));
      }
    }
    final lastLine = lines.lastOrNull;
    if (lastLine != null) {
      fommatedLines.add(lastLine);
    }

    return Qrc(fommatedLines);
  }

  @override
  String toString() {
    return (lines as List<SyncLyricLine>).toString();
  }
}

class QrcLine extends SyncLyricLine {
  QrcLine(super.start, super.length, super.words, [super.translation]);

  static QrcLine? fromLine(String line, [String? translation, int offset = 0]) {
    final splitedLine = line.split("]");
    final from = splitedLine[0].indexOf("[") + 1;
    final splitedTime = splitedLine[0].substring(from).split(",");

    if (splitedTime.length != 2) return null;

    final Duration start = Duration(
      milliseconds: max((int.tryParse(splitedTime[0]) ?? 0) - offset, 0),
    );
    final Duration length = Duration(
      milliseconds: int.tryParse(splitedTime[1]) ?? 0,
    );
    final lineStartMs = start.inMilliseconds;

    final splitedContent = splitedLine[1].split(")");
    final List<QrcWord> words = _parseWords(splitedContent, lineStartMs, start, length);

    return QrcLine(start, length, words, translation);
  }

  static List<QrcWord> _parseWords(List<String> contentParts, int lineStartMs, Duration start, Duration length) {
    final List<QrcWord> words = [];
    for (final item in contentParts) {
      final qrcWord = QrcWord.fromWord(item, lineStartMs: lineStartMs);
      if (qrcWord == null) continue;

      if (words.isNotEmpty && _shouldMergeWords(qrcWord, words.last)) {
        final last = words.last;
        final mergedEnd = last.start + last.length;
        if (mergedEnd >= qrcWord.start) {
          words[words.length - 1] = _mergeWords(last, qrcWord);
          continue;
        }
      }

      words.add(qrcWord);
    }
    return words;
  }

  static bool _shouldMergeWords(QrcWord curr, QrcWord last) {
    return curr.start == last.start ||
        (curr.length.inMilliseconds <= 60 && last.start > Duration.zero) ||
        (last.length.inMilliseconds <= 60 && last.start > Duration.zero);
  }

  static QrcWord _mergeWords(QrcWord last, QrcWord curr) {
    return QrcWord(
      last.start,
      Duration(milliseconds: last.length.inMilliseconds + curr.length.inMilliseconds),
      last.content + curr.content,
      marks: last.marks,
    );
  }
}

class QrcWord extends SyncLyricWord {
  QrcWord(super.start, super.length, super.content, {super.marks});

  static QrcWord? fromWord(String word, {required int lineStartMs}) {
    final splitedWord = word.split("(");
    if (splitedWord.length != 2) return null;

    final splitedTime = splitedWord[1].split(",");

    if (splitedTime.length != 2) return null;

    final Duration start = Duration(
      milliseconds: lineStartMs + max(int.tryParse(splitedTime[0]) ?? 0, 0),
    );
    final Duration length = Duration(
      milliseconds: int.tryParse(splitedTime[1]) ?? 0,
    );

    final content = splitedWord[0];
    final marks = WordMarkingUtil.analyzeWithDuration(
      content,
      length.inMilliseconds,
    );

    return QrcWord(start, length, content, marks: marks);
  }
}
