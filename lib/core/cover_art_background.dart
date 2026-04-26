import 'dart:async' show TimeoutException;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;

/// Build a Apple Music–style cover art background:
/// - Crop center square, scale up large
/// - Apply heavy blur so cover content is invisible, only colors remain
/// - Slight darken for text readability
Future<ui.Image?> buildCoverArtBackground(
  Uint8List coverPngBytes, {
  required int canvasSize,
  required int tileSize,
  required double blurSigma,
  required double darken,
}) async {
  return _buildCoverArtBackgroundApple(
    coverPngBytes,
    canvasSize: canvasSize,
    blurSigma: blurSigma,
    darken: darken,
  );
}

/// Apple Music–style: just scale up + blur + darken. No tile collage.
Future<ui.Image?> _buildCoverArtBackgroundApple(
  Uint8List coverPngBytes, {
  required int canvasSize,
  required double blurSigma,
  required double darken,
}) async {
  if (coverPngBytes.isEmpty) return null;
  if (canvasSize <= 8) return null;

  if (kDebugMode) {
    final codec = await ui.instantiateImageCodec(
      coverPngBytes,
      targetWidth: canvasSize,
      targetHeight: canvasSize,
    );
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  try {
    final src = await _decodeImage(coverPngBytes);
    final out = await _buildAppleBg(src, canvasSize, blurSigma, darken);
    src.dispose();
    return out;
  } on TimeoutException {
    // Fallback
  }

  final codec = await ui.instantiateImageCodec(
    coverPngBytes,
    targetWidth: canvasSize,
    targetHeight: canvasSize,
  );
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
}

Future<ui.Image> _buildAppleBg(
  ui.Image src,
  int canvasSize,
  double blurSigma,
  double darken,
) async {
  final sw = src.width.toDouble();
  final sh = src.height.toDouble();
  final s = math.min(sw, sh);
  final sx = (sw - s) / 2.0;
  final sy = (sh - s) / 2.0;
  final srcRect = ui.Rect.fromLTWH(sx, sy, s, s);

  // Scale the cover up so individual details blur away.
  // Apple Music appears to scale to roughly 1.6–2.0× the canvas.
  final scaleFactor = 1.8;
  final scaledSize = (canvasSize * scaleFactor).round();

  // Step 1: scale up the center square.
  final rec1 = ui.PictureRecorder();
  final c1 = ui.Canvas(rec1);
  final paint = ui.Paint()..filterQuality = ui.FilterQuality.high;
  c1.drawImageRect(
    src,
    srcRect,
    ui.Rect.fromLTWH(0, 0, scaledSize.toDouble(), scaledSize.toDouble()),
    paint,
  );
  final pic1 = rec1.endRecording();
  final scaled = await _toImage(pic1, scaledSize, scaledSize);

  // Step 2: downsample to blur heavily.
  final ds = math.max(16, (canvasSize / (1.0 + blurSigma / 15.0)).round());
  final rec2 = ui.PictureRecorder();
  final c2 = ui.Canvas(rec2);
  c2.drawImageRect(
    scaled,
    ui.Rect.fromLTWH(0, 0, scaledSize.toDouble(), scaledSize.toDouble()),
    ui.Rect.fromLTWH(0, 0, ds.toDouble(), ds.toDouble()),
    paint,
  );
  final pic2 = rec2.endRecording();
  final small = await _toImage(pic2, ds, ds);

  final rec3 = ui.PictureRecorder();
  final c3 = ui.Canvas(rec3);
  c3.drawImageRect(
    small,
    ui.Rect.fromLTWH(0, 0, ds.toDouble(), ds.toDouble()),
    ui.Rect.fromLTWH(0, 0, canvasSize.toDouble(), canvasSize.toDouble()),
    paint,
  );
  final pic3 = rec3.endRecording();
  final blurred = await _toImage(pic3, canvasSize, canvasSize);
  scaled.dispose();
  small.dispose();

  // Step 3: add slight darken + vignette.
  final outRec = ui.PictureRecorder();
  final outCanvas = ui.Canvas(outRec);
  outCanvas.drawImage(blurred, ui.Offset.zero, ui.Paint());

  final d = darken.clamp(0.0, 1.0);
  final overlay = ui.Paint()
    ..color = ui.Color.fromARGB((d * 200).round(), 0, 0, 0);
  outCanvas.drawRect(
    ui.Rect.fromLTWH(0, 0, canvasSize.toDouble(), canvasSize.toDouble()),
    overlay,
  );

  // Subtle vignette.
  final vignettePaint = ui.Paint()
    ..shader = ui.Gradient.radial(
      ui.Offset(canvasSize / 2.0, canvasSize / 2.0),
      canvasSize * 0.65,
      [
        const ui.Color(0x00000000),
        ui.Color.fromARGB(
          (math.min(0.45, d + 0.15) * 255).round(),
          0,
          0,
          0,
        ),
      ],
      [0.50, 1.0],
      ui.TileMode.clamp,
    );
  outCanvas.drawRect(
    ui.Rect.fromLTWH(0, 0, canvasSize.toDouble(), canvasSize.toDouble()),
    vignettePaint,
  );

  blurred.dispose();
  final outPic = outRec.endRecording();
  return _toImage(outPic, canvasSize, canvasSize);
}

// ignore: unused_element
Future<ui.Image> _approxBlur(
  ui.Image src, {
  required int canvasSize,
  required double sigma,
}) async {
  if (sigma <= 0) return src;

  // Larger sigma => stronger blur => smaller downsample.
  final factor = (1.0 + sigma / 10.0).clamp(1.0, 8.0);
  final ds = math.max(8, (canvasSize / factor).round());
  if (ds >= canvasSize) return src;

  final srcRect = ui.Rect.fromLTWH(0, 0, canvasSize.toDouble(), canvasSize.toDouble());
  final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;

  final recSmall = ui.PictureRecorder();
  final cSmall = ui.Canvas(recSmall);
  cSmall.drawImageRect(
    src,
    srcRect,
    ui.Rect.fromLTWH(0, 0, ds.toDouble(), ds.toDouble()),
    paint,
  );
  final smallPic = recSmall.endRecording();
  final small = await _toImage(smallPic, ds, ds);

  final recBig = ui.PictureRecorder();
  final cBig = ui.Canvas(recBig);
  cBig.drawImageRect(
    small,
    ui.Rect.fromLTWH(0, 0, ds.toDouble(), ds.toDouble()),
    srcRect,
    paint,
  );
  final blurredPic = recBig.endRecording();
  final blurred = await _toImage(blurredPic, canvasSize, canvasSize);
  small.dispose();
  return blurred;
}

Future<ui.Image> _decodeImage(Uint8List bytes) async {
  // `decodeImageFromList` uses a callback and may hang if the callback
  // is never invoked. `instantiateImageCodec` provides a proper Future
  // that completes with an exception on failure.
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
}

// ignore: unused_element
int _seedFromBytes(Uint8List bytes) {
  // Cheap deterministic seed.
  final n = bytes.length;
  if (n == 0) return 0;
  final a = bytes[0];
  final b = bytes[n - 1];
  final c = bytes[n >> 1];
  final d = bytes[(n * 3) >> 2];
  return (n ^ (a << 24) ^ (b << 16) ^ (c << 8) ^ d) & 0x7FFFFFFF;
}

// ignore: unused_element
Future<ui.Image?> _renderTile({
  required ui.Image src,
  required ui.Rect srcRect,
  required int size,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final dst = ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
  canvas.drawImageRect(
    src,
    srcRect,
    dst,
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final pic = recorder.endRecording();
  return _toImage(pic, size, size);
}

Future<ui.Image> _toImage(ui.Picture pic, int width, int height) async {
  // Widget tests on Windows can occasionally stall when doing multiple
  // `Picture.toImage` conversions back-to-back. Yield once after rasterization
  // to let the engine process pending tasks.
  final img = await pic.toImage(width, height);
  await Future<void>.delayed(Duration.zero);
  return img;
}

// ignore: unused_element
void _drawTile(
  ui.Canvas canvas,
  ui.Image tile,
  math.Random rng, {
  required int dx,
  required int dy,
  required int size,
  required ui.Paint paint,
}) {
  canvas.save();
  canvas.translate(dx + size / 2.0, dy + size / 2.0);
  final rot = (rng.nextInt(4) * math.pi) / 2.0;
  canvas.rotate(rot);
  if (rng.nextBool()) canvas.scale(-1.0, 1.0);
  if (rng.nextBool()) canvas.scale(1.0, -1.0);
  canvas.translate(-size / 2.0, -size / 2.0);
  canvas.drawImage(tile, ui.Offset.zero, paint);
  canvas.restore();
}
