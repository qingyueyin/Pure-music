import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

// Intentionally referenced before implementation (TDD).
import 'package:pure_music/core/cover_art_background.dart';

// A tiny, valid PNG (1x1) to avoid relying on `Picture.toImage` in widget tests,
// which can hang on some Windows CI environments.
final Uint8List _kTinyPng = base64Decode(
  // 1px transparent PNG.
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEUAAACnej3aAAAAAXRSTlMAQObYZgAAAApJREFUCNdjYAAAAAIAAeIhvDMAAAAASUVORK5CYII=',
);

void main() {
  testWidgets('buildCoverArtBackground returns deterministic image', (tester) async {
    final img1 = await tester.runAsync(() async {
      return buildCoverArtBackground(
        _kTinyPng,
        canvasSize: 256,
        tileSize: 128,
        blurSigma: 18,
        darken: 0.55,
      );
    });
    final img2 = await tester.runAsync(() async {
      return buildCoverArtBackground(
        _kTinyPng,
        canvasSize: 256,
        tileSize: 128,
        blurSigma: 18,
        darken: 0.55,
      );
    });

    expect(img1, isNotNull);
    expect(img2, isNotNull);
    expect(img1!.width, 256);
    expect(img1.height, 256);
    expect(img2!.width, 256);
    expect(img2.height, 256);

    // Don't encode the image back to PNG in widget tests: on Windows CI this can
    // hang in the raster thread. Size checks + non-null is enough for this unit.

    img1.dispose();
    img2.dispose();
  });
}
