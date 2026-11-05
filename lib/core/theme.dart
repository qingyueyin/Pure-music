import 'dart:async';
import 'dart:developer' as developer;

import 'package:pure_music/core/app_fonts.dart' as app_fonts;
import 'package:pure_music/core/color_extraction.dart';
import 'package:pure_music/core/perf_probe.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/services/native/media_metadata_service.dart';
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

Color _contrastingTextColor(Color background) {
  return background.computeLuminance() > 0.179 ? Colors.black : Colors.white;
}

/// 播放页主题色开关：开着用主题色，关着用黑白，不用被染色的字色。
Color playerThemeForeground(ColorScheme scheme, {required bool enabled}) {
  if (enabled) return scheme.primary;
  return scheme.brightness == Brightness.dark ? Colors.white : Colors.black;
}

Color playerThemeOnForeground(ColorScheme scheme, {required bool enabled}) {
  if (enabled) return scheme.onPrimary;
  return scheme.brightness == Brightness.dark ? Colors.black : Colors.white;
}

ColorScheme _buildIndependentColorScheme(Color accent, Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final surfaces = _independentSurfaces(isDark);
  final accentContainer = Color.alphaBlend(
    accent.withValues(alpha: isDark ? 0.32 : 0.18),
    surfaces.surfaceContainer,
  );
  final onAccent = _contrastingTextColor(accent);
  final onAccentContainer = _contrastingTextColor(accentContainer);
  return _independentAccentScheme(
    brightness: brightness,
    accent: accent,
    onAccent: onAccent,
    accentContainer: accentContainer,
    onAccentContainer: onAccentContainer,
  ).copyWith(
    error: isDark ? const Color(0xffffb4ab) : const Color(0xffba1a1a),
    onError: isDark ? const Color(0xff690005) : Colors.white,
    errorContainer: isDark ? const Color(0xff93000a) : const Color(0xffffdad6),
    onErrorContainer: isDark
        ? const Color(0xffffdad6)
        : const Color(0xff410002),
    surface: surfaces.surface,
    onSurface: surfaces.onSurface,
    surfaceDim: surfaces.surfaceDim,
    surfaceBright: surfaces.surfaceBright,
    surfaceContainerLowest: surfaces.surfaceContainerLowest,
    surfaceContainerLow: surfaces.surfaceContainerLow,
    surfaceContainer: surfaces.surfaceContainer,
    surfaceContainerHigh: surfaces.surfaceContainerHigh,
    surfaceContainerHighest: surfaces.surfaceContainerHighest,
    onSurfaceVariant: surfaces.onSurfaceVariant,
    outline: surfaces.outline,
    outlineVariant: surfaces.outlineVariant,
    inverseSurface: surfaces.inverseSurface,
    onInverseSurface: surfaces.onInverseSurface,
    inversePrimary: accent,
    surfaceTint: Colors.transparent,
  );
}

ColorScheme _independentAccentScheme({
  required Brightness brightness,
  required Color accent,
  required Color onAccent,
  required Color accentContainer,
  required Color onAccentContainer,
}) {
  return ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: onAccent,
    primaryContainer: accentContainer,
    onPrimaryContainer: onAccentContainer,
    primaryFixed: accent,
    primaryFixedDim: accent,
    onPrimaryFixed: onAccent,
    onPrimaryFixedVariant: onAccent,
    secondary: accent,
    onSecondary: onAccent,
    secondaryContainer: accentContainer,
    onSecondaryContainer: onAccentContainer,
    secondaryFixed: accent,
    secondaryFixedDim: accent,
    onSecondaryFixed: onAccent,
    onSecondaryFixedVariant: onAccent,
    tertiary: accent,
    onTertiary: onAccent,
    tertiaryContainer: accentContainer,
    onTertiaryContainer: onAccentContainer,
    tertiaryFixed: accent,
    tertiaryFixedDim: accent,
    onTertiaryFixed: onAccent,
    onTertiaryFixedVariant: onAccent,
    error: const Color(0xffba1a1a),
    onError: Colors.white,
    surface: const Color(0xfffafafa),
    onSurface: const Color(0xff1b1b1b),
  );
}

