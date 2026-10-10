import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_painter_params.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_tile.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';

LyricRenderConfig _config({double liftPeak = 2}) => LyricRenderConfig(
  textAlign: LyricTextAlign.left,
  baseFontSize: 32,
  translationBaseFontSize: 20,
  showTranslation: false,
  showRoman: false,
  fontWeight: 600,
  enableBlur: false,
  liftPeak: liftPeak,
);

SyncLyricLine _line() =>
    SyncLyricLine(Duration.zero, const Duration(milliseconds: 800), [
      SyncLyricWord(Duration.zero, const Duration(milliseconds: 400), 'Hello'),
      SyncLyricWord(
        const Duration(milliseconds: 400),
        const Duration(milliseconds: 400),
        'World',
      ),
    ]);

double _measure(LyricRenderConfig config) {
  return LyricsLinePainter(
    params: LyricPainterParams(
      line: _line(),
      currentTimeMs: 200,
      blurSigma: 0,
      config: config,
      isMainLine: true,
      isHighlightActive: true,
      isMainVocalActive: true,
      accelerateTailHighlight: false,
      useMaterialYouColor: false,
      opacity: 1,
      lineMedianWordDuration: Duration.zero,
    ),
    scheme: const ColorScheme.dark(),
  ).measureHeight(400);
}

