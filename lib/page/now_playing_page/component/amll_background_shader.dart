import "dart:ui";

import "package:flutter/foundation.dart";

@visibleForTesting
const amllBackgroundShaderFloatCount = 52;

typedef AmllFlow = ({double x, double y});

Float32List buildAmllBackgroundShaderFloats({
  required Size size,
  required double time,
  required double intensity,
  required double lowFreqVolume,
  required double coverDarkness,
  required double albumBlend,
  required bool hasAlbum,
  required List<Color> colors,
  required List<AmllFlow> flow16,
}) {
  assert(colors.length >= 4, "At least 4 colors are required.");
  assert(flow16.length == 16, "flow16 must have length 16.");

  final resolvedIntensity = intensity.clamp(0.0, 2.0).toDouble();
  final resolvedVolume = lowFreqVolume.clamp(0.0, 1.0).toDouble();
  final resolvedDarkness = coverDarkness.clamp(0.0, 1.0).toDouble();
  final resolvedAlbumBlend = albumBlend.clamp(0.0, 1.0).toDouble();
  final floats = Float32List(amllBackgroundShaderFloatCount);

  floats[0] = size.width;
  floats[1] = size.height;
  floats[2] = time;
  floats[3] = resolvedIntensity;
  floats[4] = resolvedVolume;
  floats[5] = resolvedDarkness;
  floats[6] = resolvedAlbumBlend;
  floats[7] = hasAlbum ? 1.0 : 0.0;

  var offset = 8;
  for (var i = 0; i < 4; i++) {
    final color = colors[i];
    floats[offset++] = color.r;
    floats[offset++] = color.g;
    floats[offset++] = color.b;
  }

  for (var i = 0; i < 16; i++) {
    final flow = flow16[i];
    floats[offset++] = flow.x;
    floats[offset++] = flow.y;
  }

  return floats;
}
