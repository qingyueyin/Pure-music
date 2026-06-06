enum LyricFormat { local, web, netease, baidu, qqmusic, manual, lrc }

class Lyric {
  final List<LyricLine> lines;
  final LyricFormat source;
  final String? rawText;

  const Lyric(this.lines, [this.source = LyricFormat.local, this.rawText]);

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

class SyncLyricWord {
  final Duration start;
  Duration length;
  String content;
  bool obscene;

  SyncLyricWord(this.start, this.length, this.content)
      : obscene = false;
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
