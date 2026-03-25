import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/advanced_color_extraction.dart';
import 'package:pure_music/core/amll_palette.dart';

void main() {
  test('deriveAmllPalette makes distinct support color for monochrome scheme', () {
    final scheme = MonetColorScheme(
      primary: const Color(0xFF00796B),
      secondary: const Color(0xFF00796B),
      tertiary: const Color(0xFF00796B),
      primaryContainer: const Color(0xFF00796B),
      primarySwatch: List<Color>.filled(13, const Color(0xFF00796B)),
      secondarySwatch: List<Color>.filled(13, const Color(0xFF00796B)),
      neutral1Swatch: List<Color>.filled(13, const Color(0xFF00796B)),
      neutral2Swatch: List<Color>.filled(13, const Color(0xFF00796B)),
    );

    final p = deriveAmllPalette(monet: scheme);
    final h1 = HSLColor.fromColor(p.base).hue;
    final h2 = HSLColor.fromColor(p.support).hue;
    final dh = (h1 - h2).abs();
    final hueDistance = dh > 180 ? 360 - dh : dh;
    expect(hueDistance, greaterThanOrEqualTo(15));
    expect(hueDistance, lessThanOrEqualTo(80));

    final lBase = HSLColor.fromColor(p.base).lightness;
    final lShadow = HSLColor.fromColor(p.shadow).lightness;
    final lHighlight = HSLColor.fromColor(p.highlight).lightness;
    expect(lShadow, lessThan(lBase));
    expect(lHighlight, greaterThan(lBase));
  });

  test('deriveAmllPalette clamps saturation and avoids mud', () {
    final scheme = MonetColorScheme(
      primary: const Color(0xFFB71C1C),
      secondary: const Color(0xFF1B5E20),
      tertiary: const Color(0xFF0D47A1),
      primaryContainer: const Color(0xFF000000),
      primarySwatch: List<Color>.filled(13, const Color(0xFFB71C1C)),
      secondarySwatch: List<Color>.filled(13, const Color(0xFF1B5E20)),
      neutral1Swatch: List<Color>.filled(13, const Color(0xFF111111)),
      neutral2Swatch: List<Color>.filled(13, const Color(0xFF111111)),
    );

    final p = deriveAmllPalette(monet: scheme);
    for (final c in [p.base, p.support, p.shadow, p.highlight]) {
      final hsl = HSLColor.fromColor(c);
      expect(hsl.saturation, inInclusiveRange(0.10, 0.95));
      expect(hsl.lightness, inInclusiveRange(0.10, 0.90));
    }
  });

  test('deriveAmllPalette returns non-zero coverDarkness for dark base color', () {
    // Black should produce high darkness.
    final pDark = deriveAmllPalette(fallback: Colors.black);
    expect(pDark.coverDarkness, greaterThan(0.5));

    // Very bright white should produce low darkness.
    final pLight = deriveAmllPalette(fallback: Colors.white);
    expect(pLight.coverDarkness, lessThan(0.35));

    // Medium gray in between.
    final pGray = deriveAmllPalette(fallback: const Color(0xFF808080));
    expect(pGray.coverDarkness, greaterThan(0.3));
    expect(pGray.coverDarkness, lessThan(0.8));
  });

  test('AmllPalette stores all fields including coverDarkness', () {
    const p = AmllPalette(
      base: Color(0xFFFF0000),
      support: Color(0xFF00FF00),
      shadow: Color(0xFF0000FF),
      highlight: Color(0xFFFFFF00),
      coverDarkness: 0.75,
    );
    expect(p.base, equals(const Color(0xFFFF0000)));
    expect(p.support, equals(const Color(0xFF00FF00)));
    expect(p.shadow, equals(const Color(0xFF0000FF)));
    expect(p.highlight, equals(const Color(0xFFFFFF00)));
    expect(p.coverDarkness, equals(0.75));
  });

  test('deriveAmllPaletteFromSampledColors falls back gracefully with null bytes', () async {
    // With null bytes it should fall back to the monet/fallback color darkness.
    final scheme = MonetColorScheme(
      primary: const Color(0xFFCCCCCC),
      secondary: const Color(0xFFCCCCCC),
      tertiary: const Color(0xFFCCCCCC),
      primaryContainer: Color(0xFFCCCCCC),
      primarySwatch: List<Color>.filled(13, const Color(0xFFCCCCCC)),
      secondarySwatch: List<Color>.filled(13, const Color(0xFFCCCCCC)),
      neutral1Swatch: List<Color>.filled(13, const Color(0xFFCCCCCC)),
      neutral2Swatch: List<Color>.filled(13, const Color(0xFFCCCCCC)),
    );

    final p = await deriveAmllPaletteFromSampledColors(
      coverBytes: null,
      monet: scheme,
    );

    // Should have a valid palette and a darkness value.
    expect(p.coverDarkness, greaterThanOrEqualTo(0.0));
    expect(p.coverDarkness, lessThanOrEqualTo(1.0));
    expect(p.base, isNotNull);
  });
}
