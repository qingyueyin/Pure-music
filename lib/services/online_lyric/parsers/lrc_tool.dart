import 'dart:isolate';

import 'package:pure_music/services/online_lyric/models/lyric_entry.dart';

/// 统一歌词解析工具
/// 综合 lrc/yrc/qrc/krc 解析器
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

  // 预编译格式检测正则（enhanced: <mm:ss.xxx> 逐字时间戳）
  static final _hasEnhancedTags = RegExp(r'<\d{2}:\d{2}\.\d{2,3}>');

  static LyricFormat _detectFormat(String lrcContent) {
    final lines = lrcContent.trim();
    // enhanced 检测：统计 <> 时间戳数量，>=5 个即视为逐字（enhanced）格式
    // 避免用 {3} 贪婪回溯——简单计数比复杂正则可靠
    if (_hasEnhancedTags.allMatches(lines).length >= 5) {
      return LyricFormat.enhanced;
    }
    if (RegExp(r'\[\d{2}:\d{2}\.\d{2,3}\].*\[\d{2}:\d{2}\.\d{2,3}\]').hasMatch(lines)) {
      return LyricFormat.wordByWord;
    }

    if (_karaOkLineRegex.hasMatch(lines)) {
      if (lines.contains('<')) {
        for (final m in _krcWordRegex.allMatches(lines)) {
          if (m.group(0)!.isNotEmpty) return LyricFormat.krc;
        }
      }
      if (lines.contains('(')) {
        for (final m in _yrcWordRegex.allMatches(lines)) {
          if (m.group(0)!.isNotEmpty) return LyricFormat.yrc;
        }
      }
      for (final m in _qrcWordRegex.allMatches(lines)) {
        if (m.group(0)!.isNotEmpty) return LyricFormat.qrc;
      }
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
      if (lyric.isEmpty || lyric == '//') continue;
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
          lineStartMs: format == LyricFormat.krc ? (int.tryParse(m.group(1)!) ?? 0) : 0);
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
    int lineStartMs = 0,
  }) {
    final words = <WordEntry>[];
    for (final m in wordRegex.allMatches(content)) {
      final curr = WordEntry(
        start: Duration(milliseconds: int.parse(m.group(startIdx)!) + lineStartMs),
        length: Duration(milliseconds: int.parse(m.group(durIdx)!)),
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

    // 酷狗等源的翻译是纯文本（无 LRC 时间戳），按行号对齐
    // 尝试解析 KRC/QRC/YRC 格式（如有些源的翻译/罗马音带时间戳）
    if (transLines.isEmpty) {
      final karaokeFormat = _detectFormat(transText);
      if (karaokeFormat == LyricFormat.qrc ||
          karaokeFormat == LyricFormat.krc ||
          karaokeFormat == LyricFormat.yrc) {
        final entries = _parseByFormat(transText, karaokeFormat);
        if (entries.isNotEmpty) {
          final plainText = entries.map((e) => e.content).join('\n');
          return _mergeTranslationText(main, plainText);
        }
      }
    }

    if (transLines.isEmpty) {
      final plainLines = transText
          .split('\n')
          .map((l) => l.trim())
          .toList();
      final nonEmptyLines = plainLines
          .where((l) => l.isNotEmpty && l != '//')
          .toList();
      if (nonEmptyLines.isEmpty) return main;

      if (main.lines.length == plainLines.length) {
        for (int i = 0; i < main.lines.length; i++) {
          if (plainLines[i].isNotEmpty && plainLines[i] != '//') {
            main.lines[i].translation = plainLines[i];
          }
        }
        return main;
      }

      int plainIdx = 0;
      for (var i = 0; i < main.lines.length && plainIdx < plainLines.length; i++) {
        if (main.lines[i].content.trim().isNotEmpty) {
          while (plainIdx < plainLines.length &&
              (plainLines[plainIdx].isEmpty || plainLines[plainIdx] == '//')) {
            plainIdx++;
          }
          if (plainIdx < plainLines.length) {
            main.lines[i].translation = plainLines[plainIdx++];
          }
        }
      }
      return main;
    }

    if (main.lines.isEmpty || transLines.isEmpty) return main;

    // 最大容许的时间漂移（5秒）
    const double maxDrift = 5000.0;
    int lastMatchedMainIdx = -1;

    for (final te in transLines) {
      final transContent = te.content.trim();
      if (transContent.isEmpty || transContent == '//') continue;

      int minDiffIdx = -1;
      double minDiff = double.infinity;

      // 强制从上一次匹配成功的下一行开始找，防止覆盖数据
      int startIndex = lastMatchedMainIdx + 1;

      for (int i = startIndex; i < main.lines.length; i++) {
        final currMain = main.lines[i];
        if (currMain.content.trim().isEmpty) continue;

        // 计算当前原文和这句翻译的时间差
        final double diff = (currMain.start.inMilliseconds - te.start.inMilliseconds).abs().toDouble();

        if (diff < minDiff) {
          minDiff = diff;
          minDiffIdx = i;
        } else if (diff > minDiff) {
          // 由于时间戳是递增的，当时间差开始变大时，说明已经越过了最小时间差，直接停止查找
          break;
        }
      }

      // 若找到了最近的行，并且误差在合理范围内，则进行赋值
      if (minDiffIdx != -1 && minDiff <= maxDrift) {
        main.lines[minDiffIdx].translation = transContent;
        // 推进游标，下一句翻译只能找 minDiffIdx 之后的行
        lastMatchedMainIdx = minDiffIdx;
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

    // 尝试解析 KRC/QRC/YRC 格式（如 QQ 源的罗马音）
    if (romaLines.isEmpty) {
      final karaokeFormat = _detectFormat(romaText);
      if (karaokeFormat == LyricFormat.qrc ||
          karaokeFormat == LyricFormat.krc ||
          karaokeFormat == LyricFormat.yrc) {
        final entries = _parseByFormat(romaText, karaokeFormat);
        if (entries.isNotEmpty) {
          final plainText = entries.map((e) => e.content).join('\n');
          return _mergeRomanizationText(main, plainText);
        }
      }
    }

    if (romaLines.isEmpty) {
      final plainLines = romaText
          .split('\n')
          .map((l) => l.trim())
          .toList();
      final nonEmptyLines = plainLines
          .where((l) => l.isNotEmpty && l != '//')
          .toList();
      if (nonEmptyLines.isEmpty) return main;

      if (main.lines.length == plainLines.length) {
        for (int i = 0; i < main.lines.length; i++) {
          if (plainLines[i].isNotEmpty && plainLines[i] != '//') {
            main.lines[i].romanization = plainLines[i];
          }
        }
        return main;
      }

      int plainIdx = 0;
      for (var i = 0; i < main.lines.length && plainIdx < plainLines.length; i++) {
        if (main.lines[i].content.trim().isNotEmpty) {
          while (plainIdx < plainLines.length &&
              (plainLines[plainIdx].isEmpty || plainLines[plainIdx] == '//')) {
            plainIdx++;
          }
          if (plainIdx < plainLines.length) {
            main.lines[i].romanization = plainLines[plainIdx++];
          }
        }
      }
      return main;
    }

    if (main.lines.isEmpty || romaLines.isEmpty) return main;

    const double maxDrift = 5000.0;
    int lastMatchedMainIdx = -1;

    for (final romaLine in romaLines) {
      final romaContent = romaLine.content.trim();
      if (romaContent.isEmpty) continue;

      int minDiffIdx = -1;
      double minDiff = double.infinity;

      int startIndex = lastMatchedMainIdx + 1;

      for (int i = startIndex; i < main.lines.length; i++) {
        final currMain = main.lines[i];
        if (currMain.content.trim().isEmpty) continue;

        final double diff =
            (currMain.start.inMilliseconds - romaLine.start.inMilliseconds)
                .abs()
                .toDouble();

        if (diff < minDiff) {
          minDiff = diff;
          minDiffIdx = i;
        } else if (diff > minDiff) {
          break;
        }
      }

      if (minDiffIdx != -1 && minDiff <= maxDrift) {
        main.lines[minDiffIdx].romanization = romaContent;
        lastMatchedMainIdx = minDiffIdx;
      }
    }
    return main;
  }

  static ParsedLyricResult _insertBlankLines(ParsedLyricResult result) {
    if (result.lines.isEmpty) return result;

    final newLines = <LyricEntry>[];

    // ── 前奏空白行（第一句歌词开始前有时长）──
    if (result.lines.first.start > const Duration(seconds: 3)) {
      newLines.add(LyricEntry(
        start: Duration.zero,
        nextTime: result.lines.first.start,
        content: '',
      ));
    }
    newLines.add(result.lines.first);

    // ── 间奏空白行（行与行之间的间隙）──
    for (int i = 1; i < result.lines.length; i++) {
      final prev = newLines.last;
      final curr = result.lines[i];

      final prevEndMs = _actualLineEndMs(prev);
      final gap = curr.start.inMilliseconds - prevEndMs;

      if (gap > 5000) {
        final blankStart = Duration(milliseconds: prevEndMs);
        final blankDuration = Duration(milliseconds: gap);
        newLines.add(LyricEntry(
          start: blankStart,
          nextTime: blankStart + blankDuration,
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

  /// 计算一行歌词的实际结束时间（基于逐字时间戳）
  static int _actualLineEndMs(LyricEntry entry) {
    if (entry.words != null && entry.words!.isNotEmpty) {
      final last = entry.words!.last;
      return last.start.inMilliseconds + last.length.inMilliseconds;
    }
    // 无逐字数据：用 start + 估计时长 3500ms
    return entry.start.inMilliseconds + 3500;
  }
}

Future<ParsedLyricResult?> parseLyricInIsolate({
  required String text,
  String? transText,
  String? romanizationText,
}) async {
  return Isolate.run(() {
    return LrcTool.parse(
      text,
      transText: transText,
      romanizationText: romanizationText,
    );
  });
}
