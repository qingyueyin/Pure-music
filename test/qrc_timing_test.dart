import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/qrc.dart';
import 'package:pure_music/lyric/lyric.dart';

void main() {
  test('QRC words align to line start (relative timestamps)', () {
    const qrcText = '''
[offset:0]
[4000,1000]你(0,200)好(200,300)
''';

    final lyric = Qrc.fromQrcText(qrcText);
    expect(lyric.lines, isNotEmpty);

    final line = lyric.lines.first as SyncLyricLine;
    expect(line.start.inMilliseconds, 4000);
    expect(line.length.inMilliseconds, 1000);

    expect(line.words.length, 2);
    expect(line.words[0].content, '你');
    expect(line.words[0].start.inMilliseconds, 4000);
    expect(line.words[0].length.inMilliseconds, 200);
    expect(line.words[1].content, '好');
    expect(line.words[1].start.inMilliseconds, 4200);
    expect(line.words[1].length.inMilliseconds, 300);
  });

  test('QRC word progress uses absolute word start', () {
    const qrcText = '[4000,1000]你(0,200)好(200,300)';
    final lyric = Qrc.fromQrcText(qrcText);
    final line = lyric.lines.first as SyncLyricLine;
    final word0 = line.words.first;

    final posInMs = 4100.0;
    final progress =
        ((posInMs - word0.start.inMilliseconds) / word0.length.inMilliseconds)
            .clamp(0.0, 1.0);

    expect(progress, closeTo(0.5, 1e-9));
  });

  test('QRC words keep line-adjusted absolute timestamps when offset exists',
      () {
    const qrcText = '''
[offset:100]
[4000,1000]你(0,200)好(200,300)
''';

    final lyric = Qrc.fromQrcText(qrcText);
    final line = lyric.lines.first as SyncLyricLine;

    expect(line.start.inMilliseconds, 3900);
    expect(line.words[0].start.inMilliseconds, 3900);
    expect(line.words[1].start.inMilliseconds, 4100);
  });
}
