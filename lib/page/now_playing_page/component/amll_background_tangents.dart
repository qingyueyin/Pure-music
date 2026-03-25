import 'dart:math' as math;

import 'package:pure_music/mesh_gradient/core/control_point.dart';

typedef AmllTangentConf = ({double urDeg, double vrDeg, double up, double vp});

typedef AmllControlPointConf = ({
	double x,
	double y,
	double urDeg,
	double vrDeg,
	double up,
	double vp,
});

typedef AmllTangentPreset = ({String id, List<AmllTangentConf> conf16});

double degToRad(double degrees) => degrees * math.pi / 180.0;

int chooseAmllTangentPresetIndex({required int seed, required int presetCount}) {
	if (presetCount <= 0) return 0;
	return (seed ^ (seed >> 11) ^ 0x9E3779B9).abs() % presetCount;
}

({double uRot, double vRot, double uScale, double vScale}) applyAmllTangentConf({
	required double baseURot,
	required double baseVRot,
	required double baseUScale,
	required double baseVScale,
	required AmllTangentConf conf,
}) {
	return (
		uRot: baseURot + degToRad(conf.urDeg),
		vRot: baseVRot + degToRad(conf.vrDeg),
		uScale: baseUScale * conf.up,
		vScale: baseVScale * conf.vp,
	);
}

({
	double x,
	double y,
	double uRot,
	double vRot,
	double uScale,
	double vScale,
}) resolveAmllControlPointConf({
	required AmllControlPointConf conf,
	required int width,
	required int height,
}) {
	if (width < 2 || height < 2) {
		throw ArgumentError("width and height must both be >= 2");
	}

	final uPower = 2.0 / (width - 1);
	final vPower = 2.0 / (height - 1);
	return (
		x: conf.x,
		y: conf.y,
		uRot: degToRad(conf.urDeg),
		vRot: degToRad(conf.vrDeg),
		uScale: conf.up * uPower,
		vScale: conf.vp * vPower,
	);
}

({double x, double y}) sampleTangentFlowFromControlPoints({
	required List<ControlPoint> controlPoints16,
	required double u,
	required double v,
}) {
	if (controlPoints16.length != 16) {
		throw ArgumentError(
			"controlPoints16 must have length 16, got ${controlPoints16.length}",
		);
	}
	final flows = buildControlPointFlowGrid(controlPoints16: controlPoints16);
	return sampleTangentFlowFromGrid(flow16: flows, u: u, v: v);
}

List<({double x, double y})> buildControlPointFlowGrid({
	required List<ControlPoint> controlPoints16,
}) {
	if (controlPoints16.length != 16) {
		throw ArgumentError(
			"controlPoints16 must have length 16, got ${controlPoints16.length}",
		);
	}

	return List<({double x, double y})>.generate(
		16,
		(i) => _flowAt(controlPoints16[i]),
		growable: false,
	);
}

({double x, double y}) sampleTangentFlowFromGrid({
	required List<({double x, double y})> flow16,
	required double u,
	required double v,
}) {
	if (flow16.length != 16) {
		throw ArgumentError("flow16 must have length 16, got ${flow16.length}");
	}

	final uu = u.clamp(0.0, 1.0);
	final vv = v.clamp(0.0, 1.0);
	final gx = uu * 3.0;
	final gy = vv * 3.0;
	final x0 = gx.floor().clamp(0, 2);
	final y0 = gy.floor().clamp(0, 2);
	final tx = gx - x0;
	final ty = gy - y0;
	final x1 = x0 + 1;
	final y1 = y0 + 1;

	final i00 = x0 + y0 * 4;
	final i10 = x1 + y0 * 4;
	final i01 = x0 + y1 * 4;
	final i11 = x1 + y1 * 4;

	final a = _lerp(flow16[i00], flow16[i10], tx);
	final b = _lerp(flow16[i01], flow16[i11], tx);
	return _lerp(a, b, ty);
}

({double x, double y}) _flowAt(ControlPoint cp) {
	final uTx = math.cos(cp.uRot) * cp.uScale;
	final uTy = math.sin(cp.uRot) * cp.uScale;
	final vTx = -math.sin(cp.vRot) * cp.vScale;
	final vTy = math.cos(cp.vRot) * cp.vScale;
	return (x: uTx + vTx, y: uTy + vTy);
}

({double x, double y}) _lerp(({double x, double y}) a, ({double x, double y}) b, double t) {
	final tt = t.clamp(0.0, 1.0);
	return (
		x: a.x + (b.x - a.x) * tt,
		y: a.y + (b.y - a.y) * tt,
	);
}
