import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_height_cache_key.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_painter_params.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';

const _config = LyricRenderConfig(
  textAlign: LyricTextAlign.center,
  baseFontSize: 32,
  translationBaseFontSize: 20,
  showTranslation: true,
  showRoman: true,
  fontWeight: 600,
  enableBlur: true,
);

const _lineWidth = 320.0;
const _beforeBackgroundMs = 10350.0;
const _backgroundActiveMs = 10500.0;
const _afterBackgroundMs = 12000.0;

const _scheme = ColorScheme.dark();

SyncLyricLine _backgroundVocalLine() {
  final line = SyncLyricLine(
    const Duration(milliseconds: 10000),
    const Duration(milliseconds: 2000),
    [
      SyncLyricWord(
        const Duration(milliseconds: 10000),
        const Duration(milliseconds: 1900),
        '主唱句子',
      ),
    ],
    '主唱翻译',
    '主唱注音',
  );
  line.bgText = '背景和声句子';
  line.bgTranslation = '背景翻译';
  line.bgStart = const Duration(milliseconds: 10400);
  line.bgEnd = const Duration(milliseconds: 11500);
  return line;
}

double _measureHeight({
  required double currentTimeMs,
  required bool isMainLine,
  bool isHighlightActive = false,
  bool isBackgroundActive = false,
}) {
  final line = _backgroundVocalLine();
  return LyricsLinePainter(
    params: LyricPainterParams(
      line: line,
      currentTimeMs: currentTimeMs,
      blurSigma: 0.0,
      config: _config,
      isMainLine: isMainLine,
      isHighlightActive: isHighlightActive,
      isBackgroundActive: isBackgroundActive,
      accelerateTailHighlight: false,
      useMaterialYouColor: false,
      opacity: 1.0,
      lineMedianWordDuration: Duration.zero,
    ),
    scheme: _scheme,
  ).measureHeight(_lineWidth, reserveBackgroundVocalHeight: true);
}

LyricHeightCacheKey _heightCacheKey(
  LyricLine line, {
  required bool reserveBackgroundVocalHeight,
}) {
  return LyricHeightCacheKey(
    line: line,
    lineWidth: _lineWidth,
    config: _config,
    isMainLine: true,
    useMaterialYouColor: false,
    reserveBackgroundVocalHeight: reserveBackgroundVocalHeight,
    fontFamily: null,
    agent: null,
  );
}

