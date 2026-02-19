import 'dart:math';

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';

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
  EnhancedLrcWord(super.start, super.length, super.content);
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
  CrcWord(super.start, super.length, super.content);
}

class LrcLine extends UnsyncLyricLine {
  bool isBlank;
  Duration length;

  LrcLine(super.start, super.content,
      {required this.isBlank, this.length = Duration.zero});

  static LrcLine defaultLine = LrcLine(
    Duration.zero,
    "无歌词",
    isBlank: false,
    length: Duration.zero,
  );

  @override
  String toString() {
    return {"time": start.toString(), "content": content}.toString();
  }

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

    return LrcLine(
      Duration(
        milliseconds: max(inMilliseconds - (offset ?? 0), 0),
      ),
      content,
      isBlank: content.isEmpty,
    );
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

  /// line_1 and line_2时间戳相同，合并成line_1[separator]line_2
  Lrc _combineLrcLine(String separator) {
    List<LrcLine> combinedLines = [];
    var buf = StringBuffer();
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].start != lines[i - 1].start) {
        buf.write((lines[i - 1] as UnsyncLyricLine).content);
        combinedLines.add(LrcLine(
          lines[i - 1].start,
          buf.toString(),
          isBlank: (lines[i - 1] as LrcLine).isBlank,
          length: (lines[i - 1] as LrcLine).length,
        ));
        buf.clear();
      } else {
        buf.write((lines[i - 1] as UnsyncLyricLine).content);
        buf.write(separator);
      }
    }
    if (lines.isNotEmpty) {
      buf.write((lines.last as UnsyncLyricLine).content);
      combinedLines.add(LrcLine(
        lines.last.start,
        buf.toString(),
        isBlank: (lines.last as LrcLine).isBlank,
        length: (lines.last as LrcLine).length,
      ));
    }

    return Lrc(combinedLines, source);
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

    final result = Lrc(lines, source);
    result._sort();

    if (separator == null) {
      return result;
    }

    return result._combineLrcLine(separator);
  }

  static Lyric? fromLrcTextAuto(
    String lrc,
    LrcSource source, {
    String? separator,
  }) {
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
        final part = separator == null ? raw : raw.split(separator!).first;
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
          : contents[primaryIndex].split(separator!);
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
            : contents[i].split(separator!);
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

        words.add(
          EnhancedLrcWord(
            Duration(milliseconds: wordStartMs),
            Duration.zero,
            text,
          ),
        );
        hasWordTimestamps = true;
      }

      if (!hasWordTimestamps && primaryText.isNotEmpty) {
        words.add(
          EnhancedLrcWord(
            start,
            Duration.zero,
            primaryText,
          ),
        );
      }

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

    return EnhancedLrc(parsedLines, source);
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
        final part = separator == null ? raw : raw.split(separator!).first;
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
          : contents[primaryIndex].split(separator!);
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
            : contents[i].split(separator!);
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
        words.add(CrcWord(
          Duration(milliseconds: wordStartMs),
          Duration.zero,
          text,
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
        words.add(CrcWord(start, Duration.zero, primaryText));
      }

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
            isBlank: true,
            length: gapLen,
          ),
        );
      }
    }

    return Crc(finalLines, source);
  }

  /// 只支持读取 ID3V2, VorbisComment, Mp4Ilst 存储的内嵌歌词
  /// 以及相同目录相同文件名的 .lrc 外挂歌词（utf-8 or utf-16）
  static Future<Lyric?> fromAudioPath(
    Audio belongTo, {
    String? separator = "┃",
  }) async {
    Lyric? lyric = await getLyricFromPath(path: belongTo.path).then((value) {
      if (value == null) {
        return null;
      }
      return Lrc.fromLrcTextAuto(value, LrcSource.local, separator: separator);
    });

    return lyric;
  }
}
