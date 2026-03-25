import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pure_music/mesh_gradient/core/control_point.dart';

typedef AmllBhpMeshVertex = ({double x, double y, double u, double v});

final Float64List _hermiteBasis = Float64List.fromList([
	2,
	-2,
	1,
	1,
	-3,
	3,
	-2,
	-1,
	0,
	0,
	1,
	0,
	1,
	0,
	0,
	0,
]);

final Float64List _hermiteBasisT = Float64List.fromList([
	2,
	-3,
	0,
	1,
	-2,
	3,
	0,
	0,
	1,
	-2,
	1,
	0,
	1,
	-1,
	0,
	0,
]);

class AmllBhpMeshGeometry {
	final int vertexWidth;
	final int vertexHeight;
	final List<AmllBhpMeshVertex> vertices;
	final List<int> indices;

	const AmllBhpMeshGeometry({
		required this.vertexWidth,
		required this.vertexHeight,
		required this.vertices,
		required this.indices,
	});

	AmllBhpMeshVertex vertexAt({required int vx, required int vy}) {
		return vertices[vx + vy * vertexWidth];
	}
}

/// Generates a bicubic Hermite patch mesh that matches AMLL's
/// `MeshGradientRenderer` (packages/core/src/bg-render/mesh-renderer/index.ts)
/// mesh generation behavior.
///
/// Notes:
/// - `subdivisions` here matches AMLL's `subDivisions` (vertex count per patch
///   edge, inclusive of both endpoints).
/// - UV mapping mirrors AMLL's `updateMesh()` implementation.
class AmllBhpMeshGenerator {
	static AmllBhpMeshGeometry generate({
		required Map2D<ControlPoint> controlPoints,
		required int subdivisions,
	}) {
		if (subdivisions < 2) {
			throw ArgumentError("subdivisions must be >= 2");
		}

		final controlPointsWidth = controlPoints.width;
		final controlPointsHeight = controlPoints.height;
		if (controlPointsWidth < 2 || controlPointsHeight < 2) {
			throw ArgumentError("controlPoints must be at least 2x2");
		}

		final vertexWidth = (controlPointsWidth - 1) * subdivisions;
		final vertexHeight = (controlPointsHeight - 1) * subdivisions;
		final vertexCount = vertexWidth * vertexHeight;

		final vertices = List<AmllBhpMeshVertex>.filled(
			vertexCount,
			(x: 0, y: 0, u: 0, v: 0),
			growable: false,
		);

		final indices = _buildGridTriangleIndices(
			vertexWidth: vertexWidth,
			vertexHeight: vertexHeight,
		);

		final subDivM1 = subdivisions - 1;

		final tW = subDivM1 * (controlPointsHeight - 1);
		final tH = subDivM1 * (controlPointsWidth - 1);
		final invTW = 1.0 / tW;
		final invTH = 1.0 / tH;

		final invSubDivM1 = 1.0 / subDivM1;
		final normPowers = Float64List(subdivisions * 4);
		for (var i = 0; i < subdivisions; i++) {
			final norm = i * invSubDivM1;
			final idx = i * 4;
			normPowers[idx] = norm * norm * norm;
			normPowers[idx + 1] = norm * norm;
			normPowers[idx + 2] = norm;
			normPowers[idx + 3] = 1.0;
		}

		for (var x = 0; x < controlPointsWidth - 1; x++) {
			for (var y = 0; y < controlPointsHeight - 1; y++) {
				final p00 = controlPoints.at(x, y);
				final p01 = controlPoints.at(x, y + 1);
				final p10 = controlPoints.at(x + 1, y);
				final p11 = controlPoints.at(x + 1, y + 1);

				final coeffX = _meshCoefficients(
					p00: p00,
					p01: p01,
					p10: p10,
					p11: p11,
					axis: _Axis.x,
				);
				final coeffY = _meshCoefficients(
					p00: p00,
					p01: p01,
					p10: p10,
					p11: p11,
					axis: _Axis.y,
				);

				final accX = _precomputeAmllAccelerationMatrix(coeffX);
				final accY = _precomputeAmllAccelerationMatrix(coeffY);

				final sX = x / (controlPointsWidth - 1);
				final sY = y / (controlPointsHeight - 1);
				final baseVx = y * subdivisions;
				final baseVy = x * subdivisions;

				for (var u = 0; u < subdivisions; u++) {
					final uIdx = u * 4;
					final u0 = normPowers[uIdx];
					final u1 = normPowers[uIdx + 1];
					final u2 = normPowers[uIdx + 2];
					final u3 = normPowers[uIdx + 3];
					final vx = baseVx + u;

					// Match AMLL: temp = acc * uVec; then dot with vVec.
					final tx0 = accX[0] * u0 + accX[4] * u1 + accX[8] * u2 + accX[12] * u3;
					final tx1 = accX[1] * u0 + accX[5] * u1 + accX[9] * u2 + accX[13] * u3;
					final tx2 = accX[2] * u0 + accX[6] * u1 + accX[10] * u2 + accX[14] * u3;
					final tx3 = accX[3] * u0 + accX[7] * u1 + accX[11] * u2 + accX[15] * u3;

					final ty0 = accY[0] * u0 + accY[4] * u1 + accY[8] * u2 + accY[12] * u3;
					final ty1 = accY[1] * u0 + accY[5] * u1 + accY[9] * u2 + accY[13] * u3;
					final ty2 = accY[2] * u0 + accY[6] * u1 + accY[10] * u2 + accY[14] * u3;
					final ty3 = accY[3] * u0 + accY[7] * u1 + accY[11] * u2 + accY[15] * u3;

					for (var v = 0; v < subdivisions; v++) {
						final vIdx = v * 4;
						final v0 = normPowers[vIdx];
						final v1 = normPowers[vIdx + 1];
						final v2 = normPowers[vIdx + 2];
						final v3 = normPowers[vIdx + 3];
						final vy = baseVy + v;

						final px = v0 * tx0 + v1 * tx1 + v2 * tx2 + v3 * tx3;
						final py = v0 * ty0 + v1 * ty1 + v2 * ty2 + v3 * ty3;

						final uvX = sX + v * invTH;
						final uvY = 1.0 - sY - u * invTW;

						vertices[vx + vy * vertexWidth] = (
							x: px,
							y: py,
							u: uvX,
							v: uvY,
						);
					}
				}
			}
		}

		return AmllBhpMeshGeometry(
			vertexWidth: vertexWidth,
			vertexHeight: vertexHeight,
			vertices: vertices,
			indices: indices,
		);
	}
}

