import 'package:pure_music/services/online_lyric/models/lyric_entry.dart';

/// 统一歌词解析工具
/// 参考 ZeroBit-Player parse_lyrics.dart + 当前项目 lrc/yrc/qrc/krc.dart
class LrcTool {
  static final _lrcLineRegex = RegExp(r'\[(\d{2}):(\d{2}\.\d{2,3})](.*?)(\r?\n|$)');
  static final _karaOkLineRegex = RegExp(r'\[(\d+),(\d+)](.*?)(\r?\n|$)');
  static final _yrcWordRegex = RegExp(r'\((\d+),(\d+),\d+\)[^(]*?((?:.(?!\(\d+,))*.)');
  static final _qrcWordRegex = RegExp(r'[^(]*?((?:.(?!\(\d+,))*.)\((\d+),(\d+)\)');
  static final _krcWordRegex = RegExp(r'<(\d+),(\d+),\d+>[^<]*?((?:.(?!<\d+,))*.)');
  static final _enhancedLrcWordRegex = RegExp(r'<(\d{2}):(\d{2}\.\d{2,3})>([^<]*)');
  static final _wordByWordLrcWordRegex = RegExp(r'\[(\d{2}):(\d{2}\.\d{2,3})]([^\[]*)');

  static double _parseTime(String m, String s) {
    final minutes = int.tryParse(m) ?? 0;
    final seconds = double.tryParse(s) ?? 0.0;
    return minutes * 60 + seconds;
  }

  static double _msToSec(String msStr) {
    final ms = int.tryParse(msStr) ?? 0;
    return ms / 1000.0;
  }

  static bool _shouldMergeWords(WordEntry curr, WordEntry last) {
    return curr.start == last.start ||
        ((curr.length.inMilliseconds / 1000 <= 0.06 ||
                last.length.inMilliseconds / 1000 <= 0.06) &&
            last.start.inMilliseconds > 0);
  }

  static WordEntry _mergeWords(WordEntry last, WordEntry curr) {
    return WordEntry(
      start: last.start,
      length: Duration(
        milliseconds:
            last.length.inMilliseconds + curr.length.inMilliseconds,
      ),
      content: last.content + curr.content,
    );
  }

  static final _tagRegex = RegExp(r'^\[(ti|ar|al|by|au|offset|re|ve):(.*)\]$');

  static ParsedLyricResult? parse(
    String text, {
    String? transText,
    String? romanizationText,
    Duration offset = Duration.zero,
  }) {
    if (text.trim().isEmpty) return null;

    final format = _detectFormat(text);
    final tags = _extractTags(text);
    final lines = _parseByFormat(text, format);
    if (lines.isEmpty) return null;

    _setNextTimes(lines);

    ParsedLyricResult result = ParsedLyricResult(
      lines: lines,
      format: format,
      offset: offset,
      tags: tags,
    );

    result = _mergeTranslationText(result, transText);
    result = _mergeRomanizationText(result, romanizationText);

    if (offset != Duration.zero) {
      result = result.applyOffset(offset);
    }

    result = _insertBlankLines(result);

    return result;
  }

  static Map<String, String> _extractTags(String text) {
    final tags = <String, String>{};
    for (final line in text.split('\n')) {
      final match = _tagRegex.firstMatch(line.trim());
      if (match != null) {
        final key = match.group(1)?.toLowerCase() ?? '';
        final value = match.group(2)?.trim() ?? '';
        if (key.isNotEmpty && value.isNotEmpty) {
          tags[key] = value;
        }
      }
    }
    return tags;
  }

  static LyricFormat _detectFormat(String lrcContent) {
    final lines = lrcContent.trim();
    if (RegExp(r'(<\d{2}:\d{2}\.\d{2,3}>[^\n\r]*){3}').hasMatch(lines)) {
      return LyricFormat.enhanced;
    }
    if (RegExp(r'\[\d{2}:\d{2}\.\d{2,3}\].*\[\d{2}:\d{2}\.\d{2,3}\]').hasMatch(lines)) {
      return LyricFormat.wordByWord;
    }

    for (final m in _yrcWordRegex.allMatches(lines)) {
      if (m.group(0)!.isNotEmpty) return LyricFormat.yrc;
    }
    for (final m in _qrcWordRegex.allMatches(lines)) {
      if (m.group(0)!.isNotEmpty) return LyricFormat.qrc;
    }
    for (final m in _krcWordRegex.allMatches(lines)) {
      if (m.group(0)!.isNotEmpty) return LyricFormat.krc;
    }

    if (_lrcLineRegex.hasMatch(lines)) return LyricFormat.lrc;

    return LyricFormat.unknown;
  }

  static List<LyricEntry> _parseByFormat(String text, LyricFormat format) {
    switch (format) {
      case LyricFormat.yrc:
        return _parseKaraOk(text, LyricFormat.yrc);
      case LyricFormat.qrc:
        return _parseKaraOk(text, LyricFormat.qrc);
      case LyricFormat.krc:
        return _parseKaraOk(text, LyricFormat.krc);
      case LyricFormat.enhanced:
        return _parseEnhanced(text);
      case LyricFormat.wordByWord:
        return _parseWordByWord(text);
      case LyricFormat.lrc:
        return _parseLrc(text);
      default:
        return _parseLrc(text);
    }
  }

