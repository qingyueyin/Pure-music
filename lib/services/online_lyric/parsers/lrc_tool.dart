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

  /// 时间窗口对齐：翻译行 → 原文行（标准 LRC 格式；KRC/QRC/YRC 走 _mergeTimedSubtitle）。
  static ParsedLyricResult _mergeTranslationText(
    ParsedLyricResult main, String? transText) {
    if (transText == null || transText.isEmpty) return main;
    final transLines = _parseLrc(transText);
    if (transLines.isEmpty) {
      final karaokeFormat = _detectFormat(transText);
      if (karaokeFormat == LyricFormat.qrc || karaokeFormat == LyricFormat.krc || karaokeFormat == LyricFormat.yrc) {
        final entries = _parseByFormat(transText, karaokeFormat);
        if (entries.isNotEmpty) {
          // 过滤翻译里的元数据行，保留时间戳做时间窗口匹配
          final nonMeta = entries.where((e) {
            final t = e.content.trim();
            return t.isNotEmpty && !_isLyricMetadata(t);
          }).toList();
          if (nonMeta.isNotEmpty) {
            return _mergeTimedSubtitle(main, nonMeta, isRomanization: false);
          }
        }
      }
      return _mergePlainText(main, transText, isRomanization: false);
    }
    return _mergeTimedSubtitle(main, transLines, isRomanization: false);
  }

  /// 时间窗口对齐：罗马音行 → 原文行（标准 LRC 格式；KRC/QRC/YRC 走 _mergeTimedSubtitle）。
  static ParsedLyricResult _mergeRomanizationText(
    ParsedLyricResult main, String? romaText) {
    if (romaText == null || romaText.isEmpty) return main;
    final romaLines = _parseLrc(romaText);
    if (romaLines.isEmpty) {
      final karaokeFormat = _detectFormat(romaText);
      if (karaokeFormat == LyricFormat.qrc || karaokeFormat == LyricFormat.krc || karaokeFormat == LyricFormat.yrc) {
        final entries = _parseByFormat(romaText, karaokeFormat);
        if (entries.isNotEmpty) {
          // 过滤罗马音里的元数据行（歌曲信息/版权声明）
          final nonMeta = entries.where((e) {
            final t = e.content.trim();
            return t.isNotEmpty && !_isLyricMetadata(t);
          }).toList();
          if (nonMeta.isNotEmpty) {
            return _mergeTimedSubtitle(main, nonMeta, isRomanization: true);
          }
        }
      }
      return _mergePlainText(main, romaText, isRomanization: true);
    }
    return _mergeTimedSubtitle(main, romaLines, isRomanization: true);
  }

  /// 时间窗口匹配核心算法。
  /// 原文、翻译、罗马音的行时间戳完全一致时，此算法可正确对齐。
  static ParsedLyricResult _mergeTimedSubtitle(
    ParsedLyricResult main, List<LyricEntry> subLines, {required bool isRomanization}) {
    if (main.lines.isEmpty || subLines.isEmpty) return main;

    final sorted = subLines
        .where((e) => e.content.trim().isNotEmpty && e.content.trim() != '//')
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    if (sorted.isEmpty) return main;

    const leadToleranceMs = 500;
    int subIdx = 0;

    for (int i = 0; i < main.lines.length; i++) {
      // 跳过主元数据行（词/曲/歌曲名等），避免它们的时间窗口捕获正常歌词
      if (_isLyricMetadata(main.lines[i].content.trim())) continue;
      final winStart = main.lines[i].start.inMilliseconds;
      final winEnd = i + 1 < main.lines.length
          ? main.lines[i + 1].start.inMilliseconds
          : 0x7FFFFFFFFFFFF;

      String? matched;
      while (subIdx < sorted.length) {
        final sub = sorted[subIdx];
        final subMs = sub.start.inMilliseconds;
        if (subMs < winStart - leadToleranceMs) { subIdx++; continue; }
        if (subMs >= winEnd) break;
        matched = sub.content.trim();
        // 仅在翻译时间戳早于下一行时才消耗条目（允许多个逐词 QRC 行共享同一条 LRC 翻译）
        if (i + 1 < main.lines.length) {
          final nextWinStart = main.lines[i + 1].start.inMilliseconds;
          if (subMs < nextWinStart - leadToleranceMs) { subIdx++; }
        } else {
          subIdx++;
        }
        break;
      }

      if (matched != null) {
        if (isRomanization) {
          main.lines[i].romanization = matched;
        } else {
          main.lines[i].translation = matched;
        }
      }
    }
    return main;
  }

  /// 纯文本回退：两边各自过滤（主行去元数据，翻译去空行），然后按索引匹配。
  static ParsedLyricResult _mergePlainText(
    ParsedLyricResult main, String plainText, {required bool isRomanization}) {
    final plainLines = plainText.split('\n').map((l) => l.trim()).toList();
    if (plainLines.isEmpty) return main;
    // 翻译侧过滤空行/元数据
    final subLines = plainLines.where((l) => l.isNotEmpty && l != '//' && !_isLyricMetadata(l)).toList();
    if (subLines.isEmpty) return main;

    int subIdx = 0;
    for (int i = 0; i < main.lines.length && subIdx < subLines.length; i++) {
      final mainText = main.lines[i].content.trim();
      // 跳过主行空行和元数据行（不消耗翻译行）
      if (mainText.isEmpty || _isLyricMetadata(mainText)) continue;
      final t = subLines[subIdx];
      if (t.isNotEmpty) {
        if (isRomanization) { main.lines[i].romanization = t; }
        else { main.lines[i].translation = t; }
      }
      subIdx++;
    }
    return main;
  }

  /// 简单判断一行文本是否为歌词元数据（词/曲/版权/歌曲名等）。
  static bool _isLyricMetadata(String text) {
    final t = text.replaceAll(RegExp(r'<[^>]*>'), '').trim();
    if (t.isEmpty) return false;
    // 中文/日文冒号
    if (RegExp(r'[：:]').hasMatch(t)) return true;
    // 横线分隔符（歌名 - 歌手、标题-艺术家），仅短文本判为元数据避免误伤歌词
    if (t.length < 60 && RegExp(r'[\-\u2013\u2014\uff0d]').hasMatch(t)) return true;
    // 版权/来源关键词
    if (RegExp(r'(?:QQ音乐|享有|着作权|著作权|版权|提供|出品|发行|翻译|翻訳)').hasMatch(t)) return true;
    // CJK 前缀 + 冒号（词/曲/编）
    if (RegExp(r'^[\u4e00-\u9fff]{1,2}[:：]').hasMatch(t)) return true;
    return false;
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
