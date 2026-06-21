enum LyricFormat { local, web, netease, baidu, qqmusic, manual, lrc }

class Lyric {
  final List<LyricLine> lines;
  final LyricFormat source;
  final String? rawText;
  final bool isDuet; // TTML 对唱标记：同时存在 v1 和 v2

  const Lyric(this.lines, [this.source = LyricFormat.local, this.rawText, this.isDuet = false]);

  static const Lyric empty = Lyric([]);

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;

  bool get isWordByWord => lines.isNotEmpty && lines.first is SyncLyricLine;
}

class LyricLine {
  final Duration start;
  Duration length;
  String? translation;
  String? romanLyric;

  LyricLine(this.start, this.length, [this.translation])
      : romanLyric = null;
}

class SyncLyricLine extends LyricLine {
  final List<SyncLyricWord> words;
  String? agent;
  String? bgText;
  List<SyncLyricWord> bgWords = [];
  String? bgTranslation;
  Duration? bgStart;
  Duration? bgEnd;

  SyncLyricLine(super.start, super.length, this.words, [super.translation, String? romanLyric]) {
    this.romanLyric = romanLyric;
  }

  String get content => words.map((w) => w.content).join();
}

class RubyTag {
  final String text;
  final Duration start;
  final Duration length;

  RubyTag(this.text, this.start, this.length);
}

class SyncLyricWord {
  final Duration start;
  Duration length;
  String content;
  bool obscene;
  bool isMerged;
  int? emptyBeat;  // amll:empty-beat 空拍标记
  List<RubyTag>? ruby;  // tts:ruby 注音

  SyncLyricWord(this.start, this.length, this.content)
      : obscene = false,
        isMerged = false,
        emptyBeat = null,
        ruby = null;
}

class UnsyncLyricLine extends LyricLine {
  String content;

  UnsyncLyricLine(
    Duration start,
    this.content, {
    Duration length = Duration.zero,
    String? translation,
  }) : super(start, length, translation);
}
