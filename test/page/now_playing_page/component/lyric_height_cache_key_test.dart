import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_height_cache_key.dart';

void main() {
  const config = LyricRenderConfig(
    textAlign: LyricTextAlign.center,
    baseFontSize: 32,
    translationBaseFontSize: 20,
    showTranslation: true,
    showRoman: true,
    fontWeight: 600,
    enableBlur: true,
  );

  test('matches when all layout inputs are unchanged', () {
    final line = LyricLine(Duration.zero, const Duration(seconds: 1));
    final first = LyricHeightCacheKey(
      line: line,
      lineWidth: 320,
      config: config,
      isMainLine: true,
      useMaterialYouColor: false,
      reserveBackgroundVocalHeight: true,
      fontFamily: 'Test',
      agent: 'v1',
    );
    final second = LyricHeightCacheKey(
      line: line,
      lineWidth: 320,
      config: config,
      isMainLine: true,
      useMaterialYouColor: false,
      reserveBackgroundVocalHeight: true,
      fontFamily: 'Test',
      agent: 'v1',
    );

    expect(first, second);
    expect(first.hashCode, second.hashCode);
  });

  test('does not match when a layout input changes', () {
    final line = LyricLine(Duration.zero, const Duration(seconds: 1));
    final base = LyricHeightCacheKey(
      line: line,
      lineWidth: 320,
      config: config,
      isMainLine: true,
      useMaterialYouColor: false,
      reserveBackgroundVocalHeight: true,
      fontFamily: 'Test',
      agent: 'v1',
    );
    final changed = LyricHeightCacheKey(
      line: line,
      lineWidth: 321,
      config: config,
      isMainLine: true,
      useMaterialYouColor: false,
      reserveBackgroundVocalHeight: true,
      fontFamily: 'Test',
      agent: 'v1',
    );

    expect(base, isNot(changed));
  });

  test('keeps distinct line instances separate', () {
    final first = LyricHeightCacheKey(
      line: LyricLine(Duration.zero, const Duration(seconds: 1)),
      lineWidth: 320,
      config: config,
      isMainLine: true,
      useMaterialYouColor: false,
      reserveBackgroundVocalHeight: true,
      fontFamily: 'Test',
      agent: 'v1',
    );
    final second = LyricHeightCacheKey(
      line: LyricLine(Duration.zero, const Duration(seconds: 1)),
      lineWidth: 320,
      config: config,
      isMainLine: true,
      useMaterialYouColor: false,
      reserveBackgroundVocalHeight: true,
      fontFamily: 'Test',
      agent: 'v1',
    );

    expect(first, isNot(second));
  });
}
