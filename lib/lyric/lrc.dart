import 'dart:math';

import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/ttml.dart';
import 'package:pure_music/lyric/lyric_format.dart';
import 'package:pure_music/lyric/metadata_detector.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';

/// 智能清理空白行：
/// 1. 移除连续的空白行（只保留第一个）
/// 2. 移除时间间隔小于 800ms 的空白行（太短无意义）
/// 3. 间奏空白行全部保留（5s+ 需要显示 LyricTransitionTile）
void cleanLyricBlankLines(List<LyricLine> lines) {
  if (lines.isEmpty) return;

  final cleaned = <LyricLine>[];

  for (final line in lines) {
    final isBlankLine = _isBlankLine(line);

    if (isBlankLine) {
      if (cleaned.isNotEmpty) {
        final prev = cleaned.last;
        if (_isBlankLine(prev)) continue;
      }
    }

    cleaned.add(line);
  }

  // 使用逐个 add 替代 addAll：addAll 在运行时检查整个 Iterable 的类型，
  // 而 add 只检查单个元素，每个元素原就来自 lines，类型必然匹配
  lines.clear();
  for (final line in cleaned) {
    lines.add(line);
  }
}

bool _isBlankLine(LyricLine line) {
  if (line is LrcLine) return line.isBlank;
  if (line is SyncLyricLine) return line.words.isEmpty;
  return false;
}

class EnhancedLrc extends Lyric {
  EnhancedLrc(super.lines, super.source, [super.rawText]);

  @override
  String toString() {
    return {'type': source, 'lyric': lines}.toString();
  }
}

class EnhancedLrcLine extends SyncLyricLine {
  EnhancedLrcLine(
    super.start,
    super.length,
    super.words, [
    super.translation,
    super.romanLyric,
  ]);
}

class _EnhancedLrcRawLine {
  final Duration start;
  final String content;
  _EnhancedLrcRawLine(this.start, this.content);
}

class EnhancedLrcWord extends SyncLyricWord {
  EnhancedLrcWord(super.start, super.length, super.content);
}

class LrcLine extends UnsyncLyricLine {
  bool isBlank;
  bool isMetadata;

  LrcLine(
    super.start,
    super.content, {
    required bool requiredIsBlank,
    this.isMetadata = false,
    super.translation,
    super.length,
  }) : isBlank = requiredIsBlank;

  static LrcLine defaultLine = LrcLine(
    Duration.zero,
    '无歌词',
    requiredIsBlank: false,
  );

  @override
  String toString() {
    return {'time': start.toString(), 'content': content}.toString();
  }

  static bool isLyricMetadataLine(String text) {
    return isLyricMetadataText(text);
  }

  /// line: [mm:ss.msmsms]content
  static LrcLine? fromLine(String line, [int? offset]) {
    if (line.trim().isEmpty) {
      return null;
    }

    final left = line.indexOf('[');
    final right = line.indexOf(']');

    if (left == -1 || right == -1) {
      return null;
    }

    var lrcTimeString = line.substring(left + 1, right);

    // replace [mm:ss.msms...] with ""
    var content = line
        .substring(right + 1)
        .trim()
        .replaceAll(RegExp(r'\[\d{2}:\d{2}\.\d{2,}\]'), '');

    var timeList = lrcTimeString.split(':');
    int? minute;
    double? second;
    if (timeList.length >= 2) {
      minute = int.tryParse(timeList[0]);
      second = double.tryParse(timeList[1]);
    }

    if (minute == null || second == null) {
      return null;
    }

    var inMilliseconds = ((minute * 60 + second) * 1000).toInt();

    final isMetadata = content.isNotEmpty && isLyricMetadataLine(content);

    return LrcLine(
      Duration(milliseconds: max(inMilliseconds - (offset ?? 0), 0)),
      content,
      requiredIsBlank: content.isEmpty,
      isMetadata: isMetadata,
    );
  }
}

class Lrc extends Lyric {
  Lrc(super.lines, super.source, [super.rawText]);

  static const _strongEnglishIndicators = {
    'the', 'a', 'an',
    'you', 'he', 'she', 'it', 'we', 'they',
    'me', 'him', 'her', 'us', 'them',
    'my', 'your', 'his', 'its', 'our', 'their',
    'mine', 'yours', 'hers', 'ours', 'theirs',
    'myself', 'yourself', 'himself', 'herself', 'itself',
    'ourselves', 'yourselves', 'themselves',
    'this', 'that', 'these', 'those',
    'am', 'is', 'are', 'was', 'were', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'done',
    'can', 'could', 'will', 'would', 'shall', 'should',
    'may', 'might', 'must', 'need',
    'of', 'in', 'on', 'at', 'to', 'for', 'with', 'by', 'from', 'into',
    'about', 'above', 'across', 'after', 'against', 'along', 'among',
    'around', 'before', 'behind', 'below', 'beneath', 'beside', 'between',
    'beyond', 'down', 'during', 'except', 'inside', 'near', 'off',
    'out', 'outside', 'over', 'through', 'throughout', 'toward', 'under',
    'underneath', 'until', 'up', 'upon', 'within', 'without',
    'and', 'or', 'but', 'so', 'because', 'while', 'when', 'if',
    'though', 'although', 'since', 'unless',
    "don't", "doesn't", "didn't", "won't", "can't", "couldn't",
    "shouldn't", "mustn't", "isn't", "aren't", "wasn't", "weren't",
    "i'm", "you're", "he's", "she's", "it's", "we're", "they're",
    "i've", "you've", "we've", "they've",
    "i'll", "you'll", "he'll", "she'll", "we'll", "they'll",
    "let's", "that's", "there's", "here's", "who's", "what's",
    "how's", "where's", "why's",
    "i'd", "you'd", "he'd", "she'd", "we'd", "they'd",
    'gonna', 'gotta', 'wanna', "ain't", 'gimme', 'lemme',
    'kinda', 'sorta', 'outta', 'lotsa',
    'who', 'what', 'where', 'why', 'how',
    'which', 'whose', 'whom',
    'not', 'just', 'now', 'then', 'here', 'there',
    'always', 'never', 'sometimes', 'often', 'usually',
    'really', 'quite', 'already', 'still', 'yet',
    'even', 'only', 'also', 'again', 'ever',
  };

  @override
  String toString() {
    return {'type': source, 'lyric': lines}.toString();
  }

  /// 歌词一般是有序的
  /// 按照时间升序排序，保留原文和译文的顺序，需要使用稳定的排序算法
  /// 这里使用插入排序
  void _sort() {
    for (int i = 1; i < lines.length; i++) {
      var temp = lines[i];
      int j;
      for (j = i; j > 0 && lines[j - 1].start > temp.start; j--) {
        lines[j] = lines[j - 1];
      }
      lines[j] = temp;
    }
  }

  /// 智能合并相同时间戳的歌词行
  /// 支持：原文、翻译、注音（罗马音）的自动识别和分组
  ///
  /// 判断优先级：
  /// 1. 有逐词时间戳标签（<mm:ss.xx>）→ 原文
  /// 2. 假名 / 西里尔压过纯汉字
  /// 3. 注音（拼音/罗马音）不当原文
  /// 4. 其余按行序：第一行非注音是原文，其余按内容进翻译或罗马音
  Lrc _combineLrcLine(String separator, {required bool keepMetadata}) {
    final grouped = <Duration, List<LyricLine>>{};
    for (final line in lines) {
      grouped.putIfAbsent(line.start, () => []).add(line);
    }

    const kOriginal = 0;
    const kTranslation = 1;
    const kRomanization = 2;
    final sampleRoles = <int, List<Map<int, int>>>{};
    for (final group in grouped.values) {
      final validLines = group
          .whereType<LrcLine>()
          .where((line) => !line.isMetadata)
          .toList();
      if (validLines.length < 2) continue;
      final confident = validLines.any(
        (line) =>
            _hasWordTimestamps(line.content) ||
            _hasKana(line.content) ||
            _hasCyrillic(line.content),
      );
      if (!confident) continue;
      final primary = _selectPrimaryLine(validLines);
      final posRole = <int, int>{};
      for (int i = 0; i < validLines.length; i++) {
        if (identical(validLines[i], primary)) {
          posRole[i] = kOriginal;
          continue;
        }
        final text = _stripTags(validLines[i].content);
        posRole[i] = _isAnnotationTrack(primary.content, text)
            ? kRomanization
            : kTranslation;
      }
      sampleRoles.putIfAbsent(validLines.length, () => []).add(posRole);
    }
    final roleMap = <int, Map<int, int>>{};
    sampleRoles.forEach((size, list) {
      final posCounts = <int, Map<int, int>>{};
      for (final pr in list) {
        pr.forEach((pos, role) {
          posCounts
              .putIfAbsent(pos, () => {})
              .update(role, (v) => v + 1, ifAbsent: () => 1);
        });
      }
      final map = <int, int>{};
      posCounts.forEach((pos, counts) {
        int bestRole = kOriginal;
        int best = 0;
        counts.forEach((role, c) {
          if (c > best) {
            best = c;
            bestRole = role;
          }
        });
        map[pos] = bestRole;
      });
      roleMap[size] = map;
    });

    final combinedLines = <LrcLine>[];

    for (final entry in grouped.entries) {
      final group = entry.value;
      final metadataLines = group
          .whereType<LrcLine>()
          .where((line) => line.isMetadata)
          .toList();
      final validLines = group
          .whereType<LrcLine>()
          .where((l) => !l.isMetadata)
          .toList();
      if (keepMetadata) combinedLines.addAll(metadataLines);
      if (validLines.isEmpty) continue;
      if (validLines.length == 1) {
        combinedLines.add(validLines[0]);
        continue;
      }
      int? learnedPrimary;
      final learned = roleMap[validLines.length];
      if (learned != null) {
        learned.forEach((pos, role) {
          if (role == kOriginal) learnedPrimary = pos;
        });
      }
      combinedLines.add(
        _combineGroup(validLines, separator, learnedPrimary: learnedPrimary),
      );
    }

    return Lrc(combinedLines, source);
  }

