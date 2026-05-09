import 'dart:convert';
import 'dart:io';
import 'package:pure_music/native/rust/api/system_theme.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/zh_converter.dart';
import 'package:flutter/material.dart';
import 'package:github/github.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

const bool portableBuild = bool.fromEnvironment(
  'PORTABLE_BUILD',
  defaultValue: true,
);

Future<Directory> getAppDataDir() async {
  final exe = Platform.resolvedExecutable;
  final exeBase = path.basename(exe).toLowerCase();
  if (portableBuild && exeBase != "dart.exe" && exeBase != "flutter_tester.exe") {
    final portable = Directory(path.join(path.dirname(exe), "data"));
    try {
      return portable.create(recursive: true);
    } catch (_) {}
  }

  final appData = Platform.environment['APPDATA'];
  if (appData != null) {
    final dir = Directory(path.join(appData, "pure_music"));
    return dir.create(recursive: true);
  }

  final userProfile = Platform.environment['USERPROFILE'];
  if (userProfile != null) {
    final dir = Directory(path.join(userProfile, "AppData", "Roaming", "pure_music"));
    return dir.create(recursive: true);
  }

  throw StateError("Unable to determine app data directory");
}

Future<Directory> getSettingsDir() async {
  final root = await getAppDataDir();
  return Directory(path.join(root.path, "settings")).create(recursive: true);
}

Future<Directory> getCacheDir() async {
  final root = await getAppDataDir();
  return Directory(path.join(root.path, "cache")).create(recursive: true);
}

Future<Directory> getDbDir() async {
  final root = await getAppDataDir();
  return Directory(path.join(root.path, "db")).create(recursive: true);
}


/// 歌词显示模式（控制显示哪些内容）
enum LyricDisplayMode {
  plain,       // 纯原文（不显示翻译/罗马音/空行）
  verbatim,    // 原文+罗马音（逐字歌词适用）
  enhanced,    // 原文+翻译+罗马音（完整）
}

