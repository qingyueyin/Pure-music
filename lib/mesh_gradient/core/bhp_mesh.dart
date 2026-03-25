// Bicubic Hermite Patch (BHP) mesh generator for gradient animation.
//
// Manages a 4×4 control point grid and generates smooth mesh surfaces
// using pre-computed Hermite basis functions. Supports audio-reactive
// deformation for frequency-responsive animation.
//
// Algorithm reference: AMLL mesh-renderer implementation

import 'dart:typed_data';
import 'package:vector_math/vector_math.dart';
import 'package:pure_music/mesh_gradient/core/control_point.dart';
import 'package:pure_music/mesh_gradient/core/hermite_math.dart';
import 'package:pure_music/mesh_gradient/config.dart';

/// Represents a vertex in the generated mesh with position and color data
class MeshVertex {
  /// Position in screen coordinates
  final double x;
  final double y;

  /// Color components (0.0 - 1.0)
  final double r;
  final double g;
  final double b;

  /// Normalized UV coordinates for texture mapping (0.0 - 1.0)
  final double u;
  final double v;

  MeshVertex({
    required this.x,
    required this.y,
    required this.r,
    required this.g,
    required this.b,
    required this.u,
    required this.v,
  });

  /// Creates a vertex from raw data array [x, y, r, g, b, u, v]
  factory MeshVertex.fromArray(List<double> data, int offset) {
    return MeshVertex(
      x: data[offset],
      y: data[offset + 1],
      r: data[offset + 2],
      g: data[offset + 3],
      b: data[offset + 4],
      u: data[offset + 5],
      v: data[offset + 6],
    );
  }

  @override
  String toString() =>
      'MeshVertex(x: $x, y: $y, color: ($r, $g, $b), uv: ($u, $v))';
}

/// Triangle mesh face defined by three vertex indices
class MeshTriangle {
  final int v1;
  final int v2;
  final int v3;

  MeshTriangle(this.v1, this.v2, this.v3);
}

/// Bicubic Hermite Patch mesh generator and manager.
///
/// Generates smooth gradient mesh from a 4×4 control point grid,
/// supporting both static rendering and audio-reactive deformation.
class BHPMesh {
  /// 4×4 control point grid (column-major layout for Hermite evaluation)
  late final Map2D<ControlPoint> controlPoints;

  /// Pre-computed acceleration matrices for position and color components
  late Matrix4 posXAccMatrix; // For x coordinates
  late Matrix4 posYAccMatrix; // For y coordinates
  late Matrix4 colorRAccMatrix; // For red channel
  late Matrix4 colorGAccMatrix; // For green channel
  late Matrix4 colorBAccMatrix; // For blue channel

  /// Pre-computed power values for all subdivisions
  late List<Vector4> uPowersList;
  late List<Vector4> vPowersList;

  /// Generated mesh vertices and triangles
  late List<MeshVertex> vertices;
  late List<MeshTriangle> triangles;

  /// Mesh configuration
  final MeshGradientConfig config;

  /// Deformation offsets for audio reactivity
  late Float32List deformationOffsets;

  /// Track original control points for deformation calculations
  late List<ControlPoint> originalControlPoints;

  BHPMesh({
    required List<ControlPoint> initialControlPoints,
    this.config = const MeshGradientConfig(),
  }) {
    if (initialControlPoints.length != 16) {
      throw ArgumentError(
        'BHPMesh requires exactly 16 control points (4×4 grid), '
        'got ${initialControlPoints.length}',
      );
    }

    // Initialize control points grid (row-major access, column-major for Hermite)
    controlPoints = Map2D<ControlPoint>(
      width: 4,
      height: 4,
      initialValue: initialControlPoints[0],
    );

    for (int i = 0; i < initialControlPoints.length; i++) {
      final x = i % 4;
      final y = i ~/ 4;
      controlPoints.set(x, y, initialControlPoints[i]);
    }

    // Store original control points for deformation tracking
    originalControlPoints = List<ControlPoint>.from(initialControlPoints);

    // Initialize deformation offsets (2 values per control point: dx, dy)
    deformationOffsets = Float32List(16 * 2);

    // Pre-compute mesh structure
    _computeAccelerationMatrices();
    _precomputePowerValues();
    _generateMesh();
  }

  /// Computes Hermite acceleration matrices from control point grid.
  ///
  /// This is the critical optimization: pre-computes H^T · M · H matrices
  /// so vertex evaluation is just dot products instead of matrix multiplications.
  void _computeAccelerationMatrices() {
    // Extract position and color coefficients from 4×4 control point grid
    posXAccMatrix = _extractAndComputeAccMatrix((cp) => cp.x);
    posYAccMatrix = _extractAndComputeAccMatrix((cp) => cp.y);
    colorRAccMatrix = _extractAndComputeAccMatrix((cp) => cp.r);
    colorGAccMatrix = _extractAndComputeAccMatrix((cp) => cp.g);
    colorBAccMatrix = _extractAndComputeAccMatrix((cp) => cp.b);
  }

  /// Extracts a 4×4 coefficient matrix from control points and computes acceleration matrix.
  ///
  /// For Hermite patches, we need position data in a specific layout.
  /// Simplified version: extract the value from each control point and build a matrix.
  Matrix4 _extractAndComputeAccMatrix(double Function(ControlPoint) extractor) {
    // Build a simple 4x4 matrix from the control points
    final values = <double>[];

    // For simplicity, arrange in column-major order
    for (int x = 0; x < 4; x++) {
      for (int y = 0; y < 4; y++) {
        final cp = controlPoints.at(x, y);
        values.add(extractor(cp));
      }
    }

    // Pad with zeros if needed
    while (values.length < 16) {
      values.add(0.0);
    }

    final coeffMatrix = Matrix4.fromList(values);
    return HermiteMath.precomputeAccelerationMatrix(coeffMatrix);
  }

