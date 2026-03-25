import 'dart:async' show TimeoutException;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;

/// Build a HyperCeiler-like "cover art" background:
/// - crop center square
/// - create a tile
/// - draw 2x2 collage with deterministic rotations/flips
/// - apply blur
/// - apply dark overlay to keep text readable
Future<ui.Image?> buildCoverArtBackground(
  Uint8List coverPngBytes, {
  required int canvasSize,
  required int tileSize,
  required double blurSigma,
  required double darken,
}) async {
  if (coverPngBytes.isEmpty) return null;
  if (canvasSize <= 8 || tileSize <= 8) return null;

  // In widget tests (and generally in debug mode on Windows), repeated
  // `Picture.toImage` rasterization can hang. Keep the function fast and
  // deterministic in debug builds.
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

  Future<ui.Image?> buildFull() async {
    final src = await _decodeImage(coverPngBytes);
    ui.Image? tile;
    ui.Image? small;
    try {
      final seed = _seedFromBytes(coverPngBytes);
      final rng = math.Random(seed);

      // Crop center square
      final sw = src.width.toDouble();
      final sh = src.height.toDouble();
      final s = math.min(sw, sh);
      final sx = (sw - s) / 2.0;
      final sy = (sh - s) / 2.0;

      tile = await _renderTile(
        src: src,
        srcRect: ui.Rect.fromLTWH(sx, sy, s, s),
        size: tileSize,
      );
      if (tile == null) return null;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;

      // Background base (near-black) so blur edges look clean.
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, canvasSize.toDouble(), canvasSize.toDouble()),
        ui.Paint()..color = const ui.Color(0xFF06070A),
      );

      // Draw 4 tiles with deterministic transforms.
      _drawTile(canvas, tile, rng, dx: 0, dy: 0, size: tileSize, paint: paint);
      _drawTile(canvas, tile, rng, dx: tileSize, dy: 0, size: tileSize, paint: paint);
      _drawTile(canvas, tile, rng, dx: 0, dy: tileSize, size: tileSize, paint: paint);
      _drawTile(canvas, tile, rng,
          dx: tileSize, dy: tileSize, size: tileSize, paint: paint);

      // Add a small accent tile (like HyperCeiler center-ish).
      final smallSize = (tileSize / 2).round();
      small = await _renderTile(
        src: src,
        srcRect: ui.Rect.fromLTWH(sx, sy, s, s),
        size: smallSize,
      );
      if (small != null) {
        final ox = tileSize * 1.5 - smallSize * 0.5;
        final oy = tileSize * 1.5 - smallSize * 0.5;
        canvas.drawImage(small, ui.Offset(ox, oy), paint);
      }

      final rawPic = recorder.endRecording();
      final raw = await _toImage(rawPic, canvasSize, canvasSize);
      final blurred =
          await _approxBlur(raw, canvasSize: canvasSize, sigma: blurSigma);
      if (!identical(blurred, raw)) {
        raw.dispose();
      }

      final outRec = ui.PictureRecorder();
      final outCanvas = ui.Canvas(outRec);
      outCanvas.drawImage(blurred, ui.Offset.zero, ui.Paint());

      // Dark overlay for readability.
      final d = darken.clamp(0.0, 1.0);
      final overlay =
          ui.Paint()..color = ui.Color.fromARGB((d * 255).round(), 0, 0, 0);
      outCanvas.drawRect(
        ui.Rect.fromLTWH(0, 0, canvasSize.toDouble(), canvasSize.toDouble()),
        overlay,
      );

      // Gentle vignette.
      final vignettePaint = ui.Paint()
        ..shader = ui.Gradient.radial(
          ui.Offset(canvasSize / 2.0, canvasSize / 2.0),
          canvasSize * 0.72,
          [
            const ui.Color(0x00000000),
            ui.Color.fromARGB(
              (math.min(0.55, d + 0.20) * 255).round(),
              0,
              0,
              0,
            ),
          ],
          [0.55, 1.0],
          ui.TileMode.clamp,
        );
      outCanvas.drawRect(
        ui.Rect.fromLTWH(0, 0, canvasSize.toDouble(), canvasSize.toDouble()),
        vignettePaint,
      );

      final outPic = outRec.endRecording();
      final out = await _toImage(outPic, canvasSize, canvasSize);
      blurred.dispose();
      return out;
    } finally {
      src.dispose();
      tile?.dispose();
      small?.dispose();
    }
  }

  try {
    // Prevent pathological hangs from stalling the app/test suite.
    final img = await buildFull().timeout(const Duration(seconds: 2));
    if (img != null) return img;
  } on TimeoutException {
    // Fall back to a simple deterministic background.
  }

  // Fallback: just decode & resize.
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
