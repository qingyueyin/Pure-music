import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 像素级 HSL 取色器
/// 
/// 直接从原始封面图片做像素采样和 HSL 分析,完全绕过 PaletteGenerator 的量化损失。
/// 支持:
/// - 灰度检测: 基于整体饱和度分布,准确识别黑白/灰度封面
/// - 主色提取: 色相分桶+人口统计,找到最突出的颜色
/// - 辅色发现: 智能寻找互补色、分裂互补色,创造冷暖对比
/// - 和谐4色生成: 暗主色、中主色、辅色、亮主色,层次分明

class HslColorSample {
  final double hue;
  final double saturation;
  final double lightness;
  final int population;

  const HslColorSample({
    required this.hue,
    required this.saturation,
    required this.lightness,
    required this.population,
  });
}

class HslColorSampler {
  static const int _hueBucketCount = 72;
  static const int _bucketWidth = 360 ~/ _hueBucketCount;

  static const double _warmHueMin = 0.0;
  static const double _warmHueMax = 60.0;
  static const double _warmHueMin2 = 330.0;
  static const double _warmHueMax2 = 360.0;
  static const double _coolHueMin = 180.0;
  static const double _coolHueMax = 270.0;

  bool _isWarmHue(double hue) {
    return (hue >= _warmHueMin && hue <= _warmHueMax) ||
        (hue >= _warmHueMin2 && hue <= _warmHueMax2);
  }

  bool _isCoolHue(double hue) {
    return hue >= _coolHueMin && hue <= _coolHueMax;
  }