  /// Pre-computes power values for all subdivisions.
  ///
  /// Critical optimization: computing all u and v powers once is much faster
  /// than per-vertex computation during evaluation.
  void _precomputePowerValues() {
    final subdivisions = config.resolution.subdivisionsPerPatch;
    uPowersList = HermiteMath.computePowerValues(subdivisions);
    vPowersList = HermiteMath.computePowerValues(subdivisions);
  }

  /// Generates the complete mesh from control points.
  ///
  /// Computes vertices and triangle connectivity for rendering.
  void _generateMesh() {
    final subdivisions = config.resolution.subdivisionsPerPatch;

    // Generate vertices using Hermite evaluation
    vertices = <MeshVertex>[];

    for (int vIdx = 0; vIdx <= subdivisions; vIdx++) {
      final vPowers = vPowersList[vIdx];

      for (int uIdx = 0; uIdx <= subdivisions; uIdx++) {
        final uPowers = uPowersList[uIdx];

        // Evaluate position (x, y) separately
        final x = HermiteMath.evaluateVertex(posXAccMatrix, uPowers, vPowers);
        final y = HermiteMath.evaluateVertex(posYAccMatrix, uPowers, vPowers);

        // Evaluate color (r, g, b) separately
        final r = HermiteMath.evaluateVertex(colorRAccMatrix, uPowers, vPowers)
            .clamp(0.0, 1.0);
        final g = HermiteMath.evaluateVertex(colorGAccMatrix, uPowers, vPowers)
            .clamp(0.0, 1.0);
        final b = HermiteMath.evaluateVertex(colorBAccMatrix, uPowers, vPowers)
            .clamp(0.0, 1.0);

        // Create vertex
        vertices.add(
          MeshVertex(
            x: x,
            y: y,
            r: r,
            g: g,
            b: b,
            u: uIdx / subdivisions,
            v: vIdx / subdivisions,
          ),
        );
      }
    }

    // Generate triangle connectivity (2 triangles per grid square)
    _generateTriangleConnectivity(subdivisions);
  }

  /// Generates triangle connectivity for grid of vertices.
  ///
  /// For each grid square, creates two triangles (CCW winding).
  void _generateTriangleConnectivity(int subdivisions) {
    triangles = <MeshTriangle>[];
    final stride = subdivisions + 1;

    for (int v = 0; v < subdivisions; v++) {
      for (int u = 0; u < subdivisions; u++) {
        // Current quad vertices
        final topLeft = v * stride + u;
        final topRight = topLeft + 1;
        final bottomLeft = (v + 1) * stride + u;
        final bottomRight = bottomLeft + 1;

        // Triangle 1 (top-left, top-right, bottom-left)
        triangles.add(MeshTriangle(topLeft, topRight, bottomLeft));

        // Triangle 2 (top-right, bottom-right, bottom-left)
        triangles.add(MeshTriangle(topRight, bottomRight, bottomLeft));
      }
    }
  }

  /// Applies audio-reactive deformation to control points.
  ///
  /// Uses frequency spectrum data to deform control points smoothly.
  /// The deformation is applied gradually based on smoothing factor.
  ///
  /// Args:
  ///   deformations: Array of deformation vectors [dx0, dy0, dx1, dy1, ..., dx15, dy15]
  ///   smoothingFactor: Interpolation factor (0.0-1.0) for smooth transitions
  void applyDeformation(Float32List deformations, double smoothingFactor) {
    if (deformations.length != 32) {
      throw ArgumentError(
        'Deformation array must have 32 values (2 per control point), '
        'got ${deformations.length}',
      );
    }

    // Smoothly interpolate deformation offsets
    for (int i = 0; i < 32; i++) {
      deformationOffsets[i] = deformationOffsets[i] * (1.0 - smoothingFactor) +
          deformations[i] * smoothingFactor;
    }

    // Update control points with deformation
    for (int i = 0; i < 16; i++) {
      final original = originalControlPoints[i];
      final dx = deformationOffsets[i * 2];
      final dy = deformationOffsets[i * 2 + 1];

      final deformed = ControlPoint(
        x: original.x + dx,
        y: original.y + dy,
        r: original.r,
        g: original.g,
        b: original.b,
        uRot: original.uRot,
        vRot: original.vRot,
        uScale: original.uScale,
        vScale: original.vScale,
      );

      final x = i % 4;
      final y = i ~/ 4;
      controlPoints.set(x, y, deformed);
    }

    // Regenerate mesh with deformed control points
    _computeAccelerationMatrices();
    _generateMesh();
  }

  /// Resets mesh to original control points (removes deformation).
  void resetDeformation() {
    for (int i = 0; i < 16; i++) {
      final x = i % 4;
      final y = i ~/ 4;
      controlPoints.set(x, y, originalControlPoints[i]);
    }
    deformationOffsets.fillRange(0, 32, 0.0);
    _computeAccelerationMatrices();
    _generateMesh();
  }

  /// Gets the current deformation state as a copy.
  Float32List getDeformationState() {
    return Float32List.fromList(deformationOffsets);
  }

  /// Returns total number of vertices in the mesh
  int get vertexCount => vertices.length;

  /// Returns total number of triangles in the mesh
  int get triangleCount => triangles.length;

  /// Returns estimated memory usage in bytes
  int get estimatedMemoryBytes {
    // vertices (List<MeshVertex>) + triangles (List<MeshTriangle>) + deformationOffsets
    return (vertexCount * 56) + (triangleCount * 12) + 256;
  }
}
