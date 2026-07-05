import 'dart:convert';
import 'dart:io';
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
  Set<NowPlayingMode> wavyBarEnabledModes = {NowPlayingMode.portrait};
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
      _instance.themeOption = ThemeOption.values[to];
    }
    final oldSep = settingsMap['ArtistSeparator'];
    if (oldSep != null) {
      _instance.artistSeparator = List<String>.from(oldSep);
    }
    _instance.artistSplitPattern = _instance.artistSeparator.join('|');

    final llf = settingsMap['LocalLyricFirst'];
    if (llf != null) {
      _instance.localLyricFirst = llf == 1;
    }

    final st = settingsMap['ShowTranslation'];
    if (st != null) {
      _instance.showTranslation = st is bool ? st : st == 1;
    }
    final sr = settingsMap['ShowRomanization'];
    if (sr != null) {
      _instance.showRomanization = sr is bool ? sr : sr == 1;
    }

    final sizeStr = settingsMap['WindowSize'];
    if (sizeStr != null) {
      final sizeStrs = (sizeStr as String).split(',');
      _instance.windowSize = Size(double.tryParse(sizeStrs[0]) ?? 1280,
          double.tryParse(sizeStrs[1]) ?? 756);
    }

    final isMaximized = settingsMap['IsWindowMaximized'];
    if (isMaximized != null) {
      _instance.isWindowMaximized = isMaximized == 1;
    }
  }

  static Future<void> readFromJson() async {
    try {
      final dir = await getSettingsDir();
      final settingsPath = path.join(dir.path, 'settings.json');

      final settingsStr = File(settingsPath).readAsStringSync();
      Map settingsMap = json.decode(settingsStr);

      if (settingsMap['Version'] == null) {
        return _readFromJsonOld(settingsMap);
      }

      final to = settingsMap['ThemeOption'];
      if (to != null) {
        _instance.themeOption = ThemeOption.values[to as int];
      }

      final sep = settingsMap['ArtistSeparator'];
      if (sep != null) {
        _instance.artistSeparator = List<String>.from(sep);
        _instance.artistSplitPattern = _instance.artistSeparator.join('|');
      }

      final llf = settingsMap['LocalLyricFirst'];
      if (llf != null) {
        _instance.localLyricFirst = llf;
      }

      final pos = settingsMap['PreferredOnlineSource'];
      if (pos != null) {
        _instance.preferredOnlineSource = switch (pos) {
          'qq' => LyricSourceType.qq,
          'kugou' => LyricSourceType.kugou,
          'ne' => LyricSourceType.ne,
          _ => LyricSourceType.qq,
        };
      }

      final st = settingsMap['ShowTranslation'];
      if (st != null) {
        _instance.showTranslation = st;
      }
      final sr = settingsMap['ShowRomanization'];
      if (sr != null) {
        _instance.showRomanization = sr;
      }

      final ldm = settingsMap['LyricDisplayMode'];
      if (ldm != null) {
        _instance.lyricDisplayMode = switch (ldm) {
          'lineByLine' => LyricDisplayMode.lineByLine,
          'wordByWord' => LyricDisplayMode.wordByWord,
          'plain' => LyricDisplayMode.lineByLine,
          'verbatim' => LyricDisplayMode.wordByWord,
          'enhanced' => LyricDisplayMode.wordByWord,
          _ => LyricDisplayMode.wordByWord,
        };
      }

      final zcm = settingsMap['ZhConversionMode'];
      if (zcm != null) {
        _instance.zhConversionMode = switch (zcm) {
          'none' => ZhConversionMode.none,
          't2s' => ZhConversionMode.traditionalToSimplified,
          's2t' => ZhConversionMode.simplifiedToTraditional,
          _ => ZhConversionMode.none,
        };
      }

      final pwt = settingsMap['PromptWriteLyricToTag'];
      if (pwt != null) {
        _instance.promptWriteLyricToTag = pwt;
      }

      final pwd = settingsMap['PromptWriteLyricToTagDelay'];
      if (pwd != null) {
        _instance.promptWriteLyricToTagDelay = pwd;
      }

      final awt = settingsMap['AutoWriteLyricToTag'];
      if (awt != null) {
        _instance.autoWriteLyricToTag = awt;
      }

      final awd = settingsMap['AutoWriteLyricToTagDelay'];
      if (awd != null) {
        _instance.autoWriteLyricToTagDelay = awd;
      }

      final umyl = settingsMap['UseMaterialYouForLyrics'];
      if (umyl != null) {
        _instance.useMaterialYouForLyrics = umyl;
      }

      final umypb = settingsMap['UseMaterialYouForProgressBar'];
      if (umypb != null) {
        _instance.useMaterialYouForProgressBar = umypb;
      }

      final umyt = settingsMap['UseMaterialYouForTransition'];
      if (umyt != null) {
        _instance.useMaterialYouForTransition = umyt;
      }

      final umyc = settingsMap['UseMaterialYouForControls'];
      if (umyc != null) {
        _instance.useMaterialYouForControls = umyc;
      }

      final wbm = settingsMap['WavyBarEnabledModes'];
      if (wbm is List) {
        _instance.wavyBarEnabledModes = NowPlayingMode.fromList(wbm);
      }

      final tbla = settingsMap['TopBarLyricAnimation'];
      if (tbla != null) {
        _instance.topBarLyricAnimation =
            TopBarLyricAnimation.fromString(tbla) ?? TopBarLyricAnimation.slideUp;
      }

      final ecce = settingsMap['EnableCoverColorExtraction'];
      if (ecce != null) {
        _instance.enableCoverColorExtraction = ecce;
      }

      final ccc = settingsMap['CustomCoverColor'];
      if (ccc != null) {
        _instance.customCoverColor = ccc;
      }

      final sizeStr = settingsMap['WindowSize'];
      if (sizeStr != null) {
        final sizeStrs = (sizeStr as String).split(',');
        _instance.windowSize = Size(double.tryParse(sizeStrs[0]) ?? 1280,
            double.tryParse(sizeStrs[1]) ?? 756);
      }

      final isMaximized = settingsMap['IsWindowMaximized'];
      if (isMaximized != null) {
        _instance.isWindowMaximized = isMaximized;
      }

      final ff = settingsMap['FontFamily'];
      final fp = settingsMap['FontPath'];
      if (ff != null) {
        _instance.fontFamily = ff;
        _instance.fontPath = fp;
      }
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
    }
  }

  Future<void> saveSettings() async {
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
      final output = await File(settingsPath).create(recursive: true);
      output.writeAsStringSync(settingsStr);
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
    }
  }
}
