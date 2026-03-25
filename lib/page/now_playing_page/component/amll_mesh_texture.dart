import 'dart:typed_data';
import 'dart:ui' as ui;

/// Preprocess cover art bytes into a small, graded + blurred texture.
///
/// This is parity-oriented with AMLL Core `MeshGradientRenderer` cover pipeline:
/// - resize to a small square (default 32x32)
/// - contrast(0.4) -> saturate(3.0) -> contrast(1.7) -> brightness(0.75)
/// - blur radius=2, quality=4
///
/// Output is suitable to feed into runtime shaders as an image sampler.
Future<ui.Image?> buildAmllMeshTextureFromCoverBytes(
  Uint8List coverBytes, {
  int textureSize = 32,
  double contrastPre = 0.4,
  double saturation = 3.0,
  double contrastPost = 1.7,
  double brightness = 0.75,
  int blurRadius = 2,
  int blurQuality = 4,
}) async {
  if (coverBytes.isEmpty) return null;
  if (textureSize <= 0) return null;

  final codec = await ui.instantiateImageCodec(
    coverBytes,
    targetWidth: textureSize,
    targetHeight: textureSize,
  );

  ui.Image? resized;
  try {
    final frame = await codec.getNextFrame();
    resized = frame.image;
    final byteData = await resized.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return null;

    final pixels = byteData.buffer.asUint8List();
    final processed = amllMeshTexturePreprocessRgba(
      pixels,
      width: resized.width,
      height: resized.height,
      contrastPre: contrastPre,
      saturation: saturation,
      contrastPost: contrastPost,
      brightness: brightness,
      blurRadius: blurRadius,
      blurQuality: blurQuality,
    );

    return _rawRgbaToImage(processed, resized.width, resized.height);
  } finally {
    codec.dispose();
    resized?.dispose();
  }
}

/// Pure CPU implementation of the AMLL mesh-renderer texture preprocessing.
///
/// The returned bytes are RGBA8888, length = width * height * 4.
Uint8List amllMeshTexturePreprocessRgba(
  Uint8List rgba, {
  required int width,
  required int height,
  double contrastPre = 0.4,
  double saturation = 3.0,
  double contrastPost = 1.7,
  double brightness = 0.75,
  int blurRadius = 2,
  int blurQuality = 4,
}) {
  if (width <= 0 || height <= 0) return Uint8List(0);
  final expectedLen = width * height * 4;
  if (rgba.length < expectedLen) {
    throw ArgumentError.value(
      rgba.length,
      'rgba.length',
      'Expected at least $expectedLen bytes for ${width}x$height RGBA',
    );
  }

  final out = Uint8List.fromList(rgba.sublist(0, expectedLen));

  // Grade.
  for (var i = 0; i < out.length; i += 4) {
    var r = out[i].toDouble();
    var g = out[i + 1].toDouble();
    var b = out[i + 2].toDouble();
    final a = out[i + 3];

    // contrast 0.4
    r = (r - 128.0) * contrastPre + 128.0;
    g = (g - 128.0) * contrastPre + 128.0;
    b = (b - 128.0) * contrastPre + 128.0;

    // saturate 3.0
    final gray = r * 0.3 + g * 0.59 + b * 0.11;
    r = gray * (1.0 - saturation) + r * saturation;
    g = gray * (1.0 - saturation) + g * saturation;
    b = gray * (1.0 - saturation) + b * saturation;

    // contrast 1.7
    r = (r - 128.0) * contrastPost + 128.0;
    g = (g - 128.0) * contrastPost + 128.0;
    b = (b - 128.0) * contrastPost + 128.0;

    // brightness 0.75
    r *= brightness;
    g *= brightness;
    b *= brightness;

    out[i] = _toUint8(r);
    out[i + 1] = _toUint8(g);
    out[i + 2] = _toUint8(b);
    out[i + 3] = a;
  }

  // Blur.
  if (blurRadius > 0 && blurQuality > 0) {
    _blurImageRgba(out, width, height, blurRadius, blurQuality);
  }

  return out;
}

/// Holds at most two processed textures for crossfade.
///
/// Ownership: this class owns the [ui.Image] instances and will dispose them.
class AmllMeshTextureHistory {
  ui.Image? _previous;
  ui.Image? _current;
  int _generation = 0;
  int? _currentSignature;

  ui.Image? get previous => _previous;
  ui.Image? get current => _current;

  Future<void> update(
    Uint8List coverBytes, {
    int textureSize = 32,
    double contrastPre = 0.4,
    double saturation = 3.0,
    double contrastPost = 1.7,
    double brightness = 0.75,
    int blurRadius = 2,
    int blurQuality = 4,
  }) async {
    final signature = _hashTextureRequest(
      coverBytes,
      textureSize: textureSize,
      contrastPre: contrastPre,
      saturation: saturation,
      contrastPost: contrastPost,
      brightness: brightness,
      blurRadius: blurRadius,
      blurQuality: blurQuality,
    );
    if (_currentSignature == signature && _current != null) {
      return;
    }

    final gen = ++_generation;
    final next = await buildAmllMeshTextureFromCoverBytes(
      coverBytes,
      textureSize: textureSize,
      contrastPre: contrastPre,
      saturation: saturation,
      contrastPost: contrastPost,
      brightness: brightness,
      blurRadius: blurRadius,
      blurQuality: blurQuality,
    );
    if (next == null) return;

    // Newer update started while awaiting.
    if (gen != _generation) {
      next.dispose();
      return;
    }

    final oldPrev = _previous;
    _previous = _current;
    _current = next;
    _currentSignature = signature;
    oldPrev?.dispose();
  }

