import 'dart:async';
import 'dart:typed_data';

import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/rust/api/color_extraction.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';

ColorScheme _applyLightSurfacePalette(ColorScheme scheme) {
  return scheme.copyWith(
    surface: scheme.surfaceContainer,
    surfaceContainer: scheme.surface,
    surfaceContainerLow: scheme.surfaceContainerLowest,
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

class ThemeProvider extends ChangeNotifier {
  ColorScheme lightScheme = _applyLightSurfacePalette(
    ColorScheme.fromSeed(
      seedColor: Color(AppSettings.getWindowsTheme()),
      brightness: Brightness.light,
    ),
  );

  ColorScheme darkScheme = _applyDarkSurfacePalette(
    ColorScheme.fromSeed(
      seedColor: Color(AppSettings.getWindowsTheme()),
      brightness: Brightness.dark,
    ),
  );

  String? fontFamily = AppSettings.instance.fontFamily;

  ColorScheme get currScheme =>
      themeMode == ThemeMode.dark ? darkScheme : lightScheme;

  ThemeMode themeMode = switch (AppSettings.instance.themeOption) {
    ThemeOption.system => ThemeMode.system,
    ThemeOption.light => ThemeMode.light,
    ThemeOption.dark => ThemeMode.dark,
  };

  static ThemeProvider? _instance;

  ThemeProvider._();

  static ThemeProvider get instance {
    _instance ??= ThemeProvider._();
    return _instance!;
  }

  void applyThemeOption(ThemeOption option) {
    final seed = Color(AppSettings.getWindowsTheme());
    lightScheme = _applyLightSurfacePalette(ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    ));
    darkScheme = _applyDarkSurfacePalette(ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    ));
    themeMode = switch (option) {
      ThemeOption.system => ThemeMode.system,
      ThemeOption.light => ThemeMode.light,
      ThemeOption.dark => ThemeMode.dark,
    };
    notifyListeners();

    PlayService.instance.desktopLyricService.canSendMessage.then((canSend) {
      if (!canSend) return;
      PlayService.instance.desktopLyricService.sendThemeMessage(darkScheme);
      PlayService.instance.desktopLyricService.sendThemeModeMessage(true);
    });
  }

  int _themeRequestToken = 0;
  Timer? _themeDebounceTimer;

  /// 缓存封面到种子色的映射，避免重复 palette_generator 计算
  static const int _seedCacheSize = 50;
  final Map<String, Color> _seedCache = {};
  final List<String> _seedAccessOrder = [];

  void _touchSeedCache(String key) {
    _seedAccessOrder.remove(key);
    _seedAccessOrder.add(key);
  }

  void _evictSeedCache() {
    while (_seedAccessOrder.length >= _seedCacheSize) {
      final oldest = _seedAccessOrder.removeAt(0);
      _seedCache.remove(oldest);
    }
  }

  void applyThemeMode(ThemeMode mode) {
    themeMode = mode;
    notifyListeners();

    PlayService.instance.desktopLyricService.canSendMessage.then((canSend) {
      if (!canSend) return;
      PlayService.instance.desktopLyricService.sendThemeMessage(darkScheme);
      PlayService.instance.desktopLyricService.sendThemeModeMessage(true);
    });
  }

  /// 直接应用预计算好的种子色（来自 Rust k-means 或其它提取路径）。
  /// 跳过 PaletteGenerator，避免重复解码。
  void applySeedColorDirectly(Color seedColor, String cacheKey) {
    final cached = _seedCache[cacheKey];
    if (cached != null) {
      _touchSeedCache(cacheKey);
      _applySeedColor(cached);
      return;
    }

    _evictSeedCache();
    _seedCache[cacheKey] = seedColor;
    _seedAccessOrder.add(cacheKey);
    _applySeedColor(seedColor);
  }

  /// 用 Rust k-means 从封面字节提取种子色（替换 palette_generator）。
  /// k-means 排序后的第一个颜色即最 dominant 的颜色。
  Future<Color> _extractSeedColor(Uint8List bytes, String cacheKey) async {
    final cached = _seedCache[cacheKey];
    if (cached != null) {
      _touchSeedCache(cacheKey);
      return cached;
    }

    try {
      final rustColors = await extractColorsFromImage(
        imageBytes: bytes,
        numColors: 4,
      );

      final seedColor = rustColors.isNotEmpty
          ? Color(rustColors.first)
          : const Color(0xff27272a);

      _evictSeedCache();
      _seedCache[cacheKey] = seedColor;
      _seedAccessOrder.add(cacheKey);

      return seedColor;
    } catch (e) {
      debugPrint('Seed color extraction failed: $e');
      return const Color(0xff27272a);
    }
  }

  /// 用种子色同时生成 light/dark 两套 ColorScheme。
  /// ColorScheme.fromSeed 是同步的，不需要 Future。
  void _applySeedColor(Color seedColor, {bool notify = true}) {
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

    PlayService.instance.desktopLyricService.canSendMessage.then((canSend) {
      if (!canSend) return;
      PlayService.instance.desktopLyricService.sendThemeMessage(darkScheme);
      PlayService.instance.desktopLyricService.sendThemeModeMessage(true);
    });

    if (notify) notifyListeners();
  }

  void applyThemeFromAudio(Audio audio) {
    if (!AppSettings.instance.enableCoverColorExtraction) {
      final custom = AppSettings.instance.customCoverColor;
      if (custom != null) {
        _applySeedColor(Color(custom));
      }
      return;
    }

    _themeRequestToken += 1;
    final token = _themeRequestToken;

    _themeDebounceTimer?.cancel();
    _themeDebounceTimer = Timer(const Duration(milliseconds: 200), () async {
      if (token != _themeRequestToken) return;

      // 用小封面字节直接调 Rust k-means，跳过 PaletteGenerator 的重复解码
      final bytes = audio.smallCoverBytes;
      if (bytes == null || token != _themeRequestToken) return;

      final seedColor = await _extractSeedColor(bytes, audio.path);
      if (token != _themeRequestToken) return;

      _applySeedColor(seedColor);
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

  ButtonStyle get primaryButtonStyle => ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return currScheme.primary.withValues(alpha: 0.12);
          }
          return currScheme.primary;
        }),
        foregroundColor: WidgetStatePropertyAll(currScheme.onPrimary),
        fixedSize: const WidgetStatePropertyAll(Size.fromHeight(40.0)),
        overlayColor: WidgetStatePropertyAll(
          currScheme.onPrimary.withValues(alpha: 0.08),
        ),
      );

  ButtonStyle get secondaryButtonStyle => ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return currScheme.secondaryContainer.withValues(alpha: 0.12);
          }
          if (states.contains(WidgetState.selected)) {
            return currScheme.secondaryContainer;
          }
          return currScheme.secondaryContainer.withValues(alpha: 0.6);
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return currScheme.onSecondaryContainer.withValues(alpha: 0.38);
          }
          if (states.contains(WidgetState.hovered)) {
            return currScheme.primary;
          }
          return currScheme.onSecondaryContainer;
        }),
        fixedSize: const WidgetStatePropertyAll(Size.fromHeight(40.0)),
        overlayColor: WidgetStatePropertyAll(
          currScheme.onSecondaryContainer.withValues(alpha: 0.08),
        ),
      );

  ButtonStyle get primaryIconButtonStyle => ButtonStyle(
        backgroundColor: WidgetStatePropertyAll(currScheme.primary),
        foregroundColor: WidgetStatePropertyAll(currScheme.onPrimary),
        overlayColor: WidgetStatePropertyAll(
          currScheme.onPrimary.withValues(alpha: 0.08),
        ),
      );

  ButtonStyle get secondaryIconButtonStyle => ButtonStyle(
        backgroundColor: WidgetStatePropertyAll(currScheme.secondaryContainer),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) {
            return currScheme.primary;
          }
          return currScheme.onSecondaryContainer;
        }),
        overlayColor: WidgetStatePropertyAll(
          currScheme.onSecondaryContainer.withValues(alpha: 0.08),
        ),
      );

  ButtonStyle get menuItemStyle => ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) {
            return currScheme.secondaryContainer.withValues(alpha: 0.8);
          }
          if (states.contains(WidgetState.selected)) {
            return currScheme.secondaryContainer;
          }
          return null;
        }),
        foregroundColor: WidgetStatePropertyAll(currScheme.onSecondaryContainer),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16.0),
        ),
        overlayColor: WidgetStatePropertyAll(
          currScheme.onSecondaryContainer.withValues(alpha: 0.08),
        ),
      );

  MenuStyle get menuStyleWithFixedSize => MenuStyle(
        backgroundColor: WidgetStatePropertyAll(currScheme.secondaryContainer),
        surfaceTintColor: WidgetStatePropertyAll(currScheme.secondaryContainer),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20.0),
        )),
        fixedSize: const WidgetStatePropertyAll(Size.fromWidth(149.0)),
      );

  MenuStyle get menuStyle => MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        backgroundColor: WidgetStatePropertyAll(currScheme.surfaceContainer),
        surfaceTintColor: WidgetStatePropertyAll(currScheme.surfaceContainer),
      );

  InputDecoration inputDecoration(String labelText) => InputDecoration(
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: currScheme.outline, width: 2),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: currScheme.primary, width: 2),
        ),
        labelText: labelText,
        labelStyle: TextStyle(color: currScheme.onSurfaceVariant),
        floatingLabelStyle: TextStyle(color: currScheme.primary),
        focusColor: currScheme.primary,
      );

  @override
  void dispose() {
    _themeDebounceTimer?.cancel();
    _seedCache.clear();
    _seedAccessOrder.clear();
    super.dispose();
  }
}
