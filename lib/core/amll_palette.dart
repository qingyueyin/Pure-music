import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

import 'advanced_color_extraction.dart';

class AmllPalette {
  /// Primary color — drives the dominant hue of the animated background.
  final Color base;

  /// Secondary color — layered behind base for depth.
  final Color support;

  /// Shadow/depth color — darker variant that anchors the palette.
  final Color shadow;

  /// Highlight — lifted, brighter variant for specular accents.
  final Color highlight;

  /// Overall darkness of the source album cover, on a [0, 1] scale.
  ///
  /// Used by the background shader to suppress brightness so that dark
  /// covers don't produce an unnaturally bright backdrop.
  final double coverDarkness;

  const AmllPalette({
    required this.base,
    required this.support,
    required this.shadow,
    required this.highlight,
    this.coverDarkness = 0.0,
  });
}

/// Estimates how dark an album cover is by sampling its pixels in linear space.
///
/// Returns a value in [0, 1] where:
/// - 0 = very bright / light cover
/// - 1 = very dark / black cover
///
/// The algorithm weighs three signals:
/// 1. Average perceived luminance of all sampled pixels (weighted 55%).
/// 2. 10th-percentile luminance — captures the darkest meaningful region (30%).
/// 3. Ratio of pixels below a luminance threshold — indicates presence of
///    large dark areas (15%).
double _computeCoverDarkness(List<Color> samples) {
  if (samples.isEmpty) return 0.0;

  // Convert to linear luminance.
  final luminances = samples.map(_relativeLuma).toList();
  luminances.sort();

  // Signal 1: mean luminance.
  final avg = luminances.reduce((a, b) => a + b) / luminances.length;

  // Signal 2: 10th-percentile luminance (darkest "typical" region).
  final p10Idx = (luminances.length * 0.10).floor().clamp(0, luminances.length - 1);
  final p10 = luminances[p10Idx];

  // Signal 3: fraction of pixels that are quite dark (luma < 0.12).
  const darkThreshold = 0.12;
  final darkCount = luminances.where((l) => l < darkThreshold).length;
  final darkRatio = darkCount / luminances.length;

  // Weighted combination.
  final signal = avg * 0.55 + p10 * 0.30 + darkRatio * 0.15;
  return signal.clamp(0.0, 1.0);
}

/// Converts a color's RGB channels to linear space and computes perceived luminance.
double _relativeLuma(Color c) {
  // Gamma-expand sRGB channels to linear, then compute luma.
  final rLin = _srgbToLinear(c.r);
  final gLin = _srgbToLinear(c.g);
  final bLin = _srgbToLinear(c.b);
  return 0.2126 * rLin + 0.7152 * gLin + 0.0722 * bLin;
}

/// sRGB gamma expansion.
double _srgbToLinear(double channel) {
  final v = channel.clamp(0.0, 1.0);
  return v <= 0.04045 ? v / 12.92 : _pow((v + 0.055) / 1.055, 2.4);
}

double _pow(double base, double exp) {
  if (base <= 0) return 0;
  // Fast approximation for common cases.
  if (exp == 2.0) return base * base;
  if (exp == 0.5) return base > 0 ? base * 0.5 : 0;
  var result = base;
  var intExp = exp.toInt();
  var fracExp = exp - intExp;
  if (intExp > 1) {
    for (var i = 1; i < intExp; i++) {
      result *= base;
    }
  }
  if (fracExp > 0) {
    // Approximate fractional exponent via log/exp.
    result *= _expApprox(fracExp * _lnApprox(base));
  }
  return result;
}

double _lnApprox(double x) {
  if (x <= 0) return -100;
  // Taylor series for ln(x) around x=1.
  final d = (x - 1) / (x + 1);
  final d2 = d * d;
  var sum = d;
  var term = d;
  for (var n = 3; n <= 15; n += 2) {
    term *= d2;
    sum += term / n;
  }
  return 2 * sum;
}

double _expApprox(double x) {
  // Taylor series for exp(x).
  var sum = 1.0;
  var term = 1.0;
  for (var n = 1; n <= 12; n++) {
    term *= x / n;
    sum += term;
  }
  return sum;
}

/// Estimates darkness of a single color (for fallback / small samples).
double _estimateDarknessFromColor(Color c) {
  final luma = _relativeLuma(c);
  return (1.0 - luma * 2.0).clamp(0.0, 1.0);
}

/// Derive a 4-role palette from already-sampled colors (RGBA bytes).
///
/// When album cover bytes are available, decode a small thumbnail, sample
/// pixels, compute coverDarkness, then build the palette. Falls back to
/// `deriveAmllPalette` if bytes are unavailable or extraction fails.
Future<AmllPalette> deriveAmllPaletteFromSampledColors({
  Uint8List? coverBytes,
  MonetColorScheme? monet,
  Color? fallback,
  int sampleSize = 96,
}) async {
  double darkness = 0.0;

  if (coverBytes != null && coverBytes.isNotEmpty) {
    try {
      final samples = await _samplePixelsFromBytes(coverBytes, sampleSize);
      darkness = _computeCoverDarkness(samples);
    } catch (_) {
      // Fall through to fallback darkness estimation.
    }
  }

  // If no cover data, estimate from the base color.
  final base = monet?.primary ?? fallback ?? Colors.blue;
  if (darkness == 0.0) {
    darkness = _estimateDarknessFromColor(base);
  }

  // Build palette normally.
  final palette = deriveAmllPalette(monet: monet, fallback: fallback);

  // Darken the base when the cover is very dark so the background
  // doesn't get unnaturally bright.
  final darknessAdjustedBase = darkness > 0.5
      ? _darkenBase(palette.base, darkness)
      : palette.base;

  return AmllPalette(
    base: darknessAdjustedBase,
    support: palette.support,
    shadow: palette.shadow,
    highlight: palette.highlight,
    coverDarkness: darkness,
  );
}