  /// 判断文本是否包含逐词时间戳标签
  bool _hasWordTimestamps(String text) {
    return RegExp(r'<\d+:\d{2}(?:\.\d+)>').hasMatch(text) ||
        RegExp(
          r'<\d+>[\u4e00-\u9fff\u3040-\u309f\u30a0-\u30ff\u1100-\u11ff\u3130-\u318f\uac00-\ud7af\u0400-\u04ff]',
        ).hasMatch(text);
  }

  LrcLine _combineGroup(
    List<LrcLine> lines,
    String separator, {
    int? learnedPrimary,
  }) {
    final primary = _selectPrimaryLine(lines, learnedPrimary: learnedPrimary);
    _assignNonPrimary(
      primary,
      lines.where((line) => !identical(line, primary)),
      separator,
    );
    return primary;
  }

  /// 同时间多行里选原文：逐字时间戳优先；假名/西里尔压过纯汉字；
  /// 注音不当原文；韩文对汉字跟行序，避免把中文原文抢走。
  LrcLine _selectPrimaryLine(List<LrcLine> group, {int? learnedPrimary}) {
    LrcLine? tagged;
    LrcLine? kana;
    LrcLine? cyrillic;
    LrcLine? hangul;
    LrcLine? firstNonRoman;
    for (final line in group) {
      if (tagged == null && _hasWordTimestamps(line.content)) tagged = line;
      if (kana == null && _hasKana(line.content)) kana = line;
      if (cyrillic == null && _hasCyrillic(line.content)) cyrillic = line;
      if (hangul == null && _hasHangul(line.content)) hangul = line;
      if (firstNonRoman == null && !_isRomanization(line.content)) {
        firstNonRoman = line;
      }
    }
    final selected = tagged ?? kana ?? cyrillic;
    if (selected != null) return selected;
    // 韩文对纯拉丁固定原文；对汉字跟行序，避免抢走中文原文。
    if (hangul != null &&
        !group.any(
          (line) =>
              _hasHanzi(line.content) &&
              !_hasHangul(line.content) &&
              !_hasKana(line.content),
        )) {
      return hangul;
    }
    if (learnedPrimary != null &&
        learnedPrimary >= 0 &&
        learnedPrimary < group.length &&
        !_isRomanization(group[learnedPrimary].content)) {
      return group[learnedPrimary];
    }
    return firstNonRoman ?? group.first;
  }

  void _assignNonPrimary(
    LrcLine primary,
    Iterable<LrcLine> others,
    String separator,
  ) {
    final romanParts = <String>[];
    final transParts = <String>[];
    for (final line in others) {
      final extracted = _extractTranslation(line.content, separator);
      final part = _stripTags(
        (extracted != null && extracted.isNotEmpty) ? extracted : line.content,
      ).trim();
      if (part.isEmpty) continue;
      if (_isAnnotationTrack(primary.content, part)) {
        romanParts.add(part);
      } else {
        transParts.add(part);
      }
    }
    if (romanParts.isNotEmpty) {
      primary.romanLyric = romanParts.join(' ');
    }
    if (transParts.isNotEmpty) {
      primary.translation = transParts.join(separator);
    }
  }

  static bool _hasKana(String text) {
    return RegExp(r'[぀-ゟ゠-ヿ]').hasMatch(text);
  }

  static bool _hasCyrillic(String text) {
    return RegExp(r'[Ѐ-ӿ]').hasMatch(text);
  }

  static bool _hasHangul(String text) {
    return RegExp(r'[ᄀ-ᇿ㄰-㆏가-힯]').hasMatch(text);
  }

  static bool _hasHanzi(String text) {
    return RegExp(r'[一-鿿]').hasMatch(text);
  }

  /// 注音进罗马音轨；亚洲/西里尔原文后的拉丁默认也是注音，
  /// 明显英文歌词除外，避免中文原文的英译被当成拼音。
  static bool _isAnnotationTrack(String primaryText, String part) {
    if (_isRomanizationStatic(part)) return true;
    if ((_hasAsianChars(primaryText) || _hasCyrillic(primaryText)) &&
        !_hasAsianChars(part) &&
        !_hasCyrillic(part)) {
      return !_hasEnglishLyricSignals(part);
    }
    return false;
  }

  static bool _hasEnglishLyricSignals(String text) {
    final stripped = text.replaceAll(RegExp(r'<[^>]*>'), '').trim();
    if (stripped.isEmpty) return false;
    if (stripped.contains('&')) return true;
    if (stripped.contains(' - ') || stripped.contains(' — ')) return true;
    if (RegExp(r'[.,;!?]').hasMatch(stripped)) return true;
    if (stripped.contains("'")) return true;
    if (RegExp(
      r'[bcdfghjklmnpqrstvwxyz]{3,}',
    ).hasMatch(stripped.toLowerCase())) {
      return true;
    }
    if (RegExp(
      r'\b[a-z]+(ing|ed|ly|tion|sion|ment|ness|ful|ous|able|ible|ture|ize|ise)\b',
      caseSensitive: false,
    ).hasMatch(stripped)) {
      return true;
    }
    final words = stripped
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    for (final w in words) {
      final clean = w.toLowerCase().replaceAll(RegExp(r"[^a-z']"), '');
      if (clean.length <= 1) continue;
      if (_strongEnglishIndicators.contains(clean)) return true;
    }
    for (final w in words) {
      final alpha = w.replaceAll(RegExp(r'[^a-zA-Z]'), '');
      if (alpha.length > 7) return true;
    }
    return false;
  }

  /// 判断文本是否为罗马音（注音）
  ///
  /// 判断逻辑：
  /// 1. 纯拉丁字母（无 CJK、无假名）→ 罗马音
  /// 2. 假名 + 少量拉丁字母 → 日文原文（非罗马音）
  /// 3. 假名为主 → 日文原文（非罗马音）
  /// 4. 混合文本：假名占比 > 拉丁字母 → 原文
  bool _isRomanization(String text) {
    return _isRomanizationStatic(text);
  }

  /// 检测文本是否含东方文字（CJK 汉字 / 日文假名 / 韩文 Hangul）
  /// 用于统一判断「这行是不是亚洲语言原文/翻译」
  static bool _hasAsianChars(String text) => RegExp(
    r'[\u4e00-\u9fff\u3040-\u309f\u30a0-\u30ff\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]',
  ).hasMatch(text);

  /// 在同一时间戳的歌词行组中，智能选择最佳的主歌词行（原文）。
  ///
  /// 优先级（从高到低）：
  ///   100 = 假名/韩文/西里尔/汉字 + 逐字时间戳
  ///    80 = 拉丁歌词 + 逐字（非注音）
  ///    55 = 假名或西里尔，无逐字（压过纯汉字翻译）
  ///    40 = 汉字 / 韩文 / 拉丁歌词，无逐字（同分跟行序）
  ///    20 = 注音 + 逐字
  ///    10 = 其余
  static int _bestPrimaryIndex(List<SyncLyricLine> group) {
    if (group.length <= 1) return 0;

    int bestIdx = 0;
    int bestPriority = -1;

    for (int i = 0; i < group.length; i++) {
      final text = group[i].words.map((w) => w.content).join();
      final hasWordTs = group[i].words.length > 1;
      final isRoman = _isRomanizationStatic(text);
      final hasKana = _hasKana(text);
      final hasCyrillic = _hasCyrillic(text);
      final hasAsian = _hasAsianChars(text);

      int priority;
      if (hasWordTs && (hasAsian || hasCyrillic) && !isRoman) {
        priority = 100;
      } else if (hasWordTs && !isRoman) {
        priority = 80;
      } else if (hasKana || hasCyrillic) {
        priority = 55;
      } else if (hasWordTs && isRoman) {
        priority = 20;
      } else if (hasAsian || !isRoman) {
        // 汉字 / 韩文 / 英文歌词同分，跟行序，避免中文翻译抢走英文原文。
        priority = 40;
      } else {
        priority = 10;
      }

      if (priority > bestPriority) {
        bestPriority = priority;
        bestIdx = i;
      }
    }

    return bestIdx;
  }

