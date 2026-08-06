import 'dart:convert';
import 'dart:io';
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/native/rust/api/system_theme.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/zh_converter.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:flutter/material.dart';
import 'package:github/github.dart';
import 'package:path/path.dart' as path;
import 'package:window_manager/window_manager.dart';

const bool portableBuild = bool.fromEnvironment(
  'PORTABLE_BUILD',
  defaultValue: true,
);

Future<Directory> getAppDataDir() async {
  final exe = Platform.resolvedExecutable;
  final exeBase = path.basename(exe).toLowerCase();
  if (portableBuild &&
      exeBase != 'dart.exe' &&
      exeBase != 'flutter_tester.exe') {
    final portable = Directory(path.join(path.dirname(exe), 'data'));
    try {
      return portable.create(recursive: true);
    } catch (_) {}
  }

  final appData = Platform.environment['APPDATA'];
  if (appData != null) {
    final dir = Directory(path.join(appData, 'pure_music'));
    return dir.create(recursive: true);
  }

  final userProfile = Platform.environment['USERPROFILE'];
  if (userProfile != null) {
    final dir =
        Directory(path.join(userProfile, 'AppData', 'Roaming', 'pure_music'));
    return dir.create(recursive: true);
  }

  throw StateError('Unable to determine app data directory');
}

Future<Directory> getSettingsDir() async {
  final root = await getAppDataDir();
  return Directory(path.join(root.path, 'settings')).create(recursive: true);
}

