import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// Monet 风格配色主结构
class MonetColorScheme {
  final Color primary;
  final Color secondary;
  final Color tertiary;
  final Color primaryContainer;
  final List<Color> primarySwatch;   // 13 色阶主色板（示例：从主色出发的亮度阶梯）
  final List<Color> secondarySwatch; // 次级色板
  final List<Color> neutral1Swatch;  // 中性色板 1
  final List<Color> neutral2Swatch;  // 中性色板 2
  final bool isMonochrome;
  final double averageLuminance;

  MonetColorScheme({
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.primaryContainer,
    required this.primarySwatch,
    required this.secondarySwatch,
    required this.neutral1Swatch,
    required this.neutral2Swatch,
    this.isMonochrome = false,
    this.averageLuminance = 0.5,
  });
}

/// 高级颜色提取服务
/// 参考 HyperCeiler 的 Monet 风格实现
class AdvancedColorExtractionService {
  static final AdvancedColorExtractionService _instance =
      AdvancedColorExtractionService._internal();
  factory AdvancedColorExtractionService() => _instance;
  AdvancedColorExtractionService._internal();

  final Map<String, MonetColorScheme> _cache = {};
  final Duration _cacheDuration = const Duration(minutes: 10);
  final Map<String, DateTime> _cacheTime = {};

  /// 提取 Monet 配色（若失败返回 null）
  Future<MonetColorScheme?> extractMonetScheme(Uint8List imageBytes) async {
    if (imageBytes.isEmpty) return null;
    final key = imageBytes.hashCode.toString();
    if (_cache.containsKey(key)) {
      final dt = _cacheTime[key]!;
      if (DateTime.now().difference(dt) < _cacheDuration) {
        return _cache[key];
      }
    }

    final imageProvider = MemoryImage(imageBytes);
    final palette = await PaletteGenerator.fromImageProvider(
      imageProvider,
      size: const Size(64, 64),
      maximumColorCount: 16,
    );

    final colors = palette.colors.toList();
    if (colors.isEmpty) return null;

    // Prefer the most frequent colors (by population) and avoid near-white/near-black.
    final entries = palette.paletteColors.toList();
    entries.sort((a, b) => (b.population).compareTo(a.population));
    final totalPopulation = entries.fold<int>(0, (sum, e) => sum + e.population);
    final weightedSaturation = totalPopulation == 0
        ? 0.0
        : entries.fold<double>(
                0.0,
                (sum, e) =>
                    sum +
                    HSLColor.fromColor(e.color).saturation * e.population,
              ) /
            totalPopulation;
    final weightedLuminance = totalPopulation == 0
        ? 0.5
        : entries.fold<double>(
                0.0,
                (sum, e) => sum + (_brightness(e.color) / 255.0) * e.population,
              ) /
            totalPopulation;
    final lowSaturationPopulation = totalPopulation == 0
        ? 0
        : entries
            .where((e) => HSLColor.fromColor(e.color).saturation < 0.10)
            .fold<int>(0, (sum, e) => sum + e.population);
    final monochromeCoverage = totalPopulation == 0
        ? 0.0
        : lowSaturationPopulation / totalPopulation;
    final isMonochrome =
        weightedSaturation < 0.14 || monochromeCoverage > 0.68;

    Color pick1 = entries.first.color;
    Color pick2 = pick1;
    Color pick3 = pick1;

    if (isMonochrome) {
      final neutralPrimary = _neutralSeedFromLuminance(weightedLuminance);
      final neutralSecondary = _neutralOffset(neutralPrimary, 0.06);
      final neutralTertiary = _neutralOffset(neutralPrimary, 0.11);
      final primarySwatch = _generateTonalPalette(neutralPrimary);
      final secondarySwatch = _generateTonalPalette(neutralSecondary);
      final neutral1Swatch = _generateNeutralPalette(neutralPrimary);
      final neutral2Swatch = _generateNeutralPalette(neutralSecondary);

      final scheme = MonetColorScheme(
        primary: neutralPrimary,
        secondary: neutralSecondary,
        tertiary: neutralTertiary,
        primaryContainer: neutralPrimary.withValues(alpha: 0.12),
        primarySwatch: primarySwatch,
        secondarySwatch: secondarySwatch,
        neutral1Swatch: neutral1Swatch,
        neutral2Swatch: neutral2Swatch,
        isMonochrome: true,
        averageLuminance: weightedLuminance,
      );

      _cache[key] = scheme;
      _cacheTime[key] = DateTime.now();
      return scheme;
    }

    for (final pc in entries) {
      if (_isUsableSeed(pc.color)) {
        pick1 = pc.color;
        break;
      }
    }
    for (final pc in entries) {
      if (_isUsableSeed(pc.color) && _colorDistance(pick1, pc.color) > 0.20) {
        pick2 = pc.color;
        break;
      }
    }
    for (final pc in entries) {
      if (_isUsableSeed(pc.color) &&
          _colorDistance(pick1, pc.color) > 0.18 &&
          _colorDistance(pick2, pc.color) > 0.18) {
        pick3 = pc.color;
        break;
      }
    }

    final p1 = pick1;
    final p2 = pick2;
    final p3 = pick3;

    final primarySwatch = _generateTonalPalette(p1);
    final secondarySwatch = _generateTonalPalette(p2);
    final neutral1Swatch = _generateNeutralPalette(p1);
    final neutral2Swatch = _generateNeutralPalette(p2);

    final scheme = MonetColorScheme(
      primary: p1,
      secondary: p2,
      tertiary: p3,
      primaryContainer: p1.withValues(alpha: 0.12),
      primarySwatch: primarySwatch,
      secondarySwatch: secondarySwatch,
      neutral1Swatch: neutral1Swatch,
      neutral2Swatch: neutral2Swatch,
      isMonochrome: false,
      averageLuminance: weightedLuminance,
    );

    _cache[key] = scheme;
    _cacheTime[key] = DateTime.now();
    return scheme;
  }