  /// 静态版本的罗马音判断（用于静态方法）
  ///
  /// 判断逻辑：
  /// 1. 纯拉丁字母（无 CJK、无假名）→ 可能是罗马音
  /// 2. 有假名或汉字 → 不是罗马音
  /// 3. 有英文语法词（介词、冠词等）→ 不是罗马音（是英文歌词）
  /// 4. 有英文标点、缩写 → 不是罗马音
  static bool _isRomanizationStatic(String text) {
    final stripped = text.replaceAll(RegExp(r'<[^>]*>'), '').trim();
    if (stripped.isEmpty) return false;

    final cjkCount = RegExp(r'[\u4e00-\u9fff]').allMatches(stripped).length;
    final hiraganaCount = RegExp(
      r'[\u3040-\u309f]',
    ).allMatches(stripped).length;
    final katakanaCount = RegExp(
      r'[\u30a0-\u30ff]',
    ).allMatches(stripped).length;
    final hangulCount = RegExp(
      r'[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]',
    ).allMatches(stripped).length;
    final kanaCount = hiraganaCount + katakanaCount;
    final alphaCount = RegExp(r'[a-zA-Z]').allMatches(stripped).length;

    if (alphaCount == 0) return false;

    // 有假名、汉字或韩文 → 不是罗马音
    if (cjkCount > 0 || kanaCount > 0 || hangulCount > 0) return false;

    // 带调号的拼音/粤拼（wo3 / ngo5）按注音处理，跳过英文启发式。
    if (RegExp(r'[a-zA-Z]+[1-6]').hasMatch(stripped)) return true;

    // 纯英文文本的排除规则
    if (stripped.contains('&')) return false;
    if (stripped.contains(' - ') || stripped.contains(' — ')) return false;
    if (RegExp(r'[.,;!?]').hasMatch(stripped)) return false;
    if (stripped.contains("'")) return false;

    final words = stripped
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return false;

    final lowerWords = words.map((w) => w.toLowerCase()).toList();
    int indicatorCount = 0;
    for (final w in lowerWords) {
      final clean = w.replaceAll(RegExp(r"[^a-z']"), '');
      // 单字母是日/韩罗马音常见音节，不当英文指示词。
      if (clean.length <= 1) continue;
      if (_strongEnglishIndicators.contains(clean)) indicatorCount++;
    }

    // 有强英文指示词 → 不是罗马音
    if (indicatorCount >= 1) return false;

    // 多单词时按平均词长判断。
    // 日/韩罗马音、拼音多是短音节，韩文罗马音平均可到 3.5（sa rang hae neo reul）。
    // 英文歌词平均词长通常更长，且多半已被指示词拦截。
    if (words.length >= 5) {
      final totalLetters = words.fold<int>(
        0,
        (sum, w) => sum + w.replaceAll(RegExp(r'[^a-zA-Z]'), '').length,
      );
      final avgLen = totalLetters / words.length;
      if (avgLen > 4.0) return false;
    }

    // 检测 3+ 连续辅音 → 不可能是罗马音
    // 罗马音几乎没有连续 3 个辅音的情况
    // 英文: "world"(rld), "night"(ght), "strong"(str)
    if (RegExp(
      r'[bcdfghjklmnpqrstvwxyz]{3,}',
    ).hasMatch(stripped.toLowerCase())) {
      return false;
    }

    // 检测英文常见后缀 → 不可能是罗马音
    if (RegExp(
      r'\b[a-z]+(ing|ed|ly|tion|sion|ment|ness|ful|ous|able|ible|ture|ize|ise)\b',
      caseSensitive: false,
    ).hasMatch(stripped)) {
      return false;
    }

    // 检测全大写单词（标题/歌名特征）
    final upperWords = words.where((w) {
      final alpha = w.replaceAll(RegExp(r'[^a-zA-Z]'), '');
      return alpha.length > 1 && alpha == alpha.toUpperCase();
    }).toList();

    if (upperWords.length >= 2) return false;

    // 单词长度分析
    int shortWordCount = 0;
    int longWordCount = 0;

    for (final w in words) {
      final cleanWord = w.replaceAll(RegExp(r'[^a-zA-Z]'), '');
      if (cleanWord.length <= 5) shortWordCount++;
      if (cleanWord.length > 7) longWordCount++;
    }

    // 有长单词 → 不是罗马音（英文歌词）
    // 罗马音中的单词几乎都是短音节（通常 ≤5 个字母）
    if (longWordCount >= 1) return false;

    // 短词占多数 → 可能是罗马音
    return shortWordCount >= longWordCount;
  }

  /// 从内容中提取翻译部分（如果包含 separator）
  String? _extractTranslation(String content, String separator) {
    final parts = content.split(separator);
    if (parts.length > 1) {
      return parts.sublist(1).join(separator).trim();
    }
    return null;
  }

  /// 移除时间标签
  String _stripTags(String text) {
    return text.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }

  /// 如果separator为null，不合并歌词；否则，合并相同时间戳的歌词
  static Lrc? fromLrcText(
    String lrc,
    LyricFormat source, {
    String? separator,
    bool? keepMetadata,
  }) {
    final shouldKeepMetadata =
        keepMetadata ?? AppSettings.instance.keepLyricMetadata;
    var lrcLines = lrc.split('\n');

    int? offsetInMilliseconds;
    final offsetPattern = RegExp(r'\[\s*offset\s*:\s*([+-]?\d+)\s*\]');
    for (var line in lrcLines) {
      final matched = offsetPattern.firstMatch(line);
      if (matched == null) continue;
      offsetInMilliseconds = int.tryParse(matched.group(1) ?? '');
      break;
    }

    final metadataTagPattern = RegExp(r'^\[[a-zA-Z]+:');

    var lines = <LrcLine>[];
    for (int i = 0; i < lrcLines.length; i++) {
      var line = lrcLines[i].trim();
      if (line.isEmpty || line == '//') continue;

      // 过滤 LRC 标准 metadata 标签：[ti:xxx]、[ar:xxx]、[al:xxx]、[by:xxx]、[au:xxx]、[length:xxx] 等
      if (metadataTagPattern.hasMatch(line)) continue;

      // 过滤 XML/HTML 标签行
      if (line.startsWith('<') && line.contains('>')) continue;

      var lyricLine = LrcLine.fromLine(line, offsetInMilliseconds);
      if (lyricLine == null) {
        continue;
      }

      if (lyricLine.isMetadata && !shouldKeepMetadata) {
        continue;
      }

      lines.add(lyricLine);
    }

    if (lines.isEmpty) {
      return null;
    }

    for (var i = 0; i < lines.length; i++) {
      final currentLine = lines[i];
      final nextLine = i < lines.length - 1 ? lines[i + 1] : null;

      if (nextLine != null) {
        final timeGap = nextLine.start - currentLine.start;
        currentLine.length = timeGap;
      } else {
        currentLine.length = const Duration(milliseconds: 3500);
        for (int j = 0; j < i; j++) {
          if (lines[j].content == currentLine.content) {
            currentLine.length = lines[j].length;
            break;
          }
        }
      }
    }

    // 插入间奏空白行（开头前奏 + 中间间奏）
    final linesWithInterludes = <LrcLine>[];
    const gapThreshold = Duration(milliseconds: 5000);

    // 1. 开头前奏：从 0 到第一句真实歌词。
    // 元数据行已被过滤，它们所占的时间应该合并进前奏间奏里显示，
    // 而不是从元数据结束位置才开始插空白（否则空白太短会被 UI 忽略）。
    if (lines.isNotEmpty) {
      final firstRealStart = lines.first.start;
      const introStart = Duration.zero;

      // 如果第一句歌词不在 0 时刻，插入前奏空白行
      if (firstRealStart > introStart) {
        linesWithInterludes.add(
          LrcLine(introStart, '', requiredIsBlank: true)
            ..length = firstRealStart - introStart,
        );
      }
    }

    // 2. 中间间奏：遍历所有行，检测间隙并插入空白行
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      linesWithInterludes.add(line);

      if (i >= lines.length - 1) continue;
      final nextStart = lines[i + 1].start;
      final gapStart = line.start + line.length;
      final gapLen = nextStart - gapStart;

      // 间隙 ≥5s 时插入空白行
      if (gapLen >= gapThreshold) {
        linesWithInterludes.add(
          LrcLine(gapStart, '', requiredIsBlank: true)..length = gapLen,
        );
      }
    }

    lines = linesWithInterludes;

    final result = Lrc(lines, source);
    result._sort();

    if (separator == null) {
      result._removeBlankLines();
      return result;
    }