  Future<HslAnalysisResult> analyzeCover(Uint8List? coverBytes) async {
    if (coverBytes == null || coverBytes.isEmpty) {
      return HslAnalysisResult.empty();
    }

    final codec = await ui.instantiateImageCodec(coverBytes);
    final frame = await codec.getNextFrame();
    final byteData = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return HslAnalysisResult.empty();

    final width = frame.image.width;
    final height = frame.image.height;
    final totalPixels = width * height;
    final pixels = byteData.buffer.asUint8List();

    final targetPixels = (totalPixels < 10000) ? totalPixels : 12000;
    final step = math.max(1, (totalPixels / targetPixels).floor());

    int grayPixelCount = 0;
    double totalGrayLightness = 0;

    final hueBuckets = List<int>.generate(_hueBucketCount, (_) => 0);
    final hueSatSums = List<double>.generate(_hueBucketCount, (_) => 0);
    final hueLightSums = List<double>.generate(_hueBucketCount, (_) => 0);

    int coloredPixelCount = 0;
    double totalColoredSaturation = 0;

    final cx = width / 2.0;
    final cy = height / 2.0;

    for (var i = 0; i < pixels.length; i += step * 4) {
      if (i + 3 >= pixels.length) break;
      final r = pixels[i];
      final g = pixels[i + 1];
      final b = pixels[i + 2];
      final a = pixels[i + 3];
      if (a < 128) continue;

      final px = (i ~/ 4) % width;
      final py = (i ~/ 4) ~/ width;
      final dx = (px - cx) / cx;
      final dy = (py - cy) / cy;
      final dist = math.sqrt(dx * dx + dy * dy);

      final centerWeight = math.max(0.0, 1.0 - dist);
      final importance = 1.0 + centerWeight * 2.0;

      final maxC = math.max(r, math.max(g, b));
      final minC = math.min(r, math.min(g, b));
      final d = maxC - minC;

      final maxF = maxC / 255.0;
      final minF = minC / 255.0;
      final l = (maxF + minF) / 2.0;

      if (l < 0.02 || l > 0.98) continue;

      if (d < 8) {
        grayPixelCount += importance.round();
        totalGrayLightness += l * importance;
        continue;
      }

      coloredPixelCount += importance.round();

      final s = l > 0.5 ? d / (510.0 - maxC - minC) : d / (maxC + minC);
      totalColoredSaturation += s * importance;

      double h;
      if (maxC == r) {
        h = 60.0 * (((g - b) / d) % 6);
      } else if (maxC == g) {
        h = 60.0 * ((b - r) / d + 2);
      } else {
        h = 60.0 * ((r - g) / d + 4);
      }
      if (h < 0) h += 360;

      final bucket = (h / _bucketWidth).floor().clamp(0, _hueBucketCount - 1);
      hueBuckets[bucket] += importance.round();
      hueSatSums[bucket] += s * importance;
      hueLightSums[bucket] += l * importance;
    }

    final overallAvgSat = coloredPixelCount > 0 
        ? totalColoredSaturation / coloredPixelCount 
        : 0.0;
    final isGrayscale = overallAvgSat < 0.08 || coloredPixelCount < 10;

    if (isGrayscale) {
      final totalValid = grayPixelCount + coloredPixelCount;
      final avgLight = totalValid > 0 
          ? (totalGrayLightness + totalColoredSaturation * 0.0) / totalValid
          : 0.5;
      return HslAnalysisResult(
        isGrayscale: true,
        primaryHue: 0.0,
        primarySaturation: 0.0,
        primaryLightness: avgLight.clamp(0.05, 0.95),
        secondaryHue: null,
        secondarySaturation: 0.0,
        secondaryLightness: 0.0,
        primaryIsWarm: false,
        primaryIsCool: false,
      );
    }

    int maxPop = 0;
    int primaryBucket = 0;
    for (var i = 0; i < _hueBucketCount; i++) {
      if (hueBuckets[i] > maxPop) {
        maxPop = hueBuckets[i];
        primaryBucket = i;
      }
    }

    final primaryHue = primaryBucket * _bucketWidth.toDouble() + (_bucketWidth / 2);
    final primarySat = hueBuckets[primaryBucket] > 0 
        ? hueSatSums[primaryBucket] / hueBuckets[primaryBucket] 
        : 0.0;
    final primaryLight = hueBuckets[primaryBucket] > 0 
        ? hueLightSums[primaryBucket] / hueBuckets[primaryBucket] 
        : 0.5;

    double? secondaryHue;
    double secondarySat = 0;
    double secondaryLight = 0;

    int secondPop = 0;
    for (var i = 0; i < _hueBucketCount; i++) {
      if (hueBuckets[i] < 5) continue;
      final bucketHue = i * _bucketWidth.toDouble() + (_bucketWidth / 2);
      final dist = _hueDistance(primaryHue, bucketHue);
      if (dist >= 30 && hueBuckets[i] > secondPop) {
        secondPop = hueBuckets[i];
        secondaryHue = bucketHue;
        secondarySat = hueSatSums[i] / hueBuckets[i];
        secondaryLight = hueLightSums[i] / hueBuckets[i];
      }
    }

    final secondarySignificance = maxPop > 0 ? secondPop / maxPop : 0.0;
    if (secondarySignificance < 0.08) {
      secondaryHue = null;
      secondarySat = 0;
    }

    final primaryIsWarm = _isWarmHue(primaryHue);
    final primaryIsCool = _isCoolHue(primaryHue);

    double? warmHue;
    double warmSat = 0;
    double warmLight = 0;
    int warmPop = 0;
    int warmTotalPop = 0;

    double? coolHue;
    double coolSat = 0;
    double coolLight = 0;
    int coolPop = 0;
    int coolTotalPop = 0;

    for (var i = 0; i < _hueBucketCount; i++) {
      if (hueBuckets[i] < 5) continue;
      final bucketHue = i * _bucketWidth.toDouble() + (_bucketWidth / 2);
      final isWarm = _isWarmHue(bucketHue);
      final isCool = _isCoolHue(bucketHue);

      if (isWarm) {
        warmTotalPop += hueBuckets[i];
        if (hueBuckets[i] > warmPop) {
          warmPop = hueBuckets[i];
          warmHue = bucketHue;
          warmSat = hueSatSums[i] / hueBuckets[i];
          warmLight = hueLightSums[i] / hueBuckets[i];
        }
      }

      if (isCool) {
        coolTotalPop += hueBuckets[i];
        if (hueBuckets[i] > coolPop) {
          coolPop = hueBuckets[i];
          coolHue = bucketHue;
          coolSat = hueSatSums[i] / hueBuckets[i];
          coolLight = hueLightSums[i] / hueBuckets[i];
        }
      }
    }

    final totalWarmCool = warmTotalPop + coolTotalPop;
    final warmRatio = totalWarmCool > 0 ? warmTotalPop / totalWarmCool : 0.0;
    final coolRatio = totalWarmCool > 0 ? coolTotalPop / totalWarmCool : 0.0;

    if (warmRatio < 0.25 || warmTotalPop < 30) {
      warmHue = null;
    }
    if (coolRatio < 0.25 || coolTotalPop < 30) {
      coolHue = null;
    }

    double avgLightness = 0;
    int lightSampleCount = 0;
    for (var i = 0; i < _hueBucketCount; i++) {
      if (hueBuckets[i] > 0) {
        avgLightness += hueLightSums[i];
        lightSampleCount++;
      }
    }
    if (lightSampleCount > 0) {
      avgLightness /= lightSampleCount;
    }

    final isLowContrastCover = avgLightness > 0.4 && avgLightness < 0.65
        && overallAvgSat < 0.25;

    return HslAnalysisResult(
      isGrayscale: false,
      primaryHue: primaryHue,
      primarySaturation: primarySat,
      primaryLightness: primaryLight,
      secondaryHue: secondaryHue,
      secondarySaturation: secondarySat,
      secondaryLightness: secondaryLight,
      primaryIsWarm: primaryIsWarm,
      primaryIsCool: primaryIsCool,
      warmHue: warmHue,
      warmSaturation: warmSat,
      warmLightness: warmLight,
      coolHue: coolHue,
      coolSaturation: coolSat,
      coolLightness: coolLight,
      isLowContrast: isLowContrastCover,
    );
  }

