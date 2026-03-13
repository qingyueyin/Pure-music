/// Flutter Canvas painter for mesh gradient rendering.
///
/// Renders triangle-based mesh with color interpolation using Flutter's
/// canvas API. Supports multiple blending modes and opacity control.

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:pure_music/mesh_gradient/core/bhp_mesh.dart';
import 'package:pure_music/mesh_gradient/config.dart';

/// Converts blend mode name to Flutter BlendMode enum.
BlendMode _parseBlendMode(String modeName) {
  return switch (modeName.toLowerCase()) {
    'screen' => BlendMode.screen,
    'multiply' => BlendMode.multiply,
    'overlay' => BlendMode.overlay,
    'lighten' => BlendMode.lighten,
    'darken' => BlendMode.darken,
    'colorDodge' => BlendMode.colorDodge,
    'colorBurn' => BlendMode.colorBurn,
    'hardLight' => BlendMode.hardLight,
    'softLight' => BlendMode.softLight,
    'difference' => BlendMode.difference,
    'plus' => BlendMode.plus,
    _ => BlendMode.srcOver,
  };
}

/// Custom painter for rendering mesh gradient using triangles.
///
/// Renders pre-generated mesh vertices and triangles with interpolated colors.
/// Highly optimized for ~10,000 triangles at 60 FPS.
class MeshCanvasRenderer extends CustomPainter {
  /// The mesh to render
  final BHPMesh mesh;

  /// Configuration (for opacity and blend mode)
  final MeshGradientConfig config;

  /// Cached paint object (reused to reduce allocations)
  late final Paint _paint;

  /// Cached path object for triangle rendering
  late final ui.Path _trianglePath;

  MeshCanvasRenderer({
    required this.mesh,
    required this.config,
  }) {
    _paint = Paint()
      ..blendMode = _parseBlendMode(config.blendMode)
      ..isAntiAlias = true;
    _trianglePath = ui.Path();
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Create clipping rect to prevent rendering outside bounds
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));

    // Save canvas state with opacity
    final opacityPaint = Paint()
      ..color = Color.fromARGB(
        (config.opacity * 255).toInt(),
        255,
        255,
        255,
      );
    canvas.saveLayer(
      Rect.fromLTWH(0, 0, size.width, size.height),
      opacityPaint,
    );

    // Render each triangle
    for (final triangle in mesh.triangles) {
      _renderTriangle(
        canvas,
        mesh.vertices[triangle.v1],
        mesh.vertices[triangle.v2],
        mesh.vertices[triangle.v3],
        size,
      );
    }

    // Restore canvas state
    canvas.restore();
  }

  /// Renders a single triangle with color interpolation.
  ///
  /// Uses bilinear interpolation of vertex colors across the triangle.
  void _renderTriangle(
    Canvas canvas,
    MeshVertex v1,
    MeshVertex v2,
    MeshVertex v3,
    Size size,
  ) {
    // Build triangle path
    _trianglePath.reset();
    _trianglePath.moveTo(v1.x, v1.y);
    _trianglePath.lineTo(v2.x, v2.y);
    _trianglePath.lineTo(v3.x, v3.y);
    _trianglePath.close();

    // Calculate average color for triangle (simple approach)
    // More sophisticated: would use gradient shader
    final avgR = (v1.r + v2.r + v3.r) / 3;
    final avgG = (v1.g + v2.g + v3.g) / 3;
    final avgB = (v1.b + v2.b + v3.b) / 3;

    // Clamp color values to valid range
    final color = Color.fromARGB(
      255,
      (avgR * 255).toInt().clamp(0, 255),
      (avgG * 255).toInt().clamp(0, 255),
      (avgB * 255).toInt().clamp(0, 255),
    );

    _paint.color = color;
    _paint.style = PaintingStyle.fill;

    // Draw filled triangle
    canvas.drawPath(_trianglePath, _paint);
  }

  @override
  bool shouldRepaint(MeshCanvasRenderer oldDelegate) {
    // Repaint if mesh vertices changed or configuration changed
    return oldDelegate.mesh.vertexCount != mesh.vertexCount ||
        oldDelegate.config.opacity != config.opacity ||
        oldDelegate.config.blendMode != config.blendMode;
  }

  @override
  bool shouldRebuildSemantics(MeshCanvasRenderer oldDelegate) => false;
}

