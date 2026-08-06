import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';

void main() {
  test('does not infer background vocals from enhanced LRC', () {
    const source = '''
[01:47.690]<01:47.690>i can't let it go<01:49.460>
[01:47.690]哦
[01:49.460]<01:49.460>oh<01:49.490>
[01:49.460]<01:49.460>know <01:49.800>that <01:50.100>i can't get over you<01:52.000>
[01:49.460]我清楚我不能征服你
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final contentLines = lyric.lines
        .whereType<SyncLyricLine>()
        .where((line) => line.words.isNotEmpty)
        .toList();

    expect(contentLines, hasLength(2));
    expect(contentLines.first.translation, '哦');
    expect(contentLines.last.content, "know that i can't get over you");
    expect(contentLines.last.translation, '我清楚我不能征服你');
    expect(contentLines.last.romanLyric, 'oh');
    expect(contentLines.last.bgText, isNull);
    expect(contentLines.last.bgWords, isEmpty);
  });

  test('keeps aligned timed pronunciation as romanization', () {
    const source = '''
[00:10.000]<00:10.000>怖<00:10.500>い<00:11.000>
[00:10.000]<00:10.000>ko<00:10.500>wai<00:11.000>
[00:10.000]可怕
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines
        .whereType<SyncLyricLine>()
        .singleWhere((line) => line.words.isNotEmpty);

    expect(line.content, '怖い');
    expect(line.translation, '可怕');
    expect(line.romanLyric, 'kowai');
    expect(line.bgText, isNull);
  });

  test('does not expose Lyricify attribute rows as background vocals', () {
    const source = '''
[00:10.000][0]hello(100,400)
[00:10.000][6]echo(100,400)
''';

    final lyric = Lrc.fromLrcTextAuto(
      source,
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines
        .whereType<SyncLyricLine>()
        .singleWhere((line) => line.words.isNotEmpty);

    expect(line.translation, 'echo');
    expect(line.bgText, isNull);
    expect(line.bgWords, isEmpty);
  });
}
