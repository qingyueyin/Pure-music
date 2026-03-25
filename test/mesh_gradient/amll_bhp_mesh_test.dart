import 'package:flutter_test/flutter_test.dart';

import 'package:pure_music/mesh_gradient/core/amll_bhp_mesh.dart';
import 'package:pure_music/mesh_gradient/core/control_point.dart';
import 'package:pure_music/page/now_playing_page/component/amll_background_tangents.dart';

void main() {
	group("AmllBhpMeshGenerator", () {
		test("uses tangents in Hermite evaluation (center != 0)", () {
			final p00 = ControlPoint(
				x: 0,
				y: 0,
				r: 1,
				g: 1,
				b: 1,
				uRot: 0,
				vRot: 0,
				uScale: 1,
				vScale: 0,
			);
			final p01 = p00.clone();
			final p10 = p00.clone()..uScale = 0;
			final p11 = p10.clone();

			final cps = Map2D<ControlPoint>(width: 2, height: 2, initialValue: p00);
			cps.set(0, 0, p00);
			cps.set(0, 1, p01);
			cps.set(1, 0, p10);
			cps.set(1, 1, p11);

			final geometry = AmllBhpMeshGenerator.generate(
				controlPoints: cps,
				subdivisions: 3,
			);

			// This configuration yields x(u=0.5,v=0.5) = 0.125 in AMLL's implementation.
			final center = geometry.vertexAt(vx: 1, vy: 1);
			expect(center.x, closeTo(0.125, 1e-12));
			expect(geometry.vertexAt(vx: 1, vy: 0).x, closeTo(0.0, 1e-12));
			expect(geometry.vertexAt(vx: 1, vy: 2).x, closeTo(0.0, 1e-12));
		});

		test("generates multi-patch geometry and AMLL-style UV mapping", () {
			const width = 5;
			const height = 5;
			const subdivisions = 3;

			final confs = <({int cx, int cy, AmllControlPointConf conf})>[
				(cx: 0, cy: 0, conf: (x: -1, y: -1, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 1, cy: 0, conf: (x: -0.5, y: -1, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 2, cy: 0, conf: (x: 0, y: -1, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 3, cy: 0, conf: (x: 0.5, y: -1, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 4, cy: 0, conf: (x: 1, y: -1, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 0, cy: 1, conf: (x: -1, y: -0.5, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 1, cy: 1, conf: (x: -0.5, y: -0.5, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(
					cx: 2,
					cy: 1,
					conf: (
						x: -0.0052029684413368305,
						y: -0.6131420587090777,
						urDeg: 0,
						vrDeg: 0,
						up: 1,
						vp: 1,
					),
				),
				(
					cx: 3,
					cy: 1,
					conf: (
						x: 0.5884227308309977,
						y: -0.3990805107556692,
						urDeg: 0,
						vrDeg: 0,
						up: 1,
						vp: 1,
					),
				),
				(cx: 4, cy: 1, conf: (x: 1, y: -0.5, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 0, cy: 2, conf: (x: -1, y: 0, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(
					cx: 1,
					cy: 2,
					conf: (
						x: -0.4210024670505933,
						y: -0.11895058380429502,
						urDeg: 0,
						vrDeg: 0,
						up: 1,
						vp: 1,
					),
				),
				(
					cx: 2,
					cy: 2,
					conf: (
						x: -0.1019613423315412,
						y: -0.023812118047224606,
						urDeg: 0,
						vrDeg: -47,
						up: 0.629,
						vp: 0.849,
					),
				),
				(
					cx: 3,
					cy: 2,
					conf: (
						x: 0.40275125660925437,
						y: -0.06345314544600389,
						urDeg: 0,
						vrDeg: 0,
						up: 1,
						vp: 1,
					),
				),
				(cx: 4, cy: 2, conf: (x: 1, y: 0, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 0, cy: 3, conf: (x: -1, y: 0.5, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(
					cx: 1,
					cy: 3,
					conf: (
						x: 0.06801958477287173,
						y: 0.5205913248960121,
						urDeg: -31,
						vrDeg: -45,
						up: 1,
						vp: 1,
					),
				),
				(
					cx: 2,
					cy: 3,
					conf: (
						x: 0.21446469120128908,
						y: 0.29331610114301043,
						urDeg: 6,
						vrDeg: -56,
						up: 0.566,
						vp: 1.321,
					),
				),
				(cx: 3, cy: 3, conf: (x: 0.5, y: 0.5, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 4, cy: 3, conf: (x: 1, y: 0.5, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 0, cy: 4, conf: (x: -1, y: 1, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 1, cy: 4, conf: (x: -0.31378372841550195, y: 1, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 2, cy: 4, conf: (x: 0.26153633255328046, y: 1, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 3, cy: 4, conf: (x: 0.5, y: 1, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
				(cx: 4, cy: 4, conf: (x: 1, y: 1, urDeg: 0, vrDeg: 0, up: 1, vp: 1)),
			];

			final first = resolveAmllControlPointConf(
				conf: confs.first.conf,
				width: width,
				height: height,
			);
			final grid = Map2D<ControlPoint>(
				width: width,
				height: height,
				initialValue: ControlPoint(
					x: first.x,
					y: first.y,
					r: 1,
					g: 1,
					b: 1,
					uRot: first.uRot,
					vRot: first.vRot,
					uScale: first.uScale,
					vScale: first.vScale,
				),
			);

			for (final item in confs) {
				final resolved = resolveAmllControlPointConf(
					conf: item.conf,
					width: width,
					height: height,
				);
				grid.set(
					item.cx,
					item.cy,
					ControlPoint(
						x: resolved.x,
						y: resolved.y,
						r: 1,
						g: 1,
						b: 1,
						uRot: resolved.uRot,
						vRot: resolved.vRot,
						uScale: resolved.uScale,
						vScale: resolved.vScale,
					),
				);
			}

			final geometry = AmllBhpMeshGenerator.generate(
				controlPoints: grid,
				subdivisions: subdivisions,
			);

			expect(geometry.vertexWidth, equals((width - 1) * subdivisions));
			expect(geometry.vertexHeight, equals((height - 1) * subdivisions));
			expect(
				geometry.vertices.length,
				equals(geometry.vertexWidth * geometry.vertexHeight),
			);

			// Corner interpolation: u=v=0 should land on (cx=0,cy=0).
			final origin = geometry.vertexAt(vx: 0, vy: 0);
			expect(origin.x, closeTo(-1.0, 1e-12));
			expect(origin.y, closeTo(-1.0, 1e-12));

			// Patch (0,0) u=v=1 should land on (cx=1,cy=1).
			final p11 = geometry.vertexAt(vx: subdivisions - 1, vy: subdivisions - 1);
			expect(p11.x, closeTo(-0.5, 1e-12));
			expect(p11.y, closeTo(-0.5, 1e-12));

			// UV mapping spot-check (derived from AMLL updateMesh formula).
			final uvSample = geometry.vertexAt(vx: 6, vy: 5);
			expect(uvSample.u, closeTo(0.5, 1e-12));
			expect(uvSample.v, closeTo(0.5, 1e-12));
		});
	});
}
