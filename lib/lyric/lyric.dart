class Lyric {
  final List<LyricLine> lines;

  const Lyric(this.lines);

  static const Lyric empty = Lyric([]);

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;
}

class LyricLine {
  final Duration start;
  Duration length;
  String? translation;

  LyricLine(this.start, this.length, [this.translation]);
}

class SyncLyricLine extends LyricLine {
  final List<SyncLyricWord> words;

  SyncLyricLine(super.start, super.length, this.words, [super.translation]);

  String get content => words.map((w) => w.content).join();
}

class SyncLyricWord {
  final Duration start;
  Duration length;
  final String content;

  SyncLyricWord(this.start, this.length, this.content);
}

class UnsyncLyricLine extends LyricLine {
  final String content;

  UnsyncLyricLine(Duration start, this.content, [String? translation])
      : super(start, Duration.zero, translation);
}
