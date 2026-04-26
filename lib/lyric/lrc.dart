import 'dart:math';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/ttml.dart';
import 'package:pure_music/lyric/krc.dart';
import 'package:pure_music/lyric/qrc.dart';
import 'package:pure_music/lyric/qrc_decryptor.dart';
import 'package:pure_music/lyric/yrc.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/page/now_playing_page/component/word_emphasis_helper.dart';

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

  lines.clear();
  lines.addAll(cleaned);
}

bool _isBlankLine(LyricLine line) {
  if (line is LrcLine) return line.isBlank;
  if (line is SyncLyricLine) return line.words.isEmpty;
  return false;
}

class EnhancedLrc extends Lyric {
  final LrcSource source;
  EnhancedLrc(super.lines, this.source);

  @override
  String toString() {
    return {"type": source, "lyric": lines}.toString();
  }
}

class EnhancedLrcLine extends SyncLyricLine {
  EnhancedLrcLine(super.start, super.length, super.words, [super.translation]);
}

class _EnhancedLrcRawLine {
  final Duration start;
  final String content;
  _EnhancedLrcRawLine(this.start, this.content);
}

class EnhancedLrcWord extends SyncLyricWord {
  EnhancedLrcWord(super.start, super.length, super.content, {super.marks});
}

class Crc extends Lyric {
  final LrcSource source;
  Crc(super.lines, this.source);

  @override
  String toString() {
    return {"type": source, "lyric": lines}.toString();
  }
}

class CrcLine extends SyncLyricLine {
  CrcLine(super.start, super.length, super.words, [super.translation]);
}

class CrcWord extends SyncLyricWord {
  CrcWord(super.start, super.length, super.content, {super.marks});
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
  }) : isBlank = requiredIsBlank {
    length = Duration.zero;
  }

  static LrcLine defaultLine = LrcLine(
    Duration.zero,
    "无歌词",
    requiredIsBlank: false,
  );

  @override
  String toString() {
    return {"time": start.toString(), "content": content}.toString();
  }

  static final _metadataPattern = RegExp(
    r'^[\s\u3000]*([\u4e00-\u9fff]|[a-zA-Z]){1,8}[\s\u3000]*[：:][\s\u3000]*',
    caseSensitive: false,
  );

  /// line: [mm:ss.msmsms]content
  static LrcLine? fromLine(String line, [int? offset]) {
    if (line.trim().isEmpty) {
      return null;
    }

    final left = line.indexOf("[");
    final right = line.indexOf("]");

    if (left == -1 || right == -1) {
      return null;
    }

    var lrcTimeString = line.substring(left + 1, right);

    // replace [mm:ss.msms...] with ""
    var content = line
        .substring(right + 1)
        .trim()
        .replaceAll(RegExp(r"\[\d{2}:\d{2}\.\d{2,}\]"), "");

    var timeList = lrcTimeString.split(":");
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

    final isMetadata = content.isNotEmpty && _isMetadataLine(content);

    return LrcLine(
      Duration(
        milliseconds: max(inMilliseconds - (offset ?? 0), 0),
      ),
      content,
      requiredIsBlank: content.isEmpty,
      isMetadata: isMetadata,
    );
  }

  static bool _isMetadataLine(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return false;
    return _metadataPattern.hasMatch(trimmed);
  }
}

enum LrcSource {
  /// mp3: USLT frame
  /// flac: LYRICS comment
  local("本地"),
  web("网络");

  final String name;

  const LrcSource(this.name);
}

class Lrc extends Lyric {
  LrcSource source;

  Lrc(super.lines, this.source);

