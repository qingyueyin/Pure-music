/// 歌词格式类型
enum LyricFormat {
  lrc,
  enhanced,
  wordByWord,
  yrc,
  qrc,
  krc,
  ttml,
  unknown,
}

/// 逐字条目
class WordEntry {
  final Duration start;
  Duration length;
  final String content;
  Duration nextTime;

  WordEntry({
    required this.start,
    this.length = Duration.zero,
    required this.content,
    this.nextTime = Duration.zero,
  });
}

/// 逐行歌词条目
/// 参考 ZeroBit-Player LyricEntry
class LyricEntry {
  final Duration start;
  Duration nextTime;
  final String content;
  String? translation;
  String? romanization;
  List<WordEntry>? words;

  LyricEntry({
    required this.start,
    this.nextTime = Duration.zero,
    required this.content,
    this.translation,
    this.romanization,
    this.words,
  });
}

/// 解析后的歌词结果
class ParsedLyricResult {
  final List<LyricEntry> lines;
  final LyricFormat format;
  final Duration offset;
  final Map<String, String> tags;

  ParsedLyricResult({
    required this.lines,
    this.format = LyricFormat.unknown,
    this.offset = Duration.zero,
    Map<String, String>? tags,
  }) : tags = tags ?? {};

  /// 常用元数据便捷访问
  String? get title => tags['ti']?.isNotEmpty == true ? tags['ti'] : null;
  String? get artist => tags['ar']?.isNotEmpty == true ? tags['ar'] : null;
  String? get album => tags['al']?.isNotEmpty == true ? tags['al'] : null;
  String? get author => tags['au']?.isNotEmpty == true ? tags['au'] : null;
  String? get lyricist => tags['by']?.isNotEmpty == true ? tags['by'] : null;

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;
  bool get hasWordByWord =>
      format == LyricFormat.wordByWord ||
      format == LyricFormat.yrc ||
      format == LyricFormat.qrc ||
      format == LyricFormat.krc;

  /// 歌词类型标签
  String get formatLabel {
    return switch (format) {
      LyricFormat.lrc => '逐行',
      LyricFormat.enhanced => '增强逐行',
      LyricFormat.wordByWord => '逐字',
      LyricFormat.yrc => '逐字(YRC)',
      LyricFormat.qrc => '逐字(QRC)',
      LyricFormat.krc => '逐字(KRC)',
      LyricFormat.ttml => 'TTML',
      LyricFormat.unknown => '未知',
    };
  }

  /// 应用 offset 到所有行
  ParsedLyricResult applyOffset(Duration offset) {
    if (offset == Duration.zero) return this;
    return ParsedLyricResult(
      format: format,
      offset: offset,
      tags: Map.from(tags),
      lines: lines.map((line) {
        return LyricEntry(
          start: Duration(
            milliseconds: (line.start.inMilliseconds + offset.inMilliseconds)
                .clamp(0, line.start.inMilliseconds + offset.inMilliseconds),
          ),
          nextTime: Duration(
            milliseconds: (line.nextTime.inMilliseconds +
                    offset.inMilliseconds)
                .clamp(0, line.nextTime.inMilliseconds + offset.inMilliseconds),
          ),
          content: line.content,
          translation: line.translation,
          romanization: line.romanization,
          words: line.words
              ?.map((w) => WordEntry(
                    start: Duration(
                      milliseconds: (w.start.inMilliseconds +
                              offset.inMilliseconds)
                          .clamp(
                              0,
                              w.start.inMilliseconds + offset.inMilliseconds),
                    ),
                    length: w.length,
                    content: w.content,
                    nextTime: Duration(
                      milliseconds: (w.nextTime.inMilliseconds +
                              offset.inMilliseconds)
                          .clamp(
                              0,
                              w.nextTime.inMilliseconds +
                                  offset.inMilliseconds),
                    ),
                  ))
              .toList(),
        );
      }).toList(),
    );
  }
}
