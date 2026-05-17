enum LyricFormat { local, web, netease, baidu, qqmusic, manual, lrc }

class Lyric {
  final List<LyricLine> lines;
  final LyricFormat source;

  const Lyric(this.lines, [this.source = LyricFormat.local]);

  static const Lyric empty = Lyric([]);

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;
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

  SyncLyricLine(super.start, super.length, this.words, [super.translation, String? romanLyric]) {
    this.romanLyric = romanLyric;
  }

  String get content => words.map((w) => w.content).join();
}

class SyncLyricWord {
  final Duration start;
  Duration length;
  final String content;
  bool obscene;

  SyncLyricWord(this.start, this.length, this.content)
      : obscene = false;
}

class UnsyncLyricLine extends LyricLine {
  final String content;

  UnsyncLyricLine(
    Duration start,
    this.content, {
    Duration length = Duration.zero,
    String? translation,
  }) : super(start, length, translation);
}
