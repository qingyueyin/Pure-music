import 'dart:math' as math;
import 'package:vector_math/vector_math.dart';

/// Represents a single control point in a bicubic Hermite patch mesh.
/// 
/// Each control point has:
/// - Position (x, y)
/// - Color (r, g, b)
/// - Tangent information (uRot, vRot, uScale, vScale)
/// 
/// The tangents are computed from rotation angles and scale factors:
/// - uTangent = (cos(uRot) * uScale, sin(uRot) * uScale)
/// - vTangent = (-sin(vRot) * vScale, cos(vRot) * vScale)
/// 
/// Algorithm reference: AMLL mesh-renderer/index.ts lines 100-150 (ControlPoint class)
class ControlPoint {
  /// Location in 2D space
  double x;
  double y;

  /// Color (0.0 - 1.0 range)
  double r;
  double g;
  double b;

  /// Tangent rotation angles (radians)
  double uRot; // Rotation for u-direction tangent
  double vRot; // Rotation for v-direction tangent

  /// Scale factors for tangent magnitudes
  double uScale; // Scale factor for u-direction tangent
  double vScale; // Scale factor for v-direction tangent

  ControlPoint({
    required this.x,
    required this.y,
    required this.r,
    required this.g,
    required this.b,
    required this.uRot,
    required this.vRot,
    required this.uScale,
    required this.vScale,
  });

  /// Computes the u-direction tangent vector.
  /// 
  /// Formula: uTangent = (cos(uRot) * uScale, sin(uRot) * uScale)
  /// 
  /// This tangent influences how the surface curves in the u direction.
  Vector2 getUTangent() {
    final tx = math.cos(uRot) * uScale;
    final ty = math.sin(uRot) * uScale;
    return Vector2(tx, ty);
  }

  /// Computes the v-direction tangent vector.
  /// 
  /// Formula: vTangent = (-sin(vRot) * vScale, cos(vRot) * vScale)
  /// 
  /// This tangent influences how the surface curves in the v direction.
  Vector2 getVTangent() {
    final tx = -math.sin(vRot) * vScale;
    final ty = math.cos(vRot) * vScale;
    return Vector2(tx, ty);
  }

  /// Creates a copy of this control point.
  ControlPoint clone() {
    return ControlPoint(
      x: x,
      y: y,
      r: r,
      g: g,
      b: b,
      uRot: uRot,
      vRot: vRot,
      uScale: uScale,
      vScale: vScale,
    );
  }

  /// Linearly interpolates between two control points.
  /// 
  /// Args:
  ///   other: The other control point to interpolate toward
  ///   t: Interpolation factor (0.0 = this, 1.0 = other)
  /// 
  /// Returns: New ControlPoint at interpolated position
  static ControlPoint lerp(ControlPoint a, ControlPoint b, double t) {
    return ControlPoint(
      x: a.x + (b.x - a.x) * t,
      y: a.y + (b.y - a.y) * t,
      r: a.r + (b.r - a.r) * t,
      g: a.g + (b.g - a.g) * t,
      b: a.b + (b.b - a.b) * t,
      uRot: a.uRot + (b.uRot - a.uRot) * t,
      vRot: a.vRot + (b.vRot - a.vRot) * t,
      uScale: a.uScale + (b.uScale - a.uScale) * t,
      vScale: a.vScale + (b.vScale - a.vScale) * t,
    );
  }

  @override
  String toString() =>
      'ControlPoint(x: $x, y: $y, color: ($r, $g, $b), uRot: $uRot, vRot: $vRot, uScale: $uScale, vScale: $vScale)';
}

/// 2D grid container for storing control points in a matrix.
/// 
/// Used to organize control points in a 2D grid for mesh generation.
/// Provides convenient access and iteration over rows and columns.
/// 
/// Performance: O(1) access, O(n²) iteration
class Map2D<T> {
  final int width;
  final int height;
  final List<T> _data;

  Map2D({required this.width, required this.height, required T initialValue})
      : _data = List<T>.filled(width * height, initialValue);

  /// Gets value at (x, y)
  T at(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      throw RangeError('Index out of bounds: ($x, $y)');
    }
    return _data[y * width + x];
  }

  /// Sets value at (x, y)
  void set(int x, int y, T value) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      throw RangeError('Index out of bounds: ($x, $y)');
    }
    _data[y * width + x] = value;
  }

  /// Iterates over all cells in row-major order
  void forEach(void Function(int x, int y, T value) callback) {
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        callback(x, y, _data[y * width + x]);
      }
    }
  }

  /// Gets all data as a flat list
  List<T> toList() => List<T>.from(_data);

  /// Gets value at (x, y) with wrapping (modulo operation)
  T atWrapped(int x, int y) {
    final wrappedX = ((x % width) + width) % width;
    final wrappedY = ((y % height) + height) % height;
    return at(wrappedX, wrappedY);
  }
}