enum _Axis { x, y }

Float64List _meshCoefficients({
	required ControlPoint p00,
	required ControlPoint p01,
	required ControlPoint p10,
	required ControlPoint p11,
	required _Axis axis,
}) {
	double l(ControlPoint p) => axis == _Axis.x ? p.x : p.y;

	// Inline tangent components to avoid allocating Vector2 per sample.
	double uT(ControlPoint p) {
		final t = math.cos(p.uRot) * p.uScale;
		final s = math.sin(p.uRot) * p.uScale;
		return axis == _Axis.x ? t : s;
	}

	double vT(ControlPoint p) {
		final t = -math.sin(p.vRot) * p.vScale;
		final s = math.cos(p.vRot) * p.vScale;
		return axis == _Axis.x ? t : s;
	}

	// This layout matches AMLL's meshCoefficients() output indices (column-major).
	return Float64List.fromList([
		l(p00),
		l(p01),
		vT(p00),
		vT(p01),
		l(p10),
		l(p11),
		vT(p10),
		vT(p11),
		uT(p00),
		uT(p01),
		0,
		0,
		uT(p10),
		uT(p11),
		0,
		0,
	]);
}

Float64List _precomputeAmllAccelerationMatrix(Float64List coefficientMatrix) {
	// AMLL does: output = transpose(M); output = output * H; output = H^T * output;
	final transposed = _mat4Transpose(coefficientMatrix);
	final mul1 = _mat4Multiply(transposed, _hermiteBasis);
	return _mat4Multiply(_hermiteBasisT, mul1);
}

Float64List _mat4Transpose(Float64List m) {
	final out = Float64List(16);
	for (var r = 0; r < 4; r++) {
		for (var c = 0; c < 4; c++) {
			out[c * 4 + r] = m[r * 4 + c];
		}
	}
	return out;
}

Float64List _mat4Multiply(Float64List a, Float64List b) {
	final out = Float64List(16);
	for (var c = 0; c < 4; c++) {
		final b0 = b[c * 4 + 0];
		final b1 = b[c * 4 + 1];
		final b2 = b[c * 4 + 2];
		final b3 = b[c * 4 + 3];
		out[c * 4 + 0] = a[0] * b0 + a[4] * b1 + a[8] * b2 + a[12] * b3;
		out[c * 4 + 1] = a[1] * b0 + a[5] * b1 + a[9] * b2 + a[13] * b3;
		out[c * 4 + 2] = a[2] * b0 + a[6] * b1 + a[10] * b2 + a[14] * b3;
		out[c * 4 + 3] = a[3] * b0 + a[7] * b1 + a[11] * b2 + a[15] * b3;
	}
	return out;
}

List<int> _buildGridTriangleIndices({
	required int vertexWidth,
	required int vertexHeight,
}) {
	if (vertexWidth < 2 || vertexHeight < 2) return const [];
	final count = (vertexWidth - 1) * (vertexHeight - 1) * 6;
	final indices = List<int>.filled(count, 0, growable: false);
	var i = 0;
	for (var y = 0; y < vertexHeight - 1; y++) {
		for (var x = 0; x < vertexWidth - 1; x++) {
			final tl = y * vertexWidth + x;
			final tr = tl + 1;
			final bl = (y + 1) * vertexWidth + x;
			final br = bl + 1;

			indices[i++] = tl;
			indices[i++] = tr;
			indices[i++] = bl;
			indices[i++] = tr;
			indices[i++] = br;
			indices[i++] = bl;
		}
	}
	return indices;
}