void main() {
  group('played hold keeps float latch', () {
    test(
      'group hold does not drop when the line finished but group remains',
      () {
        expect(
          lyricLineFloatTarget(
            mainHighlight: false,
            isHighlightActive: true,
            wasLatched: true,
          ),
          isTrue,
        );
      },
    );
  });

  group('interlude does not reserve height off-screen', () {
    final line = SyncLyricLine(
      Duration.zero,
      const Duration(seconds: 5),
      const [],
    );

    test('only the current interlude takes 40px', () {
      expect(lyricTransitionLayoutHeight(line, isMain: true), 40);
      expect(lyricTransitionLayoutHeight(line, isMain: false), 0);
    });
  });

  group('exit stays uniform with float', () {
    test('half float keeps half of the last lift', () {
      expect(lyricExitLift(-2, 1), -2);
      expect(lyricExitLift(-2, 0.5), -1);
      expect(lyricExitLift(-2, 0), 0);
    });
  });

  group('vertical rise is a duration spring, not a 2s ease', () {
    test('does not move before the syllable starts', () {
      expect(
        lyricVerticalCharLiftPx(
          nowMs: 1000,
          wordStartMs: 1000,
          wordDurationSec: 1,
          syllableIndex: 0,
          syllableCount: 1,
          softLift: false,
          liftPeak: 2,
        ),
        0,
      );
    });

    test('latin duration spring matches the closed form', () {
      const t = 0.25;
      const d = 1.0;
      const w = 2 * pi / d;
      final expected = 1 - (1 + w * t) * exp(-w * t);
      expect(lyricDurationLiftSpring(t, d), closeTo(expected, 0.0001));
      expect(
        lyricVerticalCharLiftPx(
          nowMs: 1000 + (0.4 + t) * 1000,
          wordStartMs: 1000,
          wordDurationSec: d,
          syllableIndex: 0,
          syllableCount: 1,
          softLift: false,
          liftPeak: 2,
        ),
        closeTo(-expected * 2, 0.002),
      );
    });

    test('holds near peak after the word ends', () {
      final mid = lyricVerticalCharLiftPx(
        nowMs: 1800,
        wordStartMs: 1000,
        wordDurationSec: 1,
        syllableIndex: 0,
        syllableCount: 1,
        softLift: false,
        liftPeak: 2,
      );
      final late = lyricVerticalCharLiftPx(
        nowMs: 4000,
        wordStartMs: 1000,
        wordDurationSec: 1,
        syllableIndex: 0,
        syllableCount: 1,
        softLift: false,
        liftPeak: 2,
      );
      expect(mid, lessThan(0));
      expect(late, closeTo(-2, 0.05));
    });

    test('settled lift is bit-identical while the clock keeps moving', () {
      final a = lyricVerticalCharLiftPx(
        nowMs: 5000,
        wordStartMs: 1000,
        wordDurationSec: 1,
        syllableIndex: 0,
        syllableCount: 1,
        softLift: true,
        liftPeak: 2,
      );
      final b = lyricVerticalCharLiftPx(
        nowMs: 5016,
        wordStartMs: 1000,
        wordDurationSec: 1,
        syllableIndex: 0,
        syllableCount: 1,
        softLift: true,
        liftPeak: 2,
      );
      expect(a, -2);
      expect(b, a);
      expect(lyricSoftLiftSpring(3.0), 1.0);
      expect(lyricSoftLiftSpring(3.0), lyricSoftLiftSpring(3.016));
    });
  });

  group('cosine formula at default peak 2.0', () {
    test('sung glyphs are up and later glyphs stay down', () {
      const fontSize = 20.0;
      const peak = 2.0;
      const cursor = 40.0;
      const end = 120.0;
      expect(
        lyricCosineLiftPx(
          charCenter: 10,
          cursorX: cursor,
          lineEndX: end,
          fontSize: fontSize,
          liftPeak: peak,
        ),
        closeTo(-2, 0.001),
      );
      expect(
        lyricCosineLiftPx(
          charCenter: 110,
          cursorX: cursor,
          lineEndX: end,
          fontSize: fontSize,
          liftPeak: peak,
        ),
        0,
      );
    });

    test('max lift is 0.10 * fontSize at default peak 2.0', () {
      expect(
        lyricCosineLiftPx(
          charCenter: 0,
          cursorX: 100,
          lineEndX: 400,
          fontSize: 32,
          liftPeak: 2,
        ),
        closeTo(-3, 0.001),
      );
    });
  });

  group('layout does not grow with lift peak', () {
    test('measureHeight is the same at peak 2 and peak 20', () {
      expect(_measure(_config(liftPeak: 2)), _measure(_config(liftPeak: 20)));
    });
  });

  group('scale lift gate threshold', () {
    test('opens at 90 percent of travel, not at the start', () {
      expect(
        lyricScaleReachedLiftGate(start: 0.95, target: 1.0, value: 0.95),
        isFalse,
      );
      expect(
        lyricScaleReachedLiftGate(start: 0.95, target: 1.0, value: 0.994),
        isFalse,
      );
      expect(
        lyricScaleReachedLiftGate(start: 0.95, target: 1.0, value: 0.995),
        isTrue,
      );
      expect(
        lyricScaleReachedLiftGate(start: 0.95, target: 1.0, value: 1.0),
        isTrue,
      );
    });

    test('treats zero travel as already open', () {
      expect(
        lyricScaleReachedLiftGate(start: 1.0, target: 1.0, value: 1.0),
        isTrue,
      );
    });

    test('works when shrinking toward the inactive scale', () {
      expect(
        lyricScaleReachedLiftGate(start: 1.0, target: 0.95, value: 0.956),
        isFalse,
      );
      expect(
        lyricScaleReachedLiftGate(start: 1.0, target: 0.95, value: 0.955),
        isTrue,
      );
    });
  });

  group('lift gate', () {
    test('gate 0 zeroes lift, gate 1 keeps it', () {
      expect(lyricGatedLiftPx(-2, 0), 0);
      expect(lyricGatedLiftPx(-2, 1), -2);
      expect(lyricGatedLiftPx(-2, 0.5), -1);
    });

    test('painter lift is 0 when gate is 0, unchanged when gate is 1', () {
      final gate = ValueNotifier(0.0);
      void paintWithGate() {
        LyricsLinePainter(
          params: LyricPainterParams(
            line: _line(),
            currentTimeMs: 600,
            blurSigma: 0,
            config: _config(),
            isMainLine: true,
            isHighlightActive: true,
            isMainVocalActive: true,
            accelerateTailHighlight: false,
            useMaterialYouColor: false,
            opacity: 1,
            highlightDeadlineMs: 800,
            lineMedianWordDuration: Duration.zero,
            liftGateListenable: gate,
          ),
          scheme: const ColorScheme.dark(),
        ).paint(Canvas(PictureRecorder()), const Size(400, 140));
      }

      paintWithGate();
      expect(debugLyricCharYLifts, isNotEmpty);
      expect(debugLyricCharYLifts, everyElement(0));

      gate.value = 1;
      paintWithGate();
      expect(debugLyricCharYLifts.first, lessThan(0));
    });
  });

  group('scale anchor is vertically centered', () {
    test('alignment is center and measureHeight is unchanged', () {
      final height = _measure(_config());
      expect(
        lyricLineScaleAlignment(LyricTextAlign.left),
        Alignment.centerLeft,
      );
      expect(lyricLineScaleAlignment(LyricTextAlign.center), Alignment.center);
      expect(
        lyricLineScaleAlignment(LyricTextAlign.right),
        Alignment.centerRight,
      );
      expect(_measure(_config()), height);
    });
  });

  test('catch-up still uses springs instead of filling to peak', () {
    final line = _line();
    LyricsLinePainter(
      params: LyricPainterParams(
        line: line,
        currentTimeMs: 600,
        blurSigma: 0,
        config: _config(),
        isMainLine: true,
        isHighlightActive: true,
        isMainVocalActive: true,
        accelerateTailHighlight: false,
        useMaterialYouColor: false,
        opacity: 1,
        highlightDeadlineMs: 800,
        lineMedianWordDuration: Duration.zero,
      ),
      scheme: const ColorScheme.dark(),
    ).paint(Canvas(PictureRecorder()), const Size(400, 140));
    expect(debugLyricCharYLifts, isNotEmpty);
    expect(debugLyricCharYLifts.first, lessThan(0));
    expect(
      debugLyricCharYLifts.first.abs(),
      greaterThan(debugLyricCharYLifts.last.abs()),
    );
  });

  test('fully sung lift does not change from frame to frame', () {
    final line = SyncLyricLine(
      Duration.zero,
      const Duration(milliseconds: 2000),
      [SyncLyricWord(Duration.zero, const Duration(milliseconds: 800), '你好')],
    );
    void paintAt(double nowMs) {
      LyricsLinePainter(
        params: LyricPainterParams(
          line: line,
          currentTimeMs: nowMs,
          blurSigma: 0,
          config: _config(),
          isMainLine: true,
          isHighlightActive: true,
          isMainVocalActive: true,
          accelerateTailHighlight: false,
          useMaterialYouColor: false,
          opacity: 1,
          lineMedianWordDuration: const Duration(milliseconds: 800),
        ),
        scheme: const ColorScheme.dark(),
      ).paint(Canvas(PictureRecorder()), const Size(400, 140));
    }

    paintAt(4000);
    final first = List<double>.from(debugLyricCharYLifts);
    paintAt(4016);
    expect(debugLyricCharYLifts, first);
    expect(first, everyElement(-2));
  });

  test('settled line does not request another frame', () {
    final line = _line();
    expect(
      lyricLineEffectsNeedFrame(
        words: line.words,
        nowMs: 4000,
        lineMedianDuration: const Duration(milliseconds: 400),
        enableGlow: true,
        liftActive: true,
        liftPeak: 2,
      ),
      isFalse,
    );
  });
}
