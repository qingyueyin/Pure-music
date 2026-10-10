import 'dart:convert';
import 'dart:io';
import 'package:pure_music/core/hotkey_binding.dart';
import 'package:pure_music/core/artist_name_splitter.dart';
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/core/settings/settings_decoder.dart';
import 'package:pure_music/core/settings/settings_types.dart';
import 'package:pure_music/native/rust/api/system_theme.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/zh_converter.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/lyric/lyric_tag_word_format.dart';
import 'package:flutter/material.dart';
import 'package:github/github.dart';
import 'package:path/path.dart' as path;
import 'package:window_manager/window_manager.dart';

export 'settings/settings_decoder.dart';
export 'settings/settings_types.dart';

const bool portableBuild = bool.fromEnvironment(
  'PORTABLE_BUILD',
  defaultValue: true,
);

const bool enableOnlineLyricWriting = true;

String resolveAppDataPath({
  required bool usePortableData,
  required String executablePath,
  required Map<String, String> environment,
}) {
  final exeBase = path.basename(executablePath).toLowerCase();
  if (usePortableData &&
      exeBase != 'dart.exe' &&
      exeBase != 'flutter_tester.exe') {
    return path.join(path.dirname(executablePath), 'data');
  }

  final localAppData = environment['LOCALAPPDATA'];
  if (localAppData != null && localAppData.trim().isNotEmpty) {
    return path.join(localAppData, 'pure_music');
  }

  final userProfile = environment['USERPROFILE'];
  if (userProfile != null && userProfile.trim().isNotEmpty) {
    return path.join(userProfile, 'AppData', 'Local', 'pure_music');
  }

  final appData = environment['APPDATA'];
  if (appData != null && appData.trim().isNotEmpty) {
    return path.join(appData, 'pure_music');
  }

  throw StateError('Unable to determine app data directory');
}

List<String> appDataPathCandidates({
  required bool usePortableData,
  required String executablePath,
  required Map<String, String> environment,
}) {
  final preferred = resolveAppDataPath(
    usePortableData: usePortableData,
    executablePath: executablePath,
    environment: environment,
  );
  final fallback = resolveAppDataPath(
    usePortableData: false,
    executablePath: executablePath,
    environment: environment,
  );
  return [
    preferred,
    if (path.normalize(preferred).toLowerCase() !=
        path.normalize(fallback).toLowerCase())
      fallback,
  ];
}

Future<Directory>? _appDataDirectoryFuture;

Future<Directory> getAppDataDir() {
  return _appDataDirectoryFuture ??= _resolveAppDataDir();
}

Future<Directory> _resolveAppDataDir() async {
  final executable = Platform.resolvedExecutable;
  final candidates = appDataPathCandidates(
    usePortableData: portableBuild,
    executablePath: executable,
    environment: Platform.environment,
  );
  Object? lastError;
  for (final candidate in candidates) {
    try {
      final directory = await Directory(candidate).create(recursive: true);
      await _verifyWritableDirectory(directory);
      return directory;
    } catch (error) {
      lastError = error;
    }
  }
  throw StateError('Unable to create writable app data directory: $lastError');
}