class AppSettings {
  static const String version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: "1.0.0",
  );

  static final github = GitHub();

  ThemeMode themeMode = getWindowsThemeMode();

  int defaultTheme = getWindowsTheme();

  bool dynamicTheme = true;

  bool useSystemTheme = true;

  bool useSystemThemeMode = true;

  List artistSeparator = ["/", "、"];

  bool localLyricFirst = true;
  bool showTranslation = true;
  bool showRomanization = true;
  LyricDisplayMode lyricDisplayMode = LyricDisplayMode.enhanced;
  ZhConversionMode zhConversionMode = ZhConversionMode.none;
  bool removeEmptyLines = true;
  Size windowSize = const Size(1280, 756);
  bool isWindowMaximized = false;

  String? fontFamily;
  String? fontPath;

  late String artistSplitPattern = artistSeparator.join("|");

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
    final ust = settingsMap["UseSystemTheme"];
    if (ust != null) {
      _instance.useSystemTheme = ust == 1 ? true : false;
    }

    final ustm = settingsMap["UseSystemThemeMode"];
    if (ustm != null) {
      _instance.useSystemThemeMode = ustm == 1 ? true : false;
    }

    if (!_instance.useSystemTheme) {
      _instance.defaultTheme = settingsMap["DefaultTheme"];
    }
    if (!_instance.useSystemThemeMode) {
      _instance.themeMode =
          settingsMap["ThemeMode"] == 0 ? ThemeMode.light : ThemeMode.dark;
    }

    _instance.dynamicTheme = settingsMap["DynamicTheme"] == 1 ? true : false;
    _instance.artistSeparator = settingsMap["ArtistSeparator"];
    _instance.artistSplitPattern = _instance.artistSeparator.join("|");

    final llf = settingsMap["LocalLyricFirst"];
    if (llf != null) {
      _instance.localLyricFirst = llf == 1 ? true : false;
    }

    final st = settingsMap["ShowTranslation"];
    if (st != null) {
      _instance.showTranslation = st is bool ? st : st == 1;
    }
    final sr = settingsMap["ShowRomanization"];
    if (sr != null) {
      _instance.showRomanization = sr is bool ? sr : sr == 1;
    }

    final sizeStr = settingsMap["WindowSize"];
    if (sizeStr != null) {
      final sizeStrs = (sizeStr as String).split(",");
      _instance.windowSize = Size(double.tryParse(sizeStrs[0]) ?? 1280,
          double.tryParse(sizeStrs[1]) ?? 756);
    }

    final isMaximized = settingsMap["IsWindowMaximized"];
    if (isMaximized != null) {
      _instance.isWindowMaximized = isMaximized == 1;
    }
  }

  static Future<void> readFromJson() async {
    try {
      final dir = await getSettingsDir();
      final settingsPath = path.join(dir.path, "settings.json");

      final settingsStr = File(settingsPath).readAsStringSync();
      Map settingsMap = json.decode(settingsStr);

      if (settingsMap["Version"] == null) {
        return _readFromJsonOld(settingsMap);
      }

      final ust = settingsMap["UseSystemTheme"];
      if (ust != null) {
        _instance.useSystemTheme = ust;
      }

      final ustm = settingsMap["UseSystemThemeMode"];
      if (ustm != null) {
        _instance.useSystemThemeMode = ustm;
      }

      if (!_instance.useSystemTheme) {
        _instance.defaultTheme = settingsMap["DefaultTheme"];
      }
      final dt = settingsMap["DynamicTheme"];
      if (dt != null) {
        _instance.dynamicTheme = dt is bool ? dt : dt == 1;
      }

      final themeModeValue = settingsMap["ThemeMode"];
      if (!_instance.useSystemThemeMode && themeModeValue != null) {
        _instance.themeMode = themeModeValue is bool
            ? (themeModeValue ? ThemeMode.dark : ThemeMode.light)
            : (themeModeValue == 1 ? ThemeMode.dark : ThemeMode.light);
      }

      final as = settingsMap["ArtistSeparator"];
      if (as != null) {
        _instance.artistSeparator = as;
        _instance.artistSplitPattern = _instance.artistSeparator.join("|");
      }

      final llf = settingsMap["LocalLyricFirst"];
      if (llf != null) {
        _instance.localLyricFirst = llf;
      }

      final st = settingsMap["ShowTranslation"];
      if (st != null) {
        _instance.showTranslation = st;
      }
      final sr = settingsMap["ShowRomanization"];
      if (sr != null) {
        _instance.showRomanization = sr;
      }

      final ldm = settingsMap["LyricDisplayMode"];
      if (ldm != null) {
        _instance.lyricDisplayMode = switch (ldm) {
          'plain' => LyricDisplayMode.plain,
          'verbatim' => LyricDisplayMode.verbatim,
          'enhanced' => LyricDisplayMode.enhanced,
          _ => LyricDisplayMode.enhanced,
        };
      }

      final zcm = settingsMap["ZhConversionMode"];
      if (zcm != null) {
        _instance.zhConversionMode = switch (zcm) {
          'none' => ZhConversionMode.none,
          't2s' => ZhConversionMode.traditionalToSimplified,
          's2t' => ZhConversionMode.simplifiedToTraditional,
          _ => ZhConversionMode.none,
        };
      }

      final rel = settingsMap["RemoveEmptyLines"];
      if (rel != null) {
        _instance.removeEmptyLines = rel;
      }

      final sizeStr = settingsMap["WindowSize"];
      if (sizeStr != null) {
        final sizeStrs = (sizeStr as String).split(",");
        _instance.windowSize = Size(double.tryParse(sizeStrs[0]) ?? 1280,
            double.tryParse(sizeStrs[1]) ?? 756);
      }

      final isMaximized = settingsMap["IsWindowMaximized"];
      if (isMaximized != null) {
        _instance.isWindowMaximized = isMaximized;
      }

      final ff = settingsMap["FontFamily"];
      final fp = settingsMap["FontPath"];
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
        "Version": version,
        "ThemeMode": themeMode == ThemeMode.dark,
        "DynamicTheme": dynamicTheme,
        "UseSystemTheme": useSystemTheme,
        "UseSystemThemeMode": useSystemThemeMode,
        "DefaultTheme": defaultTheme,
        "ArtistSeparator": artistSeparator,
        "LocalLyricFirst": localLyricFirst,
        "ShowTranslation": showTranslation,
        "ShowRomanization": showRomanization,
        "LyricDisplayMode": lyricDisplayMode.name,
        "ZhConversionMode": zhConversionMode.name,
        "RemoveEmptyLines": removeEmptyLines,
        "IsWindowMaximized": isMaximized,
        "FontFamily": fontFamily,
        "FontPath": fontPath,
      };

      Size sizeToSave = windowSize;
      if (!isMaximized) {
        sizeToSave = await windowManager.getSize();
      }
      settingsMap["WindowSize"] =
          "${sizeToSave.width.toStringAsFixed(1)},${sizeToSave.height.toStringAsFixed(1)}";

      final settingsStr = json.encode(settingsMap);
      final dir = await getSettingsDir();
      final settingsPath = path.join(dir.path, "settings.json");
      final output = await File(settingsPath).create(recursive: true);
      output.writeAsStringSync(settingsStr);
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
    }
  }
}
