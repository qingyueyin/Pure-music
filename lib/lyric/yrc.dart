import 'package:pure_music/lyric/lyric.dart';

class Yrc extends Lyric {
  Yrc(super.lines);

  static Yrc fromYrcText(String yrc, [String? transRawStr]) {
    final List<YrcLine> lines = [];
    final splited = yrc.split("\n");
    for (final item in splited) {
      final yrcLine = YrcLine.fromLine(item);
      if (yrcLine == null) continue;
      lines.add(yrcLine);
    }

    if (transRawStr != null) {
      int lineIt = 0;
      final splitedTrans = transRawStr.split("\n");
      for (var transLine in splitedTrans) {
        if (lineIt > lines.length - 1) break;

        final timeStr = transLine.substring(
          transLine.indexOf("[") + 1,
          transLine.indexOf("]"),
        );
        if (int.tryParse(timeStr.split(":").first) != null) {
          final t = transLine.replaceAll(RegExp(r"\[\d{2}:\d{2}\.\d{2,}\]"), "");
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

  static YrcLine? fromLine(String line, [String? translation]) {
    final splitedLine = line.split("]");
    if (splitedLine.isEmpty) return null;

    final from = splitedLine[0].indexOf("[") + 1;
    final splitedTime = splitedLine[0].substring(from).split(",");

    if (splitedTime.length != 2) return null;

    final Duration start = Duration(
      milliseconds: int.tryParse(splitedTime[0]) ?? 0,
    );
    final Duration length = Duration(
      milliseconds: int.tryParse(splitedTime[1]) ?? 0,
    );

    final splitedContent = splitedLine[1];
    final List<YrcWord> words = _parseWords(splitedContent, start, length);

    return YrcLine(start, length, words, translation);
  }

  static List<YrcWord> _parseWords(String content, Duration lineStart, Duration lineLength) {
    final List<YrcWord> words = [];
    final wordRegex = RegExp(r'\((\d+),(\d+),\d+\)([^(]*?)');

    for (final match in wordRegex.allMatches(content)) {
      final startMs = int.tryParse(match.group(1) ?? '') ?? 0;
      final durationMs = int.tryParse(match.group(2) ?? '') ?? 0;
      final text = match.group(3) ?? '';

      if (text.isEmpty) continue;

      words.add(YrcWord(
        Duration(milliseconds: startMs) + lineStart,
        Duration(milliseconds: durationMs),
        text,
      ));
    }

    if (words.isEmpty && content.isNotEmpty) {
      words.add(YrcWord(lineStart, lineLength, content));
    }

    return words;
  }
}

class YrcWord extends SyncLyricWord {
  YrcWord(super.start, super.length, super.content);
}