/// Adjusts a base color so it stays appropriately dark when the cover is dark.
Color _darkenBase(Color base, double coverDarkness) {
  final hsl = HSLColor.fromColor(base);
  // Simple proportional crush toward black: darkness=1.0 → lightness * 0.12.
  final factor = 1.0 - coverDarkness * 0.88;
  final darkened = hsl.withLightness((hsl.lightness * factor).clamp(0.02, 0.90));
  return _clampHsl(darkened.toColor(), minLightness: 0.02);
}

/// Sample `count` random-ish pixels from cover bytes using a grid pattern
/// (deterministic, no crypto RNG needed for tests).
Future<List<Color>> _samplePixelsFromBytes(Uint8List bytes, int sampleSize) async {
  final imageProvider = MemoryImage(bytes);
  // Decode at a small size to keep pixel sampling fast.
  final maxDim = sampleSize.toDouble();
  final palette = await PaletteGenerator.fromImageProvider(
    imageProvider,
    size: Size(maxDim, maxDim),
    maximumColorCount: sampleSize,
  );

  // Collect colors from the palette cache — representative sampling.
  final sampled = <Color>[];
  for (final pc in palette.paletteColors) {
    sampled.add(pc.color);
    if (sampled.length >= sampleSize) break;
  }
  return sampled;
}

/// Derive 4-role palette for a layered, vivid but clean animated background.
///
/// Goals:
/// - Avoid "mud" (brown/gray) by keeping saturation in a healthy range.
/// - Keep motion palette stable (no huge hue jumps) while still layered.
/// - Provide smooth transitions between tracks by animating between palettes.
AmllPalette deriveAmllPalette({MonetColorScheme? monet, Color? fallback}) {
  final base = monet?.primary ?? fallback ?? Colors.blue;
  final secondary = monet?.secondary ?? base;
  final tertiary = monet?.tertiary ?? secondary;

  final baseHsl = HSLColor.fromColor(base);
  final secondaryHsl = HSLColor.fromColor(secondary);

  final support = _ensureDistinct(
    base: baseHsl,
    candidate: secondaryHsl,
    degrees: 34.0,
  );

  // Shadow: allow very dark covers to produce near-black shadows.
  final shadow = baseHsl
      .withLightness((baseHsl.lightness * 0.45).clamp(0.02, 0.38))
      .withSaturation((baseHsl.saturation * 0.70).clamp(0.04, 0.80))
      .toColor();

  // Highlight: prefer tertiary if meaningful, otherwise lift support.
  // Min lightness not hard-clamped — dark covers should have dark highlights too.
  final highlightRaw = (tertiary == base && tertiary == secondary)
      ? support
      : tertiary;
  final highlightHsl = HSLColor.fromColor(highlightRaw);
  final highlight = highlightHsl
      .withLightness((highlightHsl.lightness * 1.10).clamp(0.08, 0.86))
      .withSaturation((highlightHsl.saturation * 1.02).clamp(0.06, 0.92))
      .toColor();

  // Estimate darkness from the base color when no cover is available.
  final darkness = _estimateDarknessFromColor(base);

  // Final clamps to keep palette clean.
  // Dark covers may produce a very dark base — allow lightness down to 0.03.
  return AmllPalette(
    base: _clampHsl(base, minLightness: 0.03),
    support: _clampHsl(support, minLightness: 0.03),
    shadow: _clampHsl(shadow, minLightness: 0.02),
    highlight: _clampHsl(highlight, minLightness: 0.06),
    coverDarkness: darkness,
  );
}

/// Clamp saturation/lightness to keep colors from going pure-gray or glowing.
/// Lightness is NOT clamped below to allow truly dark covers to stay dark.
Color _clampHsl(Color c, {double minLightness = 0.0}) {
  final hsl = HSLColor.fromColor(c);
  return hsl
      .withSaturation(hsl.saturation.clamp(0.06, 0.92))
      .withLightness(hsl.lightness.clamp(minLightness, 0.90))
      .toColor();
}

Color _ensureDistinct({
  required HSLColor base,
  required HSLColor candidate,
  required double degrees,
}) {
  final hueDistance = _hueDistance(base.hue, candidate.hue);
  final satOk = candidate.saturation >= 0.12;
  if (hueDistance >= 15 && hueDistance <= 80 && satOk) {
    return candidate
        .withSaturation((candidate.saturation * 1.02).clamp(0.12, 0.95))
        .toColor();
  }
  // Analogous hue shift (avoid complementary mud).
  // Don't force lightness up — dark covers should stay dark.
  return base
      .withHue((base.hue + degrees) % 360)
      .withSaturation((base.saturation * 1.08).clamp(0.06, 0.92))
      .withLightness(base.lightness.clamp(0.03, 0.82))
      .toColor();
}

double _hueDistance(double a, double b) {
  final d = (a - b).abs();
  return d > 180 ? 360 - d : d;
}