  List<Color> generateHarmoniousPalette(HslAnalysisResult analysis) {
    if (analysis.isGrayscale) {
      final baseLight = analysis.primaryLightness.clamp(0.08, 0.82);
      return [
        HSLColor.fromAHSL(1.0, 0, 0, (baseLight * 0.35).clamp(0.04, 0.25)).toColor(),
        HSLColor.fromAHSL(1.0, 0, 0, (baseLight * 0.65).clamp(0.15, 0.45)).toColor(),
        HSLColor.fromAHSL(1.0, 0, 0, baseLight.clamp(0.25, 0.65)).toColor(),
        HSLColor.fromAHSL(1.0, 0, 0, (baseLight * 1.3).clamp(0.40, 0.85)).toColor(),
      ];
    }

    double satMultiplier = 1.0;
    if (analysis.isLowContrast) {
      satMultiplier = 0.40;
    } else if (analysis.primarySaturation > 0.55) {
      satMultiplier = 0.68;
    }

    final primaryHue = analysis.primaryHue;
    final primarySat = (analysis.primarySaturation * satMultiplier).clamp(0.04, 0.55);
    final primaryLight = analysis.primaryLightness.clamp(0.15, 0.68);

    double accentHue;
    double accentSat;
    double accentLight;

    if (analysis.isLowContrast) {
      accentHue = (primaryHue + 20) % 360;
      accentSat = (primarySat * 0.55).clamp(0.03, 0.28);
      accentLight = (primaryLight * 1.08).clamp(0.30, 0.58);
    } else if (analysis.primaryIsWarm && analysis.coolHue != null) {
      accentHue = analysis.coolHue!;
      accentSat = (analysis.coolSaturation * satMultiplier).clamp(0.06, 0.42);
      accentLight = analysis.coolLightness.clamp(0.25, 0.55);
    } else if (analysis.primaryIsCool && analysis.warmHue != null) {
      accentHue = analysis.warmHue!;
      accentSat = (analysis.warmSaturation * satMultiplier).clamp(0.08, 0.45);
      accentLight = analysis.warmLightness.clamp(0.28, 0.58);
    } else if (analysis.secondaryHue != null) {
      accentHue = analysis.secondaryHue!;
      accentSat = (analysis.secondarySaturation * satMultiplier).clamp(0.06, 0.42);
      accentLight = analysis.secondaryLightness.clamp(0.25, 0.55);
    } else {
      accentHue = (primaryHue + 20) % 360;
      accentSat = (primarySat * 0.50).clamp(0.03, 0.38);
      accentLight = (primaryLight * 1.08).clamp(0.30, 0.60);
    }

    return [
      HSLColor.fromAHSL(
        1.0, 
        primaryHue, 
        primarySat, 
        (primaryLight * 0.38).clamp(0.06, 0.20)
      ).toColor(),
      
      HSLColor.fromAHSL(
        1.0, 
        primaryHue, 
        (primarySat * 1.08).clamp(0.04, 0.58), 
        primaryLight.clamp(0.28, 0.48)
      ).toColor(),
      
      HSLColor.fromAHSL(
        1.0, 
        accentHue, 
        accentSat, 
        accentLight
      ).toColor(),
      
      HSLColor.fromAHSL(
        1.0, 
        (primaryHue + 12) % 360, 
        (primarySat * 0.65).clamp(0.03, 0.45), 
        (primaryLight * 1.28).clamp(0.42, 0.72)
      ).toColor(),
    ];
  }

  double _hueDistance(double a, double b) {
    final d = (a - b).abs();
    return d > 180 ? 360 - d : d;
  }
}

/// HSL 分析结果
class HslAnalysisResult {
  final bool isGrayscale;
  final double primaryHue;
  final double primarySaturation;
  final double primaryLightness;
  final double? secondaryHue;
  final double secondarySaturation;
  final double secondaryLightness;
  final bool primaryIsWarm;
  final bool primaryIsCool;
  final double? warmHue;
  final double warmSaturation;
  final double warmLightness;
  final double? coolHue;
  final double coolSaturation;
  final double coolLightness;
  final bool isLowContrast;

  const HslAnalysisResult({
    required this.isGrayscale,
    required this.primaryHue,
    required this.primarySaturation,
    required this.primaryLightness,
    required this.secondaryHue,
    required this.secondarySaturation,
    required this.secondaryLightness,
    this.primaryIsWarm = false,
    this.primaryIsCool = false,
    this.warmHue,
    this.warmSaturation = 0.0,
    this.warmLightness = 0.0,
    this.coolHue,
    this.coolSaturation = 0.0,
    this.coolLightness = 0.0,
    this.isLowContrast = false,
  });

  factory HslAnalysisResult.empty() {
    return const HslAnalysisResult(
      isGrayscale: false,
      primaryHue: 210.0,
      primarySaturation: 0.5,
      primaryLightness: 0.5,
      secondaryHue: null,
      secondarySaturation: 0.0,
      secondaryLightness: 0.0,
    );
  }
}
