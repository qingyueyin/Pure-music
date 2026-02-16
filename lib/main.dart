import 'dart:io';

import 'package:pure_music/app_preference.dart';
import 'package:pure_music/app_settings.dart';
import 'package:pure_music/album_color_cache.dart';
import 'package:pure_music/entry.dart';
import 'package:pure_music/hotkeys_helper.dart';
import 'package:pure_music/immersive_mode.dart';
import 'package:pure_music/src/rust/api/logger.dart';
import 'package:pure_music/src/rust/frb_generated.dart';
import 'package:pure_music/theme_provider.dart';
import 'package:pure_music/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

Future<void> initWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  final minimumSize = const Size(507, 507);
  Size targetSize = AppSettings.instance.windowSize;
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final display = view.display;
  final displayW = display.size.width / display.devicePixelRatio;
  final displayH = display.size.height / display.devicePixelRatio;
  final maxW = (displayW - 16.0).clamp(minimumSize.width, double.infinity).toDouble();
  final maxH = (displayH - 16.0).clamp(minimumSize.height, double.infinity).toDouble();
  targetSize = Size(
    targetSize.width.clamp(minimumSize.width, maxW),
    targetSize.height.clamp(minimumSize.height, maxH),
  );

  WindowOptions windowOptions = WindowOptions(
    minimumSize: minimumSize,
    size: targetSize,
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

Future<void> loadPrefFont() async {
  final settings = AppSettings.instance;
  if (settings.fontFamily != null) {
    try {
      final fontLoader = FontLoader(settings.fontFamily!);

      fontLoader.addFont(
        File(settings.fontPath!).readAsBytes().then((value) {
          return ByteData.sublistView(value);
        }),
      );
      await fontLoader.load();
      ThemeProvider.instance.changeFontFamily(settings.fontFamily!);
    } catch (err, trace) {
      LOGGER.e(err, stackTrace: trace);
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await RustLib.init();

  initRustLogger().listen((msg) {
    LOGGER.i("[rs]: $msg");
  });

  // For hot reload, `unregisterAll()` needs to be called.
  await HotkeysHelper.unregisterAll();
  HotkeysHelper.registerHotKeys();

  await migrateAppData();

  final supportPath = (await getAppDataDir()).path;
  final settingsDir = await getSettingsDir();
  if (File("${settingsDir.path}\\settings.json").existsSync()) {
    await AppSettings.readFromJson();
    await loadPrefFont();
  }
  if (File("${settingsDir.path}\\app_preference.json").existsSync()) {
    await AppPreference.read();
  }
  await AlbumColorCache.instance.init();
  final welcome = !File("$supportPath\\index.json").existsSync();

  await initWindow();
  await ImmersiveModeController.instance.init();

  runApp(Entry(welcome: welcome));
}
