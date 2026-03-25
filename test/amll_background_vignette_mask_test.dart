import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

/// Vignette mask matching the GLSL mesh shader's vignette curve.
/// Center (u=0.5, v=0.5) → 1.0; corners → darker via smoothstep.
double amllMeshTextureVignetteMask({required double u, required double v}) {
	final cx = (u - 0.5).abs();
	final cy = (v - 0.5).abs();
	final dist = math.sqrt(cx * cx + cy * cy);
	// Matches mesh.frag.glsl: smoothstep(0.8, 0.3, dist)
	final t = ((dist - 0.8) / (0.3 - 0.8)).clamp(0.0, 1.0);
	final smooth = t * t * (3 - 2 * t);
	return 0.6 + smooth * 0.4;
}

void main() {
	test("amllMeshTextureVignetteMask matches mesh.frag.glsl shape", () {
		// Center should be full strength.
		expect(
			amllMeshTextureVignetteMask(u: 0.5, v: 0.5),
			closeTo(1.0, 1e-12),
		);

		// Corners are the farthest UVs in [0,1]^2.
		final corner = amllMeshTextureVignetteMask(u: 0.0, v: 0.0);
		final otherCorner = amllMeshTextureVignetteMask(u: 1.0, v: 1.0);
		expect(corner, closeTo(otherCorner, 1e-12));

		// Expected value computed from the GLSL formula at dist=sqrt(0.5^2+0.5^2).
		final dist = math.sqrt(0.5 * 0.5 + 0.5 * 0.5);
		final t = ((dist - 0.8) / (0.3 - 0.8)).clamp(0.0, 1.0);
		final smooth = t * t * (3 - 2 * t);
		final expected = 0.6 + smooth * 0.4;
		expect(corner, closeTo(expected, 1e-12));
	});
}