({
  Color surface,
  Color onSurface,
  Color surfaceDim,
  Color surfaceBright,
  Color surfaceContainerLowest,
  Color surfaceContainerLow,
  Color surfaceContainer,
  Color surfaceContainerHigh,
  Color surfaceContainerHighest,
  Color onSurfaceVariant,
  Color outline,
  Color outlineVariant,
  Color inverseSurface,
  Color onInverseSurface,
})
_independentSurfaces(bool isDark) {
  return (
    surface: isDark ? const Color(0xff121212) : const Color(0xfffafafa),
    onSurface: isDark ? const Color(0xffe6e6e6) : const Color(0xff1b1b1b),
    surfaceDim: isDark ? const Color(0xff121212) : const Color(0xffdadada),
    surfaceBright: isDark ? const Color(0xff393939) : const Color(0xfffafafa),
    surfaceContainerLowest: isDark ? const Color(0xff0d0d0d) : Colors.white,
    surfaceContainerLow: isDark
        ? const Color(0xff1b1b1b)
        : const Color(0xfff4f4f4),
    surfaceContainer: isDark
        ? const Color(0xff202020)
        : const Color(0xffeeeeee),
    surfaceContainerHigh: isDark
        ? const Color(0xff2b2b2b)
        : const Color(0xffe8e8e8),
    surfaceContainerHighest: isDark
        ? const Color(0xff363636)
        : const Color(0xffe2e2e2),
    onSurfaceVariant: isDark
        ? const Color(0xffcacaca)
        : const Color(0xff494949),
    outline: isDark ? const Color(0xff919191) : const Color(0xff767676),
    outlineVariant: isDark ? const Color(0xff454545) : const Color(0xffc6c6c6),
    inverseSurface: isDark ? const Color(0xffe6e6e6) : const Color(0xff303030),
    onInverseSurface: isDark
        ? const Color(0xff303030)
        : const Color(0xfff2f2f2),
  );
}

Color _configuredThemeSeedColor() {
  final settings = AppSettings.instance;
  switch (settings.themeColorSource) {
    case ThemeColorSource.custom:
      final customColor = settings.customCoverColor;
      return customColor != null
          ? Color(customColor)
          : Color(AppSettings.getWindowsTheme());
    case ThemeColorSource.system:
    case ThemeColorSource.cover:
      return Color(AppSettings.getWindowsTheme());
  }
}

class ThemeProvider extends ChangeNotifier {
  late ColorScheme lightScheme;
  late ColorScheme darkScheme;

  String? fontFamily = AppSettings.instance.fontFamily;
  String? lyricFontFamily = AppSettings.instance.lyricFontFamily;
  bool lyricFontFollowsUi = AppSettings.instance.lyricFontFollowsUi;

