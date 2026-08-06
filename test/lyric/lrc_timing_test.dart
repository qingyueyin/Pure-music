import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';

void main() {
  test('enhanced LRC keeps an explicit single-word end timestamp', () {
    final lyric = Lrc.fromLrcTextAuto(
      '[00:31.519] <00:31.519>Check<00:31.830>\n'
      '[00:31.519]听好了\n'
      '[00:32.163] <00:32.163>You <00:32.316>can<00:32.508>',
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines
        .whereType<SyncLyricLine>()
        .firstWhere((line) => line.content.trim() == 'Check');

    expect(line.words, hasLength(1));
    expect(line.words.single.length, const Duration(milliseconds: 311));
  });

  test('enhanced LRC keeps adjacent original and translation groups separate',
      () {
    final lyric = Lrc.fromLrcTextAuto(
      '[01:04.190] <01:04.190>oh<01:04.220>\n'
      '[01:04.190]我清楚我不能征服你\n'
      '[01:04.220] <01:04.220>know <01:04.524>that <01:04.828>i '
      '<01:05.132>can\'t <01:05.436>get <01:05.740>over '
      '<01:06.044>you<01:06.350>\n'
      '[01:04.220]因为我眼中只有你',
      LyricFormat.local,
      separator: '┃',
    )!;
    final lines = lyric.lines
        .whereType<SyncLyricLine>()
        .where((line) => line.words.isNotEmpty)
        .toList();

    expect(lines, hasLength(2));
    expect(lines[0].content.trim(), 'oh');
    expect(lines[0].translation, '我清楚我不能征服你');
    expect(lines[0].bg, isNull);
    expect(lines[1].content.trim(), "know that i can't get over you");
    expect(lines[1].translation, '因为我眼中只有你');
    expect(lines[1].bg, isNull);
  });

  test('enhanced LRC still groups a slightly offset translation', () {
    final lyric = Lrc.fromLrcTextAuto(
      '[00:10.000] <00:10.000>hello<00:10.500>\n'
      '[00:10.020]你好',
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines
        .whereType<SyncLyricLine>()
        .singleWhere((line) => line.words.isNotEmpty);

    expect(line.content, 'hello');
    expect(line.translation, '你好');
  });

  test('enhanced LRC still groups an aligned timed translation', () {
    final lyric = Lrc.fromLrcTextAuto(
      '[00:10.000] <00:10.000>hello <00:10.500>world<00:11.000>\n'
      '[00:10.020] <00:10.020>你<00:10.500>好<00:11.020>',
      LyricFormat.local,
      separator: '┃',
    )!;
    final line = lyric.lines
        .whereType<SyncLyricLine>()
        .singleWhere((line) => line.words.isNotEmpty);

    expect(line.content, 'hello world');
    expect(line.translation, '你好');
  });
}
