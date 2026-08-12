import 'dart:async';

import 'package:pure_music/core/color_extraction.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart' as rust_tag_reader;
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';

ColorScheme _applyLightSurfacePalette(ColorScheme scheme) {
  // Keep the default Material 3 surface hierarchy for light mode.
  // The scaffold/canvas background uses surfaceContainerLow (via entry.dart)
  // to avoid harsh pure-white backgrounds — surface remains the brightest
  // for cards/dialogs that need to pop.
  return scheme.copyWith(
    surface: scheme.surface,
    surfaceContainer: scheme.surfaceContainer,
    surfaceContainerLow: scheme.surfaceContainerLow,
    surfaceContainerHigh: scheme.surfaceContainerHigh,
    surfaceContainerHighest: scheme.surfaceContainerHighest,
  );
}

ColorScheme _applyDarkSurfacePalette(ColorScheme scheme) {
  return scheme.copyWith(
    surface: scheme.surface,
    surfaceContainer: scheme.surfaceContainer,
    surfaceContainerLow: scheme.surfaceContainerLow,
    surfaceContainerHigh: scheme.surfaceContainerHigh,
    surfaceContainerHighest: scheme.surfaceContainerHighest,
  );
}

Color _selectThemeSeedColor(List<Color> palette) {
  final dominant = palette.first;
  final dominantHsv = HSVColor.fromColor(dominant);
  final dominantHsl = HSLColor.fromColor(dominant);
  if (dominantHsv.saturation * dominantHsv.value >= 0.06 &&
      dominantHsl.saturation >= 0.18) {
    return dominant;
  }

  Color? selected;
  var bestScore = double.negativeInfinity;
  for (var index = 1; index < palette.length; index++) {
    final color = palette[index];
    final hsv = HSVColor.fromColor(color);
    final hsl = HSLColor.fromColor(color);
    final chroma = hsv.saturation * hsv.value;
    if (chroma < 0.06 || hsl.saturation < 0.18) continue;

    final toneFit = 1.0 - (hsl.lightness - 0.5).abs() * 2.0;
    final score = chroma * 0.65 +
        hsl.saturation * 0.2 +
        toneFit * 0.1 +
        0.05 / (index + 1);
    if (score > bestScore) {
      bestScore = score;
      selected = color;
    }
  }
  return selected ?? palette.first;
}

Color _configuredThemeSeedColor() {
  final settings = AppSettings.instance;
  if (!settings.enableCoverColorExtraction) {
    final customColor = settings.customCoverColor;
    return customColor != null
        ? Color(customColor)
        : Color(AppSettings.getWindowsTheme());
  }
  return Color(AppSettings.getWindowsTheme());
}

class ThemeProvider extends ChangeNotifier {
  late ColorScheme lightScheme;
  late ColorScheme darkScheme;

  String? fontFamily = AppSettings.instance.fontFamily;

  Brightness get effectiveBrightness => switch (themeMode) {
        ThemeMode.light => Brightness.light,
        ThemeMode.dark => Brightness.dark,
        ThemeMode.system =>
          WidgetsBinding.instance.platformDispatcher.platformBrightness,
      };

  ColorScheme get currScheme =>
      effectiveBrightness == Brightness.dark ? darkScheme : lightScheme;

  ThemeMode themeMode = switch (AppSettings.instance.themeOption) {
    ThemeOption.system => ThemeMode.system,
    ThemeOption.light => ThemeMode.light,
    ThemeOption.dark => ThemeMode.dark,
  };

  static ThemeProvider? _instance;

  ThemeProvider._() {
    _appliedSeedColor = _configuredThemeSeedColor();
    _updateColorSchemes(_appliedSeedColor);
  }

  static ThemeProvider get instance {
    _instance ??= ThemeProvider._();
    return _instance!;
  }

  late Color _appliedSeedColor;

