import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/ttml.dart';

void main() {
  group('TTML spacing', () {
    test('keeps spaces stored at the start of timed spans', () {
      final lyric = Ttml.fromTtmlText(_ttml('''
<p begin="00:00.000" end="00:02.000">
  <span begin="00:00.000" end="00:00.400">We</span><span begin="00:00.400" end="00:00.800"> should</span><span begin="00:00.800" end="00:01.200"> be</span><span begin="00:01.200" end="00:02.000"> dancing</span>
</p>
'''));

      final line = lyric!.lines.single as TtmlLine;
      expect(line.content, 'We should be dancing');
      expect(
        line.words.map((w) => w.content),
        ['We', ' should', ' be', ' dancing'],
      );
    });

    test('merges adjacent latin fragments inside the same word', () {
      final lyric = Ttml.fromTtmlText(_ttml('''
<p begin="00:00.000" end="00:03.000">
  <span begin="00:00.000" end="00:00.500">go</span><span begin="00:00.500" end="00:00.800"> a</span><span begin="00:00.800" end="00:01.100">way</span><span begin="00:01.100" end="00:01.600"> hun</span><span begin="00:01.600" end="00:02.000">dred</span>
</p>
'''));

      final line = lyric!.lines.single as TtmlLine;
      expect(line.content, 'go away hundred');
      expect(line.words.map((w) => w.content), ['go', ' away', ' hundred']);
    });

    test('keeps CJK and kana timing spans separate', () {
      final lyric = Ttml.fromTtmlText(_ttml('''
<p begin="00:00.000" end="00:02.000">
  <span begin="00:00.000" end="00:00.400">太</span><span begin="00:00.400" end="00:00.800">陽</span><span begin="00:00.800" end="00:01.200">まっ</span><span begin="00:01.200" end="00:02.000">た</span>
</p>
'''));

      final line = lyric!.lines.single as TtmlLine;
      expect(line.content, '太陽まった');
      expect(line.words.map((w) => w.content), ['太', '陽', 'まっ', 'た']);
    });
    test('creates timing for direct background text', () {
      final lyric = Ttml.fromTtmlText(_ttml('''
<p begin="00:00.000" end="00:03.000">
  <span begin="00:00.000" end="00:03.000">Main</span>
  <span ttm:role="x-bg" begin="00:00.500" end="00:02.500">Oh</span>
</p>
'''));

      final line = lyric!.lines.single as TtmlLine;
      expect(line.bgText, 'Oh');
      expect(line.bgWords, hasLength(1));
      expect(line.bgWords.single.content, 'Oh');
      expect(line.bgWords.single.start, const Duration(milliseconds: 500));
      expect(line.bgWords.single.length, const Duration(seconds: 2));
    });
  });
}

String _ttml(String body) => '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <body>
    <div>
      $body
    </div>
  </body>
</tt>
''';
