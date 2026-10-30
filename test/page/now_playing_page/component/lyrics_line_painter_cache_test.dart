import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_painter_params.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';

const _wordTexts = ['甲乙丙', '丁戊己', '庚辛壬', '癸子丑', '寅卯辰', '巳午未', '申酉戌', '亥天地'];

SyncLyricLine _buildLine() {
  final words = <SyncLyricWord>[];
  var startMs = 0;
  for (final text in _wordTexts) {
    words.add(
      SyncLyricWord(
        Duration(milliseconds: startMs),
        const Duration(milliseconds: 300),
        text,
      ),
    );
    startMs += 300;
  }
  return SyncLyricLine(Duration.zero, Duration(milliseconds: startMs), words);
}

LyricRenderConfig _config() => const LyricRenderConfig(
  textAlign: LyricTextAlign.left,
  baseFontSize: 24,
  translationBaseFontSize: 18,
  showTranslation: false,
  showRoman: false,
  fontWeight: 500,
  enableBlur: false,
  enableGlow: false,
  displayMode: LyricDisplayMode.wordByWord,
);

LyricsLinePainter _painter(
  SyncLyricLine line,
  double timeMs,
  LyricRenderConfig config, {
  bool highlight = true,
}) {
  return LyricsLinePainter(
    params: LyricPainterParams(
      line: line,
      currentTimeMs: timeMs,
      blurSigma: 0,
      config: config,
      isMainLine: true,
      isHighlightActive: highlight,
      accelerateTailHighlight: false,
      useMaterialYouColor: false,
      opacity: 1,
      lineMedianWordDuration: lyricMedianWordDuration(line.words),
    ),
    scheme: const ColorScheme.dark(),
  );
}

void _paintFrame(LyricsLinePainter painter, [Size size = const Size(720, 200)]) {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  recorder.endRecording().dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('同一行连续帧的逐字 layout 从每字一次降到 0~3 次', () {
    LyricsLinePainter.clearPool();
    final line = _buildLine();
    final config = _config();
    final charCount = line.content.characters.length;

    LyricsLinePainter.resetDebugGlyphCounters();
    _paintFrame(_painter(line, 900, config));
    final firstFrame = LyricsLinePainter.debugGlyphLayoutCount;

    // 每帧都新建 painter，模拟换行/淡入时 painter 被重建的最坏情况
    LyricsLinePainter.resetDebugGlyphCounters();
    _paintFrame(_painter(line, 916, config));
    final secondFrame = LyricsLinePainter.debugGlyphLayoutCount;

    LyricsLinePainter.resetDebugGlyphCounters();
    _paintFrame(_painter(line, 932, config));
    final thirdFrame = LyricsLinePainter.debugGlyphLayoutCount;

    // ignore: avoid_print
    print(
      'glyph layouts: chars=$charCount frame1=$firstFrame '
      'frame2=$secondFrame frame3=$thirdFrame',
    );
    expect(firstFrame, greaterThanOrEqualTo(charCount));
    expect(secondFrame, lessThanOrEqualTo(3));
    expect(thirdFrame, lessThanOrEqualTo(3));
    // 字位排版只建一次
    expect(LyricsLinePainter.debugCharLayoutBuildCount, 1);
  });

  test('非高亮行第二帧零逐字 layout', () {
    LyricsLinePainter.clearPool();
    final line = _buildLine();
    final config = _config();

    LyricsLinePainter.resetDebugGlyphCounters();
    _paintFrame(_painter(line, 5000, config, highlight: false));
    final firstFrame = LyricsLinePainter.debugGlyphLayoutCount;

    LyricsLinePainter.resetDebugGlyphCounters();
    _paintFrame(_painter(line, 5016, config, highlight: false));
    final secondFrame = LyricsLinePainter.debugGlyphLayoutCount;

    expect(firstFrame, greaterThan(0));
    expect(secondFrame, 0);
  });

  test('排版缓存随宽度与翻译变化失效', () {
    LyricsLinePainter.clearPool();
    final line = _buildLine();
    final config = _config();

    _paintFrame(_painter(line, 900, config));
    final afterFirst = LyricsLinePainter.debugCharLayoutBuildCount;
    _paintFrame(_painter(line, 916, config));
    final afterSame = LyricsLinePainter.debugCharLayoutBuildCount;
    _paintFrame(_painter(line, 932, config), const Size(600, 200));
    final afterWidth = LyricsLinePainter.debugCharLayoutBuildCount;
    line.translation = '译';
    _paintFrame(_painter(line, 948, config), const Size(600, 200));
    final afterTranslation = LyricsLinePainter.debugCharLayoutBuildCount;

    expect(afterFirst, 1);
    expect(afterSame, afterFirst);
    expect(afterWidth, afterSame + 1);
    expect(afterTranslation, afterWidth + 1);
  });
}
