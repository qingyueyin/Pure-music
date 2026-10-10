import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/settings.dart';

void main() {
  test('keeps legacy theme setting compatibility', () {
    expect(normalizedThemeOption('ThemeOption.dark'), ThemeOption.dark);
    expect(normalizedThemeOption(1), ThemeOption.light);
    expect(normalizedThemeOption('unknown'), ThemeOption.system);
    expect(normalizedThemeColorMode('monochrome'), ThemeColorMode.independent);
    expect(normalizedThemeColorMode('seed'), ThemeColorMode.material3);
    expect(normalizedThemeColorSource('system'), ThemeColorSource.system);
    expect(normalizedThemeColorSource('unknown'), isNull);
  });

  test('keeps enum name and fallback decoding', () {
    expect(
      normalizedSettingEnumValue(
        'WindowCloseBehavior.minimizeToTray',
        WindowCloseBehavior.values,
      ),
      WindowCloseBehavior.minimizeToTray,
    );
    expect(
      normalizedSettingEnumValue(
        'not-a-behavior',
        WindowCloseBehavior.values,
        fallback: WindowCloseBehavior.exit,
      ),
      WindowCloseBehavior.exit,
    );
  });

  test('keeps stored wavy bar modes decoding', () {
    expect(
      normalizedWavyBarEnabledModes('portrait').single,
      NowPlayingMode.portrait,
    );
    expect(normalizedWavyBarEnabledModes(['portrait', 'invalid']), {
      NowPlayingMode.portrait,
    });
    expect(normalizedWavyBarEnabledModes(null), isEmpty);
  });

  test('keeps legacy values at the settings read boundary', () async {
    final settings = AppSettings.instance;
    final previousThemeOption = settings.themeOption;
    final previousColorMode = settings.themeColorMode;
    final previousStackedEffect = settings.enableStackedScrollEffect;
    final previousCloseBehavior = settings.windowCloseBehavior;
    try {
      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'ThemeOption': 'ThemeOption.dark',
        'ThemeColorMode': 'monochrome',
        'EnableStackedScrollEffect': 'off',
        'WindowCloseBehavior': 'not-a-behavior',
      });

      expect(settings.themeOption, ThemeOption.dark);
      expect(settings.themeColorMode, ThemeColorMode.independent);
      expect(settings.enableStackedScrollEffect, isFalse);
      expect(settings.windowCloseBehavior, WindowCloseBehavior.exit);
    } finally {
      settings
        ..themeOption = previousThemeOption
        ..themeColorMode = previousColorMode
        ..enableStackedScrollEffect = previousStackedEffect
        ..windowCloseBehavior = previousCloseBehavior;
    }
  });

  test('migrates theme color source from cover extraction settings', () async {
    final settings = AppSettings.instance;
    final previousSource = settings.themeColorSource;
    final previousExtraction = settings.enableCoverColorExtraction;
    final previousCustomColor = settings.customCoverColor;
    try {
      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'EnableCoverColorExtraction': false,
        'CustomCoverColor': 0xFF112233,
      });
      expect(settings.themeColorSource, ThemeColorSource.custom);
      expect(settings.enableCoverColorExtraction, isFalse);

      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'EnableCoverColorExtraction': false,
        'CustomCoverColor': null,
      });
      expect(settings.themeColorSource, ThemeColorSource.system);

      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'ThemeColorSource': 'system',
        'EnableCoverColorExtraction': true,
        'CustomCoverColor': 0xFF445566,
      });
      expect(settings.themeColorSource, ThemeColorSource.system);
      expect(settings.enableCoverColorExtraction, isFalse);
    } finally {
      settings
        ..themeColorSource = previousSource
        ..enableCoverColorExtraction = previousExtraction
        ..customCoverColor = previousCustomColor;
    }
  });

  test('keeps midi soundfont path at the settings read boundary', () async {
    final settings = AppSettings.instance;
    final previous = settings.midiSoundfontPath;
    try {
      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'MidiSoundfontPath': r'D:\Soundfonts\piano.sf2',
      });
      expect(settings.midiSoundfontPath, r'D:\Soundfonts\piano.sf2');
    } finally {
      settings.midiSoundfontPath = previous;
    }
  });

  test('reads artist split extras from settings map', () async {
    final settings = AppSettings.instance;
    final previousSeparator = List<String>.from(settings.artistSeparator);
    final previousNoSplit = List<String>.from(settings.artistNoSplitNames);
    final previousFeat = settings.enableFeatArtistSplit;
    final previousAliases = Map<String, String>.from(settings.artistAliases);
    try {
      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'ArtistSeparator': ['/', '、'],
        'ArtistNoSplitNames': ['AC/DC'],
        'EnableFeatArtistSplit': true,
        'ArtistAliases': {'夜遊': 'YOASOBI'},
      });
      expect(settings.artistNoSplitNames, ['AC/DC']);
      expect(settings.enableFeatArtistSplit, isTrue);
      expect(settings.artistAliases, {'夜遊': 'YOASOBI'});
      expect(settings.splitArtistNames('AC/DC/张三'), ['AC/DC', '张三']);
      expect(settings.splitArtistNames('周杰伦 feat. 蔡依林'), ['周杰伦', '蔡依林']);
      expect(settings.splitArtistNames('周杰伦feat.蔡依林'), ['周杰伦feat.蔡依林']);
      expect(settings.splitArtistNames('夜遊'), ['YOASOBI']);

      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'ArtistSeparator': <String>[],
        'ArtistNoSplitNames': <String>[],
        'EnableFeatArtistSplit': false,
        'ArtistAliases': <String, String>{},
      });
      expect(settings.artistSeparator, isEmpty);
      expect(settings.splitArtistNames('张三/李四'), ['张三/李四']);
    } finally {
      settings.artistSeparator = previousSeparator;
      settings.artistNoSplitNames = previousNoSplit;
      settings.enableFeatArtistSplit = previousFeat;
      settings.artistAliases = previousAliases;
      settings.syncArtistSplitPattern();
    }
  });

  test('artist split regex follows pattern changes', () {
    final settings = AppSettings.instance;
    final previousSeparator = List<String>.from(settings.artistSeparator);
    final previousFeat = settings.enableFeatArtistSplit;
    try {
      settings.enableFeatArtistSplit = false;
      settings.artistSeparator = ['/'];
      settings.syncArtistSplitPattern();
      expect('A/B'.split(settings.artistSplitRegex), ['A', 'B']);

      settings.artistSeparator = ['、'];
      settings.syncArtistSplitPattern();
      expect('A、B'.split(settings.artistSplitRegex), ['A', 'B']);
      expect('A/B'.split(settings.artistSplitRegex), ['A/B']);

      settings.artistSeparator = ['.'];
      settings.syncArtistSplitPattern();
      expect('A.B'.split(settings.artistSplitRegex), ['A', 'B']);
      expect('ABCD'.split(settings.artistSplitRegex), ['ABCD']);
    } finally {
      settings.artistSeparator = previousSeparator;
      settings.enableFeatArtistSplit = previousFeat;
      settings.syncArtistSplitPattern();
    }
  });
}
