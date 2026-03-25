import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

// Intentionally referenced before implementation (TDD).
import 'package:pure_music/page/now_playing_page/component/amll_mesh_texture.dart';

// A tiny, valid PNG (1x1). Keep tests deterministic and avoid
// `Picture.toImage` + PNG re-encoding in Windows widget tests.
final Uint8List _kTinyPng = base64Decode(
	// 1px transparent PNG.
	"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEUAAACnej3aAAAAAXRSTlMAQObYZgAAAApJREFUCNdjYAAAAAIAAeIhvDMAAAAASUVORK5CYII=",
);

final Uint8List _kAltTinyPng = base64Decode(
	// 1px opaque PNG with a different pixel payload.
	"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXY/jPwPAfAAUAAf+mXJtdAAAAAElFTkSuQmCC",
);

void main() {
	test("amllMeshTexturePreprocessRgba applies grade constants (no blur)", () {
		final rgba = Uint8List.fromList([200, 10, 50, 255]);

		final processed = amllMeshTexturePreprocessRgba(
			rgba,
			width: 1,
			height: 1,
			blurRadius: 0,
			blurQuality: 0,
		);

		expect(processed, hasLength(4));
		// Expected value computed from AMLL mesh-renderer grading:
		// contrast(0.4) -> saturate(3) -> contrast(1.7) -> brightness(0.75)
		expect(processed[0], 255);
		expect(processed[1], 0);
		expect(processed[2], 34);
		expect(processed[3], 255);
	});

	test("amllMeshTexturePreprocessRgba blur softens a step edge", () {
		const width = 9;
		const height = 1;
		final rgba = Uint8List(width * height * 4);

		for (var x = 0; x < width; x++) {
			final i = x * 4;
			if (x <= 3) {
				rgba[i] = 255;
				rgba[i + 1] = 0;
				rgba[i + 2] = 0;
				rgba[i + 3] = 255;
			} else {
				rgba[i] = 0;
				rgba[i + 1] = 0;
				rgba[i + 2] = 255;
				rgba[i + 3] = 255;
			}
		}

		final processed = amllMeshTexturePreprocessRgba(
			rgba,
			width: width,
			height: height,
			contrastPre: 1.0,
			saturation: 1.0,
			contrastPost: 1.0,
			brightness: 1.0,
			blurRadius: 2,
			blurQuality: 2,
		);

		// With multiple blur iterations, some bleed is expected even at edges.
		// Still, the left edge should remain more red than blue, and vice-versa.
		final leftR = processed[0 * 4 + 0];
		final leftB = processed[0 * 4 + 2];
		expect(leftR, greaterThan(leftB));
		expect(processed[0 * 4 + 3], 255);

		final rightR = processed[8 * 4 + 0];
		final rightB = processed[8 * 4 + 2];
		expect(rightB, greaterThan(rightR));
		expect(processed[8 * 4 + 3], 255);

		// Center boundary pixel should contain a mix of red and blue.
		final boundaryR = processed[4 * 4 + 0];
		final boundaryB = processed[4 * 4 + 2];
		expect(boundaryR, greaterThan(0));
		expect(boundaryB, greaterThan(0));
	});

	testWidgets("buildAmllMeshTextureFromCoverBytes returns a square texture",
		(tester) async {
		final image = await tester.runAsync(() async {
			return buildAmllMeshTextureFromCoverBytes(_kTinyPng, textureSize: 32);
		});

		expect(image, isNotNull);
		expect(image!.width, 32);
		expect(image.height, 32);

		image.dispose();
	});

	testWidgets("AmllMeshTextureHistory retains previous/current for crossfade",
		(tester) async {
		final history = AmllMeshTextureHistory();
		addTearDown(history.dispose);

		await tester.runAsync(() async {
			await history.update(_kTinyPng, textureSize: 32);
		});
		final first = history.current;
		expect(first, isNotNull);
		expect(history.previous, isNull);

		await tester.runAsync(() async {
			await history.update(_kAltTinyPng, textureSize: 32);
		});
		final second = history.current;
		final prev = history.previous;
		expect(second, isNotNull);
		expect(prev, isNotNull);
		expect(identical(prev, first), isTrue);
		expect(identical(second, first), isFalse);
	});

	testWidgets("AmllMeshTextureHistory skips rebuild for identical cover bytes",
		(tester) async {
		final history = AmllMeshTextureHistory();
		addTearDown(history.dispose);

		await tester.runAsync(() async {
			await history.update(_kTinyPng, textureSize: 32);
		});
		final first = history.current;
		expect(first, isNotNull);

		await tester.runAsync(() async {
			await history.update(_kTinyPng, textureSize: 32);
		});

		expect(identical(history.current, first), isTrue);
		expect(history.previous, isNull);
	});
}