  @override
  String toString() {
    return {"type": source, "lyric": lines}.toString();
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
  Lrc _combineLrcLine(String separator) {
    // 按时间戳分组
    final grouped = <Duration, List<LyricLine>>{};
    for (final line in lines) {
      grouped.putIfAbsent(line.start, () => []).add(line);
    }

    final combinedLines = <LrcLine>[];

    for (final entry in grouped.entries) {
      final group = entry.value;
      if (group.length == 1) {
        // 只有一行，直接添加
        combinedLines.add(group[0] as LrcLine);
      } else if (group.length == 2) {
        // 两行：原文 + 翻译 或 注音 + 原文
        final primary = group[0] as LrcLine;
        final secondary = group[1] as LrcLine;

        if (_isRomanization(secondary.content)) {
          // secondary 是注音，primary 是原文
          primary.translation = _extractTranslation(primary.content, separator);
          primary.romanLyric = _stripTags(secondary.content);
          combinedLines.add(primary);
        } else {
          // 原文 + 翻译
          primary.translation = _stripTags(secondary.content);
          combinedLines.add(primary);
        }
      } else {
        // 三行或更多：注音 + 原文 + 翻译
        final roma = group[0] as LrcLine;
        final primary = group[1] as LrcLine;
        final trans = group.length > 2 ? group[2] as LrcLine? : null;

        primary.romanLyric = _stripTags(roma.content);
        if (trans != null) {
          primary.translation = _stripTags(trans.content);
        }
        combinedLines.add(primary);
      }
    }

    return Lrc(combinedLines, source);
  }

  /// 判断文本是否为注音（罗马音）
  /// 注音通常不包含中文字符，且字符密度较低
  bool _isRomanization(String text) {
    final cjkCount = RegExp(r'[\u4e00-\u9fff\u3040-\u309f\u30a0-\u30ff]').allMatches(text).length;
    final alphaCount = RegExp(r'[a-zA-Z]').allMatches(text).length;
    return cjkCount == 0 && alphaCount > text.length ~/ 3;
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
  static Lrc? fromLrcText(String lrc, LrcSource source, {String? separator}) {
    var lrcLines = lrc.split("\n");

    int? offsetInMilliseconds;
    final offsetPattern = RegExp(r'\[\s*offset\s*:\s*([+-]?\d+)\s*\]');
    for (var line in lrcLines) {
      final matched = offsetPattern.firstMatch(line);
      if (matched == null) continue;
      offsetInMilliseconds = int.tryParse(matched.group(1) ?? "");
      break;
    }

    var lines = <LrcLine>[];
    for (int i = 0; i < lrcLines.length; i++) {
      var lyricLine = LrcLine.fromLine(lrcLines[i], offsetInMilliseconds);
      if (lyricLine == null) {
        continue;
      }
      lines.add(lyricLine);
    }

    if (lines.isEmpty) {
      return null;
    }

    for (var i = 0; i < lines.length - 1; i++) {
      lines[i].length = lines[i + 1].start - lines[i].start;
    }
    if (lines.isNotEmpty) {
      lines.last.length = Duration.zero;
    }

    // 为前奏间隙创建空白行（第一句歌词开始前有时间间隙）
    if (lines.isNotEmpty && lines.first.start > Duration.zero) {
      final firstLineStart = lines.first.start;
      lines.insert(
        0,
        LrcLine(
          Duration.zero,
          '',
          requiredIsBlank: true,
        )..length = firstLineStart,
      );
    }

    final result = Lrc(lines, source);
    result._sort();

    if (separator == null) {
      result._removeBlankLines();
      return result;
    }

    final combined = result._combineLrcLine(separator);
    combined._removeBlankLines();
    return combined;
  }

  static Lyric? fromLrcTextAuto(
    String lrc,
    LrcSource source, {
    String? separator,
  }) {
    if (_isTtml(lrc)) {
      return Ttml.fromTtmlText(lrc, source, separator: separator);
    }
    final hasWordTags = RegExp(r'<(\d+:\d+\.\d+|\d+)>').hasMatch(lrc);
    if (!hasWordTags) {
      return fromLrcText(lrc, source, separator: separator);
    }
    final hasEndMarkers =
        RegExp(r'<(\d+:\d+\.\d+|\d+)>\s*$', multiLine: true).hasMatch(lrc);
    if (hasEndMarkers) {
      return _parseCrcText(lrc, source, separator: separator);
    }
    return _parseEnhancedLrcText(lrc, source, separator: separator);
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
    LrcSource source, {
    String? separator,
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

    final rawLines = <_EnhancedLrcRawLine>[];

    for (final raw in lrcLines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;

      final timeMatches = timeTagRe.allMatches(line).toList(growable: false);
      if (timeMatches.isEmpty) continue;

      final contentRaw = line.replaceAll(timeTagRe, '').trim();

      for (final m in timeMatches) {
        final minute = int.tryParse(m.group(1) ?? '');
        final sec = double.tryParse(m.group(2) ?? '');
        if (minute == null || sec == null) continue;
        final lineStartMs =
            max(((minute * 60 + sec) * 1000).round() - offsetMs, 0);

        rawLines.add(_EnhancedLrcRawLine(
          Duration(milliseconds: lineStartMs),
          contentRaw,
        ));
      }
    }

    if (rawLines.isEmpty) return null;

    // Group by timestamp
    final grouped = <Duration, List<String>>{};
    for (final rl in rawLines) {
      grouped.putIfAbsent(rl.start, () => []).add(rl.content);
    }

    final parsedLines = <EnhancedLrcLine>[];

    for (final entry in grouped.entries) {
      final start = entry.key;
      final contents = entry.value;

      // Identify primary (one with most word tags, ignoring inline translations)
      String primaryText = contents.first;
      final translations = <String>[];

      int extractTagCount(String raw) {
        final part = separator == null ? raw : raw.split(separator).first;
        return wordTagRe.allMatches(part).length;
      }

      int primaryIndex = 0;
      int maxTags = -1;
      for (int i = 0; i < contents.length; i++) {
        final tagCount = extractTagCount(contents[i]);
        if (tagCount > maxTags) {
          maxTags = tagCount;
          primaryIndex = i;
        }
      }

      final primaryParts = separator == null
          ? <String>[contents[primaryIndex]]
          : contents[primaryIndex].split(separator);
      primaryText = primaryParts.first;
      if (primaryParts.length > 1) {
        translations.add(
          primaryParts.sublist(1).join(separator ?? '┃').trim(),
        );
      }

      for (int i = 0; i < contents.length; i++) {
        if (i == primaryIndex) continue;
        final parts = separator == null
            ? <String>[contents[i]]
            : contents[i].split(separator);
        final inlinePrimary = parts.first;
        final inlineTrans =
            parts.length > 1 ? parts.sublist(1).join(separator ?? '┃') : null;
        if (inlineTrans != null && inlineTrans.trim().isNotEmpty) {
          translations.add(inlineTrans.trim());
        } else {
          final cleaned =
              inlinePrimary.replaceAll(RegExp(r'<[^>]*>'), '').trim();
          if (cleaned.isNotEmpty) translations.add(cleaned);
        }
      }

      final translationText = translations.isEmpty
          ? null
          : translations
              .where((e) => e.trim().isNotEmpty)
              .join(separator ?? '┃');

      final words = <EnhancedLrcWord>[];
      bool hasWordTimestamps = false;

      for (final w in wordTagRe.allMatches(primaryText)) {
        final timeStr = w.group(1);
        final text = w.group(2) ?? ''; // preserve spaces
        if (timeStr == null || text.isEmpty) continue;

        final wordStartMs = parseTimeTagToMs(timeStr);
        if (wordStartMs == null) continue;

        final marks = WordMarkingUtil.analyze(text);
        words.add(
          EnhancedLrcWord(
            Duration(milliseconds: wordStartMs),
            Duration.zero,
            text,
            marks: marks,
          ),
        );
        hasWordTimestamps = true;
      }

      if (!hasWordTimestamps && primaryText.isNotEmpty) {
        final cleanedText = primaryText.replaceAll(RegExp(r'<[^>]*>'), '').trim();
        if (cleanedText.isNotEmpty) {
          final marks = WordMarkingUtil.analyze(cleanedText);
          words.add(
            EnhancedLrcWord(
              start,
              Duration.zero,
              cleanedText,
              marks: marks,
            ),
          );
        }
      }

      if (words.isEmpty) continue;

      parsedLines.add(
        EnhancedLrcLine(
          start,
          Duration.zero,
          words,
          translationText?.isEmpty == true ? null : translationText,
        ),
      );
    }

    if (parsedLines.isEmpty) return null;

    parsedLines.sort((a, b) => a.start.compareTo(b.start));

    for (int i = 0; i < parsedLines.length; i++) {
      final line = parsedLines[i];
      final nextStart =
          i < parsedLines.length - 1 ? parsedLines[i + 1].start : null;
      final lineLen = nextStart == null
          ? const Duration(seconds: 5)
          : (nextStart - line.start);
      line.length = lineLen.isNegative ? Duration.zero : lineLen;

      if (line.words.isEmpty) continue;
      final words = line.words.cast<EnhancedLrcWord>();
      for (int j = 0; j < words.length; j++) {
        final curr = words[j];
        final nextWordStart = j < words.length - 1 ? words[j + 1].start : null;
        final end = nextWordStart ?? (line.start + line.length);
        final d = end - curr.start;
        curr.length = d.isNegative
            ? Duration.zero
            : (d < const Duration(milliseconds: 50)
                ? const Duration(milliseconds: 50)
                : d);
      }
    }

    final finalLines = <LyricLine>[];
    const gapThreshold = Duration(milliseconds: 1200);
    for (int i = 0; i < parsedLines.length; i++) {
      final line = parsedLines[i];
      finalLines.add(line);

      if (i >= parsedLines.length - 1) continue;
      final nextStart = parsedLines[i + 1].start;
      final gapStart = line.start + line.length;
      final gapLen = nextStart - gapStart;
      if (gapLen > gapThreshold) {
        finalLines.add(
          EnhancedLrcLine(
            gapStart,
            gapLen,
            [],
          ),
        );
      }
    }

    if (finalLines.isNotEmpty && finalLines.first.start > Duration.zero) {
      final firstLineStart = finalLines.first.start;
      finalLines.insert(
        0,
        EnhancedLrcLine(
          Duration.zero,
          firstLineStart,
          [],
        ),
      );
    }

    cleanLyricBlankLines(finalLines);
    return EnhancedLrc(finalLines.cast<EnhancedLrcLine>(), source);
  }

  static Lyric? _parseCrcText(
    String lrc,
    LrcSource source, {
    String? separator,
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
    final timeOnlyTagRe = RegExp(r'<(\d+:\d+\.\d+|\d+)>');

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

    final rawLines = <_EnhancedLrcRawLine>[];
    for (final raw in lrcLines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;

      final timeMatches = timeTagRe.allMatches(line).toList(growable: false);
      if (timeMatches.isEmpty) continue;

      final contentRaw = line.replaceAll(timeTagRe, '').trim();

      for (final m in timeMatches) {
        final minute = int.tryParse(m.group(1) ?? '');
        final sec = double.tryParse(m.group(2) ?? '');
        if (minute == null || sec == null) continue;
        final lineStartMs =
            max(((minute * 60 + sec) * 1000).round() - offsetMs, 0);
        rawLines.add(_EnhancedLrcRawLine(
          Duration(milliseconds: lineStartMs),
          contentRaw,
        ));
      }
    }
    if (rawLines.isEmpty) return null;

    final grouped = <Duration, List<String>>{};
    for (final rl in rawLines) {
      grouped.putIfAbsent(rl.start, () => []).add(rl.content);
    }

    final parsedLines = <CrcLine>[];

    for (final entry in grouped.entries) {
      final start = entry.key;
      final contents = entry.value;

      int extractTagCount(String raw) {
        final part = separator == null ? raw : raw.split(separator).first;
        return wordTagRe.allMatches(part).length;
      }

      int primaryIndex = 0;
      int maxTags = -1;
      for (int i = 0; i < contents.length; i++) {
        final tagCount = extractTagCount(contents[i]);
        if (tagCount > maxTags) {
          maxTags = tagCount;
          primaryIndex = i;
        }
      }

      final translations = <String>[];
      final primaryParts = separator == null
          ? <String>[contents[primaryIndex]]
          : contents[primaryIndex].split(separator);
      final primaryText = primaryParts.first;
      if (primaryParts.length > 1) {
        translations.add(
          primaryParts.sublist(1).join(separator ?? '┃').trim(),
        );
      }

      for (int i = 0; i < contents.length; i++) {
        if (i == primaryIndex) continue;
        final parts = separator == null
            ? <String>[contents[i]]
            : contents[i].split(separator);
        final inlinePrimary = parts.first;
        final inlineTrans =
            parts.length > 1 ? parts.sublist(1).join(separator ?? '┃') : null;
        if (inlineTrans != null && inlineTrans.trim().isNotEmpty) {
          translations.add(inlineTrans.trim());
        } else {
          final cleaned =
              inlinePrimary.replaceAll(RegExp(r'<[^>]*>'), '').trim();
          if (cleaned.isNotEmpty) translations.add(cleaned);
        }
      }

      final translationText = translations.isEmpty
          ? null
          : translations
              .where((e) => e.trim().isNotEmpty)
              .join(separator ?? '┃');

      final words = <CrcWord>[];
      bool hasWordTimestamps = false;
      for (final w in wordTagRe.allMatches(primaryText)) {
        final timeStr = w.group(1);
        final text = w.group(2) ?? '';
        if (timeStr == null || text.isEmpty) continue;
        final wordStartMs = parseTimeTagToMs(timeStr);
        if (wordStartMs == null) continue;
        final marks = WordMarkingUtil.analyze(text);
        words.add(CrcWord(
          Duration(milliseconds: wordStartMs),
          Duration.zero,
          text,
          marks: marks,
        ));
        hasWordTimestamps = true;
      }

      Duration lineLength = Duration.zero;
      final trimmedPrimary = primaryText.trimRight();
      final allEndMatches =
          timeOnlyTagRe.allMatches(trimmedPrimary).toList(growable: false);
      if (allEndMatches.isNotEmpty) {
        final last = allEndMatches.last;
        if (last.end == trimmedPrimary.length) {
          final endMs = parseTimeTagToMs(last.group(1) ?? '');
          if (endMs != null) {
            final end = Duration(milliseconds: endMs);
            final d = end - start;
            if (!d.isNegative) lineLength = d;
          }
        }
      }

      if (!hasWordTimestamps && primaryText.isNotEmpty) {
        final cleanedText = primaryText.replaceAll(RegExp(r'<[^>]*>'), '').trim();
        if (cleanedText.isNotEmpty) {
          final marks = WordMarkingUtil.analyze(cleanedText);
          words.add(CrcWord(start, Duration.zero, cleanedText, marks: marks));
        }
      }

      if (words.isEmpty) continue;

      parsedLines.add(CrcLine(
        start,
        lineLength,
        words,
        translationText?.isEmpty == true ? null : translationText,
      ));
    }

    if (parsedLines.isEmpty) return null;
    parsedLines.sort((a, b) => a.start.compareTo(b.start));

    for (int i = 0; i < parsedLines.length; i++) {
      final line = parsedLines[i];
      final nextStart =
          i < parsedLines.length - 1 ? parsedLines[i + 1].start : null;
      if (line.length == Duration.zero) {
        final lineLen = nextStart == null
            ? const Duration(seconds: 5)
            : (nextStart - line.start);
        line.length = lineLen.isNegative ? Duration.zero : lineLen;
      }

      if (line.words.isEmpty) continue;
      final words = line.words.cast<CrcWord>();
      for (int j = 0; j < words.length; j++) {
        final curr = words[j];
        final nextWordStart = j < words.length - 1 ? words[j + 1].start : null;
        final end = nextWordStart ?? (line.start + line.length);
        final d = end - curr.start;
        curr.length = d.isNegative
            ? Duration.zero
            : (d < const Duration(milliseconds: 50)
                ? const Duration(milliseconds: 50)
                : d);
      }
    }

    final finalLines = <LyricLine>[];
    const gapThreshold = Duration(milliseconds: 1200);
    for (int i = 0; i < parsedLines.length; i++) {
      final line = parsedLines[i];
      finalLines.add(line);

      if (i >= parsedLines.length - 1) continue;
      final nextStart = parsedLines[i + 1].start;
      final gapStart = line.start + line.length;
      final gapLen = nextStart - gapStart;
      if (gapLen > gapThreshold) {
        finalLines.add(
          LrcLine(
            gapStart,
            '',
            requiredIsBlank: true,
          )..length = gapLen,
        );
      }
    }

    // 为前奏间隙创建空白行（第一行歌词开始前有时间间隙）
    if (finalLines.isNotEmpty && finalLines.first.start > Duration.zero) {
      final firstLineStart = finalLines.first.start;
      finalLines.insert(
        0,
        LrcLine(
          Duration.zero,
          '',
          requiredIsBlank: true,
        )..length = firstLineStart,
      );
    }

    cleanLyricBlankLines(finalLines);
    return Crc(finalLines, source);
  }

  /// 智能清理空白行：
  /// 1. 移除连续的空白行（只保留第一个）
  /// 2. 移除时间间隔小于 800ms 的空白行（太短无意义）
  /// 3. 保留时长合理的间奏空白行（800ms ~ 10s）
  void _removeBlankLines() {
    cleanLyricBlankLines(lines);
  }

  /// 只支持读取 ID3V2, VorbisComment, Mp4Ilst 存储的内嵌歌词
  /// 以及相同目录相同文件名的 .lrc/.krc/.qrc/.yrc 外挂歌词
  /// 优先级：内嵌歌词 > YRC > QRC > KRC > LRC
  static Future<Lyric?> fromAudioPath(
    Audio belongTo, {
    String? separator = "┃",
  }) async {
    final audioPath = belongTo.path;
    final dir = p.dirname(audioPath);
    final baseName = p.basenameWithoutExtension(audioPath);

    final embeddedLyric = await getLyricFromPath(path: audioPath);
    if (embeddedLyric != null && embeddedLyric.isNotEmpty) {
      final lyric = Lrc.fromLrcTextAuto(embeddedLyric, LrcSource.local, separator: separator);
      if (lyric != null && lyric.lines.isNotEmpty) {
        return lyric;
      }
    }

    final extensions = ['.yrc', '.qrc', '.krc', '.lrc'];

    for (final ext in extensions) {
      final lyricPath = p.join(dir, '$baseName$ext');
      final lyricFile = File(lyricPath);

      if (await lyricFile.exists()) {
        try {
          final content = await lyricFile.readAsString();

          if (ext == '.yrc') {
            final vtsPath = p.join(dir, '$baseName.lrc');
            String? transContent;
            if (await File(vtsPath).exists()) {
              transContent = await File(vtsPath).readAsString();
            }
            final lyric = Yrc.fromYrcText(content, transContent);
            if (lyric.lines.isNotEmpty) return lyric;
          } else if (ext == '.qrc') {
            String? contentToParse = content;

            if (!content.trimLeft().startsWith('<?xml') &&
                !content.trimLeft().startsWith('<Qrc')) {
              final decrypted = await qrcDecrypt(
                encryptedQrc: await lyricFile.readAsBytes(),
                isLocal: true,
              );
              if (decrypted != null) {
                contentToParse = decrypted;
              } else {
                continue;
              }
            }

            final vtsPath = p.join(dir, '$baseName.lrc');
            String? transContent;
            if (await File(vtsPath).exists()) {
              transContent = await File(vtsPath).readAsString();
            }
            final lyric = Qrc.fromQrcText(contentToParse, transContent);
            if (lyric.lines.isNotEmpty) return lyric;
          } else if (ext == '.krc') {
            final lyric = Krc.fromKrcText(content);
            if (lyric.lines.isNotEmpty) return lyric;
          } else if (ext == '.lrc') {
            final lyric = Lrc.fromLrcTextAuto(content, LrcSource.local, separator: separator);
            if (lyric != null && lyric.lines.isNotEmpty) return lyric;
          }
        } catch (e) {
          continue;
        }
      }
    }

    return null;
  }
}
