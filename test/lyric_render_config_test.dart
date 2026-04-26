import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_word_highlight_mask.dart';

void main() {
  test('NowPlayingPagePreference exposes unified lyric render config', () {
    final pref = NowPlayingPagePreference(
      NowPlayingViewMode.withLyric,
      LyricTextAlign.right,
      28.0,
      20.0,
      false,
      700,
      true,
    );

    final config = pref.lyricRenderConfig;

    expect(config.textAlign, LyricTextAlign.right);
    expect(config.baseFontSize, 28.0);
    expect(config.translationBaseFontSize, 20.0);
    expect(config.showTranslation, isFalse);
    expect(config.showRoman, isFalse);
    expect(config.fontWeight, 700);
    expect(config.enableBlur, isTrue);
    expect(config.viewportFadeExtent, 0.04);
    expect(config.enableLineScale, isTrue);
    expect(config.enableLineSpring, isTrue);
    expect(config.activeLineScaleMultiplier, 1.0);
    expect(config.lineSpring.stiffness, 90.0);
    expect(config.lineSpring.damping, 15.0);
    expect(config.lineSpring.mass, 0.9);
  });

  test('LyricRenderConfig helper methods stay monotonic and clamp correctly',
      () {
    const config = LyricRenderConfig(
      textAlign: LyricTextAlign.left,
      baseFontSize: 22.0,
      translationBaseFontSize: 18.0,
      showTranslation: true,
      showRoman: false,
      fontWeight: 400,
      enableBlur: true,
      enableWordEmphasis: true,
    );

    expect(config.primaryFontSize(isMainLine: true), 22.0);
    expect(config.primaryFontSize(isMainLine: false), 22.0);
    expect(
      config.translationFontSize(isMainLine: true),
      closeTo(14.04, 1e-9),
    );
    expect(
      config.translationFontSize(isMainLine: false),
      closeTo(12.6, 1e-9),
    );
    expect(config.primaryLineHeight(400), 1.2);
    expect(config.blurSigmaForDistance(5), 12.0);
    const highlightMask = LyricWordHighlightMask(
      progress: 0.95,
    );
    expect(highlightMask.stops, const [0.0, 0.333, 0.666]);
    expect(highlightMask.shouldHighlight, isTrue);
    expect(
      config.viewportMaskStops(),
      const [0.0, 0.04, 0.96, 1.0],
    );
  });

  test('LyricRenderConfig disables effect helpers when switches are off', () {
    const config = LyricRenderConfig(
      textAlign: LyricTextAlign.center,
      baseFontSize: 22.0,
      translationBaseFontSize: 18.0,
      showTranslation: true,
      showRoman: true,
      fontWeight: 500,
      enableBlur: false,
      enableWordEmphasis: false,
    );

    expect(config.blurSigmaForDistance(4), 0.0);
    expect(config.shouldApplyWordEmphasis, isFalse);
  });

  test('NowPlayingPagePreference round-trips through map', () {
    final pref = NowPlayingPagePreference(
      NowPlayingViewMode.withLyric,
      LyricTextAlign.left,
      22.0,
      18.0,
      true,
      400,
      false,
    );

    final map = pref.toMap();
    expect(map['lyricTextAlign'], 'left');
    expect(map['lyricFontSize'], 22.0);
    expect(map['translationFontSize'], 18.0);
    expect(map['showLyricTranslation'], isTrue);
    expect(map['lyricFontWeight'], 400);
    expect(map['enableLyricBlur'], isFalse);

    final restored = NowPlayingPagePreference.fromMap(map);
    expect(restored.lyricTextAlign, LyricTextAlign.left);
    expect(restored.lyricFontSize, 22.0);
    expect(restored.translationFontSize, 18.0);
    expect(restored.showLyricTranslation, isTrue);
    expect(restored.lyricFontWeight, 400);
    expect(restored.enableLyricBlur, isFalse);
  });

  test('LyricRenderConfig viewportFadeExtent defaults to 0.04', () {
    const config = LyricRenderConfig(
      textAlign: LyricTextAlign.left,
      baseFontSize: 22.0,
      translationBaseFontSize: 18.0,
      showTranslation: true,
      showRoman: false,
      fontWeight: 400,
      enableBlur: true,
      enableWordEmphasis: true,
    );

    expect(config.viewportFadeExtent, 0.04);
  });
}