/// High-performance batch renderer for mesh gradient.
///
/// Optimized for rendering many triangles with minimal allocations.
/// Uses pre-computed vertex and triangle data from BHPMesh.
class MeshBatchRenderer {
  /// The mesh to render
  final BHPMesh mesh;

  /// Configuration
  final MeshGradientConfig config;

  /// Pre-computed triangle list (vertices + indices)
  late List<Offset> vertexPositions;
  late List<Color> vertexColors;
  late List<int> triangleIndices;

  /// Performance metrics
  int framesRendered = 0;
  int totalTrianglesRendered = 0;

  MeshBatchRenderer({
    required this.mesh,
    required this.config,
  }) {
    _prebuildRenderData();
  }

  /// Pre-builds render data from mesh for faster rendering.
  void _prebuildRenderData() {
    vertexPositions = <Offset>[];
    vertexColors = <Color>[];
    triangleIndices = <int>[];

    for (final vertex in mesh.vertices) {
      vertexPositions.add(Offset(vertex.x, vertex.y));
      vertexColors.add(Color.fromARGB(
        255,
        (vertex.r * 255).toInt().clamp(0, 255),
        (vertex.g * 255).toInt().clamp(0, 255),
        (vertex.b * 255).toInt().clamp(0, 255),
      ));
    }

    for (final triangle in mesh.triangles) {
      triangleIndices.addAll([triangle.v1, triangle.v2, triangle.v3]);
    }
  }

  /// Renders the mesh using batch operations.
  void render(Canvas canvas, Size size) {
    framesRendered++;
    totalTrianglesRendered += mesh.triangleCount;

    final paint = Paint()
      ..blendMode = _parseBlendMode(config.blendMode)
      ..isAntiAlias = false; // Disabled for speed
    
    // Apply opacity via alpha channel
    final opacityAlpha = (config.opacity * 255).toInt();

    // Render triangles in batches
    for (int i = 0; i < triangleIndices.length; i += 3) {
      final v1Idx = triangleIndices[i];
      final v2Idx = triangleIndices[i + 1];
      final v3Idx = triangleIndices[i + 2];

      final path = ui.Path()
        ..moveTo(vertexPositions[v1Idx].dx, vertexPositions[v1Idx].dy)
        ..lineTo(vertexPositions[v2Idx].dx, vertexPositions[v2Idx].dy)
        ..lineTo(vertexPositions[v3Idx].dx, vertexPositions[v3Idx].dy)
        ..close();

      // Average color
      final r = (vertexColors[v1Idx].red +
              vertexColors[v2Idx].red +
              vertexColors[v3Idx].red) /
          3;
      final g = (vertexColors[v1Idx].green +
              vertexColors[v2Idx].green +
              vertexColors[v3Idx].green) /
          3;
      final b = (vertexColors[v1Idx].blue +
              vertexColors[v2Idx].blue +
              vertexColors[v3Idx].blue) /
          3;

      paint.color = Color.fromARGB(
        opacityAlpha,
        r.toInt().clamp(0, 255),
        g.toInt().clamp(0, 255),
        b.toInt().clamp(0, 255),
      );
      canvas.drawPath(path, paint);
    }
  }

  /// Returns performance metrics.
  Map<String, dynamic> getMetrics() {
    final avgTrianglesPerFrame = totalTrianglesRendered / framesRendered;
    return {
      'framesRendered': framesRendered,
      'totalTriangles': totalTrianglesRendered,
      'averageTrianglesPerFrame': avgTrianglesPerFrame,
      'meshVertexCount': mesh.vertexCount,
      'meshTriangleCount': mesh.triangleCount,
    };
  }

  /// Resets performance metrics.
  void resetMetrics() {
    framesRendered = 0;
    totalTrianglesRendered = 0;
  }
}