  /// 生成 13 色阶的主色板（以 base 为中心，基于 HSL 调整亮度）
  List<Color> _generateTonalPalette(Color base) {
    final hsl = HSLColor.fromColor(base);
    final List<Color> colors = [];
    // Android-like tones: 0,10,20,...,100 (13 items)
    final tones = <double>[
      0.02,
      0.10,
      0.20,
      0.30,
      0.40,
      0.50,
      0.60,
      0.70,
      0.80,
      0.90,
      0.96,
      0.98,
      0.995,
    ];
    for (final t in tones) {
      final adjusted = hsl.withLightness(_clamp01(_toneCurve(t))).toColor();
      colors.add(adjusted);
    }
    return colors;
  }

  /// 生成中性色板（降低饱和度）
  List<Color> _generateNeutralPalette(Color base) {
    final hsl = HSLColor.fromColor(base);
    final desat = hsl.withSaturation(hsl.saturation * 0.5);
    return _generateTonalPalette(desat.toColor());
  }

  double _brightness(Color c) => 0.299 * (c.r * 255) + 0.587 * (c.g * 255) + 0.114 * (c.b * 255);
  double _clamp01(double v) => v.clamp(0.0, 1.0);

  bool _isUsableSeed(Color c) {
    final b = _brightness(c) / 255.0;
    if (b < 0.08 || b > 0.92) return false;
    final hsl = HSLColor.fromColor(c);
    if (hsl.saturation < 0.12) return false;
    return true;
  }

  double _colorDistance(Color a, Color b) {
    final dr = (a.r - b.r).abs();
    final dg = (a.g - b.g).abs();
    final db = (a.b - b.b).abs();
    return (dr + dg + db) / 3.0;
  }

  double _toneCurve(double t) {
    // Keep mid-tones richer; avoid washed highlights.
    if (t < 0.5) return t * 0.90;
    return 0.90 + (t - 0.5) * 0.22;
  }

  Color _neutralSeedFromLuminance(double luminance) {
    final lightness = switch (luminance) {
      > 0.80 => 0.08,
      > 0.62 => 0.12,
      > 0.42 => 0.16,
      > 0.25 => 0.20,
      _ => 0.24,
    };
    return HSLColor.fromAHSL(1.0, 0.0, 0.04, lightness).toColor();
  }

  Color _neutralOffset(Color base, double deltaLightness) {
    final hsl = HSLColor.fromColor(base);
    return hsl
        .withLightness((hsl.lightness + deltaLightness).clamp(0.0, 1.0))
        .toColor();
  }

}
