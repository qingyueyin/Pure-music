import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/vtt.dart';

void main() {
  group('VTT parse', () {
    test('parses basic cues without hour segment', () {
      final lyric = Vtt.fromVttText('''
WEBVTT

00:00.000 --> 00:02.000
Hello world

00:02.500 --> 00:04.000
Second line

00:05.000 --> 00:06.000
Third line
''');
      expect(lyric, isNotNull);
      expect(lyric!.lines, hasLength(3));
      final first = lyric.lines[0] as VttLine;
      expect(first.content, 'Hello world');
      expect(first.start, Duration.zero);
      expect(first.length, const Duration(seconds: 2));
      expect(lyric.lines[1].start, const Duration(milliseconds: 2500));
    });

    test('parses cues with hour segment', () {
      final lyric = Vtt.fromVttText('''
WEBVTT

00:00:01.000 --> 00:00:02.000
First

00:00:03.000 --> 00:00:04.500
Second
''');
      expect(lyric!.lines, hasLength(2));
      expect(lyric.lines[0].start, const Duration(seconds: 1));
      expect(lyric.lines[1].start, const Duration(seconds: 3));
    });

    test('parses unlimited hour segment', () {
      final lyric = Vtt.fromVttText('''
WEBVTT

00:00.000 --> 00:02.000
Start

999:59:59.000 --> 1000:00:00.000
Long cue
''');
      final nonBlank = lyric!.lines
          .where((l) => (l as VttLine).words.isNotEmpty)
          .toList();
      expect(nonBlank, hasLength(2));
      expect(
        (nonBlank[1] as VttLine).start,
        const Duration(hours: 999, minutes: 59, seconds: 59),
      );
    });

    test('strips inline tags and voice spans', () {
      final lyric = Vtt.fromVttText('''
WEBVTT

00:00.000 --> 00:02.000
<v Bob>Hello</v> <c.yellow>world</c.yellow> <i>!</i>
''');
      final line = lyric!.lines.single as VttLine;
      expect(line.content, 'Hello world !');
    });

    test('joins multi-line cue text into one line', () {
      final lyric = Vtt.fromVttText('''
WEBVTT

00:00.000 --> 00:02.000
Line one
line two

00:03.000 --> 00:04.000
Next
''');
      expect(lyric!.lines, hasLength(2));
      final first = lyric.lines[0] as VttLine;
      expect(first.content, 'Line one line two');
    });

    test('splits translation by separator', () {
      final lyric = Vtt.fromVttText(
        '''
WEBVTT

00:00.000 --> 00:02.000
原文┃translation
''',
        separator: '┃',
      );
      final line = lyric!.lines.single as VttLine;
      expect(line.content, '原文');
      expect(line.translation, 'translation');
    });

    test('inserts prelude and interlude blank lines', () {
      final lyric = Vtt.fromVttText('''
WEBVTT

00:06.000 --> 00:08.000
First

00:20.000 --> 00:22.000
Second
''');
      expect(lyric!.lines, hasLength(4));
      final prelude = lyric.lines[0] as VttLine;
      expect(prelude.content, isEmpty);
      expect(prelude.start, Duration.zero);
      expect(prelude.length, const Duration(seconds: 6));
      final interlude = lyric.lines[2] as VttLine;
      expect(interlude.content, isEmpty);
      expect(interlude.start, const Duration(seconds: 8));
      expect(interlude.length, const Duration(seconds: 12));
    });

    test('does not treat NOTE-prefixed cue identifiers as comment blocks', () {
      final lyric = Vtt.fromVttText('''
WEBVTT

00:00.000 --> 00:02.000
Normal line

NOTES
00:03.000 --> 00:04.000
Identified line

STYLE-1
00:05.000 --> 00:06.000
Style cue
''');
      expect(lyric!.lines, hasLength(3));
      expect((lyric.lines[0] as VttLine).content, 'Normal line');
      expect((lyric.lines[1] as VttLine).content, 'Identified line');
      expect((lyric.lines[2] as VttLine).content, 'Style cue');
    });

    test('keeps literal encoded tags as text', () {
      final lyric = Vtt.fromVttText('''
WEBVTT

00:00.000 --> 00:02.000
Say &lt;i&gt;hello&lt;/i&gt;
''');
      final line = lyric!.lines.single as VttLine;
      expect(line.content, 'Say <i>hello</i>');
    });

    test('skips NOTE blocks and invalid timings', () {
      final lyric = Vtt.fromVttText('''
WEBVTT

NOTE this is a comment
that spans two lines

00:00.000 --> 00:02.000
Valid

99:99.999 --> 100:00.000
Invalid seconds

00:05.000 --> 00:06.000
Also valid
''');
      expect(lyric!.lines, hasLength(2));
      expect((lyric.lines[0] as VttLine).content, 'Valid');
    });

    test('parses cues without WEBVTT header', () {
      final lyric = Vtt.fromVttText('''
00:00.000 --> 00:02.000
No header
''');
      expect(lyric!.lines, hasLength(1));
    });

    test('returns null for empty or note-only content', () {
      expect(Vtt.fromVttText(''), isNull);
      expect(Vtt.fromVttText('NOTE nothing here\n'), isNull);
    });
  });
}
