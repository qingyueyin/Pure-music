import 'package:flutter/material.dart';
import 'package:pure_music/core/advanced_color_extraction.dart';
import 'package:pure_music/mesh_gradient/core/control_point.dart';
import 'package:pure_music/page/now_playing_page/component/amll_background_tangents.dart';

typedef AmllControlPointPreset = ({
  String id,
  int width,
  int height,
  List<AmllControlPointConf> conf,
});

final List<AmllControlPointPreset> kAmllControlPointPresets = [
  (
    id: 'amll-4x4-a',
    width: 4,
    height: 4,
    conf: const [
      (x: -1.0, y: -1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -0.3333333333, y: -1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.3333333333, y: -1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 1.0, y: -1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -1.0, y: -0.044954, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -0.2405611752, y: -0.2246599902, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.3347588858, y: -0.0053129719, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.9989920471, y: -0.3382976021, urDeg: 8.0, vrDeg: 0.0, up: 0.566, vp: 1.792),
      (x: -1.0, y: 0.3333333333, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -0.3425497315, y: -0.0000275016, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.3321437946, y: 0.1981776354, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 1.0, y: 0.0766118180, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -1.0, y: 1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -0.3333333333, y: 1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.3333333333, y: 1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 1.0, y: 1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
    ],
  ),
  (
    id: 'amll-4x4-b',
    width: 4,
    height: 4,
    conf: const [
      (x: -1.0, y: -1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 2.075),
      (x: -0.3333333333, y: -1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.3333333333, y: -1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 1.0, y: -1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -1.0, y: -0.4545779491, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -0.3333333333, y: -0.3333333333, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.0889403143, y: -0.6025711181, urDeg: -32.0, vrDeg: 45.0, up: 1.0, vp: 1.0),
      (x: 1.0, y: -0.3333333333, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -1.0, y: -0.0740240861, urDeg: 1.0, vrDeg: 0.0, up: 1.0, vp: 0.094),
      (x: -0.2719422694, y: 0.0977536993, urDeg: 25.0, vrDeg: -18.0, up: 1.321, vp: 0.0),
      (x: 0.1987741441, y: 0.4307383295, urDeg: 48.0, vrDeg: -40.0, up: 0.755, vp: 0.975),
      (x: 1.0, y: 0.3333333333, urDeg: -37.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -1.0, y: 1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -0.3333333333, y: 1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.5125850864, y: 1.0, urDeg: -20.0, vrDeg: -18.0, up: 0.0, vp: 1.604),
      (x: 1.0, y: 1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
    ],
  ),
  (
    id: 'amll-5x5-a',
    width: 5,
    height: 5,
    conf: const [
      (x: -1.0, y: -1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -0.5, y: -1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.0, y: -1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.5, y: -1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 1.0, y: -1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -1.0, y: -0.5, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -0.5, y: -0.5, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -0.0052029684, y: -0.6131420587, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.5884227308, y: -0.3990805108, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 1.0, y: -0.5, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -1.0, y: 0.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -0.4210024671, y: -0.1189505838, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -0.1019613423, y: -0.0238121180, urDeg: 0.0, vrDeg: -47.0, up: 0.629, vp: 0.849),
      (x: 0.4027512566, y: -0.0634531454, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 1.0, y: 0.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -1.0, y: 0.5, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.0680195848, y: 0.5205913249, urDeg: -31.0, vrDeg: -45.0, up: 1.0, vp: 1.0),
      (x: 0.2144646912, y: 0.2933161011, urDeg: 6.0, vrDeg: -56.0, up: 0.566, vp: 1.321),
      (x: 0.5, y: 0.5, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 1.0, y: 0.5, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -1.0, y: 1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: -0.3137837284, y: 1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.2615363326, y: 1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 0.5, y: 1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
      (x: 1.0, y: 1.0, urDeg: 0.0, vrDeg: 0.0, up: 1.0, vp: 1.0),
    ],
  ),
];

AmllControlPointPreset pickAmllControlPointPreset({required int seed}) {
  if (kAmllControlPointPresets.isEmpty) {
    return generateAmllControlPointPreset(seed: seed);
  }
  final generated = ((seed >> 3) & 0x3) == 0;
  if (generated) {
    final width = (seed & 0x1) == 0 ? 4 : 5;
    final height = ((seed >> 1) & 0x1) == 0 ? 4 : 5;
    return generateAmllControlPointPreset(
      seed: seed,
      width: width,
      height: height,
    );
  }
  final index = seed.abs() % kAmllControlPointPresets.length;
  return kAmllControlPointPresets[index];
}

AmllControlPointPreset generateAmllControlPointPreset({
  required int seed,
  int width = 4,
  int height = 4,
}) {
  final random = _SeededRandom(seed);
  final conf = <AmllControlPointConf>[];

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final u = width == 1 ? 0.0 : x / (width - 1);
      final v = height == 1 ? 0.0 : y / (height - 1);
      final isBorder = x == 0 || y == 0 || x == width - 1 || y == height - 1;
      final baseX = u * 2.0 - 1.0;
      final baseY = v * 2.0 - 1.0;
      final jitter = isBorder ? 0.0 : 0.18;
      conf.add((
        x: (baseX + random.nextSigned(jitter)).clamp(-1.0, 1.0),
        y: (baseY + random.nextSigned(jitter)).clamp(-1.0, 1.0),
        urDeg: isBorder ? 0.0 : random.nextSigned(52.0),
        vrDeg: isBorder ? 0.0 : random.nextSigned(52.0),
        up: isBorder ? 1.0 : 0.82 + random.nextDouble() * 0.42,
        vp: isBorder ? 1.0 : 0.82 + random.nextDouble() * 0.42,
      ));
    }
  }

  return (
    id: 'generated-${seed.toRadixString(16)}-$width-$height',
    width: width,
    height: height,
    conf: conf,
  );
}

Map2D<ControlPoint> buildAmllControlPointGrid({
  required AmllControlPointPreset preset,
  required int dominantColorValue,
  MonetColorScheme? monetScheme,
}) {
  final dominant = Color(dominantColorValue);
  final corners = deriveMeshCornerPalette(
    dominant: dominant,
    monetScheme: monetScheme,
  );

  final grid = Map2D<ControlPoint>(
    width: preset.width,
    height: preset.height,
    initialValue: _resolveControlPoint(
      conf: preset.conf.first,
      width: preset.width,
      height: preset.height,
      color: corners.first,
    ),
  );

  for (var y = 0; y < preset.height; y++) {
    for (var x = 0; x < preset.width; x++) {
      final index = x + y * preset.width;
      final u = preset.width == 1 ? 0.0 : x / (preset.width - 1);
      final v = preset.height == 1 ? 0.0 : y / (preset.height - 1);
      final color = _sampleCornerColors(corners, u, v);
      grid.set(
        x,
        y,
        _resolveControlPoint(
          conf: preset.conf[index],
          width: preset.width,
          height: preset.height,
          color: color,
        ),
      );
    }
  }

  return grid;
}

ControlPoint _resolveControlPoint({
  required AmllControlPointConf conf,
  required int width,
  required int height,
  required Color color,
}) {
  final resolved = resolveAmllControlPointConf(
    conf: conf,
    width: width,
    height: height,
  );
  return ControlPoint(
    x: resolved.x,
    y: resolved.y,
    r: color.r,
    g: color.g,
    b: color.b,
    uRot: resolved.uRot,
    vRot: resolved.vRot,
    uScale: resolved.uScale,
    vScale: resolved.vScale,
  );
}

List<Color> deriveMeshCornerPalette({
  required Color dominant,
  MonetColorScheme? monetScheme,
}) {
  if (monetScheme != null) {
    if (monetScheme.isMonochrome) {
      final darkBase = switch (monetScheme.averageLuminance) {
        > 0.80 => 0.07,
        > 0.60 => 0.10,
        > 0.40 => 0.13,
        _ => 0.17,
      };
      return [
        HSLColor.fromAHSL(1.0, 0.0, 0.03, darkBase).toColor(),
        HSLColor.fromAHSL(1.0, 0.0, 0.04, darkBase + 0.03).toColor(),
        HSLColor.fromAHSL(1.0, 0.0, 0.04, darkBase + 0.07).toColor(),
        HSLColor.fromAHSL(1.0, 0.0, 0.04, darkBase + 0.05).toColor(),
      ];
    }

    final primaryHsl = HSLColor.fromColor(monetScheme.primary);
    final secondaryHsl = HSLColor.fromColor(monetScheme.secondary);
    final tertiaryHsl = HSLColor.fromColor(monetScheme.tertiary);

    final primaryShadow = primaryHsl
        .withSaturation((primaryHsl.saturation * 0.70).clamp(0.18, 0.82))
        .withLightness((primaryHsl.lightness * 0.60).clamp(0.16, 0.42))
        .toColor();
    final primaryMid = primaryHsl
        .withSaturation((primaryHsl.saturation * 0.92).clamp(0.24, 0.92))
        .withLightness((primaryHsl.lightness * 0.92).clamp(0.28, 0.62))
        .toColor();
    final accent = tertiaryHsl
        .withSaturation((tertiaryHsl.saturation * 0.95).clamp(0.22, 0.88))
        .withLightness((tertiaryHsl.lightness * 0.98).clamp(0.30, 0.72))
        .toColor();
    final accentShadow = secondaryHsl
        .withSaturation((secondaryHsl.saturation * 0.72).clamp(0.16, 0.72))
        .withLightness((secondaryHsl.lightness * 0.72).clamp(0.24, 0.54))
        .toColor();

    return [primaryShadow, primaryMid, accent, accentShadow];
  }

  return deriveAmllCornerPalette(dominant);
}

List<Color> deriveAmllCornerPalette(Color dominant) {
  final hsl = HSLColor.fromColor(dominant);

  Color shifted(double hue, double saturation, double lightness) {
    final nextHue = (hsl.hue + hue + 360.0) % 360.0;
    return hsl
        .withHue(nextHue)
        .withSaturation((hsl.saturation * saturation).clamp(0.22, 0.98))
        .withLightness((hsl.lightness * lightness).clamp(0.18, 0.82))
        .toColor();
  }

  return [
    shifted(-18.0, 0.85, 0.54),
    shifted(24.0, 1.05, 0.72),
    shifted(52.0, 0.92, 0.78),
    shifted(-8.0, 1.0, 0.46),
  ];
}

Color _sampleCornerColors(List<Color> corners, double u, double v) {
  final top = Color.lerp(corners[0], corners[1], u)!;
  final bottom = Color.lerp(corners[3], corners[2], u)!;
  return Color.lerp(top, bottom, v)!;
}

class _SeededRandom {
  int _state;

  _SeededRandom(int seed) : _state = seed == 0 ? 0x6D2B79F5 : seed;

  double nextDouble() {
    _state = (_state + 0x6D2B79F5) & 0xFFFFFFFF;
    var t = _state;
    t = (t ^ (t >> 15)) * (t | 1);
    t ^= t + ((t ^ (t >> 7)) * (t | 61));
    final result = ((t ^ (t >> 14)) & 0xFFFFFFFF) / 0x100000000;
    return result.clamp(0.0, 0.999999999);
  }

  double nextSigned(double range) {
    return (nextDouble() * 2.0 - 1.0) * range;
  }
}
