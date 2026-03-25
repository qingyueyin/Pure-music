import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/preference.dart';

void main() {
  test('NowPlayingPagePreference: legacy AMLL toggle migrates to mesh gradient mode', () {
    final pref = NowPlayingPagePreference.fromMap({
      'nowPlayingViewMode': 'withLyric',
      'lyricTextAlign': 'left',
      'lyricFontSize': 22.0,
      'translationFontSize': 18.0,
      'showLyricTranslation': true,
      'showLyricRoman': false,
      'lyricFontWeight': 400,
      'enableLyricBlur': false,
      'enableAmllBackground': true,
    });

    expect(pref.backgroundMode, NowPlayingBackgroundMode.meshGradient);
  });

  test('NowPlayingPagePreference: legacy disabled AMLL toggle migrates to mesh gradient mode', () {
    final pref = NowPlayingPagePreference.fromMap({
      'nowPlayingViewMode': 'withLyric',
      'lyricTextAlign': 'left',
      'lyricFontSize': 22.0,
      'translationFontSize': 18.0,
      'showLyricTranslation': true,
      'showLyricRoman': false,
      'lyricFontWeight': 400,
      'enableLyricBlur': false,
      'enableAmllBackground': false,
    });

    expect(pref.backgroundMode, NowPlayingBackgroundMode.meshGradient);
  });

  test('NowPlayingPagePreference: background mode round-trips through map', () {
    final pref = NowPlayingPagePreference(
      NowPlayingViewMode.withLyric,
      LyricTextAlign.left,
      22.0,
      18.0,
      true,
      400,
      false,
      backgroundMode: NowPlayingBackgroundMode.simpleFallback,
    );

    final map = pref.toMap();
    expect(map['backgroundMode'], 'simpleFallback');
    expect(map['enableAmllBackground'], isNull);

    final restored = NowPlayingPagePreference.fromMap(map);
    expect(restored.backgroundMode, NowPlayingBackgroundMode.simpleFallback);
  });
}