  static List<LyricEntry> _parseLrc(String text) {
    final reg1 = RegExp(r'<\d{2}:\d{2}\.\d{2,3}>');
    final reg2 = RegExp(r'\[\d{2}:\d{2}\.\d{2,3}\]');

    final entries = <LyricEntry>[];
    for (final match in _lrcLineRegex.allMatches(text)) {
      final startSec = _parseTime(match.group(1)!, match.group(2)!);
      final lyric = match.group(3)!
          .replaceAll(reg1, '')
          .replaceAll(reg2, '')
          .trim();
      if (lyric.isEmpty) continue;
      entries.add(LyricEntry(
        start: Duration(milliseconds: (startSec * 1000).round()),
        content: lyric,
      ));
    }
    return entries;
  }

  static List<LyricEntry> _parseEnhanced(String text) {
    final segments = <LyricEntry>[];
    for (final m in _lrcLineRegex.allMatches(text)) {
      final start = _parseTime(m.group(1)!, m.group(2)!);
      final lyric = m.group(3)!.trim();
      final words = _parseWordEntries(lyric, _enhancedLrcWordRegex, (wordMatch) {
        final startSec = _parseTime(wordMatch.group(1)!, wordMatch.group(2)!);
        return WordEntry(
          start: Duration(milliseconds: (startSec * 1000).round()),
          length: const Duration(milliseconds: 50),
          content: wordMatch.group(3)?.replaceAll('\n', '') ?? '',
        );
      });
      final content = words.map((w) => w.content).join();
      if (content.isEmpty) continue;
      segments.add(LyricEntry(
        start: Duration(milliseconds: (start * 1000).round()),
        content: content,
        words: words,
      ));
    }
    return segments;
  }

  static List<LyricEntry> _parseWordByWord(String text) {
    final segments = <LyricEntry>[];
    for (final m in _lrcLineRegex.allMatches(text)) {
      final start = _parseTime(m.group(1)!, m.group(2)!);
      final lyric = m.group(3)!.trim();
      final words = _parseWordEntries(lyric, _wordByWordLrcWordRegex, (wordMatch) {
        final startSec = _parseTime(wordMatch.group(1)!, wordMatch.group(2)!);
        return WordEntry(
          start: Duration(milliseconds: (startSec * 1000).round()),
          length: const Duration(milliseconds: 50),
          content: wordMatch.group(3)?.replaceAll('\n', '') ?? '',
        );
      });
      final content = words.map((w) => w.content).join();
      if (content.isEmpty) continue;
      segments.add(LyricEntry(
        start: Duration(milliseconds: (start * 1000).round()),
        content: content,
        words: words,
      ));
    }
    return segments;
  }

  static List<LyricEntry> _parseKaraOk(String text, LyricFormat format) {
    final segments = <LyricEntry>[];
    for (final m in _karaOkLineRegex.allMatches(text)) {
      final startMs = int.tryParse(m.group(1)!) ?? 0;
      final content = m.group(3)!;

      final (regex, startIdx, durIdx, textIdx) = _getKaraOkConfig(format);
      if (regex == null) continue;

      final words = _parseKaraOkWords(content, regex, startIdx, durIdx, textIdx,
          lineStartSec: format == LyricFormat.krc ? _msToSec(m.group(1)!) : 0.0);
      final lineContent = words.map((w) => w.content).join();
      if (lineContent.isEmpty) continue;

      segments.add(LyricEntry(
        start: Duration(milliseconds: startMs),
        content: lineContent,
        words: words,
      ));
    }
    return segments;
  }

  static List<WordEntry> _parseKaraOkWords(
    String content,
    RegExp wordRegex,
    int startIdx,
    int durIdx,
    int textIdx, {
    double lineStartSec = 0.0,
  }) {
    final words = <WordEntry>[];
    for (final m in wordRegex.allMatches(content)) {
      final curr = WordEntry(
        start: Duration(milliseconds: ((_msToSec(m.group(startIdx)!) + lineStartSec) * 1000).round()),
        length: Duration(milliseconds: (_msToSec(m.group(durIdx)!) * 1000).round()),
        content: m.group(textIdx)?.replaceAll('\n', '') ?? '',
      );

      if (words.isNotEmpty && _shouldMergeWords(curr, words.last)) {
        final last = words.last;
        if (last.start.inMilliseconds + last.length.inMilliseconds >=
            curr.start.inMilliseconds) {
          words[words.length - 1] = _mergeWords(last, curr);
          continue;
        }
      }
      words.add(curr);
    }

    for (var i = 0; i < words.length; i++) {
      words[i].nextTime = i < words.length - 1
          ? words[i + 1].start
          : Duration(milliseconds: words[i].start.inMilliseconds + 5000);
    }
    return words;
  }

