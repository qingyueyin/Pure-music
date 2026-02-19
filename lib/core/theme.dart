import 'dart:async';

import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';

ColorScheme _applyLightSurfacePalette(ColorScheme scheme) {
  return scheme.copyWith(
    surface: const Color(0xFFFAFAFA),
    surfaceContainerLowest: const Color(0xFFFFFFFF),
    surfaceContainerLow: const Color(0xFFF5F5F5),
    surfaceContainer: const Color(0xFFF0F0F0),
    surfaceContainerHigh: const Color(0xFFEAEAEA),
    surfaceContainerHighest: const Color(0xFFE4E4E4),
  );
}

class ThemeProvider extends ChangeNotifier {
  ColorScheme lightScheme = _applyLightSurfacePalette(
    ColorScheme.fromSeed(
      seedColor: Color(AppSettings.instance.defaultTheme),
      brightness: Brightness.light,
    ),
  );

  ColorScheme darkScheme = ColorScheme.fromSeed(
    seedColor: Color(AppSettings.instance.defaultTheme),
    brightness: Brightness.dark,
  ).copyWith(
    surface: const Color(0xFF121314),
    surfaceContainer: const Color(0xFF171819),
    surfaceContainerHigh: const Color(0xFF1A1B1C),
    surfaceContainerHighest: const Color(0xFF1C1D1E),
  );

  String? fontFamily = AppSettings.instance.fontFamily;

  ColorScheme get currScheme =>
      themeMode == ThemeMode.dark ? darkScheme : lightScheme;

  ThemeMode themeMode = AppSettings.instance.themeMode;
  final Map<String, ColorScheme> _schemeCache = {};
  final Map<String, Future<ColorScheme>> _schemeFutureCache = {};
  int _themeRequestToken = 0;
  Timer? _themeDebounceTimer;

  static ThemeProvider? _instance;

  ThemeProvider._();

  static ThemeProvider get instance {
    _instance ??= ThemeProvider._();
    return _instance!;
  }

  void applyTheme({required Color seedColor}) {
    lightScheme = _applyLightSurfacePalette(ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
    ));

    darkScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
    ).copyWith(
      surface: const Color(0xFF121314),
      surfaceContainer: const Color(0xFF171819),
      surfaceContainerHigh: const Color(0xFF1A1B1C),
      surfaceContainerHighest: const Color(0xFF1C1D1E),
    );
    notifyListeners();

    PlayService.instance.desktopLyricService.canSendMessage.then((canSend) {
      if (!canSend) return;

      PlayService.instance.desktopLyricService.sendThemeMessage(darkScheme);
    });
  }

  /// 应用从 image 生成的主题。只在 themeMode == this.themeMode 时通知改变。
  void applyThemeFromImage(
    ImageProvider image,
    ThemeMode themeMode, {
    String? cacheKey,
    int? requestToken,
  }) {
    final brightness = switch (themeMode) {
      ThemeMode.system => Brightness.light,
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
    };

    final key = cacheKey == null ? null : "$cacheKey|${brightness.name}";
    final cached = key == null ? null : _schemeCache[key];
    if (cached != null) {
      switch (brightness) {
        case Brightness.light:
          lightScheme = _applyLightSurfacePalette(cached);
          break;
        case Brightness.dark:
          darkScheme = cached.copyWith(
            surface: const Color(0xFF121314),
            surfaceContainer: const Color(0xFF171819),
            surfaceContainerHigh: const Color(0xFF1A1B1C),
            surfaceContainerHighest: const Color(0xFF1C1D1E),
          );
          break;
      }

      if ((requestToken == null || requestToken == _themeRequestToken) &&
          brightness == Brightness.dark) {
        PlayService.instance.desktopLyricService.canSendMessage.then((canSend) {
          if (!canSend) return;
          PlayService.instance.desktopLyricService.sendThemeMessage(darkScheme);
          PlayService.instance.desktopLyricService.sendThemeModeMessage(true);
        });
      }

      if (themeMode == this.themeMode &&
          (requestToken == null || requestToken == _themeRequestToken)) {
        notifyListeners();
      }
      return;
    }

    final future = key == null
        ? ColorScheme.fromImageProvider(provider: image, brightness: brightness)
        : _schemeFutureCache.putIfAbsent(
            key,
            () => ColorScheme.fromImageProvider(
              provider: image,
              brightness: brightness,
            ),
          );

    future.then((value) {
      if (key != null) {
        _schemeFutureCache.remove(key);
        _schemeCache[key] = value;
      }

      if (requestToken != null && requestToken != _themeRequestToken) return;

      switch (brightness) {
        case Brightness.light:
          lightScheme = _applyLightSurfacePalette(value);
          break;
        case Brightness.dark:
          darkScheme = value.copyWith(
            surface: const Color(0xFF121314),
            surfaceContainer: const Color(0xFF171819),
            surfaceContainerHigh: const Color(0xFF1A1B1C),
            surfaceContainerHighest: const Color(0xFF1C1D1E),
          );
          break;
      }

      if (brightness == Brightness.dark) {
        PlayService.instance.desktopLyricService.canSendMessage.then((canSend) {
          if (!canSend) return;
          PlayService.instance.desktopLyricService.sendThemeMessage(darkScheme);
          PlayService.instance.desktopLyricService.sendThemeModeMessage(true);
        });
      }

      if (themeMode == this.themeMode) {
        notifyListeners();
      }
    });
  }

  void applyThemeMode(ThemeMode themeMode) {
    this.themeMode = themeMode;
    notifyListeners();
    PlayService.instance.desktopLyricService.canSendMessage.then((canSend) {
      if (!canSend) return;

      PlayService.instance.desktopLyricService.sendThemeMessage(darkScheme);
      PlayService.instance.desktopLyricService.sendThemeModeMessage(
        true,
      );
    });
  }

  void applyThemeFromAudio(Audio audio) {
    if (!AppSettings.instance.dynamicTheme) return;
    _themeRequestToken += 1;
    final token = _themeRequestToken;

    _themeDebounceTimer?.cancel();
    _themeDebounceTimer = Timer(const Duration(milliseconds: 200), () {
      audio.cover.then((image) {
        if (image == null) return;
        if (token != _themeRequestToken) return;

        applyThemeFromImage(
          image,
          themeMode,
          cacheKey: audio.path,
          requestToken: token,
        );

        final second = switch (themeMode) {
          ThemeMode.system => ThemeMode.dark,
          ThemeMode.light => ThemeMode.dark,
          ThemeMode.dark => ThemeMode.light,
        };
        Timer(const Duration(milliseconds: 420), () {
          if (token != _themeRequestToken) return;
          applyThemeFromImage(
            image,
            second,
            cacheKey: audio.path,
            requestToken: token,
          );
        });
      });
    });
  }

  void changeFontFamily(String? fontFamily) {
    this.fontFamily = fontFamily;
    notifyListeners();
  }

  static const double radiusSmall = 6.0;
  static const double radiusMedium = 8.0;
  static const double radiusLarge = 12.0;
  static const double elevationLow = 1.0;
  static const double elevationMedium = 3.0;
  static const double elevationHigh = 6.0;

  // ButtonStyle get primaryButtonStyle => ButtonStyle(
  //       backgroundColor: WidgetStatePropertyAll(scheme.primary),
  //       foregroundColor: WidgetStatePropertyAll(scheme.onPrimary),
  //       fixedSize: const WidgetStatePropertyAll(Size.fromHeight(40.0)),
  //       overlayColor:
  //           WidgetStatePropertyAll(scheme.onPrimary.withOpacity(0.08)),
  //     );

  // ButtonStyle get secondaryButtonStyle => ButtonStyle(
  //       backgroundColor: WidgetStatePropertyAll(scheme.secondaryContainer),
  //       foregroundColor: WidgetStatePropertyAll(scheme.onSecondaryContainer),
  //       fixedSize: const WidgetStatePropertyAll(Size.fromHeight(40.0)),
  //       overlayColor: WidgetStatePropertyAll(
  //           scheme.onSecondaryContainer.withOpacity(0.08)),
  //     );

  // ButtonStyle get primaryIconButtonStyle => ButtonStyle(
  //       backgroundColor: WidgetStatePropertyAll(scheme.primary),
  //       foregroundColor: WidgetStatePropertyAll(scheme.onPrimary),
  //       overlayColor: WidgetStatePropertyAll(
  //         scheme.onPrimary.withOpacity(0.08),
  //       ),
  //     );

  // ButtonStyle get secondaryIconButtonStyle => ButtonStyle(
  //       backgroundColor: WidgetStatePropertyAll(scheme.secondaryContainer),
  //       foregroundColor: WidgetStatePropertyAll(scheme.onSecondaryContainer),
  //       overlayColor: WidgetStatePropertyAll(
  //         scheme.onSecondaryContainer.withOpacity(0.08),
  //       ),
  //     );

  // ButtonStyle get menuItemStyle => ButtonStyle(
  //       backgroundColor: WidgetStatePropertyAll(scheme.secondaryContainer),
  //       foregroundColor: WidgetStatePropertyAll(scheme.onSecondaryContainer),
  //       padding: const WidgetStatePropertyAll(
  //         EdgeInsets.symmetric(horizontal: 16.0),
  //       ),
  //       overlayColor: WidgetStatePropertyAll(
  //         scheme.onSecondaryContainer.withOpacity(0.08),
  //       ),
  //     );

  // MenuStyle get menuStyleWithFixedSize => MenuStyle(
  //       backgroundColor: WidgetStatePropertyAll(scheme.secondaryContainer),
  //       surfaceTintColor: WidgetStatePropertyAll(scheme.secondaryContainer),
  //       shape: WidgetStatePropertyAll(RoundedRectangleBorder(
  //         borderRadius: BorderRadius.circular(20.0),
  //       )),
  //       fixedSize: const WidgetStatePropertyAll(Size.fromWidth(149.0)),
  //     );

  // MenuStyle get menuStyle => MenuStyle(
  //       shape: WidgetStatePropertyAll(
  //         RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
  //       ),
  //       backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
  //       surfaceTintColor: WidgetStatePropertyAll(scheme.surfaceContainer),
  //     );

  // InputDecoration inputDecoration(String labelText) => InputDecoration(
  //       enabledBorder: OutlineInputBorder(
  //         borderSide: BorderSide(color: scheme.outline, width: 2),
  //       ),
  //       focusedBorder: OutlineInputBorder(
  //         borderSide: BorderSide(color: scheme.primary, width: 2),
  //       ),
  //       labelText: labelText,
  //       labelStyle: TextStyle(color: scheme.onSurfaceVariant),
  //       floatingLabelStyle: TextStyle(color: scheme.primary),
  //       focusColor: scheme.primary,
  //     );
}
