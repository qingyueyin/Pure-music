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
    final line = lyric.lines
        .whereType<LrcLine>()
        .singleWhere((line) => line.content.isNotEmpty);

    expect(line.content, '心臓こじ开けて さらっと食べて');
    expect(line.romanLyric, 'shi n zo u ko ji a ke te sa ra tto ta be te');
    expect(line.translation, '将心脏撬开 轻描淡写地吞下');
  });
}
