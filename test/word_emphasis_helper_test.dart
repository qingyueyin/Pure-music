import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/word_emphasis_helper.dart';
import 'dart:typed_data';

void main() {
  const emphasisConfig = LyricRenderConfig(
    textAlign: LyricTextAlign.left,
    baseFontSize: 22.0,
    translationBaseFontSize: 18.0,
    showTranslation: true,
    showRoman: false,
    fontWeight: 400,
    enableBlur: true,
    enableWordEmphasis: true,
  );

  test('WordEmphasisHelper.resolve returns neutral state when disabled', () {
    const disabledConfig = LyricRenderConfig(
      textAlign: LyricTextAlign.left,
      baseFontSize: 22.0,
      translationBaseFontSize: 18.0,
      showTranslation: true,
      showRoman: false,
      fontWeight: 400,
      enableBlur: true,
      enableWordEmphasis: false,
    );

    final state = WordEmphasisHelper.resolve(
      progress: 0.5,
      baseSize: 22.0,
      config: disabledConfig,
    );

    expect(state.yOffset, 0.0);
    expect(state.scale, 1.0);
    expect(state.glowIntensity, 0.0);
    expect(state.glowAlpha, 0.0);
  });

  test('WordEmphasisHelper.resolve peaks near middle progress', () {
    final early = WordEmphasisHelper.resolve(
      progress: 0.1,
      baseSize: 22.0,
      config: emphasisConfig,
    );
    final peak = WordEmphasisHelper.resolve(
      progress: 0.5,
      baseSize: 22.0,
      config: emphasisConfig,
    );
    final late = WordEmphasisHelper.resolve(
      progress: 0.9,
      baseSize: 22.0,
      config: emphasisConfig,
    );

    expect(peak.yOffset, lessThan(0.0));
    expect(peak.scale, greaterThan(1.0));
    expect(peak.glowIntensity, greaterThan(early.glowIntensity));
    expect(peak.glowIntensity, greaterThan(late.glowIntensity));
  });

  test('WordEmphasisHelper.resolve clamps out-of-range progress', () {
    final state = WordEmphasisHelper.resolve(
      progress: 2.0,
      baseSize: 22.0,
      config: emphasisConfig,
    );

    expect(state.glowIntensity, greaterThanOrEqualTo(0.0));
    expect(state.scale, greaterThanOrEqualTo(1.0));
  });

  test('WordEmphasisHelper only emphasizes long enough latin words', () {
    final shortWord = SyncLyricWord(
      const Duration(milliseconds: 0),
      const Duration(milliseconds: 500),
      'gave',
    );
    final longWord = SyncLyricWord(
      const Duration(milliseconds: 0),
      const Duration(milliseconds: 1200),
      'gave',
    );
    final tooLongWord = SyncLyricWord(
      const Duration(milliseconds: 0),
      const Duration(milliseconds: 1200),
      'everything',
    );

    expect(WordEmphasisHelper.shouldEmphasizeWord(shortWord), isFalse);
    expect(WordEmphasisHelper.shouldEmphasizeWord(longWord), isTrue);
    expect(WordEmphasisHelper.shouldEmphasizeWord(tooLongWord), isFalse);
  });

  test('WordEmphasisHelper allows long enough CJK words to emphasize', () {
    final word = SyncLyricWord(
      const Duration(milliseconds: 0),
      const Duration(milliseconds: 1000),
      '你给我',
    );

    expect(WordEmphasisHelper.shouldEmphasizeWord(word), isTrue);
  });

  test('WordEmphasisHelper.resolve can react differently to low and high bands',
      () {
    final word = SyncLyricWord(
      const Duration(milliseconds: 0),
      const Duration(milliseconds: 1400),
      'gave',
    );
    final lowBands =
        Float32List.fromList([0.1, 0.8, 0.7, 0.4, 0.2, 0.1, 0.05, 0.02]);
    final highBands =
        Float32List.fromList([0.05, 0.1, 0.2, 0.35, 0.7, 0.85, 0.75, 0.2]);
    const reactiveConfig = LyricRenderConfig(
      textAlign: LyricTextAlign.left,
      baseFontSize: 22.0,
      translationBaseFontSize: 18.0,
      showTranslation: true,
      showRoman: false,
      fontWeight: 400,
      enableBlur: true,
      enableWordEmphasis: true,
      enableAudioReactive: true,
      audioReactiveStrength: 1.0,
    );

    final lowState = WordEmphasisHelper.resolve(
      progress: 0.5,
      baseSize: 22.0,
      config: reactiveConfig,
      word: word,
      spectrumBands: lowBands,
    );
    final highState = WordEmphasisHelper.resolve(
      progress: 0.5,
      baseSize: 22.0,
      config: reactiveConfig,
      word: word,
      spectrumBands: highBands,
    );

    expect(highState.yOffset, lessThan(lowState.yOffset));
    expect(highState.glowIntensity, greaterThan(lowState.glowIntensity));
  });

  test('WordEmphasisHelper.resolve staggers emphasized characters', () {
    final word = SyncLyricWord(
      const Duration(milliseconds: 0),
      const Duration(milliseconds: 1400),
      'gave',
    );

    final centerState = WordEmphasisHelper.resolve(
      progress: 0.5,
      baseSize: 22.0,
      config: emphasisConfig,
      word: word,
      characterIndex: 1,
      characterCount: 4,
    );
    final edgeState = WordEmphasisHelper.resolve(
      progress: 0.5,
      baseSize: 22.0,
      config: emphasisConfig,
      word: word,
      characterIndex: 3,
      characterCount: 4,
    );

    expect(centerState.scale != edgeState.scale, isTrue);
  });
}
