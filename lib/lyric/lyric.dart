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
  String? romanLyric;

  LyricLine(this.start, this.length, [this.translation])
      : romanLyric = null;
}

class SyncLyricLine extends LyricLine {
  final List<SyncLyricWord> words;

  SyncLyricLine(super.start, super.length, this.words, [super.translation]);

  String get content => words.map((w) => w.content).join();
}

enum WordMark {
  punctuation,
  emoji,
  descender,
  longNote,
  singleChar,
}

class SyncLyricWord {
  final Duration start;
  Duration length;
  final String content;
  bool obscene;
  final Set<WordMark> marks;

  SyncLyricWord(this.start, this.length, this.content, {Set<WordMark>? marks})
      : obscene = false,
        marks = marks ?? const {};

  bool hasMark(WordMark mark) => marks.contains(mark);

  bool get isPunctuation => hasMark(WordMark.punctuation);
  bool get isEmoji => hasMark(WordMark.emoji);
  bool get hasDescender => hasMark(WordMark.descender);
  bool get isLongNote => hasMark(WordMark.longNote);
  bool get isSingleChar => hasMark(WordMark.singleChar);
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