  static (RegExp?, int, int, int) _getKaraOkConfig(LyricFormat type) {
    return switch (type) {
      LyricFormat.yrc => (_yrcWordRegex, 1, 2, 3),
      LyricFormat.qrc => (_qrcWordRegex, 2, 3, 1),
      LyricFormat.krc => (_krcWordRegex, 1, 2, 3),
      _ => (null, 0, 0, 0),
    };
  }

  static List<WordEntry> _parseWordEntries(
    String content,
    RegExp regex,
    WordEntry Function(RegExpMatch) builder,
  ) {
    final words = <WordEntry>[];
    for (final m in regex.allMatches(content)) {
      words.add(builder(m));
    }
    if (words.length > 1) {
      for (var i = 0; i < words.length - 1; i++) {
        words[i].length = Duration(
          milliseconds: words[i + 1].start.inMilliseconds - words[i].start.inMilliseconds,
        );
      }
    }
    return words;
  }

  static void _setNextTimes(List<LyricEntry> lines) {
    for (var i = 0; i < lines.length - 1; i++) {
      lines[i].nextTime = lines[i + 1].start;
    }
    if (lines.isNotEmpty) {
      lines.last.nextTime = Duration(
        milliseconds: lines.last.start.inMilliseconds + 5000,
      );
    }
  }

  static ParsedLyricResult _mergeTranslationText(
    ParsedLyricResult main,
    String? transText,
  ) {
    if (transText == null || transText.isEmpty) return main;

    final transLines = _parseLrc(transText);
    if (transLines.isEmpty) return main;

    // 行数一致时直接对齐
    if (main.lines.length == transLines.length) {
      for (int i = 0; i < main.lines.length; i++) {
        if (transLines[i].content.trim().isNotEmpty) {
          main.lines[i].translation = transLines[i].content;
        }
      }
      return main;
    }

    // Lyrico 的时间窗口匹配算法
    final tolerance =
        (main.format == LyricFormat.qrc || main.format == LyricFormat.lrc)
            ? 100
            : 800;

    int transIdx = 0;

    for (var i = 0; i < main.lines.length; i++) {
      final curr = main.lines[i];
      final currEnd = curr.nextTime.inMilliseconds;

      // 跳过空行（保持翻译对齐）
      if (curr.content.trim().isEmpty) {
        continue;
      }

      while (transIdx < transLines.length) {
        final te = transLines[transIdx];
        final transStart = te.start.inMilliseconds;

        // 翻译行太早，跳过
        if (transStart < curr.start.inMilliseconds - tolerance) {
          transIdx++;
          continue;
        }

        // 翻译行已经进入下一行范围，停止匹配
        if (transStart > currEnd + tolerance) {
          break;
        }

        // 命中时间窗口
        final transContent = te.content.trim();
        if (transContent.isNotEmpty && transContent != '//') {
          curr.translation = transContent;
        }
        transIdx++;
        break;
      }
    }

    return main;
  }

  static ParsedLyricResult _mergeRomanizationText(
    ParsedLyricResult main,
    String? romaText,
  ) {
    if (romaText == null || romaText.isEmpty) return main;

    final romaLines = _parseLrc(romaText);
    if (romaLines.isEmpty) return main;

    if (main.lines.length == romaLines.length) {
      for (int i = 0; i < main.lines.length; i++) {
        if (romaLines[i].content.trim().isNotEmpty) {
          main.lines[i].romanization = romaLines[i].content;
        }
      }
      return main;
    }

    const tolerance = 100;
    int romaIdx = 0;
    for (var i = 0; i < main.lines.length; i++) {
      final curr = main.lines[i];
      while (romaIdx < romaLines.length) {
        final re = romaLines[romaIdx];
        if (curr.start.inMilliseconds >= re.start.inMilliseconds - tolerance) {
          if (curr.start.inMilliseconds <= re.start.inMilliseconds + tolerance) {
            if (re.content.trim().isNotEmpty) {
              curr.romanization = re.content;
            }
          }
        } else {
          break;
        }
        romaIdx++;
      }
    }
    return main;
  }

  static ParsedLyricResult _insertBlankLines(ParsedLyricResult result) {
    if (result.lines.isEmpty) return result;

    final newLines = <LyricEntry>[result.lines.first];

    for (int i = 1; i < result.lines.length; i++) {
      final prev = newLines.last;
      final curr = result.lines[i];
      final gap = curr.start.inMilliseconds - prev.nextTime.inMilliseconds;

      if (gap > 5000) {
        final midStart = Duration(
          milliseconds: prev.nextTime.inMilliseconds + (gap ~/ 3),
        );
        final midEnd = Duration(
          milliseconds: curr.start.inMilliseconds - (gap ~/ 3),
        );
        newLines.add(LyricEntry(
          start: midStart,
          nextTime: midEnd,
          content: '',
        ));
      }
      newLines.add(curr);
    }

    return ParsedLyricResult(
      lines: newLines,
      format: result.format,
      offset: result.offset,
      tags: Map.from(result.tags),
    );
  }
}
