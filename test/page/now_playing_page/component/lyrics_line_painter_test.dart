import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';

void main() {
  group('lyricHighlightTimeMs', () {
    test('keeps the final lyric line on its authored timing', () {
      expect(
        lyricHighlightTimeMs(
          currentTimeMs: 9800,
          lineStartMs: 8000,
          lastWordEndMs: 10000,
          deadlineMs: null,
        ),
        9800,
      );
    });

    test('keeps catch-up when another lyric line follows', () {
      final adjusted = lyricHighlightTimeMs(
        currentTimeMs: 9800,
        lineStartMs: 8000,
        lastWordEndMs: 10100,
        deadlineMs: 10000,
      );

      expect(adjusted, greaterThan(9800));
    });

    test(
      'accelerates the tail when its deadline is just after the final word',
      () {
        final adjusted = lyricHighlightTimeMs(
          currentTimeMs: 9900,
          lineStartMs: 8000,
          lastWordEndMs: 10000,
          deadlineMs: 10032,
        );

        expect(adjusted, greaterThan(9900));
      },
    );

    test('never moves highlight time backwards after a late frame', () {
      final adjusted = lyricHighlightTimeMs(
        currentTimeMs: 10150,
        lineStartMs: 8000,
        lastWordEndMs: 10000,
        deadlineMs: 10032,
      );

      expect(adjusted, 10150);
    });
  });

  group('lyricWordEffect', () {
    const typicalLine = Duration(milliseconds: 500);

    test('keeps ordinary short words unchanged', () {
      expect(
        lyricWordEffect(
          duration: const Duration(milliseconds: 749),
          lineMedianDuration: typicalLine,
          isLineEnding: false,
        ),
        LyricWordEffect.none,
      );
    });

    test('scales words at the absolute threshold', () {
      expect(
        lyricWordEffect(
          duration: const Duration(milliseconds: 950),
          lineMedianDuration: typicalLine,
          isLineEnding: false,
        ),
        LyricWordEffect.scale,
      );
    });

    test('scales shorter words that stand out from the line', () {
      expect(
        lyricWordEffect(
          duration: const Duration(milliseconds: 750),
          lineMedianDuration: const Duration(milliseconds: 400),
          isLineEnding: false,
        ),
        LyricWordEffect.scale,
      );
    });

    test('adds glow at the absolute threshold', () {
      expect(
        lyricWordEffect(
          duration: const Duration(milliseconds: 1600),
          lineMedianDuration: typicalLine,
          isLineEnding: false,
        ),
        LyricWordEffect.scaleAndGlow,
      );
    });

    test('adds glow to a clear relative long note', () {
      expect(
        lyricWordEffect(
          duration: const Duration(milliseconds: 1200),
          lineMedianDuration: const Duration(milliseconds: 500),
          isLineEnding: false,
        ),
        LyricWordEffect.scaleAndGlow,
      );
    });

    test('lets a moderately long line ending glow', () {
      expect(
        lyricWordEffect(
          duration: const Duration(milliseconds: 1200),
          lineMedianDuration: const Duration(milliseconds: 600),
          isLineEnding: true,
        ),
        LyricWordEffect.scaleAndGlow,
      );
    });
  });

  group('lyricCharacterScale', () {
    const duration = Duration(milliseconds: 1600);

    test('rests at the original size at both ends', () {
      expect(
        lyricCharacterScale(
          effect: LyricWordEffect.scaleAndGlow,
          duration: duration,
          lineMedianDuration: const Duration(milliseconds: 500),
          progress: 0,
        ),
        1.0,
      );
      expect(
        lyricCharacterScale(
          effect: LyricWordEffect.scaleAndGlow,
          duration: duration,
          lineMedianDuration: const Duration(milliseconds: 500),
          progress: 1,
        ),
        1.0,
      );
    });

    test('keeps the peak restrained', () {
      final scale = lyricCharacterScale(
        effect: LyricWordEffect.scaleAndGlow,
        duration: duration,
        lineMedianDuration: const Duration(milliseconds: 500),
        progress: 0.5,
      );
      expect(scale, greaterThanOrEqualTo(1.15));
      expect(scale, lessThanOrEqualTo(1.26));
    });

    test('uses the same parabola on both sides of the peak', () {
      final risingScale = lyricCharacterScale(
        effect: LyricWordEffect.scale,
        duration: duration,
        lineMedianDuration: const Duration(milliseconds: 500),
        progress: 0.25,
      );
      final fallingScale = lyricCharacterScale(
        effect: LyricWordEffect.scale,
        duration: duration,
        lineMedianDuration: const Duration(milliseconds: 500),
        progress: 0.75,
      );
      expect(fallingScale, closeTo(risingScale, 0.0001));
    });

    test('raises the peak for more prominent long notes', () {
      final ordinaryScale = lyricCharacterScale(
        effect: LyricWordEffect.scale,
        duration: const Duration(milliseconds: 950),
        lineMedianDuration: const Duration(milliseconds: 600),
        progress: 0.5,
      );
      final prominentScale = lyricCharacterScale(
        effect: LyricWordEffect.scale,
        duration: const Duration(milliseconds: 2200),
        lineMedianDuration: const Duration(milliseconds: 500),
        progress: 0.5,
      );
      expect(prominentScale, greaterThan(ordinaryScale));
    });
  });

  group('lyricWrappedWordReveal', () {
    test('matches whole-word progress when the word is not wrapped', () {
      expect(
        lyricWrappedWordReveal(
          wordProgress: 0.5,
          wordCharIndex: 0,
          segmentLength: 10,
          wordPlacedCount: 10,
        ),
        5,
      );
    });

    test('fills the first visual line before the wrapped remainder', () {
      expect(
        lyricWrappedWordReveal(
          wordProgress: 0.5,
          wordCharIndex: 0,
          segmentLength: 8,
          wordPlacedCount: 10,
        ),
        5,
      );
      expect(
        lyricWrappedWordReveal(
          wordProgress: 0.5,
          wordCharIndex: 8,
          segmentLength: 2,
          wordPlacedCount: 10,
        ),
        0,
      );
    });

    test('starts the second visual line only after the first is full', () {
      expect(
        lyricWrappedWordReveal(
          wordProgress: 0.9,
          wordCharIndex: 0,
          segmentLength: 8,
          wordPlacedCount: 10,
        ),
        8,
      );
      expect(
        lyricWrappedWordReveal(
          wordProgress: 0.9,
          wordCharIndex: 8,
          segmentLength: 2,
          wordPlacedCount: 10,
        ),
        1,
      );
    });
  });

  group('lyricScaledContentWidth', () {
    test('keeps the layout width when scale is 1', () {
      expect(
        lyricScaledContentWidth(
          layoutWidth: 400,
          scale: 1,
          paddingHorizontal: 24,
        ),
        376,
      );
    });

    test('shrinks wrap width when the current line is scaled up', () {
      expect(
        lyricScaledContentWidth(
          layoutWidth: 400,
          scale: 1.25,
          paddingHorizontal: 24,
        ),
        closeTo(400 / 1.25 - 24, 0.0001),
      );
    });

    test('widens wrap width when inactive lines are scaled down', () {
      expect(
        lyricScaledContentWidth(
          layoutWidth: 400,
          scale: 0.9,
          paddingHorizontal: 24,
        ),
        closeTo(400 / 0.9 - 24, 0.0001),
      );
    });
  });

  group('lyricUnifiedWrapScale', () {
    test('uses the larger scale so played and unplayed wrap the same', () {
      expect(lyricUnifiedWrapScale(activeScale: 1.0, inactiveScale: 0.9), 1.0);
      expect(
        lyricScaledContentWidth(
          layoutWidth: 400,
          scale: lyricUnifiedWrapScale(activeScale: 1.0, inactiveScale: 0.9),
          paddingHorizontal: 24,
        ),
        376,
      );
    });
  });

  group('layoutTimedWordChars', () {
    LyricWordLayoutCursor cursor({
      double x = 0,
      double y = 0,
      bool firstOnLine = true,
    }) => LyricWordLayoutCursor(x: x, y: y, firstOnLine: firstOnLine);

    List<(int, double, double)> place({
      required List<String> chars,
      required List<double> widths,
      required LyricWordLayoutCursor cursor,
      double contentLeft = 0,
      double contentRight = 100,
      double lineHeight = 20,
    }) {
      final placed = <(int, double, double)>[];
      layoutTimedWordChars(
        chars: chars,
        widths: widths,
        contentLeft: contentLeft,
        contentRight: contentRight,
        lineHeight: lineHeight,
        cursor: cursor,
        onPlace: (i, x, y) => placed.add((i, x, y)),
      );
      return placed;
    }

    test('keeps a short timed word on one line', () {
      final c = cursor();
      final placed = place(chars: ['h', 'i'], widths: [10, 10], cursor: c);
      expect(placed, [(0, 0.0, 0.0), (1, 10.0, 0.0)]);
      expect(c.visualLineCount, 1);
      expect(c.x, 20);
    });

    test('does not split a timed word that still fits on the current line', () {
      final c = cursor(x: 40, firstOnLine: false);
      final placed = place(chars: ['o', 'h'], widths: [10, 10], cursor: c);
      expect(placed.map((e) => e.$3).toSet(), {0.0});
      expect(c.visualLineCount, 1);
      expect(c.x, 60);
    });

    test('wraps an oversized timed word at spaces', () {
      final c = cursor();
      final placed = place(
        chars: ['W', 'h', 'a', ' ', 'o', 'h', ' ', 'o', 'h'],
        widths: List<double>.filled(9, 10),
        cursor: c,
        contentRight: 35,
      );
      expect(placed.where((e) => e.$3 == 0.0).map((e) => e.$1).toList(), [
        0,
        1,
        2,
      ]);
      expect(placed.where((e) => e.$3 == 20.0).map((e) => e.$1).toList(), [
        4,
        5,
        6,
      ]);
      expect(placed.where((e) => e.$3 == 40.0).map((e) => e.$1).toList(), [
        7,
        8,
      ]);
      expect(c.visualLineCount, 3);
    });

    test('does not wrap a spaced timed word that already fits', () {
      final c = cursor();
      final placed = place(
        chars: ['h', 'i', ' ', 'o', 'h'],
        widths: List<double>.filled(5, 10),
        cursor: c,
        contentRight: 100,
      );
      expect(placed.map((e) => e.$3).toSet(), {0.0});
      expect(c.visualLineCount, 1);
    });

    test('wraps a spaceless overflow at characters', () {
      final c = cursor();
      place(
        chars: ['A', 'B', 'C', 'D', 'E', 'F'],
        widths: List<double>.filled(6, 10),
        cursor: c,
        contentRight: 35,
      );
      expect(c.visualLineCount, 2);
      expect(c.y, 20);
    });
  });
}
