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
}
