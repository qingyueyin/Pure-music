double _glslMod(double x, double y) {
	// GLSL: mod(x, y) = x - y * floor(x / y)
	// Dart's `%` uses truncated division and diverges for negatives.
	return x - y * (x / y).floorToDouble();
}

/// Mirrors a UV coordinate into the [0,1] range with a repeat period of 2.
///
/// Ported from `assets/shaders/amll_background.frag`:
///
/// ```glsl
/// vec2 mirroredUv(vec2 uv) {
///     vec2 tiled = mod(uv, 2.0);
///     return mix(tiled, 2.0 - tiled, step(1.0, tiled));
/// }
/// ```
({double u, double v}) amllMirroredUv({required double u, required double v}) {
	final tiledU = _glslMod(u, 2.0);
	final tiledV = _glslMod(v, 2.0);
	return (
		u: tiledU >= 1.0 ? 2.0 - tiledU : tiledU,
		v: tiledV >= 1.0 ? 2.0 - tiledV : tiledV,
	);
}
