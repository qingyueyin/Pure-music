import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_timing_preprocessor.dart';

LrcLine _line(int startMs, int lengthMs, String content,
    {bool isBlank = false}) {
  return LrcLine(
    Duration(milliseconds: startMs),
    content,
    isBlank: isBlank,
    length: Duration(milliseconds: lengthMs),
  );
}

void main() {
  group('LyricTimingPreprocessor', () {
    test('advance start for normal line', () {
      final lyric = Lrc([
        _line(0, 2000, 'A'),
        _line(2600, 1600, 'B'),
      ], LrcSource.local);

      final result = const LyricTimingPreprocessor().preprocess(lyric);

      expect(result.effectiveLineStartMs, [0, 2380]);
    });

    test('interlude-friendly: large gap uses small advance', () {
      final lyric = Lrc([
        _line(0, 2000, 'A'),
        _line(7000, 1200, 'B'),
      ], LrcSource.local);

      final result = const LyricTimingPreprocessor().preprocess(lyric);

      expect(result.effectiveLineStartMs, [0, 6920]);
    });

    test('overlap clean: clamp early enter when previous line is long', () {
      final lyric = Lrc([
        _line(0, 5000, 'A'),
        _line(5050, 1200, 'B'),
      ], LrcSource.local);

      final result = const LyricTimingPreprocessor().preprocess(lyric);

      expect(result.effectiveLineStartMs, [0, 4880]);
    });

    test('transition line keeps raw start and does not advance', () {
      final lyric = Lrc([
        _line(0, 2000, 'A'),
        _line(3000, 1000, '', isBlank: true),
      ], LrcSource.local);

      final result = const LyricTimingPreprocessor().preprocess(lyric);

      expect(result.effectiveLineStartMs, [0, 3000]);
    });

    test('advance can be disabled to keep raw line start', () {
      final lyric = Lrc([
        _line(0, 2000, 'A'),
        _line(2600, 1600, 'B'),
      ], LrcSource.local);

      final result = const LyricTimingPreprocessor(advanceMs: 0).preprocess(
        lyric,
      );

      expect(result.effectiveLineStartMs, [0, 2600]);
    });

    test('effective start remains monotonic with duplicated timestamps', () {
      final lyric = Lyric([
        _line(1000, 2000, 'A'),
        _line(1000, 1000, 'B'),
      ]);

      final result = const LyricTimingPreprocessor().preprocess(lyric);

      expect(result.effectiveLineStartMs.first, 1000);
      expect(result.effectiveLineStartMs[1],
          greaterThan(result.effectiveLineStartMs[0]));
      expect(result.effectiveLineStartMs[1], 2880);
    });
  });
}
