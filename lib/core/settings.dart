import 'dart:convert';
import 'dart:io';
import 'package:pure_music/core/setting_action_state.dart';
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

Future<Directory> getAppDataDir() async {
  final exe = Platform.resolvedExecutable;
  final resolvedPath = resolveAppDataPath(
    usePortableData: portableBuild,
    executablePath: exe,
    environment: Platform.environment,
  );
  return Directory(resolvedPath).create(recursive: true);
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

/// 歌词显示模式（控制是否使用逐字歌词）
enum LyricDisplayMode {
  lineByLine, // 逐行歌词（标准LRC格式）
  wordByWord, // 逐字歌词（带逐字时间戳）
  plain, // 旧名兼容
  enhanced, // 旧名兼容
}

enum ThemeOption { system, light, dark }

enum ThemeColorMode { material3, independent }

enum WindowCloseBehavior { exit, minimizeToTray }

Set<NowPlayingMode> defaultWavyBarEnabledModes() => {};

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

ThemeColorMode normalizedThemeColorMode(Object? value) {
  final index = normalizedEnumIndex(
    value,
    length: ThemeColorMode.values.length,
    defaultIndex: -1,
  );
  if (index >= 0) return ThemeColorMode.values[index];

  return switch (normalizedSettingEnumName(value)) {
    'seed' || 'material3' => ThemeColorMode.material3,
    'monochrome' || 'independent' => ThemeColorMode.independent,
    _ => ThemeColorMode.material3,
  };
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
  static final backgroundNotifier = RebuildNotifier();
  static final listMotionNotifier = RebuildNotifier();
  static const String version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '2.2.3',
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
  DesktopLyricBrightnessMode desktopLyricBrightnessMode =
      DesktopLyricBrightnessMode.follow;
  ZhConversionMode zhConversionMode = ZhConversionMode.none;
  int promptWriteLyricToTagDelay = 15;
  bool autoWriteLyricToTag = false;
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
  Set<NowPlayingMode> wavyBarEnabledModes = defaultWavyBarEnabledModes();
  TopBarLyricAnimation topBarLyricAnimation = TopBarLyricAnimation.slideUp;
  bool enableCoverColorExtraction = true;
  bool enableStackedScrollEffect = true;
  bool enableContentTransitionMotion = true;
  bool enableInteractiveSurfaceMotion = true;
  bool enableDetailHeaderCollapseMotion = true;
  bool enableDataTransitionMotion = true;
  bool alwaysShowNowPlayingControls = false;
  int? customCoverColor;
  String? appBackgroundImagePath;
  double appBackgroundImageOpacity = 0.22;
  double appBackgroundImageBlur = 0;
  Size windowSize = const Size(1280, 756);
  bool isWindowMaximized = false;
  WindowCloseBehavior windowCloseBehavior = WindowCloseBehavior.exit;

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

    _instance.windowCloseBehavior =
        normalizedSettingEnumValue(
          settingsMap['WindowCloseBehavior'],
          WindowCloseBehavior.values,
        ) ??
        WindowCloseBehavior.exit;
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

    if (settingsMap.containsKey('WavyBarEnabledModes')) {
      _instance.wavyBarEnabledModes = normalizedWavyBarEnabledModes(
        settingsMap['WavyBarEnabledModes'],
      );
    }

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

    _instance.windowCloseBehavior =
        normalizedSettingEnumValue(
          settingsMap['WindowCloseBehavior'],
          WindowCloseBehavior.values,
        ) ??
        WindowCloseBehavior.exit;

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
      final isFullScreen = await windowManager.isFullScreen();
      final isMinimized = await windowManager.isMinimized();
      final settingsMap = {
        'Version': version,
        'ThemeOption': themeOption.index,
        'ThemeColorMode': themeColorMode.name,
        'EnableStackedScrollEffect': enableStackedScrollEffect,
        'EnableContentTransitionMotion': enableContentTransitionMotion,
        'EnableInteractiveSurfaceMotion': enableInteractiveSurfaceMotion,
        'EnableDetailHeaderCollapseMotion': enableDetailHeaderCollapseMotion,
        'EnableDataTransitionMotion': enableDataTransitionMotion,
        'AlwaysShowNowPlayingControls': alwaysShowNowPlayingControls,
        'ArtistSeparator': artistSeparator,
        'LocalLyricFirst': localLyricFirst,
        'PreferredOnlineSource': preferredOnlineSource.name,
        'ShowTranslation': showTranslation,
        'ShowRomanization': showRomanization,
        'KeepLyricMetadata': keepLyricMetadata,
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
        'DesktopLyricBrightnessMode': desktopLyricBrightnessMode.name,
        'ZhConversionMode': zhConversionMode.name,
        'PromptWriteLyricToTagDelay': promptWriteLyricToTagDelay,
        'AutoWriteLyricToTag': autoWriteLyricToTag,
        'AutoWriteLyricToTagDelay': autoWriteLyricToTagDelay,
        'LyricTagWordFormat': lyricTagWordFormat.name,
        'LyricTagIncludeTranslation': lyricTagIncludeTranslation,
        'LyricTagIncludeRomanization': lyricTagIncludeRomanization,
        'AutoSaveExternalLyric': autoSaveExternalLyric,
        'UseMaterialYouForLyrics': useMaterialYouForLyrics,
        'UseMaterialYouForProgressBar': useMaterialYouForProgressBar,
        'UseMaterialYouForTransition': useMaterialYouForTransition,
        'UseMaterialYouForControls': useMaterialYouForControls,
        'KeepPitch': keepPitch,
        'WavyBarEnabledModes': NowPlayingMode.toList(wavyBarEnabledModes),
        'TopBarLyricAnimation': topBarLyricAnimation.name,
        'EnableCoverColorExtraction': enableCoverColorExtraction,
        'CustomCoverColor': customCoverColor,
        'AppBackgroundImagePath': appBackgroundImagePath,
        'AppBackgroundImageOpacity': appBackgroundImageOpacity,
        'AppBackgroundImageBlur': appBackgroundImageBlur,
        'IsWindowMaximized': isMaximized,
        'WindowCloseBehavior': windowCloseBehavior.name,
        'FontFamily': fontFamily,
        'FontPath': fontPath,
      };

      Size sizeToSave = windowSize;
      if (!isMaximized && !isFullScreen && !isMinimized) {
        final currentSize = await windowManager.getSize();
        if (currentSize.width >= minimumWindowSizeSetting.width &&
            currentSize.height >= minimumWindowSizeSetting.height) {
          sizeToSave = currentSize;
        }
      }
      final normalizedSize = normalizedWindowSizeSetting([
        sizeToSave.width,
        sizeToSave.height,
      ]);
      sizeToSave = Size(normalizedSize.width, normalizedSize.height);
      windowSize = sizeToSave;
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
