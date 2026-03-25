import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/component/amll_background_uv_math.dart';

double _glslMod(double x, double y) {
	// GLSL: mod(x, y) = x - y * floor(x / y)
	return x - y * (x / y).floorToDouble();
}

({double u, double v}) _glslMirroredUv({required double u, required double v}) {
	final tiledU = _glslMod(u, 2.0);
	final tiledV = _glslMod(v, 2.0);
	return (
		u: tiledU >= 1.0 ? 2.0 - tiledU : tiledU,
		v: tiledV >= 1.0 ? 2.0 - tiledV : tiledV,
	);
}

void main() {
	test('amllMirroredUv matches amll_background.frag mirroredUv behavior', () {
		const samples = <({double u, double v})>[
			(u: 0.25, v: 0.75),
			(u: 1.25, v: 0.75),
			(u: 2.25, v: 0.75),
			(u: -0.25, v: 0.75),
			(u: -1.25, v: -0.75),
			(u: 3.99, v: -2.01),
		];

		for (final uv in samples) {
			final expected = _glslMirroredUv(u: uv.u, v: uv.v);
			final actual = amllMirroredUv(u: uv.u, v: uv.v);

			expect(actual.u, closeTo(expected.u, 1e-12));
			expect(actual.v, closeTo(expected.v, 1e-12));
			expect(actual.u, inInclusiveRange(0.0, 1.0));
			expect(actual.v, inInclusiveRange(0.0, 1.0));
		}
	});
}