Future<void> writeTextFileAtomically(String filePath, String content) async {
  final target = File(filePath);
  await target.parent.create(recursive: true);
  final tmpPath = '$filePath.tmp.${DateTime.now().microsecondsSinceEpoch}.$pid';
  final tmp = File(tmpPath);
  try {
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(filePath);
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}

Future<Directory> getCacheDir() async {
  final root = await getAppDataDir();
  return Directory(path.join(root.path, 'cache')).create(recursive: true);
}

Future<Directory> getDbDir() async {
  final root = await getAppDataDir();
  return Directory(path.join(root.path, 'db')).create(recursive: true);
}

/// 歌词显示模式（控制是否使用逐字歌词）
enum LyricDisplayMode {
  lineByLine, // 逐行歌词（标准LRC格式）
  wordByWord, // 逐字歌词（带逐字时间戳）
  plain, // 旧名兼容
  enhanced, // 旧名兼容
}

enum ThemeOption { system, light, dark }

Set<NowPlayingMode> defaultWavyBarEnabledModes() =>
    {NowPlayingMode.portrait, NowPlayingMode.landscape};

ThemeOption normalizedThemeOption(Object? value) {
  final index = normalizedEnumIndex(
    value,
    length: ThemeOption.values.length,
    defaultIndex: -1,
  );
  if (index >= 0) return ThemeOption.values[index];

  final name = normalizedSettingEnumName(value);
  for (final option in ThemeOption.values) {
    if (option.name == name) return option;
  }
  return ThemeOption.system;
}

Set<NowPlayingMode> normalizedWavyBarEnabledModes(Object? value) {
  if (value is String) {
    final mode = NowPlayingMode.fromStoredValue(value);
    return mode == null ? defaultWavyBarEnabledModes() : {mode};
  }
  if (value is! List) return defaultWavyBarEnabledModes();
  if (value.isEmpty) return {};
  final modes = NowPlayingMode.fromList(value);
  return modes.isEmpty ? defaultWavyBarEnabledModes() : modes;
}

String? normalizedSettingEnumName(Object? value) {
  final normalized = normalizedStringSetting(value)?.toLowerCase();
  if (normalized == null) return null;
  final separator = normalized.lastIndexOf('.');
  return separator < 0 ? normalized : normalized.substring(separator + 1);
}

String? normalizedPathSetting(Object? value) {
  final normalized = normalizedStringSetting(value);
  if (normalized == null) return null;
  final uri = Uri.tryParse(normalized);
  if (uri != null && uri.scheme.toLowerCase() == 'file') {
    final host = uri.host.toLowerCase();
    if ((host.isEmpty || host == 'localhost') && uri.path == '/') return null;
    if (host == 'localhost') {
      return uri.replace(host: '').toFilePath(windows: true);
    }
    return uri.toFilePath(windows: true);
  }
  return normalized;
}

T? normalizedSettingEnumValue<T extends Enum>(
  Object? value,
  List<T> values, {
  T? fallback,
}) {
  final index = normalizedEnumIndex(
    value,
    length: values.length,
    defaultIndex: -1,
  );
  if (index >= 0) return values[index];

  final name = normalizedSettingEnumName(value);
  if (name != null) {
    for (final option in values) {
      if (option.name.toLowerCase() == name) return option;
    }
  }
  return fallback;
}

class RebuildNotifier extends ChangeNotifier {
  void rebuild() => notifyListeners();
}

class AppSettings {
  static final rebuildNotifier = RebuildNotifier();
  static const String version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '2.0.0-preview',
  );

  static GitHub? _github;
  static GitHub get github {
    _github ??= GitHub();
    return _github!;
  }

  static void closeGithub() {
    _github?.dispose();
    _github = null;
  }

  ThemeOption themeOption = ThemeOption.system;

  List<String> artistSeparator = ['/', '、'];

  bool localLyricFirst = true;
  LyricSourceType preferredOnlineSource = LyricSourceType.qq;
  bool showTranslation = true;
  bool showRomanization = true;
  bool showDesktopLyricRoman = true;
  int desktopLyricRomanPosition = 1;
  bool desktopShowTranslation = true;
  bool desktopShowNowPlayingInfo = true;
  bool desktopEnableStroke = true;
  bool desktopEnablePinTop = true;
  double desktopLyricFontSize = 22.0;
  double desktopTranslationFontSize = 18.0;
  int desktopLyricFontWeight = 700;
  double desktopBackgroundOpacity = 0.0;
  int desktopLyricTextAlign = 1;
  int? desktopPlayedColor;
  int? desktopUnplayedColor;
  bool desktopFollowThemeColor = true;
  DesktopLyricBrightnessMode desktopLyricBrightnessMode =
      DesktopLyricBrightnessMode.follow;
  LyricDisplayMode lyricDisplayMode = LyricDisplayMode.wordByWord;
  ZhConversionMode zhConversionMode = ZhConversionMode.none;
  bool promptWriteLyricToTag = true;
  int promptWriteLyricToTagDelay = 15;
  bool autoWriteLyricToTag = false;
  int autoWriteLyricToTagDelay = 30;
  bool useMaterialYouForLyrics = false;
  bool useMaterialYouForProgressBar = false;
  bool useMaterialYouForTransition = false;
  bool useMaterialYouForControls = false;
  bool keepPitch = true;
  Set<NowPlayingMode> wavyBarEnabledModes = defaultWavyBarEnabledModes();
  TopBarLyricAnimation topBarLyricAnimation = TopBarLyricAnimation.slideUp;
  bool enableCoverColorExtraction = true;
  int? customCoverColor;
  Size windowSize = const Size(1280, 756);
  bool isWindowMaximized = false;

  String? fontFamily;
  String? fontPath;

  late String artistSplitPattern = artistSeparator.join('|');
  RegExp? _cachedArtistSplitRegex;

  /// 缓存的正则，避免每个 Audio 构造时重新编译
  RegExp get artistSplitRegex =>
      _cachedArtistSplitRegex ??= RegExp(artistSplitPattern);

  static final AppSettings _instance = AppSettings._();

  static AppSettings get instance => _instance;

  static ThemeMode getWindowsThemeMode() {
    final systemTheme = SystemTheme.getSystemTheme();

    final isDarkMode = (((5 * systemTheme.fore.$3) +
            (2 * systemTheme.fore.$2) +
            systemTheme.fore.$4) >
        (8 * 128));
    return isDarkMode ? ThemeMode.dark : ThemeMode.light;
  }

  static int getWindowsTheme() {
    final systemTheme = SystemTheme.getSystemTheme();
    return Color.fromARGB(
      systemTheme.accent.$1,
      systemTheme.accent.$2,
      systemTheme.accent.$3,
      systemTheme.accent.$4,
    ).toARGB32();
  }

  AppSettings._();

  static Future<void> _readFromJsonOld(Map settingsMap) async {
    final to = settingsMap['ThemeOption'];
    if (to != null) {
      _instance.themeOption = normalizedThemeOption(to);
    }
    final oldSep = settingsMap['ArtistSeparator'];
    if (oldSep != null) {
      _instance.artistSeparator = normalizedArtistSeparators(oldSep);
    }
    _instance.artistSplitPattern = _instance.artistSeparator.join('|');

    final llf = settingsMap['LocalLyricFirst'];
    if (llf != null) {
      _instance.localLyricFirst = normalizedBoolSetting(
        llf,
        defaultValue: true,
      );
    }

    final st = settingsMap['ShowTranslation'];
    if (st != null) {
      _instance.showTranslation = normalizedBoolSetting(
        st,
        defaultValue: true,
      );
    }
    final sr = settingsMap['ShowRomanization'];
    if (sr != null) {
      _instance.showRomanization = normalizedBoolSetting(
        sr,
        defaultValue: true,
      );
    }

    final sizeStr = settingsMap['WindowSize'];
    if (sizeStr != null) {
      final size = normalizedWindowSizeSetting(sizeStr);
      _instance.windowSize = Size(size.width, size.height);
    }

    final isMaximized = settingsMap['IsWindowMaximized'];
    if (isMaximized != null) {
      _instance.isWindowMaximized = normalizedBoolSetting(
        isMaximized,
        defaultValue: false,
      );
    }
  }

  @visibleForTesting
  static Future<void> readFromSettingsMapForTest(Map settingsMap) =>
      _readFromSettingsMap(settingsMap);

  static Future<void> _readFromSettingsMap(Map settingsMap) async {
    if (settingsMap['Version'] == null) {
      return _readFromJsonOld(settingsMap);
    }

    final to = settingsMap['ThemeOption'];
    if (to != null) {
      _instance.themeOption = normalizedThemeOption(to);
    }

    final sep = settingsMap['ArtistSeparator'];
    if (sep != null) {
      _instance.artistSeparator = normalizedArtistSeparators(sep);
      _instance.artistSplitPattern = _instance.artistSeparator.join('|');
    }

    final llf = settingsMap['LocalLyricFirst'];
    if (llf != null) {
      _instance.localLyricFirst = normalizedBoolSetting(
        llf,
        defaultValue: true,
      );
    }

    final pos = settingsMap['PreferredOnlineSource'];
    if (pos != null) {
      _instance.preferredOnlineSource = normalizedSettingEnumValue(
        pos,
        LyricSourceType.values,
        fallback: LyricSourceType.qq,
      )!;
    }

    final st = settingsMap['ShowTranslation'];
    if (st != null) {
      _instance.showTranslation = normalizedBoolSetting(
        st,
        defaultValue: true,
      );
    }
    final sr = settingsMap['ShowRomanization'];
    if (sr != null) {
      _instance.showRomanization = normalizedBoolSetting(
        sr,
        defaultValue: true,
      );
    }

    final ldm = settingsMap['LyricDisplayMode'];
    if (ldm != null) {
      final modeName = normalizedSettingEnumName(ldm);
      _instance.lyricDisplayMode =
          normalizedSettingEnumValue(ldm, LyricDisplayMode.values) ??
              switch (modeName) {
                'plain' => LyricDisplayMode.lineByLine,
                'verbatim' => LyricDisplayMode.wordByWord,
                'enhanced' => LyricDisplayMode.wordByWord,
                _ => LyricDisplayMode.wordByWord,
              };
    }

    final zcm = settingsMap['ZhConversionMode'];
    if (zcm != null) {
      final modeName = normalizedSettingEnumName(zcm);
      _instance.zhConversionMode =
          normalizedSettingEnumValue(zcm, ZhConversionMode.values) ??
              switch (modeName) {
                't2s' => ZhConversionMode.traditionalToSimplified,
                's2t' => ZhConversionMode.simplifiedToTraditional,
                _ => ZhConversionMode.none,
              };
    }

    final pwt = settingsMap['PromptWriteLyricToTag'];
    if (pwt != null) {
      _instance.promptWriteLyricToTag = normalizedBoolSetting(
        pwt,
        defaultValue: true,
      );
    }

    final pwd = settingsMap['PromptWriteLyricToTagDelay'];
    if (pwd != null) {
      _instance.promptWriteLyricToTagDelay = normalizedBoundedIntSetting(
        pwd,
        defaultValue: 15,
        min: 5,
        max: 60,
      );
    }

    final awt = settingsMap['AutoWriteLyricToTag'];
    if (awt != null) {
      _instance.autoWriteLyricToTag = normalizedBoolSetting(
        awt,
        defaultValue: false,
      );
    }

    final awd = settingsMap['AutoWriteLyricToTagDelay'];
    if (awd != null) {
      _instance.autoWriteLyricToTagDelay = normalizedBoundedIntSetting(
        awd,
        defaultValue: 30,
        min: 10,
        max: 120,
      );
    }

    final umyl = settingsMap['UseMaterialYouForLyrics'];
    if (umyl != null) {
      _instance.useMaterialYouForLyrics = normalizedBoolSetting(
        umyl,
        defaultValue: false,
      );
    }

    final umypb = settingsMap['UseMaterialYouForProgressBar'];
    if (umypb != null) {
      _instance.useMaterialYouForProgressBar = normalizedBoolSetting(
        umypb,
        defaultValue: false,
      );
    }

    final umyt = settingsMap['UseMaterialYouForTransition'];
    if (umyt != null) {
      _instance.useMaterialYouForTransition = normalizedBoolSetting(
        umyt,
        defaultValue: false,
      );
    }

    final umyc = settingsMap['UseMaterialYouForControls'];
    if (umyc != null) {
      _instance.useMaterialYouForControls = normalizedBoolSetting(
        umyc,
        defaultValue: false,
      );
    }

    final kp = settingsMap['KeepPitch'];
    if (kp != null) {
      _instance.keepPitch = normalizedBoolSetting(
        kp,
        defaultValue: true,
      );
    }

    if (settingsMap.containsKey('WavyBarEnabledModes')) {
      _instance.wavyBarEnabledModes = normalizedWavyBarEnabledModes(
        settingsMap['WavyBarEnabledModes'],
      );
    }

    final tbla = settingsMap['TopBarLyricAnimation'];
    if (tbla != null) {
      _instance.topBarLyricAnimation = normalizedSettingEnumValue(
        tbla,
        TopBarLyricAnimation.values,
        fallback: TopBarLyricAnimation.slideUp,
      )!;
    }

    final ecce = settingsMap['EnableCoverColorExtraction'];
    if (ecce != null) {
      _instance.enableCoverColorExtraction = normalizedBoolSetting(
        ecce,
        defaultValue: true,
      );
    }

    if (settingsMap.containsKey('CustomCoverColor')) {
      _instance.customCoverColor = normalizedOptionalColorSetting(
        settingsMap['CustomCoverColor'],
      );
    }

    final sizeStr = settingsMap['WindowSize'];
    if (sizeStr != null) {
      final size = normalizedWindowSizeSetting(sizeStr);
      _instance.windowSize = Size(size.width, size.height);
    }

    final isMaximized = settingsMap['IsWindowMaximized'];
    if (isMaximized != null) {
      _instance.isWindowMaximized = normalizedBoolSetting(
        isMaximized,
        defaultValue: false,
      );
    }

    final sdlr = settingsMap['ShowDesktopLyricRoman'];
    if (sdlr != null) {
      _instance.showDesktopLyricRoman = normalizedBoolSetting(
        sdlr,
        defaultValue: true,
      );
    }

    final dlrp = settingsMap['DesktopLyricRomanPosition'];
    if (dlrp != null) {
      _instance.desktopLyricRomanPosition = normalizedBoundedIntSetting(
        dlrp,
        defaultValue: 1,
        min: 0,
        max: 2,
      );
    }

    final dst = settingsMap['DesktopShowTranslation'];
    if (dst != null) {
      _instance.desktopShowTranslation = normalizedBoolSetting(
        dst,
        defaultValue: true,
      );
    }

    final dsnp = settingsMap['DesktopShowNowPlayingInfo'];
    if (dsnp != null) {
      _instance.desktopShowNowPlayingInfo = normalizedBoolSetting(
        dsnp,
        defaultValue: true,
      );
    }

    final des = settingsMap['DesktopEnableStroke'];
    if (des != null) {
      _instance.desktopEnableStroke = normalizedBoolSetting(
        des,
        defaultValue: true,
      );
    }

    final dept = settingsMap['DesktopEnablePinTop'];
    if (dept != null) {
      _instance.desktopEnablePinTop = normalizedBoolSetting(
        dept,
        defaultValue: true,
      );
    }

    final dls = settingsMap['DesktopLyricFontSize'];
    if (dls != null) {
      _instance.desktopLyricFontSize = (dls as num).clamp(12, 60).toDouble();
    }

    final dts = settingsMap['DesktopTranslationFontSize'];
    if (dts != null) {
      _instance.desktopTranslationFontSize =
          (dts as num).clamp(8, 48).toDouble();
    }

    final dlfw = settingsMap['DesktopLyricFontWeight'];
    if (dlfw != null) {
      _instance.desktopLyricFontWeight =
          ((dlfw as num).toInt()).clamp(100, 900);
    }

    final dbo = settingsMap['DesktopBackgroundOpacity'];
    if (dbo != null) {
      _instance.desktopBackgroundOpacity =
          (dbo as num).clamp(0.0, 1.0).toDouble();
    }

    final dlta = settingsMap['DesktopLyricTextAlign'];
    if (dlta != null) {
      _instance.desktopLyricTextAlign = ((dlta as num).toInt()).clamp(0, 2);
    }

    if (settingsMap.containsKey('DesktopTextColor')) {
      _instance.desktopPlayedColor = settingsMap['DesktopTextColor'] as int?;
    }
    if (settingsMap.containsKey('DesktopPlayedColor')) {
      _instance.desktopPlayedColor = settingsMap['DesktopPlayedColor'] as int?;
    }
    if (settingsMap.containsKey('DesktopUnplayedColor')) {
      _instance.desktopUnplayedColor =
          settingsMap['DesktopUnplayedColor'] as int?;
    }

    final dftc = settingsMap['DesktopFollowThemeColor'];
    if (dftc != null) {
      _instance.desktopFollowThemeColor =
          normalizedBoolSetting(dftc, defaultValue: true);
    }

    _instance.desktopLyricBrightnessMode =
        DesktopLyricBrightnessMode.fromString(
              settingsMap['DesktopLyricBrightnessMode']?.toString(),
            ) ??
            DesktopLyricBrightnessMode.follow;

    final ff = settingsMap['FontFamily'];
    final fp = settingsMap['FontPath'];
    if (ff != null || fp != null) {
      final fontFamily = normalizedStringSetting(ff);
      final fontPath = normalizedPathSetting(fp);
      if (fontFamily == null || fontPath == null) {
        _instance.fontFamily = null;
        _instance.fontPath = null;
      } else {
        _instance.fontFamily = fontFamily;
        _instance.fontPath = fontPath;
      }
    }
  }

  static Future<void> readFromJson() async {
    try {
      final dir = await getSettingsDir();
      final settingsPath = path.join(dir.path, 'settings.json');

      final settingsStr = File(settingsPath).readAsStringSync();
      Map settingsMap = json.decode(settingsStr);
      await _readFromSettingsMap(settingsMap);
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
    }
  }

  Future<bool> saveSettings() async {
    try {
      final isMaximized = await windowManager.isMaximized();
      final settingsMap = {
        'Version': version,
        'ThemeOption': themeOption.index,
        'ArtistSeparator': artistSeparator,
        'LocalLyricFirst': localLyricFirst,
        'PreferredOnlineSource': preferredOnlineSource.name,
        'ShowTranslation': showTranslation,
        'ShowRomanization': showRomanization,
        'ShowDesktopLyricRoman': showDesktopLyricRoman,
        'DesktopLyricRomanPosition': desktopLyricRomanPosition,
        'DesktopShowTranslation': desktopShowTranslation,
        'DesktopShowNowPlayingInfo': desktopShowNowPlayingInfo,
        'DesktopEnableStroke': desktopEnableStroke,
        'DesktopEnablePinTop': desktopEnablePinTop,
        'DesktopLyricFontSize': desktopLyricFontSize,
        'DesktopTranslationFontSize': desktopTranslationFontSize,
        'DesktopLyricFontWeight': desktopLyricFontWeight,
        'DesktopBackgroundOpacity': desktopBackgroundOpacity,
        'DesktopLyricTextAlign': desktopLyricTextAlign,
        'DesktopPlayedColor': desktopPlayedColor,
        'DesktopUnplayedColor': desktopUnplayedColor,
        'DesktopFollowThemeColor': desktopFollowThemeColor,
        'DesktopLyricBrightnessMode': desktopLyricBrightnessMode.name,
        'LyricDisplayMode': lyricDisplayMode.name,
        'ZhConversionMode': zhConversionMode.name,
        'PromptWriteLyricToTag': promptWriteLyricToTag,
        'PromptWriteLyricToTagDelay': promptWriteLyricToTagDelay,
        'AutoWriteLyricToTag': autoWriteLyricToTag,
        'AutoWriteLyricToTagDelay': autoWriteLyricToTagDelay,
        'UseMaterialYouForLyrics': useMaterialYouForLyrics,
        'UseMaterialYouForProgressBar': useMaterialYouForProgressBar,
        'UseMaterialYouForTransition': useMaterialYouForTransition,
        'UseMaterialYouForControls': useMaterialYouForControls,
        'KeepPitch': keepPitch,
        'WavyBarEnabledModes': NowPlayingMode.toList(wavyBarEnabledModes),
        'TopBarLyricAnimation': topBarLyricAnimation.name,
        'EnableCoverColorExtraction': enableCoverColorExtraction,
        'CustomCoverColor': customCoverColor,
        'IsWindowMaximized': isMaximized,
        'FontFamily': fontFamily,
        'FontPath': fontPath,
      };

      Size sizeToSave = windowSize;
      if (!isMaximized) {
        sizeToSave = await windowManager.getSize();
      }
      settingsMap['WindowSize'] =
          '${sizeToSave.width.toStringAsFixed(1)},${sizeToSave.height.toStringAsFixed(1)}';

      final settingsStr = json.encode(settingsMap);
      final dir = await getSettingsDir();
      final settingsPath = path.join(dir.path, 'settings.json');
      await writeTextFileAtomically(settingsPath, settingsStr);
      return true;
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
      return false;
    }
  }
}