  String? get resolvedLyricFontFamily => app_fonts.resolvedLyricFontFamily(
    followsUi: lyricFontFollowsUi,
    lyricFontFamily: lyricFontFamily,
    uiFontFamily: fontFamily,
  );

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
    _appliedThemeColorMode = AppSettings.instance.themeColorMode;
    _updateColorSchemes(_appliedSeedColor, _appliedThemeColorMode);
  }

  static ThemeProvider get instance {
    _instance ??= ThemeProvider._();
    return _instance!;
  }

  late Color _appliedSeedColor;
  late ThemeColorMode _appliedThemeColorMode;

  void _updateColorSchemes(Color seedColor, ThemeColorMode colorMode) {
    switch (colorMode) {
      case ThemeColorMode.material3:
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
      case ThemeColorMode.independent:
        lightScheme = _buildIndependentColorScheme(seedColor, Brightness.light);
        darkScheme = _buildIndependentColorScheme(seedColor, Brightness.dark);
    }
  }

  bool _setSeedColor(Color seedColor) {
    final colorMode = AppSettings.instance.themeColorMode;
    if (_appliedSeedColor == seedColor && _appliedThemeColorMode == colorMode) {
      return false;
    }
    _appliedSeedColor = seedColor;
    _appliedThemeColorMode = colorMode;
    _updateColorSchemes(seedColor, colorMode);
    return true;
  }

  void applyThemeColorMode(ThemeColorMode colorMode) {
    if (_appliedThemeColorMode == colorMode) return;
    _appliedThemeColorMode = colorMode;
    _updateColorSchemes(_appliedSeedColor, colorMode);
    _notifyThemeChanged();
  }

  void _notifyThemeChanged() {
    notifyListeners();
    final desktopLyricService = PlayService.existingDesktopLyricService;
    if (desktopLyricService == null) return;
    desktopLyricService.canSendMessage.then((canSend) {
      if (!canSend) return;
      final scheme = currScheme;
      desktopLyricService.sendThemeMessage(
        scheme,
        darkMode: scheme.brightness == Brightness.dark,
      );
    });
  }

  void applyThemeOption(ThemeOption option) {
    if (!AppSettings.instance.enableCoverColorExtraction ||
        PlayService.existingPlaybackService?.nowPlaying == null) {
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

  /// 无封面跟随时，重新读取系统强调色或自定义色。
  void refreshConfiguredSeedIfNeeded() {
    if (AppSettings.instance.enableCoverColorExtraction &&
        PlayService.existingPlaybackService?.nowPlaying != null) {
      return;
    }
    _applySeedColor(_configuredThemeSeedColor());
  }

  void handlePlatformBrightnessChanged() {
    if (themeMode != ThemeMode.system) return;
    _notifyThemeChanged();
  }

  Color? _getCachedSeedColor(String path, {int? modified}) {
    final palette = _colorService.getCachedPaletteForPath(
      path,
      modified: modified,
    );
    if (palette == null || palette.isEmpty) return null;
    return selectThemeSeedColor(palette);
  }

  /// 直接应用预计算好的种子色，避免重复解码。
  void applySeedColorDirectly(
    Color seedColor,
    String cacheKey, {
    int? modified,
  }) {
    if (!AppSettings.instance.enableCoverColorExtraction) {
      _applySeedColor(_configuredThemeSeedColor());
      return;
    }

    _applySeedColor(
      _getCachedSeedColor(cacheKey, modified: modified) ?? seedColor,
    );
  }

  /// 从完整封面提取与播放页一致的种子色。
  Future<Color> _extractSeedColor(String path, {int? modified}) async {
    final cachedSeedColor = _getCachedSeedColor(path, modified: modified);
    if (cachedSeedColor != null) return cachedSeedColor;

    try {
      developer.Timeline.startSync('cover.extractColors');
      late final List<int> rustColors;
      try {
        final result = await MediaMetadataService.instance.getPictureAndColors(
          path: path,
          width: 1,
          height: 1,
          numColors: 4,
        );
        rustColors = result.colors;
      } finally {
        developer.Timeline.finishSync();
      }
      final palette = rustColors.map(Color.new).toList(growable: false);
      if (palette.isNotEmpty) {
        _colorService.cachePaletteForPath(path, palette, modified: modified);
      }

      return selectThemeSeedColor(palette);
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

    final cachedSeedColor = _getCachedSeedColor(
      audio.path,
      modified: audio.modified,
    );
    if (cachedSeedColor != null) {
      final watch = Stopwatch()..start();
      _applySeedColor(cachedSeedColor);
      watch.stop();
      PerfProbe.event('theme.cover_color', {
        'audioId': audio.path.hashCode.toUnsigned(32).toRadixString(16),
        'cached': true,
        'elapsedMs': watch.elapsedMicroseconds / 1000,
      });
      return;
    }

    _themeDebounceTimer = Timer(const Duration(milliseconds: 60), () async {
      if (token != _themeRequestToken) return;

      final watch = Stopwatch()..start();
      final seedColor = await _extractSeedColor(
        audio.path,
        modified: audio.modified,
      );
      watch.stop();
      PerfProbe.event('theme.cover_color', {
        'audioId': audio.path.hashCode.toUnsigned(32).toRadixString(16),
        'cached': false,
        'elapsedMs': watch.elapsedMicroseconds / 1000,
      });
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

  void changeLyricFontFamily(String? fontFamily) {
    lyricFontFamily = fontFamily;
    notifyListeners();
  }

  void changeLyricFontFollowsUi(bool follows) {
    if (lyricFontFollowsUi == follows) return;
    lyricFontFollowsUi = follows;
    notifyListeners();
  }

  void applyLoadedFonts() {
    final settings = AppSettings.instance;
    fontFamily = settings.fontFamily;
    lyricFontFamily = settings.lyricFontFamily;
    lyricFontFollowsUi = settings.lyricFontFollowsUi;
    notifyListeners();
  }

  @override
  void dispose() {
    _themeDebounceTimer?.cancel();
    super.dispose();
  }
}