    final combined = result._combineLrcLine(
      separator,
      keepMetadata: shouldKeepMetadata,
    );
    combined._removeBlankLines();
    return combined;
  }

  static Lyric? fromLrcTextAuto(
    String lrc,
    LyricFormat source, {
    String? separator,
    bool? keepMetadata,
  }) {
    final shouldKeepMetadata =
        keepMetadata ?? AppSettings.instance.keepLyricMetadata;
    if (_isTtml(lrc)) {
      logger.i('[lrc] fromLrcTextAuto: TTML detected');
      return Ttml.fromTtmlText(lrc, separator: separator);
    }

    // 智能检测 LRC 子格式（逐字 / 增强 / 普通）
    final lrcFormat = detectLrcFormat(lrc);
    logger.i(
      '[lrc] fromLrcTextAuto: format=${lrcFormat.name} sep=${separator ?? 'null'}',
    );
    if (lrcFormat == LrcFormatType.wordByWord) {
      final rawLines = parseWordByWordLrc(lrc);
      if (rawLines.isNotEmpty) {
        // Group SyncLyricLine by start time and combine same-timestamp lines
        // (original + translation + roman at same timestamp = separate lines from parser)
        final grouped = <Duration, List<SyncLyricLine>>{};
        for (final line in rawLines) {
          grouped.putIfAbsent(line.start, () => []).add(line);
        }

        // 抽样学习「位置→角色」映射（原文/翻译/注音）
        // 同一首歌里分组结构稳定：从能确定角色的组（原文带逐字时间戳）取样，
        // 学出每个位置上是什么角色，再套用到无法确定角色的歧义组。
        const kOriginal = 0;
        const kTranslation = 1;
        const kRomanization = 2;
        final sampleRoles = <int, List<Map<int, int>>>{};
        for (final group in grouped.values) {
          if (group.length == 1) continue;
          final primaryIdx = _bestPrimaryIndex(group);
          // 只有原文是多词（带逐字时间戳）的组才算可靠样本
          if (group[primaryIdx].words.length <= 1) continue;
          final posRole = <int, int>{};
          for (int i = 0; i < group.length; i++) {
            if (i == primaryIdx) {
              posRole[i] = kOriginal;
              continue;
            }
            final text = group[i].words.map((w) => w.content).join().trim();
            final primaryText = group[primaryIdx].words
                .map((w) => w.content)
                .join();
            posRole[i] = _isAnnotationTrack(primaryText, text)
                ? kRomanization
                : kTranslation;
          }
          sampleRoles.putIfAbsent(group.length, () => []).add(posRole);
        }
        // 聚合多数，得到每个行数下的「位置→角色」映射
        final roleMap = <int, Map<int, int>>{};
        sampleRoles.forEach((size, list) {
          final posCounts = <int, Map<int, int>>{};
          for (final pr in list) {
            pr.forEach((pos, role) {
              posCounts
                  .putIfAbsent(pos, () => {})
                  .update(role, (v) => v + 1, ifAbsent: () => 1);
            });
          }
          final map = <int, int>{};
          posCounts.forEach((pos, counts) {
            int bestRole = kOriginal;
            int best = 0;
            counts.forEach((role, c) {
              if (c > best) {
                best = c;
                bestRole = role;
              }
            });
            map[pos] = bestRole;
          });
          roleMap[size] = map;
        });

        final combined = <SyncLyricLine>[];
        for (final entry in grouped.entries) {
          final group = entry.value;
          if (group.length == 1) {
            combined.add(group[0]);
            continue;
          }
          final primaryIdx = _bestPrimaryIndex(group);
          // 歧义组：整组都没有带逐字时间戳的原文（如单词原文 "Monday"），
          // 且已学到该行数的位置角色映射时，用抽样结果代替逐组判断。
          final hasConfidentOriginal = group.any((l) => l.words.length > 1);
          final useLearned =
              !hasConfidentOriginal && roleMap.containsKey(group.length);
          int primary = primaryIdx;
          if (useLearned) {
            final learned = roleMap[group.length]!;
            final found = learned.entries
                .firstWhere(
                  (e) => e.value == kOriginal,
                  orElse: () => const MapEntry(-1, -1),
                )
                .key;
            if (found != -1) primary = found;
          }
          final pri = group[primary];
          final romanParts = <String>[];
          final transParts = <String>[];
          for (int i = 0; i < group.length; i++) {
            if (i == primary) continue;
            final text = group[i].words.map((w) => w.content).join().trim();
            if (text.isEmpty) continue;
            // 使用抽样角色时按学到的位置判断翻译/注音；
            // 否则只把注音（拼音/罗马音）放进罗马音轨，英文歌词进翻译。
            final primaryText = pri.words.map((w) => w.content).join();
            final isRoman = useLearned
                ? roleMap[group.length]![i] == kRomanization
                : _isAnnotationTrack(primaryText, text);
            if (isRoman) {
              romanParts.add(text);
            } else {
              transParts.add(text);
            }
          }
          if (romanParts.isNotEmpty) {
            pri.romanLyric = romanParts.join(' ');
          }
          if (transParts.isNotEmpty) {
            pri.translation = transParts.join(separator ?? '\u2503');
          }
          combined.add(pri);
        }
        // 插入开头前奏和中间间奏空白行（与 enhanced/Lyricify 对齐）
        final withInterludes = _insertInterludesForWordByWord(combined);
        final result = Lyric(withInterludes, source);
        logger.i(
          '[lrc] fromLrcTextAuto: wordByWord combined -> ${combined.length} lines, after interludes -> ${withInterludes.length} lines',
        );
        for (
          int i = 0;
          i < (withInterludes.length > 3 ? 3 : withInterludes.length);
          i++
        ) {
          logger.i(
            '[lrc]   line[$i] start=${withInterludes[i].start.inMilliseconds}ms trans=${withInterludes[i].translation ?? 'null'} roman=${withInterludes[i].romanLyric ?? 'null'}',
          );
        }
        return result;
      }
    }

    final hasWordTags = RegExp(r'<(\d+:\d+\.\d+|\d+)>').hasMatch(lrc);
    logger.i('[lrc] fromLrcTextAuto: hasWordTags=$hasWordTags');
    if (!hasWordTags) {
      if (_isLyricifyFormat(lrc)) {
        logger.i('[lrc] fromLrcTextAuto: Lyricify format');
        return _parseLyricify(
          lrc,
          source,
          separator: separator,
          keepMetadata: shouldKeepMetadata,
        );
      }
      logger.i('[lrc] fromLrcTextAuto: standard LRC -> fromLrcText');
      final result = fromLrcText(
        lrc,
        source,
        separator: separator,
        keepMetadata: shouldKeepMetadata,
      );
      if (result != null) {
        logger.i('[lrc] fromLrcText result: ${result.lines.length} lines');
        for (
          int i = 0;
          i < (result.lines.length > 3 ? 3 : result.lines.length);
          i++
        ) {
          final l = result.lines[i];
          logger.i(
            '[lrc]   line[$i] start=${l.start.inMilliseconds}ms content="${l is LrcLine ? l.content : (l is SyncLyricLine ? l.words.map((w) => w.content).join() : (l is UnsyncLyricLine ? l.content : ''))}" trans=${l.translation ?? 'null'} roman=${l.romanLyric ?? 'null'}',
          );
        }
      }
      return result;
    }
    logger.i('[lrc] fromLrcTextAuto: enhanced LRC -> _parseEnhancedLrcText');
    final result = _parseEnhancedLrcText(
      lrc,
      source,
      separator: separator,
      keepMetadata: shouldKeepMetadata,
    );
    if (result != null) {
      logger.i('[lrc] enhanced result: ${result.lines.length} lines');
      for (
        int i = 0;
        i < (result.lines.length > 3 ? 3 : result.lines.length);
        i++
      ) {
        final l = result.lines[i];
        logger.i(
          '[lrc]   line[$i] start=${l.start.inMilliseconds}ms words=${l is SyncLyricLine ? l.words.length : 'N/A'} trans=${l.translation ?? 'null'} roman=${l.romanLyric ?? 'null'}',
        );
      }
    }
    return result;
  }

  /// 为 wordByWord 格式插入开头前奏和中间间奏空白行
  /// 逻辑与 _parseLyricify / _parseEnhancedLrcText 的间奏插入对齐
  static List<SyncLyricLine> _insertInterludesForWordByWord(
    List<SyncLyricLine> lines,
  ) {
    if (lines.isEmpty) return lines;

    final result = <SyncLyricLine>[];
    const gapThreshold = Duration(milliseconds: 5000);

    // 开头前奏：第一行前超过 5 秒则插入空白行
    final firstLine = lines.first;
    if (firstLine.start >= gapThreshold) {
      result.add(SyncLyricLine(Duration.zero, firstLine.start, []));
    }

    // 中间间奏：基于最后一个字的实际结束时间计算间隙
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      result.add(line);

      if (i >= lines.length - 1) continue;
      final nextStart = lines[i + 1].start;
      final gapStart = line.words.isNotEmpty
          ? line.words.last.start + line.words.last.length
          : line.start + const Duration(milliseconds: 3500);
      final gapLen = nextStart - gapStart;

      if (gapLen >= gapThreshold) {
        result.add(SyncLyricLine(gapStart, gapLen, []));
      }
    }

    return result;
  }

  static bool _isLyricifyFormat(String text) {
    return RegExp(r'\S.*?\(\d+,\d+\)').hasMatch(text);
  }

  /// Parse Lyricify format lyrics
  /// Format: word(startMs,durationMs)word2(start,duration) ...
  /// Attribute lines remain regular lyric rows; background vocals belong to TTML.
  static Lyric? _parseLyricify(
    String lrc,
    LyricFormat source, {
    String? separator,
    required bool keepMetadata,
  }) {
    final lrcLines = lrc.split('\n');

    int? offsetInMilliseconds;
    final offsetPattern = RegExp(r'\[\s*offset\s*:\s*([+-]?\d+)\s*\]');
    for (final line in lrcLines) {
      final matched = offsetPattern.firstMatch(line);
      if (matched == null) continue;
      offsetInMilliseconds = int.tryParse(matched.group(1) ?? '');
      break;
    }
    final offsetMs = offsetInMilliseconds ?? 0;

    final timeTagRe = RegExp(r'\[(\d{1,2}):(\d{2}(?:\.\d{1,3})?)\]');
    final syllablePattern = RegExp(r'([^\(]*?)\((\d+),(\d+)\)');
    final attributePattern = RegExp(r'^\[(\d+)\]');

    // 预计算整首歌的近似总时长，用于把元数据过滤限制在首尾附近。
    int maxTimeMs = 0;
    for (final raw in lrcLines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;
      for (final m in timeTagRe.allMatches(line)) {
        final mm = int.tryParse(m.group(1) ?? '');
        final ss = double.tryParse(m.group(2) ?? '');
        if (mm != null && ss != null) {
          final ms = ((mm * 60 + ss) * 1000).round() - offsetMs;
          if (ms > maxTimeMs) maxTimeMs = ms;
        }
      }
    }
    final totalMs = maxTimeMs + 5000;
    const edgeThresholdMs = 30000;
    final useEdgeFilter = totalMs > edgeThresholdMs * 2;

    final rawLines = <_EnhancedLrcRawLine>[];
    final metadataLines = <_EnhancedLrcRawLine>[];
    final filteredMetadataMs = <int>{};
    // 记录最大的元数据时间戳，用于计算间奏开始时间
    int? maxMetadataTimeMs;

    for (final raw in lrcLines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;

      final timeMatches = timeTagRe.allMatches(line).toList(growable: false);
      if (timeMatches.isEmpty) continue;

      final contentRaw = line.replaceAll(timeTagRe, '').trim();

      // 过滤元数据行，只在歌曲首尾附近生效，防止中间歌词被误伤
      if (LrcLine.isLyricMetadataLine(contentRaw)) {
        if (keepMetadata) {
          for (final m in timeMatches) {
            final mm = int.tryParse(m.group(1) ?? '');
            final ss = double.tryParse(m.group(2) ?? '');
            if (mm != null && ss != null) {
              metadataLines.add(
                _EnhancedLrcRawLine(
                  Duration(
                    milliseconds: max(
                      ((mm * 60 + ss) * 1000).round() - offsetMs,
                      0,
                    ),
                  ),
                  contentRaw,
                ),
              );
            }
          }
          continue;
        }
        for (final m in timeMatches) {
          final mm = int.tryParse(m.group(1) ?? '');
          final ss = double.tryParse(m.group(2) ?? '');
          if (mm != null && ss != null) {
            final ms = max(((mm * 60 + ss) * 1000).round() - offsetMs, 0);
            // 只在首尾阈值内过滤；中间的歌词即使命中元数据特征也保留
            if (!useEdgeFilter ||
                ms <= edgeThresholdMs ||
                ms >= totalMs - edgeThresholdMs) {
              filteredMetadataMs.add(ms);
              // 更新最大元数据时间戳
              if (maxMetadataTimeMs == null || ms > maxMetadataTimeMs) {
                maxMetadataTimeMs = ms;
              }
            }
          }
        }
        continue;
      }

      for (final m in timeMatches) {
        final minute = int.tryParse(m.group(1) ?? '');
        final sec = double.tryParse(m.group(2) ?? '');
        if (minute == null || sec == null) continue;
        final lineStartMs = max(
          ((minute * 60 + sec) * 1000).round() - offsetMs,
          0,
        );

        if (filteredMetadataMs.contains(lineStartMs)) continue;

        rawLines.add(
          _EnhancedLrcRawLine(Duration(milliseconds: lineStartMs), contentRaw),
        );
      }
    }

    if (rawLines.isEmpty && metadataLines.isEmpty) return null;

    // Group by timestamp with tolerance
    final groupKeys = <List<String>>[];
    final groupStartTimes = <Duration>[];

    for (final rl in rawLines) {
      final rlMs = rl.start.inMilliseconds;
      int? foundIndex;
      for (int i = 0; i < groupStartTimes.length; i++) {
        if ((rlMs - groupStartTimes[i].inMilliseconds).abs() < 50) {
          foundIndex = i;
          break;
        }
      }
      if (foundIndex != null) {
        groupKeys[foundIndex].add(rl.content);
      } else {
        groupKeys.add([rl.content]);
        groupStartTimes.add(rl.start);
      }
    }

    final parsedLines = <EnhancedLrcLine>[];

    for (int g = 0; g < groupKeys.length; g++) {
      final start = groupStartTimes[g];
      final contents = groupKeys[g];

      final mainLines = <String>[];
      final additionalLines = <String>[];

      for (final c in contents) {
        final attrMatch = attributePattern.firstMatch(c);
        if (attrMatch != null) {
          final attrNum = int.tryParse(attrMatch.group(1) ?? '');
          if (attrNum != null && attrNum > 5) {
            additionalLines.add(c);
          } else {
            mainLines.add(c);
          }
        } else {
          mainLines.add(c);
        }
      }

      // First main line is the primary text
      if (mainLines.isEmpty) continue;
      final primaryContent = mainLines.first;
      final primaryWords = <EnhancedLrcWord>[];

      // Parse syllable timestamps from primary
      for (final match in syllablePattern.allMatches(primaryContent)) {
        final text = match.group(1) ?? '';
        final startMsStr = match.group(2);
        final durMsStr = match.group(3);
        if (startMsStr == null || durMsStr == null || text.isEmpty) continue;

        final startMs = int.tryParse(startMsStr);
        final durMs = int.tryParse(durMsStr);
        if (startMs == null || durMs == null) continue;

        final wordStart = Duration(milliseconds: startMs - offsetMs);
        final wordLength = Duration(milliseconds: durMs);

        primaryWords.add(EnhancedLrcWord(wordStart, wordLength, text));
      }

      // Remaining main lines are translations
      final translations = <String>[];
      for (int i = 1; i < mainLines.length; i++) {
        final stripped = mainLines[i].replaceAll(attributePattern, '').trim();
        // Also strip syllable patterns for translations
        final cleanTranslation = stripped
            .replaceAll(RegExp(r'\(\d+,\d+\)'), '')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .trim();
        if (cleanTranslation.isNotEmpty) {
          translations.add(cleanTranslation);
        }
      }

      for (final additionalLine in additionalLines) {
        final stripped = additionalLine.replaceAll(attributePattern, '').trim();
        final clean = stripped
            .replaceAll(RegExp(r'\(\d+,\d+\)'), '')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .trim();
        if (clean.isNotEmpty) translations.add(clean);
      }

      if (primaryWords.isEmpty && primaryContent.trim().isEmpty) continue;

      // If no syllable timestamps found, create a single word
      if (primaryWords.isEmpty) {
        final cleaned = primaryContent
            .replaceAll(syllablePattern, '')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .replaceAll(attributePattern, '')
            .trim();
        if (cleaned.isNotEmpty) {
          primaryWords.add(EnhancedLrcWord(start, Duration.zero, cleaned));
        }
      }

      if (primaryWords.isEmpty) continue;

      // 元数据残留保护：primary 匹配元数据特征 → 整组跳过
      // 只在首尾附近生效，避免中间普通歌词被误伤
      final startMs = start.inMilliseconds;
      final nearEdge =
          !useEdgeFilter ||
          startMs <= edgeThresholdMs ||
          startMs >= totalMs - edgeThresholdMs;
      if (!keepMetadata &&
          nearEdge &&
          LrcLine.isLyricMetadataLine(
            primaryContent.replaceAll(RegExp(r'<[^>]*>'), '').trim(),
          )) {
        continue;
      }

      final line = EnhancedLrcLine(
        start,
        Duration.zero,
        primaryWords,
        translations.isEmpty ? null : translations.join(separator ?? '┃'),
      );

      parsedLines.add(line);
    }

    for (final metadata in metadataLines) {
      final content = metadata.content
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim();
      if (content.isEmpty) continue;
      parsedLines.add(
        EnhancedLrcLine(metadata.start, const Duration(milliseconds: 500), [
          EnhancedLrcWord(
            metadata.start,
            const Duration(milliseconds: 500),
            content,
          ),
        ]),
      );
    }

    if (parsedLines.isEmpty) return null;

    parsedLines.sort((a, b) => a.start.compareTo(b.start));

    // Calculate line durations
    for (int i = 0; i < parsedLines.length; i++) {
      final line = parsedLines[i];
      final nextStart = i < parsedLines.length - 1
          ? parsedLines[i + 1].start
          : null;
      final lineLen = nextStart == null
          ? const Duration(seconds: 5)
          : (nextStart - line.start);
      line.length = lineLen.isNegative ? Duration.zero : lineLen;

      // Fill word durations
      final words = line.words.cast<EnhancedLrcWord>();
      for (int j = 0; j < words.length; j++) {
        final curr = words[j];
        if (curr.length.inMilliseconds <= 0) {
          final nextWordStart = j < words.length - 1
              ? words[j + 1].start
              : null;

          // 修复：最后一个词不要用 line.length（会拉长到下一行），而是用合理的估计值
          final end =
              nextWordStart ?? (curr.start + const Duration(milliseconds: 500));

          final d = end - curr.start;
          curr.length = d.isNegative
              ? Duration.zero
              : (d < const Duration(milliseconds: 50)
                    ? const Duration(milliseconds: 50)
                    : d);
        }
      }
    }

    // Insert interlude gaps
    final finalLines = <LyricLine>[];
    const gapThreshold = Duration(milliseconds: 5000);
    for (int i = 0; i < parsedLines.length; i++) {
      final line = parsedLines[i];
      finalLines.add(line);

      if (i >= parsedLines.length - 1) continue;
      final nextStart = parsedLines[i + 1].start;
      // 间奏起点 = 本行最后一个字的实际结束时间（而非占满到下一行的 length），
      // 否则 gapStart 恒等于 nextStart、gapLen 恒为 0，中间间奏永远插不进来。
      // 对齐在线源 lrc_tool 的 _actualLineEndMs 算法。
      final gapStart = line.words.isNotEmpty
          ? line.words.last.start + line.words.last.length
          : line.start + const Duration(milliseconds: 3500);
      final gapLen = nextStart - gapStart;
      if (gapLen >= gapThreshold) {
        finalLines.add(EnhancedLrcLine(gapStart, gapLen, []));
      }
    }

    // 插入前奏空白行：从 0 到第一句歌词。
    // 元数据行已被过滤，它们所占的时间应该合并进前奏间奏里显示。
    if (finalLines.isNotEmpty) {
      final firstLine = finalLines.first;
      final firstLineStart = firstLine.start;
      const introStart = Duration.zero;

      logger.i(
        '[lrc] _parseLyricify: maxMetadataTimeMs=$maxMetadataTimeMs, firstLineStart=${firstLineStart.inMilliseconds}ms, introStart=${introStart.inMilliseconds}ms',
      );

      // 如果第一句歌词不在 0 时刻，且第一行不是已经从 0 开始的空白行，插入前奏空白行
      final firstLineIsIntroBlank =
          firstLine is SyncLyricLine &&
          firstLine.words.isEmpty &&
          firstLineStart == introStart;

      if (firstLineStart > introStart && !firstLineIsIntroBlank) {
        logger.i(
          '[lrc] _parseLyricify: inserting intro blank line from ${introStart.inMilliseconds}ms to ${firstLineStart.inMilliseconds}ms',
        );
        finalLines.insert(
          0,
          EnhancedLrcLine(introStart, firstLineStart - introStart, []),
        );
      }
    }

    cleanLyricBlankLines(finalLines);
    return EnhancedLrc(finalLines.cast<EnhancedLrcLine>(), source);
  }

  static bool _isTtml(String text) {
    final trimmed = text.trim();
    return trimmed.startsWith('<?xml') ||
        trimmed.startsWith('<tt') ||
        trimmed.contains('<tt ') ||
        trimmed.contains('<body>') ||
        (trimmed.contains('<p ') && trimmed.contains('begin='));
  }

  static Lyric? _parseEnhancedLrcText(
    String lrc,
    LyricFormat source, {
    String? separator,
    required bool keepMetadata,
  }) {
    final lrcLines = lrc.split('\n');

    int? offsetInMilliseconds;
    final offsetPattern = RegExp(r'\[\s*offset\s*:\s*([+-]?\d+)\s*\]');
    for (final line in lrcLines) {
      final matched = offsetPattern.firstMatch(line);
      if (matched == null) continue;
      offsetInMilliseconds = int.tryParse(matched.group(1) ?? '');
      break;
    }
    final offsetMs = offsetInMilliseconds ?? 0;

    final timeTagRe = RegExp(r'\[(\d{1,2}):(\d{2}(?:\.\d{1,3})?)\]');
    final wordTagRe = RegExp(r'<(\d+:\d+\.\d+|\d+)>([^<]*)');

    int? parseTimeTagToMs(String timeStr) {
      if (timeStr.contains(':')) {
        final p = timeStr.split(':');
        if (p.length != 2) return null;
        final wm = int.tryParse(p[0]);
        final ws = double.tryParse(p[1]);
        if (wm == null || ws == null) return null;
        return max(((wm * 60 + ws) * 1000).round() - offsetMs, 0);
      }
      final rawMs = int.tryParse(timeStr);
      if (rawMs == null) return null;
      return max(rawMs - offsetMs, 0);
    }

    // 预计算整首歌的近似总时长，用于把元数据过滤限制在首尾附近。
    // 普通歌词中的“作词/作曲”等元数据极少出现在歌曲中间。
    int maxTimeMs = 0;
    for (final raw in lrcLines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;
      for (final m in timeTagRe.allMatches(line)) {
        final mm = int.tryParse(m.group(1) ?? '');
        final ss = double.tryParse(m.group(2) ?? '');
        if (mm != null && ss != null) {
          final ms = ((mm * 60 + ss) * 1000).round() - offsetMs;
          if (ms > maxTimeMs) maxTimeMs = ms;
        }
      }
    }
    final totalMs = maxTimeMs + 5000;
    const edgeThresholdMs = 30000;
    final useEdgeFilter = totalMs > edgeThresholdMs * 2;

    final rawLines = <_EnhancedLrcRawLine>[];
    final metadataLines = <_EnhancedLrcRawLine>[];
    // 记录被过滤元数据行的时间戳，后续同步过滤同时间戳的罗马音等残留行
    final filteredMetadataMs = <int>{};
    // 记录最大的元数据时间戳，用于计算间奏开始时间
    int? maxMetadataTimeMs;

    for (final raw in lrcLines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;

      final timeMatches = timeTagRe.allMatches(line).toList(growable: false);
      if (timeMatches.isEmpty) continue;

      final contentRaw = line.replaceAll(timeTagRe, '').trim();

      // 从逐字时间戳中提取文本内容（不能直接用 replaceAll 删除标签，
      // 因为 wordTagRe 的匹配包含文本，删除标签的同时也会删除文本内容，
      // 导致「全部是逐字标签」的行得到空字符串，元数据检测失效）
      final wordContent = wordTagRe
          .allMatches(contentRaw)
          .map((m) => m.group(2) ?? '')
          .join();
      final metadataCheckText = wordContent.isNotEmpty
          ? wordContent.trim()
          : contentRaw;

      // 过滤元数据行（"Adam Levine："、"词：xxx"、"Lyrics by："等），
      // 避免它们抢真实歌词的主位。只在歌曲首尾附近生效，防止中间歌词被误伤。
      if (LrcLine.isLyricMetadataLine(metadataCheckText)) {
        if (keepMetadata) {
          for (final m in timeMatches) {
            final mm = int.tryParse(m.group(1) ?? '');
            final ss = double.tryParse(m.group(2) ?? '');
            if (mm != null && ss != null) {
              metadataLines.add(
                _EnhancedLrcRawLine(
                  Duration(
                    milliseconds: max(
                      ((mm * 60 + ss) * 1000).round() - offsetMs,
                      0,
                    ),
                  ),
                  contentRaw,
                ),
              );
            }
          }
          continue;
        }
        // 记录该行所有时间戳，以便后续过滤同组的罗马音等残留行
        for (final m in timeMatches) {
          final mm = int.tryParse(m.group(1) ?? '');
          final ss = double.tryParse(m.group(2) ?? '');
          if (mm != null && ss != null) {
            final ms = max(((mm * 60 + ss) * 1000).round() - offsetMs, 0);
            // 只在首尾阈值内过滤；中间的歌词即使命中元数据特征也保留
            if (!useEdgeFilter ||
                ms <= edgeThresholdMs ||
                ms >= totalMs - edgeThresholdMs) {
              filteredMetadataMs.add(ms);
              // 更新最大元数据时间戳
              if (maxMetadataTimeMs == null || ms > maxMetadataTimeMs) {
                maxMetadataTimeMs = ms;
              }
            }
          }
        }
        continue;
      }

      for (final m in timeMatches) {
        final minute = int.tryParse(m.group(1) ?? '');
        final sec = double.tryParse(m.group(2) ?? '');
        if (minute == null || sec == null) continue;
        final lineStartMs = max(
          ((minute * 60 + sec) * 1000).round() - offsetMs,
          0,
        );

        // 检查该时间戳是否已被元数据过滤
        if (filteredMetadataMs.contains(lineStartMs)) continue;

        rawLines.add(
          _EnhancedLrcRawLine(Duration(milliseconds: lineStartMs), contentRaw),
        );
      }
    }

    if (rawLines.isEmpty && metadataLines.isEmpty) return null;

    bool hasTimedContent(String raw) => wordTagRe
        .allMatches(raw)
        .any((match) => (match.group(2) ?? '').trim().isNotEmpty);

    ({int start, int end})? timedContentRange(String raw) {
      final matches = wordTagRe.allMatches(raw).toList(growable: false);
      final contentMatches = matches
          .where((match) => (match.group(2) ?? '').trim().isNotEmpty)
          .toList(growable: false);
      if (contentMatches.isEmpty) return null;
      final rangeStart = parseTimeTagToMs(contentMatches.first.group(1)!);
      if (rangeStart == null) return null;
      var rangeEnd = rangeStart + 500;
      for (final match in matches.reversed) {
        final time = parseTimeTagToMs(match.group(1)!);
        if (time != null && time > rangeStart) {
          rangeEnd = time;
          break;
        }
      }
      return (start: rangeStart, end: rangeEnd);
    }

    ({int start, int end})? bestTimedRange(List<String> contents) {
      String? best;
      var bestTagCount = -1;
      for (final content in contents) {
        if (!hasTimedContent(content)) continue;
        final tagCount = wordTagRe.allMatches(content).length;
        if (tagCount > bestTagCount) {
          best = content;
          bestTagCount = tagCount;
        }
      }
      return best == null ? null : timedContentRange(best);
    }

    bool hasAlignedTimedRange(List<String> a, List<String> b) {
      final aRange = bestTimedRange(a);
      final bRange = bestTimedRange(b);
      if (aRange == null || bRange == null) return false;
      final overlap =
          min(aRange.end, bRange.end) - max(aRange.start, bRange.start);
      if (overlap <= 0) return false;
      final aDuration = max(aRange.end - aRange.start, 1);
      final bDuration = max(bRange.end - bRange.start, 1);
      final shorterDuration = min(aDuration, bDuration);
      final longerDuration = max(aDuration, bDuration);
      final endDifference = (aRange.end - bRange.end).abs();
      return overlap * 2 >= shorterDuration &&
          endDifference <= max(500, (longerDuration * 0.25).round());
    }

    final exactGroups = <Duration, List<String>>{};
    for (final line in rawLines) {
      exactGroups.putIfAbsent(line.start, () => []).add(line.content);
    }

    // 时间范围重合的逐字副行仍可归组；首尾相接的相邻原文保持独立。
    final groupedMap = <Duration, List<String>>{};
    for (final entry in exactGroups.entries) {
      if (entry.value.any(hasTimedContent)) {
        Duration? alignedStart;
        var nearestDifferenceMs = 50;
        for (final groupedEntry in groupedMap.entries) {
          final differenceMs =
              (entry.key.inMilliseconds - groupedEntry.key.inMilliseconds)
                  .abs();
          if (differenceMs < nearestDifferenceMs &&
              hasAlignedTimedRange(groupedEntry.value, entry.value)) {
            alignedStart = groupedEntry.key;
            nearestDifferenceMs = differenceMs;
          }
        }
        if (alignedStart == null) {
          groupedMap[entry.key] = List<String>.from(entry.value);
        } else {
          groupedMap[alignedStart]!.addAll(entry.value);
        }
      }
    }
    for (final entry in exactGroups.entries) {
      if (entry.value.any(hasTimedContent)) continue;
      Duration? nearestStart;
      var nearestDifferenceMs = 50;
      for (final start in groupedMap.keys) {
        final differenceMs = (entry.key.inMilliseconds - start.inMilliseconds)
            .abs();
        if (differenceMs < nearestDifferenceMs) {
          nearestStart = start;
          nearestDifferenceMs = differenceMs;
        }
      }
      if (nearestStart == null) {
        groupedMap[entry.key] = List<String>.from(entry.value);
      } else {
        groupedMap[nearestStart]!.addAll(entry.value);
      }
    }

    final parsedLines = <EnhancedLrcLine>[];
    final explicitLineEndMsByStart = <Duration, int>{};
    Duration? firstLyricLineStart;
    Duration? firstLyricWordStart;

    for (final entry in groupedMap.entries) {
      final start = entry.key;
      final contents = entry.value;

      // Identify primary (one with most word tags, ignoring inline translations)
      // Also separate romanization lines from translation lines
      String primaryText = contents.first;
      final translations = <String>[];
      String? romanText;

      int extractTagCount(String raw) {
        final part = separator == null ? raw : raw.split(separator).first;
        return wordTagRe.allMatches(part).length;
      }

      // 判断哪行有逐词标签（有标签的 = 原文）
      // 关键区分：<时间>后面有文字 = 逐词标签；文字后面<时间> = 行尾时间戳
      // 例：<00:00.691>あ ← 逐词标签；那孩子真好啊<00:04.135> ← 行尾时间戳
      bool hasWordTimeTags(String raw) {
        final tagMatches = wordTagRe.allMatches(raw).toList();
        for (final m in tagMatches) {
          final endPos = m.end;
          // 检查标签后面是否还有非空白文字
          if (endPos < raw.length) {
            final after = raw.substring(endPos);
            if (RegExp(r'\S').hasMatch(after)) {
              return true;
            }
          }
        }
        return false;
      }

      final contentsWithTags = <String>[];
      final contentsWithoutTags = <String>[];
      for (final c in contents) {
        if (hasWordTimeTags(c)) {
          contentsWithTags.add(c);
        } else {
          contentsWithoutTags.add(c);
        }
      }

      // 判断罗马音（仅对没有逐词标签的行使用）。
      // 英文歌词不是注音，不能因为无东方文字就进罗马音轨。
      final romanContents = <String>[];
      final otherContents = <String>[];
      for (final c in contentsWithoutTags) {
        otherContents.add(c);
      }

      // 原文 = 有逐词标签的行（最可靠）；如果没有，从 otherContents 里选标签最多的
      String primaryRaw;
      int? primaryIndex; // null = primary 不在 otherContents 中

      if (contentsWithTags.isNotEmpty) {
        // 选逐词标签最多的行作为原文。
        // 解决元数据行（如 "Adam Levine："）被 50ms 容差和实际歌词分到同一组时抢主位的问题。
        // 实际歌词的逐词标签数远多于元数据行。
        int bestTagIdx = 0;
        int maxTagCount = -1;
        for (int i = 0; i < contentsWithTags.length; i++) {
          final tc = extractTagCount(contentsWithTags[i]);
          if (tc > maxTagCount) {
            maxTagCount = tc;
            bestTagIdx = i;
          }
        }
        primaryRaw = contentsWithTags[bestTagIdx];
        primaryIndex = null;

        // 剩余有标签的行先放进 other，原文确定后再按注音/翻译拆。
        for (int i = 0; i < contentsWithTags.length; i++) {
          if (i == bestTagIdx) continue;
          otherContents.add(contentsWithTags[i]);
        }
      } else if (otherContents.isNotEmpty) {
        int maxTags = -1;
        int pi = 0;
        for (int i = 0; i < otherContents.length; i++) {
          final tagCount = extractTagCount(otherContents[i]);
          if (tagCount > maxTags) {
            maxTags = tagCount;
            pi = i;
          }
        }
        primaryRaw = otherContents[pi];
        primaryIndex = pi;
      } else {
        // 全是罗马音（极端情况）
        primaryRaw = contents[0];
        primaryIndex = null;
      }
      final primaryParts = separator == null
          ? <String>[primaryRaw]
          : primaryRaw.split(separator);
      primaryText = primaryParts.first;
      if (primaryParts.length > 1) {
        translations.add(primaryParts.sublist(1).join(separator ?? '').trim());
      }

      String? primaryCleaned = primaryText
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim();

      for (int i = 0; i < otherContents.length; i++) {
        if (i == primaryIndex) continue;
        final parts = separator == null
            ? <String>[otherContents[i]]
            : otherContents[i].split(separator);
        final inlinePrimary = parts.first;
        final inlineTrans = parts.length > 1
            ? parts.sublist(1).join(separator ?? '┃')
            : null;
        if (inlineTrans != null && inlineTrans.trim().isNotEmpty) {
          translations.add(inlineTrans.trim());
          continue;
        }
        final cleaned = inlinePrimary.replaceAll(RegExp(r'<[^>]*>'), '').trim();
        if (cleaned.isEmpty || cleaned == primaryCleaned) continue;
        if (_isAnnotationTrack(primaryCleaned, cleaned)) {
          romanContents.add(otherContents[i]);
        } else {
          translations.add(cleaned);
        }
      }

      for (final r in romanContents) {
        final parts = separator == null ? <String>[r] : r.split(separator);
        final cleaned = parts.first.replaceAll(RegExp(r'<[^>]*>'), '').trim();

        // Skip if identical to primary - this happens when entire line is pure English
        // and gets misclassified as Romanization
        if (cleaned.isEmpty) continue;
        if (cleaned == primaryCleaned) continue;
        if (cleaned.toLowerCase() == primaryCleaned.toLowerCase()) continue;

        if (romanText == null || romanText.isEmpty) {
          romanText = cleaned;
        } else {
          romanText = '$romanText $cleaned';
        }
      }

      final translationText = translations.isEmpty
          ? null
          : translations
                .where((e) => e.trim().isNotEmpty)
                .join(separator ?? '┃');

      final words = <EnhancedLrcWord>[];
      bool hasWordTimestamps = false;
      int? explicitLineEndMs;

      for (final w in wordTagRe.allMatches(primaryText)) {
        final timeStr = w.group(1);
        final text = w.group(2) ?? ''; // preserve spaces
        if (timeStr == null) continue;

        final wordStartMs = parseTimeTagToMs(timeStr);
        if (wordStartMs == null) continue;
        if (text.isEmpty) {
          explicitLineEndMs = wordStartMs;
          continue;
        }

        words.add(
          EnhancedLrcWord(
            Duration(milliseconds: wordStartMs),
            Duration.zero,
            text,
          ),
        );
        hasWordTimestamps = true;
      }

      // 行首纯空格时间锚点不参与歌词显示和跟随。
      while (words.isNotEmpty && words.first.content.trim().isEmpty) {
        words.removeAt(0);
      }
      hasWordTimestamps = words.isNotEmpty;

      if (!hasWordTimestamps && primaryText.isNotEmpty) {
        final cleanedText = primaryText
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .trim();
        if (cleanedText.isNotEmpty) {
          words.add(EnhancedLrcWord(start, Duration.zero, cleanedText));
        }
      }

      // 元数据残留保护：primary 匹配元数据特征 → 整组跳过
      // 使用 allMatches 提取文本内容，避免 wordTagRe 的 replaceAll 吞掉文本
      // 只在首尾附近生效，避免中间普通歌词被误伤
      final startMs = start.inMilliseconds;
      final nearEdge =
          !useEdgeFilter ||
          startMs <= edgeThresholdMs ||
          startMs >= totalMs - edgeThresholdMs;
      final primaryWordContent = wordTagRe
          .allMatches(primaryText)
          .map((m) => m.group(2) ?? '')
          .join();
      final primaryCheckText = primaryWordContent.isNotEmpty
          ? primaryWordContent.trim()
          : primaryText;
      if (words.isEmpty ||
          (!keepMetadata &&
              nearEdge &&
              LrcLine.isLyricMetadataLine(primaryCheckText))) {
        continue;
      }

      parsedLines.add(
        EnhancedLrcLine(
          start,
          Duration.zero,
          words,
          translationText?.isEmpty == true ? null : translationText,
          romanText?.isEmpty == true ? null : romanText,
        ),
      );

      Duration? meaningfulWordStart;
      for (final word in words) {
        if (word.content.trim().isEmpty) continue;
        if (meaningfulWordStart == null || word.start < meaningfulWordStart) {
          meaningfulWordStart = word.start;
        }
      }
      if (firstLyricLineStart == null || start < firstLyricLineStart) {
        firstLyricLineStart = start;
        firstLyricWordStart = meaningfulWordStart;
      } else if (start == firstLyricLineStart &&
          meaningfulWordStart != null &&
          (firstLyricWordStart == null ||
              meaningfulWordStart < firstLyricWordStart)) {
        firstLyricWordStart = meaningfulWordStart;
      }
      if (explicitLineEndMs != null) {
        explicitLineEndMsByStart[start] = explicitLineEndMs;
      }
    }

    for (final metadata in metadataLines) {
      final content = metadata.content
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim();
      if (content.isEmpty) continue;
      parsedLines.add(
        EnhancedLrcLine(metadata.start, const Duration(milliseconds: 500), [
          EnhancedLrcWord(
            metadata.start,
            const Duration(milliseconds: 500),
            content,
          ),
        ]),
      );
    }

    if (parsedLines.isEmpty) return null;

    parsedLines.sort((a, b) => a.start.compareTo(b.start));

    for (int i = 0; i < parsedLines.length; i++) {
      final line = parsedLines[i];
      final nextStart = i < parsedLines.length - 1
          ? parsedLines[i + 1].start
          : null;
      final lineLen = nextStart == null
          ? const Duration(seconds: 5)
          : (nextStart - line.start);
      line.length = lineLen.isNegative ? Duration.zero : lineLen;

      if (line.words.isEmpty) continue;
      final words = line.words.cast<EnhancedLrcWord>();
      for (int j = 0; j < words.length; j++) {
        final curr = words[j];
        final nextWordStart = j < words.length - 1 ? words[j + 1].start : null;

        final explicitLineEndMs = explicitLineEndMsByStart[line.start];
        final explicitLineEnd = explicitLineEndMs == null
            ? null
            : Duration(milliseconds: explicitLineEndMs);
        final end =
            nextWordStart ??
            (explicitLineEnd != null && explicitLineEnd > curr.start
                ? explicitLineEnd
                : curr.start + const Duration(milliseconds: 500));

        final d = end - curr.start;
        curr.length = d.isNegative
            ? Duration.zero
            : (d < const Duration(milliseconds: 50)
                  ? const Duration(milliseconds: 50)
                  : d);
      }
    }

    final finalLines = <LyricLine>[];
    const gapThreshold = Duration(milliseconds: 5000);
    for (int i = 0; i < parsedLines.length; i++) {
      final line = parsedLines[i];
      finalLines.add(line);

      if (i >= parsedLines.length - 1) continue;
      final nextStart = parsedLines[i + 1].start;
      // 间奏起点 = 本行最后一个字的实际结束时间（而非占满到下一行的 length），
      // 否则 gapStart 恒等于 nextStart、gapLen 恒为 0，中间间奏永远插不进来。
      // 对齐在线源 lrc_tool 的 _actualLineEndMs 算法。
      final gapStart = line.words.isNotEmpty
          ? line.words.last.start + line.words.last.length
          : line.start + const Duration(milliseconds: 3500);
      final gapLen = nextStart - gapStart;
      if (gapLen >= gapThreshold) {
        finalLines.add(EnhancedLrcLine(gapStart, gapLen, []));
      }
    }

    // 插入前奏空白行：从 0 到第一句歌词。
    // 元数据行已被过滤，它们所占的时间应该合并进前奏间奏里显示。
    if (finalLines.isNotEmpty) {
      final firstLine = finalLines.first;
      var firstLineStart = firstLyricLineStart ?? firstLine.start;
      const introStart = Duration.zero;

      if (firstLineStart == introStart &&
          firstLyricWordStart != null &&
          firstLyricWordStart > introStart) {
        firstLineStart = firstLyricWordStart;
      }

      logger.i(
        '[lrc] _parseEnhancedLrcText: maxMetadataTimeMs=$maxMetadataTimeMs, firstLineStart=${firstLineStart.inMilliseconds}ms, introStart=${introStart.inMilliseconds}ms',
      );

      // 如果第一句歌词不在 0 时刻，且第一行不是已经从 0 开始的空白行，插入前奏空白行
      final firstLineIsIntroBlank =
          firstLine is SyncLyricLine &&
          firstLine.words.isEmpty &&
          firstLineStart == introStart;

      if (firstLineStart > introStart && !firstLineIsIntroBlank) {
        logger.i(
          '[lrc] _parseEnhancedLrcText: inserting intro blank line from ${introStart.inMilliseconds}ms to ${firstLineStart.inMilliseconds}ms',
        );
        finalLines.insert(
          0,
          EnhancedLrcLine(introStart, firstLineStart - introStart, []),
        );
      }
    }

    cleanLyricBlankLines(finalLines);
    return EnhancedLrc(finalLines.cast<EnhancedLrcLine>(), source);
  }

  /// 智能清理空白行：
  /// 1. 移除连续的空白行（只保留第一个）
  /// 2. 移除时间间隔小于 800ms 的空白行（太短无意义）
  /// 3. 保留时长合理的间奏空白行（800ms ~ 10s）
  void _removeBlankLines() {
    cleanLyricBlankLines(lines);
  }

  /// 从 Rust FFI 加载内嵌歌词（ID3v2/VorbisComment/MP4）。
  /// 返回原始文本后由 [fromLrcTextAuto] 自动检测格式（普通/增强/逐字/TTML）。
  static Future<Lyric?> fromAudioPath(
    Audio belongTo, {
    String? separator = '┃',
  }) async {
    final raw = await getLyricFromPath(path: belongTo.path);
    logger.i(
      'lrc: fromAudioPath raw=${raw?.substring(0, raw.length > 80 ? 80 : raw.length)}',
    );
    if (raw == null || raw.isEmpty) {
      logger.i('lrc: fromAudioPath -> null (no lyric)');
      return null;
    }
    final parsed = Lrc.fromLrcTextAuto(
      raw,
      LyricFormat.local,
      separator: separator,
    );
    logger.i('lrc: fromAudioPath parsed=${parsed?.lines.length} lines');
    return parsed;
  }
}