	void dispose() {
		// Invalidate any in-flight async updates.
		_generation++;
		_previous?.dispose();
		_current?.dispose();
		_previous = null;
		_current = null;
		_currentSignature = null;
	}
}

int _hashTextureRequest(
  Uint8List coverBytes, {
  required int textureSize,
  required double contrastPre,
  required double saturation,
  required double contrastPost,
  required double brightness,
  required int blurRadius,
  required int blurQuality,
}) {
  var hash = 0x811C9DC5;

  void mixInt(int value) {
    hash ^= value & 0xFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }

  void mixDouble(double value) {
    mixInt((value * 1000).round() & 0xFF);
    mixInt(((value * 1000).round() >> 8) & 0xFF);
  }

  final stride = (coverBytes.length ~/ 1024).clamp(1, coverBytes.length);
  for (var i = 0; i < coverBytes.length; i += stride) {
    mixInt(coverBytes[i]);
  }
  mixInt(coverBytes.length & 0xFF);
  mixInt((coverBytes.length >> 8) & 0xFF);
  mixInt(textureSize);
  mixDouble(contrastPre);
  mixDouble(saturation);
  mixDouble(contrastPost);
  mixDouble(brightness);
  mixInt(blurRadius);
  mixInt(blurQuality);
  return hash;
}

int _toUint8(double value) {
  if (value.isNaN) return 0;
  if (value <= 0) return 0;
  if (value >= 255) return 255;
  return value.round();
}

void _blurImageRgba(
  Uint8List pixels,
  int width,
  int height,
  int radius,
  int quality,
) {
  if (radius <= 0 || quality <= 0) return;
  if (width <= 0 || height <= 0) return;

  final wm = width - 1;
  final hm = height - 1;
  final rad1x = radius + 1;
  final divx = radius + rad1x;
  final rad1y = radius + 1;
  final divy = radius + rad1y;
  final div2 = 1.0 / (divx * divy);

  final count = width * height;
  final r = List<int>.filled(count, 0);
  final g = List<int>.filled(count, 0);
  final b = List<int>.filled(count, 0);
  final a = List<int>.filled(count, 0);
  final vmin = List<int>.filled(width > height ? width : height, 0);
  final vmax = List<int>.filled(width > height ? width : height, 0);

  while (quality-- > 0) {
    var yw = 0;
    var yi = 0;

    for (var y = 0; y < height; y++) {
      var rsum = pixels[yw] * rad1x;
      var gsum = pixels[yw + 1] * rad1x;
      var bsum = pixels[yw + 2] * rad1x;
      var asum = pixels[yw + 3] * rad1x;

      for (var i = 1; i <= radius; i++) {
        var p = yw + ((i > wm ? wm : i) << 2);
        rsum += pixels[p++];
        gsum += pixels[p++];
        bsum += pixels[p++];
        asum += pixels[p];
      }

      for (var x = 0; x < width; x++) {
        r[yi] = rsum;
        g[yi] = gsum;
        b[yi] = bsum;
        a[yi] = asum;

        if (y == 0) {
          vmin[x] = (x + rad1x <= wm ? x + rad1x : wm) << 2;
          vmax[x] = (x - radius >= 0 ? x - radius : 0) << 2;
        }

        final p1 = yw + vmin[x];
        final p2 = yw + vmax[x];
        rsum += pixels[p1] - pixels[p2];
        gsum += pixels[p1 + 1] - pixels[p2 + 1];
        bsum += pixels[p1 + 2] - pixels[p2 + 2];
        asum += pixels[p1 + 3] - pixels[p2 + 3];

        yi++;
      }

      yw += width << 2;
    }

    for (var x = 0; x < width; x++) {
      var yp = x;
      var rsum = r[yp] * rad1y;
      var gsum = g[yp] * rad1y;
      var bsum = b[yp] * rad1y;
      var asum = a[yp] * rad1y;

      for (var i = 1; i <= radius; i++) {
        yp += i > hm ? 0 : width;
        rsum += r[yp];
        gsum += g[yp];
        bsum += b[yp];
        asum += a[yp];
      }

      var outIndex = x << 2;
      for (var y = 0; y < height; y++) {
        pixels[outIndex] = (rsum * div2 + 0.5).floor();
        pixels[outIndex + 1] = (gsum * div2 + 0.5).floor();
        pixels[outIndex + 2] = (bsum * div2 + 0.5).floor();
        pixels[outIndex + 3] = (asum * div2 + 0.5).floor();

        if (x == 0) {
          vmin[y] = (y + rad1y <= hm ? y + rad1y : hm) * width;
          vmax[y] = (y - radius >= 0 ? y - radius : 0) * width;
        }

        final p1 = x + vmin[y];
        final p2 = x + vmax[y];
        rsum += r[p1] - r[p2];
        gsum += g[p1] - g[p2];
        bsum += b[p1] - b[p2];
        asum += a[p1] - a[p2];

        outIndex += width << 2;
      }
    }
  }
}

Future<ui.Image> _rawRgbaToImage(Uint8List rgba, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  try {
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
      rowBytes: width * 4,
    );
    try {
      final codec = await descriptor.instantiateCodec();
      try {
        final frame = await codec.getNextFrame();
        return frame.image;
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}
