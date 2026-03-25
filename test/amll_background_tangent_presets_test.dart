import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/mesh_gradient/core/control_point.dart';
import 'package:pure_music/page/now_playing_page/component/amll_background_tangents.dart';

void main() {
	test("degToRad converts degrees to radians", () {
		expect(degToRad(0), 0);
		expect(degToRad(180), closeTo(math.pi, 1e-12));
		expect(degToRad(-90), closeTo(-math.pi / 2, 1e-12));
	});

	test("applyAmllTangentConf offsets rotations and scales", () {
		final conf = (urDeg: 60.0, vrDeg: -30.0, up: 2.0, vp: 0.5);
		final applied = applyAmllTangentConf(
			baseURot: 0.1,
			baseVRot: -0.2,
			baseUScale: 0.20,
			baseVScale: 0.30,
			conf: conf,
		);

		expect(applied.uRot, closeTo(0.1 + degToRad(60.0), 1e-12));
		expect(applied.vRot, closeTo(-0.2 + degToRad(-30.0), 1e-12));
		expect(applied.uScale, closeTo(0.40, 1e-12));
		expect(applied.vScale, closeTo(0.15, 1e-12));
	});

	test("resolveAmllControlPointConf matches AMLL 4x4 preset scaling", () {
		final resolved = resolveAmllControlPointConf(
			conf: (
				x: 0.9989920471,
				y: -0.3382976021,
				urDeg: 8.0,
				vrDeg: 0.0,
				up: 0.566,
				vp: 1.792,
			),
			width: 4,
			height: 4,
		);

		expect(resolved.x, closeTo(0.9989920471, 1e-12));
		expect(resolved.y, closeTo(-0.3382976021, 1e-12));
		expect(resolved.uRot, closeTo(degToRad(8.0), 1e-12));
		expect(resolved.vRot, closeTo(0.0, 1e-12));
		expect(resolved.uScale, closeTo((2.0 / 3.0) * 0.566, 1e-12));
		expect(resolved.vScale, closeTo((2.0 / 3.0) * 1.792, 1e-12));
	});

	test("resolveAmllControlPointConf matches AMLL 5x5 preset scaling", () {
		final resolved = resolveAmllControlPointConf(
			conf: (
				x: -0.4501953125,
				y: -1.0,
				urDeg: 0.0,
				vrDeg: 55.0,
				up: 1.0,
				vp: 2.075,
			),
			width: 5,
			height: 5,
		);

		expect(resolved.uScale, closeTo(0.5, 1e-12));
		expect(resolved.vScale, closeTo(0.5 * 2.075, 1e-12));
		expect(resolved.vRot, closeTo(degToRad(55.0), 1e-12));
	});

	test("sampleTangentFlowFromControlPoints returns constant flow", () {
		final controlPoints = List<ControlPoint>.generate(16, (_) {
			return ControlPoint(
				x: 0,
				y: 0,
				r: 0,
				g: 0,
				b: 0,
				uRot: 0,
				vRot: 0,
				uScale: 0.25,
				vScale: 0,
			);
		});

		final flow = sampleTangentFlowFromControlPoints(
			controlPoints16: controlPoints,
			u: 0.42,
			v: 0.84,
		);
		expect(flow.x, closeTo(0.25, 1e-12));
		expect(flow.y, closeTo(0, 1e-12));
	});
}