void main() {
  test('background vocal height collapses after its authored window', () {
    final active = _measureHeight(
      currentTimeMs: _backgroundActiveMs,
      isMainLine: true,
      isHighlightActive: true,
    );
    final ended = _measureHeight(
      currentTimeMs: _backgroundActiveMs,
      isMainLine: false,
      isHighlightActive: false,
    );

    expect(ended, lessThan(active));
    expect(active, greaterThan(0));
  });

  test(
    'background vocal height holds after its authored end while the main line is current',
    () {
      final active = _measureHeight(
        currentTimeMs: 11000.0,
        isMainLine: true,
        isHighlightActive: true,
        isBackgroundActive: true,
      );
      final afterAuthoredEnd = _measureHeight(
        currentTimeMs: 11600.0,
        isMainLine: true,
        isHighlightActive: true,
      );
      final stillCurrent = _measureHeight(
        currentTimeMs: _afterBackgroundMs,
        isMainLine: true,
        isHighlightActive: true,
      );

      expect(afterAuthoredEnd, closeTo(active, 0.5));
      expect(stillCurrent, closeTo(active, 0.5));
    },
  );

  test('background vocal height collapses over the exit window', () {
    final active = _measureHeight(
      currentTimeMs: 11000.0,
      isMainLine: true,
      isHighlightActive: true,
      isBackgroundActive: true,
    );
    final collapsing = LyricsLinePainter(
      params: LyricPainterParams(
        line: _backgroundVocalLine(),
        currentTimeMs: 11600.0,
        blurSigma: 0.0,
        config: _config,
        isMainLine: true,
        isHighlightActive: true,
        isBackgroundActive: false,
        accelerateTailHighlight: false,
        useMaterialYouColor: false,
        opacity: 1.0,
        lineMedianWordDuration: Duration.zero,
        backgroundVocalVisibilityListenable: ValueNotifier(0.45),
      ),
      scheme: _scheme,
    ).measureHeight(_lineWidth, reserveBackgroundVocalHeight: true);
    final collapsed = _measureHeight(
      currentTimeMs: _afterBackgroundMs,
      isMainLine: false,
      isHighlightActive: false,
    );

    expect(collapsing, lessThan(active));
    expect(collapsing, greaterThan(collapsed));
  });

  test('background vocal height grows only after its authored start', () {
    final beforeTrigger = _measureHeight(
      currentTimeMs: _beforeBackgroundMs,
      isMainLine: true,
      isBackgroundActive: false,
    );
    final afterTrigger = _measureHeight(
      currentTimeMs: _backgroundActiveMs,
      isMainLine: true,
      isHighlightActive: true,
      isBackgroundActive: true,
    );

    expect(afterTrigger, greaterThan(beforeTrigger));
  });

  test(
    'background vocal layout returns to the main line height after exit',
    () {
      final first = _measureHeight(
        currentTimeMs: _backgroundActiveMs,
        isMainLine: true,
        isHighlightActive: true,
        isBackgroundActive: false,
      );
      final second = _measureHeight(
        currentTimeMs: _afterBackgroundMs,
        isMainLine: false,
        isHighlightActive: false,
        isBackgroundActive: true,
      );

      expect(second, lessThan(first));

      final line = _backgroundVocalLine();
      final reserved = _heightCacheKey(
        line,
        reserveBackgroundVocalHeight: true,
      );
      final repeated = _heightCacheKey(
        line,
        reserveBackgroundVocalHeight: true,
      );
      final notReserved = _heightCacheKey(
        line,
        reserveBackgroundVocalHeight: false,
      );
      expect(repeated, reserved);
      expect(repeated.hashCode, reserved.hashCode);
      expect(notReserved, isNot(reserved));
    },
  );

  test('lift holds after the line ends until the next line takes over', () {
    var latched = lyricLineFloatTarget(
      mainHighlight: false,
      isHighlightActive: false,
      wasLatched: false,
    );
    expect(latched, isFalse);

    latched = lyricLineFloatTarget(
      mainHighlight: true,
      isHighlightActive: true,
      wasLatched: latched,
    );
    expect(latched, isTrue);

    latched = lyricLineFloatTarget(
      mainHighlight: false,
      isHighlightActive: true,
      wasLatched: latched,
    );
    expect(latched, isTrue);

    latched = lyricLineFloatTarget(
      mainHighlight: false,
      isHighlightActive: false,
      wasLatched: latched,
    );
    expect(latched, isFalse);
  });

  test('lift does not start before the line sings within its group', () {
    expect(
      lyricLineFloatTarget(
        mainHighlight: false,
        isHighlightActive: true,
        wasLatched: false,
      ),
      isFalse,
    );
    expect(
      lyricLineFloatTarget(
        mainHighlight: true,
        isHighlightActive: false,
        wasLatched: false,
      ),
      isTrue,
    );
  });

  group('monotonic playback clock', () {
    test('does not jump backward when native lags', () {
      expect(
        lyricMonotonicPlaybackMs(
          previousMs: 1200,
          predictedMs: 1216,
          nativeMs: 1180,
        ),
        1216,
      );
    });

    test('a small native lead does not pull the clock', () {
      expect(
        lyricMonotonicPlaybackMs(
          previousMs: 1200,
          predictedMs: 1216,
          nativeMs: 1240,
        ),
        1216,
      );
    });

    test('snaps on a seek-sized jump', () {
      expect(
        lyricMonotonicPlaybackMs(
          previousMs: 1200,
          predictedMs: 1216,
          nativeMs: 4000,
        ),
        4000,
      );
    });

    test('predicted time never walks backward', () {
      expect(
        lyricMonotonicPlaybackMs(
          previousMs: 1200,
          predictedMs: 1180,
          nativeMs: 1190,
        ),
        1200,
      );
    });
  });
}
