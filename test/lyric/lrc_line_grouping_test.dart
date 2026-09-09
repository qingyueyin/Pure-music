import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';

void main() {
  test('keeps spaced romanization separate from line lyric translation', () {
    const source = '''
[00:42.156]心臓こじ开けて さらっと食べて
[00:42.156]shi n zo u ko ji a ke te sa ra tto ta be te
[00:42.156]将心脏撬开 轻描淡写地吞下
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, '心臓こじ开けて さらっと食べて');
    expect(line.romanLyric, 'shi n zo u ko ji a ke te sa ra tto ta be te');
    expect(line.translation, '将心脏撬开 轻描淡写地吞下');
  });

  test('keeps hangul original with romanization and chinese translation', () {
    const source = '''
[00:12.000]사랑해 너를
[00:12.000]sa rang hae neo reul
[00:12.000]我爱你
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, '사랑해 너를');
    expect(line.romanLyric, 'sa rang hae neo reul');
    expect(line.translation, '我爱你');
  });

  test('keeps hangul original when romanization is listed first', () {
    const source = '''
[00:12.000]sa rang hae
[00:12.000]사랑해
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, '사랑해');
    expect(line.romanLyric, 'sa rang hae');
    expect(line.translation, isNull);
  });

  test('keeps hangul original when romanization leads a three-line group', () {
    const source = '''
[00:12.000]sa rang hae neo reul
[00:12.000]사랑해 너를
[00:12.000]我爱你
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, '사랑해 너를');
    expect(line.romanLyric, 'sa rang hae neo reul');
    expect(line.translation, '我爱你');
  });

  test('keeps hangul original with chinese translation', () {
    const source = '''
[00:12.000]사랑해
[00:12.000]我爱你
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, '사랑해');
    expect(line.translation, '我爱你');
    expect(line.romanLyric, isNull);
  });

  test('keeps chinese original when hangul translation follows', () {
    const source = '''
[00:12.000]我爱你
[00:12.000]사랑해
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, '我爱你');
    expect(line.translation, '사랑해');
    expect(line.romanLyric, isNull);
  });

  test('keeps chinese original in a three-line group with hangul translation', () {
    const source = '''
[00:12.000]我爱你
[00:12.000]사랑해
[00:12.000]wo ai ni
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, '我爱你');
    expect(line.translation, '사랑해');
    expect(line.romanLyric, 'wo ai ni');
  });

  test('keeps hangul original when word timestamps use millisecond tags', () {
    const source = '''
[00:12.000]<0>사<120>랑<240>해
[00:12.000]sa rang hae
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<SyncLyricLine>().firstWhere(
      (line) => line.words.isNotEmpty,
    );

    expect(line.words.map((w) => w.content).join(), '사랑해');
    expect(line.romanLyric, 'sa rang hae');
  });

  test('keeps english original with chinese translation', () {
    const source = '''
[00:12.000]I love you
[00:12.000]我爱你
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, 'I love you');
    expect(line.translation, '我爱你');
    expect(line.romanLyric, isNull);
  });

  test('keeps chinese original with english translation not romanization', () {
    const source = '''
[00:12.000]夜空中最亮的星
[00:12.000]The brightest star in the night sky
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, '夜空中最亮的星');
    expect(line.translation, 'The brightest star in the night sky');
    expect(line.romanLyric, isNull);
  });

  test('keeps chinese original with jyutping romanization', () {
    const source = '''
[00:12.000]我钟意你
[00:12.000]ngo5 zung1 ji3 nei5
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, '我钟意你');
    expect(line.romanLyric, 'ngo5 zung1 ji3 nei5');
    expect(line.translation, isNull);
  });

  test('keeps chinese original with pinyin romanization', () {
    const source = '''
[00:12.000]夜空中最亮的星
[00:12.000]ye4 kong1 zhong1 zui4 liang4 de xing1
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, '夜空中最亮的星');
    expect(line.romanLyric, 'ye4 kong1 zhong1 zui4 liang4 de xing1');
    expect(line.translation, isNull);
  });

  test('keeps cyrillic original with chinese translation', () {
    const source = '''
[00:12.000]Я люблю тебя
[00:12.000]我爱你
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, 'Я люблю тебя');
    expect(line.translation, '我爱你');
    expect(line.romanLyric, isNull);
  });

  test('keeps cyrillic original when chinese translation is listed first', () {
    const source = '''
[00:12.000]我爱你
[00:12.000]Я люблю тебя
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, 'Я люблю тебя');
    expect(line.translation, '我爱你');
    expect(line.romanLyric, isNull);
  });

  test('keeps japanese original when chinese translation is listed first', () {
    const source = '''
[00:12.000]将心脏撬开
[00:12.000]心臓こじ開けて
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines.whereType<LrcLine>().singleWhere(
      (line) => line.content.isNotEmpty,
    );

    expect(line.content, '心臓こじ開けて');
    expect(line.translation, '将心脏撬开');
    expect(line.romanLyric, isNull);
  });

  test('uses song-level sampling for kanji-only japanese original', () {
    const source = '''
[00:10.000]将心脏撬开
[00:10.000]心臓こじ開けて
[00:20.000]将心脏撬开
[00:20.000]心臓
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final lines = lyric.lines
        .whereType<LrcLine>()
        .where((line) => line.content.isNotEmpty)
        .toList();

    expect(lines[0].content, '心臓こじ開けて');
    expect(lines[0].translation, '将心脏撬开');
    expect(lines[1].content, '心臓');
    expect(lines[1].translation, '将心脏撬开');
  });
}
