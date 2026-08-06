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
}
