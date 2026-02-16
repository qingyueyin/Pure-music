import 'dart:convert';
import 'dart:io';
import 'package:pure_music/src/rust/api/system_theme.dart';
import 'package:pure_music/utils.dart';
import 'package:flutter/material.dart';
import 'package:github/github.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

Future<void> migrateAppData() async {
  try {
    final newAppDataDir = await getAppDataDir();
    final hasData = newAppDataDir.listSync().isNotEmpty;

    if (!hasData) {
      final candidates = <Directory>[];
      candidates.add(await getApplicationSupportDirectory());
      final docs = await getApplicationDocumentsDirectory();
      candidates.add(Directory(path.join(docs.path, "pure_music")));
      candidates.add(Directory(path.join(docs.path, "coriander_player")));

      for (final oldDir in candidates) {
        if (!oldDir.existsSync()) continue;
        if (path.canonicalize(oldDir.path) ==
            path.canonicalize(newAppDataDir.path)) {
          continue;
        }
        if (oldDir.listSync().isEmpty) continue;

        for (final entity in oldDir.listSync(followLinks: false)) {
          final basename = path.basename(entity.path);
          final target = path.join(newAppDataDir.path, basename);
          if (entity is File) {
            entity.copySync(target);
          } else if (entity is Directory) {
            _copyDirectory(entity, Directory(target));
          }
        }
        break;
      }
    }
    await migrateAppDataLayout();
  } catch (err, trace) {
    LOGGER.e(err, stackTrace: trace);
  }
}

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

  final dir = await getApplicationDocumentsDirectory();
  return Directory(path.join(dir.path, "pure_music")).create(recursive: true);
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

Future<void> migrateAppDataLayout() async {
  try {
    final root = await getAppDataDir();
    final settingsDir = await getSettingsDir();
    final cacheDir = await getCacheDir();
    final dbDir = await getDbDir();

    final moves = <(String, String)>[
      (path.join(root.path, "settings.json"),
          path.join(settingsDir.path, "settings.json")),
      (path.join(root.path, "app_preference.json"),
          path.join(settingsDir.path, "app_preference.json")),
      (path.join(root.path, "album_colors.json"),
          path.join(cacheDir.path, "album_colors.json")),
      (path.join(root.path, "app.sqlite"), path.join(dbDir.path, "app.sqlite")),
      (path.join(root.path, "app.sqlite-wal"),
          path.join(dbDir.path, "app.sqlite-wal")),
      (path.join(root.path, "app.sqlite-shm"),
          path.join(dbDir.path, "app.sqlite-shm")),
    ];

    for (final m in moves) {
      final from = File(m.$1);
      if (!from.existsSync()) continue;
      final to = File(m.$2);
      if (to.existsSync()) continue;
      try {
        await from.rename(to.path);
      } catch (_) {
        await to.create(recursive: true);
        await from.copy(to.path);
        try {
          await from.delete();
        } catch (_) {}
      }
    }
  } catch (err, trace) {
    LOGGER.e(err, stackTrace: trace);
  }
}

void _copyDirectory(Directory source, Directory dest) {
  dest.createSync(recursive: true);
  for (final entity in source.listSync(followLinks: false)) {
    final name = path.basename(entity.path);
    final target = path.join(dest.path, name);
    if (entity is File) {
      entity.copySync(target);
    } else if (entity is Directory) {
      _copyDirectory(entity, Directory(target));
    }
  }
}

class AppSettings {
  static final github = GitHub();
static const String version = "1.0.0";

  ThemeMode themeMode = getWindowsThemeMode();

  int defaultTheme = getWindowsTheme();

  bool dynamicTheme = true;

  bool useSystemTheme = true;

  bool useSystemThemeMode = true;

  List artistSeparator = ["/", "、"];

  bool localLyricFirst = true;
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
    ).value;
  }

  AppSettings._();

  static Future<void> _readFromJson_old(Map settingsMap) async {
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
        return _readFromJson_old(settingsMap);
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
      if (!_instance.useSystemThemeMode) {
        _instance.themeMode = (settingsMap["ThemeMode"] ?? false)
            ? ThemeMode.dark
            : ThemeMode.light;
      }

      final dt = settingsMap["DynamicTheme"];
      if (dt != null) {
        _instance.dynamicTheme = dt;
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
      LOGGER.e(err, stackTrace: trace);
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
      LOGGER.e(err, stackTrace: trace);
    }
  }
}