  void _updateColorSchemes(Color seedColor) {
    lightScheme = _applyLightSurfacePalette(
      ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.light,
      ),
    );
    darkScheme = _applyDarkSurfacePalette(
      ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.dark,
      ),
    );
  }

  bool _setSeedColor(Color seedColor) {
    if (_appliedSeedColor == seedColor) return false;
    _appliedSeedColor = seedColor;
    _updateColorSchemes(seedColor);
    return true;
  }

  void _notifyThemeChanged() {
    notifyListeners();
    PlayService.instance.desktopLyricService.canSendMessage.then((canSend) {
      if (!canSend) return;
      final scheme = currScheme;
      PlayService.instance.desktopLyricService.sendThemeMessage(
        scheme,
        darkMode: scheme.brightness == Brightness.dark,
      );
    });
  }

  void applyThemeOption(ThemeOption option) {
    if (!AppSettings.instance.enableCoverColorExtraction ||
        PlayService.instance.playbackService.nowPlaying == null) {
      _setSeedColor(_configuredThemeSeedColor());
    }
    themeMode = switch (option) {
      ThemeOption.system => ThemeMode.system,
      ThemeOption.light => ThemeMode.light,
      ThemeOption.dark => ThemeMode.dark,
    };
    _notifyThemeChanged();
  }

  int _themeRequestToken = 0;
  Timer? _themeDebounceTimer;
  final ColorExtractionService _colorService = ColorExtractionService();

  void applyThemeMode(ThemeMode mode) {
    themeMode = mode;
    _notifyThemeChanged();
  }

  void handlePlatformBrightnessChanged() {
    if (themeMode != ThemeMode.system) return;
    _notifyThemeChanged();
  }

  Color? _getCachedSeedColor(String path) {
    final palette = _colorService.getCachedPaletteForPath(path);
    if (palette == null || palette.isEmpty) return null;
    return _selectThemeSeedColor(palette);
  }

  /// 直接应用预计算好的种子色，避免重复解码。
  void applySeedColorDirectly(Color seedColor, String cacheKey) {
    if (!AppSettings.instance.enableCoverColorExtraction) {
      _applySeedColor(_configuredThemeSeedColor());
      return;
    }

    _applySeedColor(_getCachedSeedColor(cacheKey) ?? seedColor);
  }

  /// 从完整封面提取与播放页一致的种子色。
  Future<Color> _extractSeedColor(String cacheKey) async {
    final cachedSeedColor = _getCachedSeedColor(cacheKey);
    if (cachedSeedColor != null) return cachedSeedColor;

    try {
      final (_, rustColors) = await rust_tag_reader.getPictureAndColors(
        path: cacheKey,
        width: 1,
        height: 1,
        numColors: 4,
      );
      final palette = rustColors.map(Color.new).toList(growable: false);
      if (palette.isNotEmpty) {
        _colorService.cachePaletteForPath(cacheKey, palette);
      }

      return palette.isNotEmpty
          ? _selectThemeSeedColor(palette)
          : const Color(0xff27272a);
    } catch (e) {
      debugPrint('Seed color extraction failed: $e');
      return const Color(0xff27272a);
    }
  }

  void _applySeedColor(Color seedColor) {
    if (!_setSeedColor(seedColor)) return;
    _notifyThemeChanged();
  }

  void applyThemeFromAudio(Audio audio) {
    if (!AppSettings.instance.enableCoverColorExtraction) {
      cancelPendingAudioTheme();
      _applySeedColor(_configuredThemeSeedColor());
      return;
    }

    _themeRequestToken += 1;
    final token = _themeRequestToken;

    _themeDebounceTimer?.cancel();
    _themeDebounceTimer = null;

    final cachedSeedColor = _getCachedSeedColor(audio.path);
    if (cachedSeedColor != null) {
      _applySeedColor(cachedSeedColor);
      return;
    }

    _themeDebounceTimer = Timer(const Duration(milliseconds: 60), () async {
      if (token != _themeRequestToken) return;

      final seedColor = await _extractSeedColor(audio.path);
      if (token != _themeRequestToken ||
          !AppSettings.instance.enableCoverColorExtraction) {
        return;
      }

      _applySeedColor(seedColor);
    });
  }

  void cancelPendingAudioTheme() {
    _themeRequestToken += 1;
    _themeDebounceTimer?.cancel();
    _themeDebounceTimer = null;
  }

  void changeFontFamily(String? fontFamily) {
    this.fontFamily = fontFamily;
    notifyListeners();
  }

  @override
  void dispose() {
    _themeDebounceTimer?.cancel();
    super.dispose();
  }
}
