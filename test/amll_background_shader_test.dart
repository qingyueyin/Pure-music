import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/component/amll_background_shader.dart';

void main() {
  test('buildAmllBackgroundShaderFloats packs uniforms in shader order', () {
    const colors = [
      Color(0xFF102030),
      Color(0xFF405060),
      Color(0xFF708090),
      Color(0xFFA0B0C0),
    ];

    final floats = buildAmllBackgroundShaderFloats(
      size: const Size(320, 180),
      time: 12.5,
      intensity: 0.9,
      lowFreqVolume: 0.35,
      coverDarkness: 0.6,
      albumBlend: 0.4,
      hasAlbum: true,
      colors: colors,
      flow16: List.generate(16, (i) => (x: i.toDouble(), y: -i.toDouble())),
    );

    expect(floats.length, amllBackgroundShaderFloatCount);
    expect(floats[0], 320);
    expect(floats[1], 180);
    expect(floats[2], closeTo(12.5, 1e-6));
    expect(floats[3], closeTo(0.9, 1e-6));
    expect(floats[4], closeTo(0.35, 1e-6));
    expect(floats[5], closeTo(0.6, 1e-6));
    expect(floats[6], closeTo(0.4, 1e-6));
    expect(floats[7], closeTo(1.0, 1e-6));

    expect(floats[8], closeTo(colors[0].r, 1e-6));
    expect(floats[9], closeTo(colors[0].g, 1e-6));
    expect(floats[10], closeTo(colors[0].b, 1e-6));
    expect(floats[17], closeTo(colors[3].r, 1e-6));
    expect(floats[18], closeTo(colors[3].g, 1e-6));
    expect(floats[19], closeTo(colors[3].b, 1e-6));

    expect(floats[20], closeTo(0.0, 1e-6));
    expect(floats[21], closeTo(0.0, 1e-6));
    expect(floats[22], closeTo(1.0, 1e-6));
    expect(floats[23], closeTo(-1.0, 1e-6));
    expect(floats[50], closeTo(15.0, 1e-6));
    expect(floats[51], closeTo(-15.0, 1e-6));
  });

  test('buildAmllBackgroundShaderFloats clamps intensity and volume', () {
    final floats = buildAmllBackgroundShaderFloats(
      size: const Size(1, 1),
      time: 0,
      intensity: -3,
      lowFreqVolume: 8,
      coverDarkness: -2,
      albumBlend: 5,
      hasAlbum: false,
      colors: const [
        Color(0xFF000000),
        Color(0xFF000000),
        Color(0xFF000000),
        Color(0xFF000000),
      ],
      flow16: List.generate(16, (_) => (x: 0.0, y: 0.0)),
    );

    expect(floats[3], closeTo(0, 1e-6));
    expect(floats[4], closeTo(1, 1e-6));
    expect(floats[5], closeTo(0, 1e-6));
    expect(floats[6], closeTo(1, 1e-6));
    expect(floats[7], closeTo(0, 1e-6));
  });
}