Future<void> _verifyWritableDirectory(Directory directory) async {
  final probe = File(
    path.join(
      directory.path,
      '.pure_music_write_test_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  try {
    await probe.writeAsBytes(const <int>[], flush: true);
  } finally {
    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {}
  }
}

Future<Directory> getSettingsDir() async {
  final root = await getAppDataDir();
  return Directory(path.join(root.path, 'settings')).create(recursive: true);
}

final Map<String, Future<void>> _atomicWriteQueues = <String, Future<void>>{};

Future<void> _writeTextFileAtomicallyNow(
  String filePath,
  String content,
) async {
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

Future<void> writeTextFileAtomically(String filePath, String content) {
  final queueKey = path.normalize(path.absolute(filePath)).toLowerCase();
  final previous = _atomicWriteQueues[queueKey];
  late Future<void> current;
  current = _writeQueuedTextFile(
    previous: previous,
    filePath: filePath,
    content: content,
    queueKey: queueKey,
    current: () => current,
  );
  _atomicWriteQueues[queueKey] = current;
  return current;
}

Future<void> _writeQueuedTextFile({
  required Future<void>? previous,
  required String filePath,
  required String content,
  required String queueKey,
  required Future<void> Function() current,
}) async {
  try {
    if (previous != null) {
      try {
        await previous;
      } catch (_) {}
    }
    await _writeTextFileAtomicallyNow(filePath, content);
  } finally {
    if (identical(_atomicWriteQueues[queueKey], current())) {
      _atomicWriteQueues.remove(queueKey);
    }
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

class RebuildNotifier extends ChangeNotifier {
  void rebuild() => notifyListeners();
}

class AppSettings {
  static final rebuildNotifier = RebuildNotifier();
  static final backgroundNotifier = RebuildNotifier();
  static final listMotionNotifier = RebuildNotifier();
  static const String version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '2.2.5',
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
  ThemeColorMode themeColorMode = ThemeColorMode.material3;

  List<String> artistSeparator = ['/', '、'];
  List<String> artistNoSplitNames = [];
  bool enableFeatArtistSplit = false;
  Map<String, String> artistAliases = {};

  bool localLyricFirst = true;
  LyricSourceType preferredOnlineSource = LyricSourceType.qq;
  bool showTranslation = true;
  bool showRomanization = true;
  bool keepLyricMetadata = true;
  bool showDesktopLyricRoman = true;
  int desktopLyricRomanPosition = 1;
  bool desktopShowTranslation = true;
  int desktopLyricTranslationPosition = 1;
  bool desktopShowNowPlayingInfo = true;
  bool desktopHideOnPause = false;
  bool desktopHoverHide = false;
  bool desktopFullscreenHide = false;
  double desktopLineGap = 4.0;
  bool desktopEnableStroke = true;
  bool desktopEnablePinTop = true;
  bool desktopUseVerticalDisplayMode = false;
  bool desktopShowDoubleLine = false;
  bool desktopUseMultiLineMode = false;
  bool desktopHidePlayedLines = false;
  double desktopLyricFontSize = 22.0;
  double desktopTranslationFontSize = 18.0;
  int desktopLyricFontWeight = 700;
  double desktopBackgroundOpacity = 0.0;
  double desktopFontOpacity = 1.0;
  int desktopLyricTextAlign = 1;
  DesktopLyricAnimation desktopLyricAnimation = DesktopLyricAnimation.slideUp;
  LyricStaggerStyle desktopMultiLineAnimation = LyricStaggerStyle.smooth;
  int? desktopPlayedColor;
  int? desktopUnplayedColor;
  bool desktopFollowThemeColor = true;
  bool desktopIconFollowThemeColor = true;
  DesktopLyricBrightnessMode desktopLyricBrightnessMode =
      DesktopLyricBrightnessMode.follow;
  ZhConversionMode zhConversionMode = ZhConversionMode.none;
  int promptWriteLyricToTagDelay = 15;
  LyricWriteMode lyricWriteMode = LyricWriteMode.ask;
  int autoWriteLyricToTagDelay = 30;
  LyricTagWordFormat lyricTagWordFormat = LyricTagWordFormat.enhanced;
  bool lyricTagIncludeTranslation = true;
  bool lyricTagIncludeRomanization = true;
  bool autoSaveExternalLyric = false;
  bool useMaterialYouForLyrics = false;
  bool useMaterialYouForProgressBar = false;
  bool useMaterialYouForTransition = false;
  bool useMaterialYouForControls = false;
  bool keepPitch = true;
  bool lastFmEnabled = false;
  Set<NowPlayingMode> wavyBarEnabledModes = defaultWavyBarEnabledModes();
  TopBarLyricAnimation topBarLyricAnimation = TopBarLyricAnimation.slideUp;
  bool enableCoverColorExtraction = true;
  ThemeColorSource themeColorSource = ThemeColorSource.cover;
  bool enableStackedScrollEffect = true;
  bool enableContentTransitionMotion = true;
  bool enableInteractiveSurfaceMotion = true;
  bool enableCoverPointerSheen = true;
  bool enableDetailHeaderCollapseMotion = true;
  bool enableDataTransitionMotion = true;
  bool alwaysShowNowPlayingControls = false;
  bool globalHotkeysEnabled = false;
  Map<HotkeyAction, HotkeyBinding> inAppHotkeys = defaultInAppHotkeys();
  Map<HotkeyAction, HotkeyBinding> globalHotkeys = defaultGlobalHotkeys();
  int? customCoverColor;
  String? appBackgroundImagePath;
  double appBackgroundImageOpacity = 0.22;
  double appBackgroundImageBlur = 0;
  bool appWindowTransparent = false;
  double appWindowOpacity = 1.0;
  double appWindowBlur = 0;
  bool enableTitleBarFrostedGlass = false;
  bool enableSidebarFrostedGlass = false;
  Size windowSize = const Size(1280, 756);
  Offset? windowPosition;
  bool isWindowMaximized = false;
  WindowCloseBehavior windowCloseBehavior = WindowCloseBehavior.exit;
  bool preventSleepOnNowPlaying = false;
  bool rememberPlaybackPosition = false;

  String? midiSoundfontPath;

  String? fontFamily;
  String? fontPath;
  bool lyricFontFollowsUi = true;
  String? lyricFontFamily;
  String? lyricFontPath;

  late String artistSplitPattern = _patternFromSeparators(artistSeparator);
  String? _cachedArtistSplitPattern;
  RegExp? _cachedArtistSplitRegex;

  static final RegExp _neverMatchingSplitRegex = RegExp('(?!x)x');

  List<String> get effectiveArtistSeparators {
    if (!enableFeatArtistSplit) return artistSeparator;
    return [...artistSeparator, ...ArtistNameSplitter.featSeparators];
  }

  String get artistSplitSignature {
    final aliases = artistAliases.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return json.encode({
      'separators': artistSeparator,
      'noSplit': artistNoSplitNames,
      'feat': enableFeatArtistSplit,
      'aliases': {for (final entry in aliases) entry.key: entry.value},
    });
  }

  void syncArtistSplitPattern() {
    artistSplitPattern = _patternFromSeparators(effectiveArtistSeparators);
    _cachedArtistSplitPattern = null;
    _cachedArtistSplitRegex = null;
  }

  static String _patternFromSeparators(List<String> separators) {
    return separators.map(RegExp.escape).join('|');
  }

  List<String> splitArtistNames(String raw) {
    return ArtistNameSplitter.split(
      raw,
      separators: effectiveArtistSeparators,
      noSplitNames: artistNoSplitNames,
      aliases: artistAliases,
    );
  }

  /// 缓存的正则，避免每个 Audio 构造时重新编译；分隔符改了要跟着换
  RegExp get artistSplitRegex {
    final pattern = artistSplitPattern;
    if (pattern.isEmpty) return _neverMatchingSplitRegex;
    final cached = _cachedArtistSplitRegex;
    if (cached != null && _cachedArtistSplitPattern == pattern) {
      return cached;
    }
    _cachedArtistSplitPattern = pattern;
    return _cachedArtistSplitRegex = RegExp(pattern, caseSensitive: false);
  }

  static final AppSettings _instance = AppSettings._();

  static AppSettings get instance => _instance;

  static ThemeMode getWindowsThemeMode() {
    final systemTheme = SystemTheme.getSystemTheme();

    final isDarkMode =
        (((5 * systemTheme.fore.$3) +
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
    _readThemeMotionHotkeySettings(settingsMap);
    _readBackgroundGlassSettings(settingsMap);
    _readLegacyArtistSeparator(settingsMap);
    _readLyricPreferenceSettings(settingsMap);
    _readWindowPlaybackSettings(settingsMap);
  }

  static void _readLegacyArtistSeparator(Map settingsMap) {
    final oldSep = settingsMap['ArtistSeparator'];
    if (oldSep != null) {
      _instance.artistSeparator = normalizedArtistSeparators(oldSep);
    }
    _instance.syncArtistSplitPattern();
  }

  @visibleForTesting
  static Future<void> readFromSettingsMapForTest(Map settingsMap) =>
      _readFromSettingsMap(settingsMap);

  static Future<void> _readFromSettingsMap(Map settingsMap) async {
    if (settingsMap['Version'] == null) {
      return _readFromJsonOld(settingsMap);
    }
    _readThemeMotionHotkeySettings(settingsMap);
    _readLyricPreferenceSettings(settingsMap);
    _readLyricConversionAndDelaySettings(settingsMap);
    _readLyricTagSettings(settingsMap);
    _readMaterialScrobbleSettings(settingsMap);
    _readCoverColorSettings(settingsMap);
    _readBackgroundGlassSettings(settingsMap);
    _readWindowPlaybackSettings(settingsMap);
    _readDesktopLyricVisibilitySettings(settingsMap);
    _readDesktopLyricBehaviorSettings(settingsMap);
    _readDesktopLyricLayoutSettings(settingsMap);
    _readDesktopLyricTypographySettings(settingsMap);
    _readDesktopLyricColorSettings(settingsMap);
    _readFontSettings(settingsMap);
  }

  static void _readThemeMotionHotkeySettings(Map settingsMap) {
    final to = settingsMap['ThemeOption'];
    if (to != null) {
      _instance.themeOption = normalizedThemeOption(to);
    }
    _instance.themeColorMode = normalizedThemeColorMode(
      settingsMap['ThemeColorMode'],
    );
    final stackedScrollEffect = normalizedBoolSetting(
      settingsMap['EnableStackedScrollEffect'],
      defaultValue: true,
    );
    _instance.enableStackedScrollEffect = stackedScrollEffect;
    _instance.enableContentTransitionMotion = normalizedBoolSetting(
      settingsMap['EnableContentTransitionMotion'],
      defaultValue: true,
    );
    _instance.enableInteractiveSurfaceMotion = normalizedBoolSetting(
      settingsMap['EnableInteractiveSurfaceMotion'],
      defaultValue: stackedScrollEffect,
    );
    _instance.enableCoverPointerSheen = normalizedBoolSetting(
      settingsMap['EnableCoverPointerSheen'],
      defaultValue: stackedScrollEffect,
    );
    _instance.enableDetailHeaderCollapseMotion = normalizedBoolSetting(
      settingsMap['EnableDetailHeaderCollapseMotion'],
      defaultValue: stackedScrollEffect,
    );
    _instance.enableDataTransitionMotion = normalizedBoolSetting(
      settingsMap['EnableDataTransitionMotion'],
      defaultValue: stackedScrollEffect,
    );
    _instance.alwaysShowNowPlayingControls = normalizedBoolSetting(
      settingsMap['AlwaysShowNowPlayingControls'],
      defaultValue: false,
    );
    _instance.globalHotkeysEnabled = normalizedBoolSetting(
      settingsMap['GlobalHotkeysEnabled'],
      defaultValue: false,
    );
    _instance.inAppHotkeys = decodeInAppHotkeys(settingsMap['InAppHotkeys']);
    _instance.globalHotkeys = decodeGlobalHotkeys(settingsMap['GlobalHotkeys']);
  }

  static void _readLyricPreferenceSettings(Map settingsMap) {
    final sep = settingsMap['ArtistSeparator'];
    if (sep != null) {
      _instance.artistSeparator = normalizedArtistSeparators(sep);
    }
    final noSplit = settingsMap['ArtistNoSplitNames'];
    if (noSplit != null) {
      _instance.artistNoSplitNames = uniqueTextListItems(
        noSplit is Iterable ? noSplit.whereType<String>() : const <String>[],
      );
    }
    if (settingsMap['EnableFeatArtistSplit'] != null) {
      _instance.enableFeatArtistSplit = normalizedBoolSetting(
        settingsMap['EnableFeatArtistSplit'],
        defaultValue: false,
      );
    }
    if (settingsMap['ArtistAliases'] != null) {
      _instance.artistAliases = normalizedArtistAliases(
        settingsMap['ArtistAliases'],
      );
    }
    _instance.syncArtistSplitPattern();

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
      _instance.showTranslation = normalizedBoolSetting(st, defaultValue: true);
    }
    final sr = settingsMap['ShowRomanization'];
    if (sr != null) {
      _instance.showRomanization = normalizedBoolSetting(
        sr,
        defaultValue: true,
      );
    }
    final klm = settingsMap['KeepLyricMetadata'];
    if (klm != null) {
      _instance.keepLyricMetadata = normalizedBoolSetting(
        klm,
        defaultValue: true,
      );
    }
  }

  static void _readLyricConversionAndDelaySettings(Map settingsMap) {
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

    final pwd = settingsMap['PromptWriteLyricToTagDelay'];
    if (pwd != null) {
      _instance.promptWriteLyricToTagDelay = normalizedBoundedIntSetting(
        pwd,
        defaultValue: 15,
        min: 5,
        max: 60,
      );
    }

    final lwm = settingsMap['LyricWriteMode'];
    if (lwm != null) {
      _instance.lyricWriteMode = normalizedSettingEnumValue(
        lwm,
        LyricWriteMode.values,
        fallback: LyricWriteMode.ask,
      )!;
    } else if (normalizedBoolSetting(
      settingsMap['AutoWriteLyricToTag'],
      defaultValue: false,
    )) {
      _instance.lyricWriteMode = LyricWriteMode.auto;
    } else {
      _instance.lyricWriteMode = LyricWriteMode.ask;
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
  }

  static void _readLyricTagSettings(Map settingsMap) {
    final ltwf = settingsMap['LyricTagWordFormat'];
    if (ltwf != null) {
      _instance.lyricTagWordFormat = normalizedSettingEnumValue(
        ltwf,
        LyricTagWordFormat.values,
        fallback: LyricTagWordFormat.enhanced,
      )!;
    }

    final ltit = settingsMap['LyricTagIncludeTranslation'];
    if (ltit != null) {
      _instance.lyricTagIncludeTranslation = normalizedBoolSetting(
        ltit,
        defaultValue: true,
      );
    }

    final ltir = settingsMap['LyricTagIncludeRomanization'];
    if (ltir != null) {
      _instance.lyricTagIncludeRomanization = normalizedBoolSetting(
        ltir,
        defaultValue: true,
      );
    }

    final asel = settingsMap['AutoSaveExternalLyric'];
    if (asel != null) {
      _instance.autoSaveExternalLyric = normalizedBoolSetting(
        asel,
        defaultValue: false,
      );
    }
  }

  static void _readMaterialScrobbleSettings(Map settingsMap) {
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
      _instance.keepPitch = normalizedBoolSetting(kp, defaultValue: true);
    }

    _instance.lastFmEnabled = normalizedBoolSetting(
      settingsMap['LastFmEnabled'],
      defaultValue: false,
    );

    if (settingsMap.containsKey('WavyBarEnabledModes')) {
      _instance.wavyBarEnabledModes = normalizedWavyBarEnabledModes(
        settingsMap['WavyBarEnabledModes'],
      );
    }
  }

  static void _readCoverColorSettings(Map settingsMap) {
    final tbla = settingsMap['TopBarLyricAnimation'];
    if (tbla != null) {
      final storedName = normalizedSettingEnumName(tbla);
      _instance.topBarLyricAnimation = switch (storedName) {
        'flipx' => TopBarLyricAnimation.slideLeft,
        'flipy' => TopBarLyricAnimation.slideRight,
        _ => normalizedSettingEnumValue(
          tbla,
          TopBarLyricAnimation.values,
          fallback: TopBarLyricAnimation.slideUp,
        )!,
      };
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

    final storedSource = normalizedThemeColorSource(
      settingsMap['ThemeColorSource'],
    );
    if (storedSource != null) {
      _instance.themeColorSource = storedSource;
      _instance.enableCoverColorExtraction =
          storedSource == ThemeColorSource.cover;
    } else if (settingsMap.containsKey('EnableCoverColorExtraction') ||
        settingsMap.containsKey('CustomCoverColor')) {
      if (_instance.enableCoverColorExtraction) {
        _instance.themeColorSource = ThemeColorSource.cover;
      } else if (_instance.customCoverColor != null) {
        _instance.themeColorSource = ThemeColorSource.custom;
      } else {
        _instance.themeColorSource = ThemeColorSource.system;
      }
    }
  }

  static void _readBackgroundGlassSettings(Map settingsMap) {
    _instance.appBackgroundImagePath = normalizedPathSetting(
      settingsMap['AppBackgroundImagePath'],
    );
    final backgroundOpacity = settingsMap['AppBackgroundImageOpacity'];
    _instance.appBackgroundImageOpacity = backgroundOpacity is num
        ? backgroundOpacity.clamp(0.1, 0.6).toDouble()
        : 0.22;
    final backgroundBlur = settingsMap['AppBackgroundImageBlur'];
    _instance.appBackgroundImageBlur = backgroundBlur is num
        ? backgroundBlur.clamp(0.0, 30.0).toDouble()
        : 0.0;
    _instance.appWindowTransparent = normalizedBoolSetting(
      settingsMap['AppWindowTransparent'],
      defaultValue: false,
    );
    final windowOpacity = settingsMap['AppWindowOpacity'];
    _instance.appWindowOpacity = windowOpacity is num
        ? windowOpacity.clamp(0.1, 1.0).toDouble()
        : 1.0;
    final windowBlur = settingsMap['AppWindowBlur'];
    _instance.appWindowBlur = windowBlur is num
        ? windowBlur.clamp(0.0, 30.0).toDouble()
        : 0.0;
    _instance.enableTitleBarFrostedGlass = normalizedBoolSetting(
      settingsMap['EnableTitleBarFrostedGlass'],
      defaultValue: false,
    );
    _instance.enableSidebarFrostedGlass = normalizedBoolSetting(
      settingsMap['EnableSidebarFrostedGlass'],
      defaultValue: false,
    );
  }

  static void _readWindowPlaybackSettings(Map settingsMap) {
    final sizeStr = settingsMap['WindowSize'];
    if (sizeStr != null) {
      final size = normalizedWindowSizeSetting(sizeStr);
      _instance.windowSize = Size(size.width, size.height);
    }

    final position = normalizedWindowPositionSetting(
      settingsMap['WindowPosition'],
    );
    if (position != null) {
      _instance.windowPosition = Offset(position.x, position.y);
    }

    final isMaximized = settingsMap['IsWindowMaximized'];
    if (isMaximized != null) {
      _instance.isWindowMaximized = normalizedBoolSetting(
        isMaximized,
        defaultValue: false,
      );
    }

    _instance.windowCloseBehavior =
        normalizedSettingEnumValue(
          settingsMap['WindowCloseBehavior'],
          WindowCloseBehavior.values,
        ) ??
        WindowCloseBehavior.exit;
    _instance.preventSleepOnNowPlaying = normalizedBoolSetting(
      settingsMap['PreventSleepOnNowPlaying'],
      defaultValue: false,
    );
    _instance.rememberPlaybackPosition = normalizedBoolSetting(
      settingsMap['RememberPlaybackPosition'],
      defaultValue: false,
    );
    _instance.midiSoundfontPath = normalizedPathSetting(
      settingsMap['MidiSoundfontPath'],
    );
  }

  static void _readDesktopLyricVisibilitySettings(Map settingsMap) {
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

    final dltp = settingsMap['DesktopLyricTranslationPosition'];
    if (dltp != null) {
      _instance.desktopLyricTranslationPosition = normalizedBoundedIntSetting(
        dltp,
        defaultValue: 1,
        min: 0,
        max: 1,
      );
    }

    final dsnp = settingsMap['DesktopShowNowPlayingInfo'];
    if (dsnp != null) {
      _instance.desktopShowNowPlayingInfo = normalizedBoolSetting(
        dsnp,
        defaultValue: true,
      );
    }
  }

  static void _readDesktopLyricBehaviorSettings(Map settingsMap) {
    final dhop = settingsMap['DesktopHideOnPause'];
    if (dhop != null) {
      _instance.desktopHideOnPause = normalizedBoolSetting(
        dhop,
        defaultValue: false,
      );
    }

    final dhh = settingsMap['DesktopHoverHide'];
    if (dhh != null) {
      _instance.desktopHoverHide = normalizedBoolSetting(
        dhh,
        defaultValue: false,
      );
    }

    final dfh = settingsMap['DesktopFullscreenHide'];
    if (dfh != null) {
      _instance.desktopFullscreenHide = normalizedBoolSetting(
        dfh,
        defaultValue: false,
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
  }

  static void _readDesktopLyricLayoutSettings(Map settingsMap) {
    final dvu = settingsMap['DesktopUseVerticalDisplayMode'];
    if (dvu != null) {
      _instance.desktopUseVerticalDisplayMode = normalizedBoolSetting(
        dvu,
        defaultValue: false,
      );
    }

    final dsdl = settingsMap['DesktopShowDoubleLine'];
    if (dsdl != null) {
      _instance.desktopShowDoubleLine = normalizedBoolSetting(
        dsdl,
        defaultValue: false,
      );
    }

    final dum = settingsMap['DesktopUseMultiLineMode'];
    if (dum != null) {
      _instance.desktopUseMultiLineMode = normalizedBoolSetting(
        dum,
        defaultValue: false,
      );
    }
    if (_instance.desktopUseMultiLineMode) {
      _instance.desktopShowDoubleLine = false;
    }

    final dhpl = settingsMap['DesktopHidePlayedLines'];
    if (dhpl != null) {
      _instance.desktopHidePlayedLines = normalizedBoolSetting(
        dhpl,
        defaultValue: false,
      );
    }
  }

  static void _readDesktopLyricTypographySettings(Map settingsMap) {
    final dls = settingsMap['DesktopLyricFontSize'];
    if (dls != null) {
      _instance.desktopLyricFontSize = (dls as num).clamp(12, 60).toDouble();
    }

    final dlg = settingsMap['DesktopLineGap'];
    if (dlg is num) {
      _instance.desktopLineGap = dlg.clamp(0, 16).toDouble();
    }

    final dts = settingsMap['DesktopTranslationFontSize'];
    if (dts != null) {
      _instance.desktopTranslationFontSize = (dts as num)
          .clamp(8, 48)
          .toDouble();
    }

    final dlfw = settingsMap['DesktopLyricFontWeight'];
    if (dlfw != null) {
      _instance.desktopLyricFontWeight = ((dlfw as num).toInt()).clamp(
        100,
        900,
      );
    }

    final dbo = settingsMap['DesktopBackgroundOpacity'];
    if (dbo != null) {
      _instance.desktopBackgroundOpacity = (dbo as num)
          .clamp(0.0, 1.0)
          .toDouble();
    }

    final dfo = settingsMap['DesktopFontOpacity'];
    if (dfo is num) {
      _instance.desktopFontOpacity = dfo.clamp(0, 1).toDouble();
    }

    final dlta = settingsMap['DesktopLyricTextAlign'];
    if (dlta != null) {
      _instance.desktopLyricTextAlign = ((dlta as num).toInt()).clamp(0, 3);
    }
    if (!_instance.desktopShowDoubleLine &&
        _instance.desktopLyricTextAlign == 3) {
      _instance.desktopLyricTextAlign = 1;
    }
  }

  static void _readDesktopLyricColorSettings(Map settingsMap) {
    _instance.desktopLyricAnimation =
        DesktopLyricAnimation.fromString(
          settingsMap['DesktopLyricAnimation']?.toString() ?? '',
        ) ??
        DesktopLyricAnimation.slideUp;
    _instance.desktopMultiLineAnimation =
        LyricStaggerStyle.fromString(
          settingsMap['DesktopMultiLineAnimation']?.toString() ?? '',
        ) ??
        LyricStaggerStyle.smooth;

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
      _instance.desktopFollowThemeColor = normalizedBoolSetting(
        dftc,
        defaultValue: true,
      );
    }

    final difc = settingsMap['DesktopIconFollowThemeColor'];
    if (difc != null) {
      _instance.desktopIconFollowThemeColor = normalizedBoolSetting(
        difc,
        defaultValue: true,
      );
    }

    _instance.desktopLyricBrightnessMode =
        DesktopLyricBrightnessMode.fromString(
          settingsMap['DesktopLyricBrightnessMode']?.toString(),
        ) ??
        DesktopLyricBrightnessMode.follow;
  }

  static void _readFontSettings(Map settingsMap) {
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

    final lff = settingsMap['LyricFontFamily'];
    final lfp = settingsMap['LyricFontPath'];
    if (lff != null || lfp != null) {
      final fontFamily = normalizedStringSetting(lff);
      final fontPath = normalizedPathSetting(lfp);
      if (fontFamily == null || fontPath == null) {
        _instance.lyricFontFamily = null;
        _instance.lyricFontPath = null;
      } else {
        _instance.lyricFontFamily = fontFamily;
        _instance.lyricFontPath = fontPath;
      }
    }

    if (settingsMap.containsKey('LyricFontFollowsUi')) {
      _instance.lyricFontFollowsUi = normalizedBoolSetting(
        settingsMap['LyricFontFollowsUi'],
        defaultValue: true,
      );
    } else {
      _instance.lyricFontFollowsUi = _instance.lyricFontFamily == null;
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
      log.settings.error('legacy', err.toString(), stackTrace: trace);
    }
  }

  Map<String, Object?> _themeMotionHotkeySettingsMap() => {
    'Version': version,
    'ThemeOption': themeOption.index,
    'ThemeColorMode': themeColorMode.name,
    'EnableStackedScrollEffect': enableStackedScrollEffect,
    'EnableContentTransitionMotion': enableContentTransitionMotion,
    'EnableInteractiveSurfaceMotion': enableInteractiveSurfaceMotion,
    'EnableCoverPointerSheen': enableCoverPointerSheen,
    'EnableDetailHeaderCollapseMotion': enableDetailHeaderCollapseMotion,
    'EnableDataTransitionMotion': enableDataTransitionMotion,
    'AlwaysShowNowPlayingControls': alwaysShowNowPlayingControls,
    ...encodeHotkeySettings(
      globalEnabled: globalHotkeysEnabled,
      inApp: inAppHotkeys,
      global: globalHotkeys,
    ),
  };

  Map<String, Object?> _lyricSettingsMap() => {
    'ArtistSeparator': artistSeparator,
    'ArtistNoSplitNames': artistNoSplitNames,
    'EnableFeatArtistSplit': enableFeatArtistSplit,
    'ArtistAliases': artistAliases,
    'LocalLyricFirst': localLyricFirst,
    'PreferredOnlineSource': preferredOnlineSource.name,
    'ShowTranslation': showTranslation,
    'ShowRomanization': showRomanization,
    'KeepLyricMetadata': keepLyricMetadata,
    'ZhConversionMode': zhConversionMode.name,
    'PromptWriteLyricToTagDelay': promptWriteLyricToTagDelay,
    'LyricWriteMode': lyricWriteMode.name,
    'AutoWriteLyricToTag': lyricWriteMode == LyricWriteMode.auto,
    'AutoWriteLyricToTagDelay': autoWriteLyricToTagDelay,
    'LyricTagWordFormat': lyricTagWordFormat.name,
    'LyricTagIncludeTranslation': lyricTagIncludeTranslation,
    'LyricTagIncludeRomanization': lyricTagIncludeRomanization,
    'AutoSaveExternalLyric': autoSaveExternalLyric,
  };

  Map<String, Object?> _desktopLyricSettingsMap() => {
    'ShowDesktopLyricRoman': showDesktopLyricRoman,
    'DesktopLyricRomanPosition': desktopLyricRomanPosition,
    'DesktopShowTranslation': desktopShowTranslation,
    'DesktopLyricTranslationPosition': desktopLyricTranslationPosition,
    'DesktopShowNowPlayingInfo': desktopShowNowPlayingInfo,
    'DesktopHideOnPause': desktopHideOnPause,
    'DesktopHoverHide': desktopHoverHide,
    'DesktopFullscreenHide': desktopFullscreenHide,
    'DesktopEnableStroke': desktopEnableStroke,
    'DesktopEnablePinTop': desktopEnablePinTop,
    'DesktopUseVerticalDisplayMode': desktopUseVerticalDisplayMode,
    'DesktopShowDoubleLine': desktopShowDoubleLine,
    'DesktopUseMultiLineMode': desktopUseMultiLineMode,
    'DesktopHidePlayedLines': desktopHidePlayedLines,
    'DesktopLineGap': desktopLineGap,
    'DesktopLyricFontSize': desktopLyricFontSize,
    'DesktopTranslationFontSize': desktopTranslationFontSize,
    'DesktopLyricFontWeight': desktopLyricFontWeight,
    'DesktopBackgroundOpacity': desktopBackgroundOpacity,
    'DesktopFontOpacity': desktopFontOpacity,
    'DesktopLyricTextAlign': desktopLyricTextAlign,
    'DesktopLyricAnimation': desktopLyricAnimation.name,
    'DesktopMultiLineAnimation': desktopMultiLineAnimation.name,
    'DesktopPlayedColor': desktopPlayedColor,
    'DesktopUnplayedColor': desktopUnplayedColor,
    'DesktopFollowThemeColor': desktopFollowThemeColor,
    'DesktopIconFollowThemeColor': desktopIconFollowThemeColor,
    'DesktopLyricBrightnessMode': desktopLyricBrightnessMode.name,
  };

  Map<String, Object?> _materialAppearanceSettingsMap() => {
    'UseMaterialYouForLyrics': useMaterialYouForLyrics,
    'UseMaterialYouForProgressBar': useMaterialYouForProgressBar,
    'UseMaterialYouForTransition': useMaterialYouForTransition,
    'UseMaterialYouForControls': useMaterialYouForControls,
    'KeepPitch': keepPitch,
    'LastFmEnabled': lastFmEnabled,
    'WavyBarEnabledModes': NowPlayingMode.toList(wavyBarEnabledModes),
    'TopBarLyricAnimation': topBarLyricAnimation.name,
    'EnableCoverColorExtraction': enableCoverColorExtraction,
    'ThemeColorSource': themeColorSource.name,
    'CustomCoverColor': customCoverColor,
    'AppBackgroundImagePath': appBackgroundImagePath,
    'AppBackgroundImageOpacity': appBackgroundImageOpacity,
    'AppBackgroundImageBlur': appBackgroundImageBlur,
    'AppWindowTransparent': appWindowTransparent,
    'AppWindowOpacity': appWindowOpacity,
    'AppWindowBlur': appWindowBlur,
    'EnableTitleBarFrostedGlass': enableTitleBarFrostedGlass,
    'EnableSidebarFrostedGlass': enableSidebarFrostedGlass,
  };

  Map<String, Object?> _windowFontPlaybackSettingsMap() => {
    'WindowCloseBehavior': windowCloseBehavior.name,
    'FontFamily': fontFamily,
    'FontPath': fontPath,
    'LyricFontFollowsUi': lyricFontFollowsUi,
    'LyricFontFamily': lyricFontFamily,
    'LyricFontPath': lyricFontPath,
    'PreventSleepOnNowPlaying': preventSleepOnNowPlaying,
    'RememberPlaybackPosition': rememberPlaybackPosition,
    'MidiSoundfontPath': midiSoundfontPath,
  };

  Future<void> _writeSettingsFile(
    Map<String, Object?> settingsMap, {
    required bool isMaximized,
    required bool isFullScreen,
    required bool isMinimized,
  }) async {
    Size sizeToSave = windowSize;
    Offset? positionToSave = windowPosition;
    if (!isMaximized && !isFullScreen && !isMinimized) {
      final currentSize = await windowManager.getSize();
      if (currentSize.width >= minimumWindowSizeSetting.width &&
          currentSize.height >= minimumWindowSizeSetting.height) {
        sizeToSave = currentSize;
      }
      positionToSave = await windowManager.getPosition();
    }
    final normalizedSize = normalizedWindowSizeSetting([
      sizeToSave.width,
      sizeToSave.height,
    ]);
    sizeToSave = Size(normalizedSize.width, normalizedSize.height);
    windowSize = sizeToSave;
    settingsMap['WindowSize'] = encodedWindowSizeSetting(
      sizeToSave.width,
      sizeToSave.height,
    );
    if (positionToSave != null) {
      windowPosition = positionToSave;
      settingsMap['WindowPosition'] = encodedWindowPositionSetting(
        positionToSave.dx,
        positionToSave.dy,
      );
    }
    final settingsStr = json.encode(settingsMap);
    final dir = await getSettingsDir();
    final settingsPath = path.join(dir.path, 'settings.json');
    await writeTextFileAtomically(settingsPath, settingsStr);
  }

  Future<bool> saveSettings() async {
    try {
      final isMaximized = await windowManager.isMaximized();
      final isFullScreen = await windowManager.isFullScreen();
      final isMinimized = await windowManager.isMinimized();
      final settingsMap = <String, Object?>{
        ..._themeMotionHotkeySettingsMap(),
        ..._lyricSettingsMap(),
        ..._desktopLyricSettingsMap(),
        ..._materialAppearanceSettingsMap(),
        'IsWindowMaximized': isMaximized,
        ..._windowFontPlaybackSettingsMap(),
      };
      await _writeSettingsFile(
        settingsMap,
        isMaximized: isMaximized,
        isFullScreen: isFullScreen,
        isMinimized: isMinimized,
      );
      return true;
    } catch (err, trace) {
      log.settings.error('legacy', err.toString(), stackTrace: trace);
      return false;
    }
  }
}
