import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/advanced_color_extraction.dart';
import 'package:pure_music/mesh_gradient/core/amll_control_point_presets.dart';

void main() {
  test('pickAmllControlPointPreset is deterministic for the same seed', () {
    final first = pickAmllControlPointPreset(seed: 0x12345678);
    final second = pickAmllControlPointPreset(seed: 0x12345678);

    expect(first.id, second.id);
    expect(first.width, second.width);
    expect(first.height, second.height);
    expect(first.conf.length, second.conf.length);
  });

  test('buildAmllControlPointGrid keeps preset dimensions and border anchors', () {
    final preset = pickAmllControlPointPreset(seed: 0x12345678);
    final grid = buildAmllControlPointGrid(
      preset: preset,
      dominantColorValue: 0xFF336699,
    );

    expect(grid.width, preset.width);
    expect(grid.height, preset.height);
    expect(grid.at(0, 0).x, closeTo(-1.0, 1e-9));
    expect(grid.at(preset.width - 1, 0).x, closeTo(1.0, 1e-9));
    expect(grid.at(0, preset.height - 1).y, closeTo(1.0, 1e-9));
  });

  test('deriveMeshCornerPalette uses monet tertiary accent when available', () {
    final scheme = MonetColorScheme(
      primary: const Color(0xFF1976D2),
      secondary: const Color(0xFF42A5F5),
      tertiary: const Color(0xFFD97A1C),
      primaryContainer: const Color(0xFF1976D2),
      primarySwatch: const [],
      secondarySwatch: const [],
      neutral1Swatch: const [],
      neutral2Swatch: const [],
    );

    final palette = deriveMeshCornerPalette(
      dominant: scheme.primary,
      monetScheme: scheme,
    );

    final tertiaryHue = HSLColor.fromColor(scheme.tertiary).hue;
    final paletteHues = palette.map((c) => HSLColor.fromColor(c).hue).toList();
    final hasWarmAccent = paletteHues.any((hue) {
      final delta = (hue - tertiaryHue).abs();
      final wrapped = delta > 180 ? 360 - delta : delta;
      return wrapped < 24;
    });

    expect(hasWarmAccent, isTrue);
  });

  test('deriveMeshCornerPalette collapses monochrome covers to neutral tones', () {
    final scheme = MonetColorScheme(
      primary: const Color(0xFF6C6C6C),
      secondary: const Color(0xFF909090),
      tertiary: const Color(0xFFA5A5A5),
      primaryContainer: const Color(0xFF6C6C6C),
      primarySwatch: const [],
      secondarySwatch: const [],
      neutral1Swatch: const [],
      neutral2Swatch: const [],
      isMonochrome: true,
      averageLuminance: 0.82,
    );

    final palette = deriveMeshCornerPalette(
      dominant: scheme.primary,
      monetScheme: scheme,
    );

    for (final color in palette) {
      expect(HSLColor.fromColor(color).saturation, lessThan(0.10));
      expect(HSLColor.fromColor(color).lightness, lessThan(0.24));
    }
  });
}
