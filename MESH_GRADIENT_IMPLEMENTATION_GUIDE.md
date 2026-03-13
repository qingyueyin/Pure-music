# Mesh Gradient Implementation Guide for Flutter

## Overview

This guide provides step-by-step implementation instructions for porting the AMLL Mesh Gradient renderer to Flutter, based on the reference implementation analysis.

## Phase 1: Foundation Setup

### 1.1 Dependencies

Add to `pubspec.yaml`:
```yaml
dependencies:
  vector_math: ^2.1.0
  flutter_gpu: ^0.1.0  # For GPU rendering
  image: ^4.0.0        # Image processing
```

### 1.2 Base Classes

```dart
// lib/rendering/mesh_gradient/mesh_gradient_renderer.dart

import 'dart:ui' as ui;
import 'package:vector_math/vector_math.dart';

abstract class BaseRenderer {
  late HTMLCanvasElement canvas;
  double flowSpeed = 1.0;
  double currentRenderScale = 0.75;
  
  void setFlowSpeed(double speed);
  void setRenderScale(double scale);
  void setStaticMode(bool enable);
  void setFPS(int fps);
  void pause();
  void resume();
  Future<void> setAlbum(String albumSource);
  void setLowFreqVolume(double volume);
  void dispose();
}

class MeshGradientRenderer extends BaseRenderer {
  late ui.Image? _albumImage;
  late List<ControlPoint> _controlPoints;
  late BHPMesh _mesh;
  
  double frameTime = 0.0;
  double volume = 0.0;
  double smoothedVolume = 0.0;
  
  @override
  void setRenderScale(double scale) {
    currentRenderScale = scale;
    // Trigger resize
  }
}
```

## Phase 2: Mathematical Foundation

### 2.1 Vector and Matrix Utilities

```dart
// lib/rendering/mesh_gradient/math_utils.dart

import 'package:vector_math/vector_math.dart';

class HermiteMath {
  // Hermite basis matrix
  static final Matrix4 H = Matrix4.fromList([
    2, -3, 0, 1,
   -2, 3, 0, 0,
    1, -2, 1, 0,
    1, -1, 0, 0,
  ]);
  
  static final Matrix4 H_T = Matrix4.copy(H)..transpose();
  
  /// Hermite basis function h0(t) = 2t³ - 3t² + 1
  static double h0(double t) => 2*t*t*t - 3*t*t + 1;
  
  /// Hermite basis function h1(t) = -2t³ + 3t²
  static double h1(double t) => -2*t*t*t + 3*t*t;
  
  /// Hermite basis function h2(t) = t³ - 2t² + t
  static double h2(double t) => t*t*t - 2*t*t + t;
  
  /// Hermite basis function h3(t) = t³ - t²
  static double h3(double t) => t*t*t - t*t;
  
  /// Evaluate Hermite curve at parameter t
  static double evalHermite(
    double p0, double p1,
    double t0, double t1,
    double t,
  ) {
    return h0(t) * p0 + 
           h1(t) * p1 + 
           h2(t) * t0 + 
           h3(t) * t1;
  }
  
  /// Precompute M' = H^T * M * H for efficient evaluation
  static Matrix4 precomputeCoefficients(Matrix4 M) {
    final result = Matrix4.identity();
    result.setValues(M);
    result.transpose();
    result.multiply(H);
    final temp = Matrix4.copy(H_T);
    temp.multiply(result);
    return temp;
  }
}
```

### 2.2 Control Point System

```dart
// lib/rendering/mesh_gradient/control_point.dart

import 'package:vector_math/vector_math.dart' as vm;

class ControlPoint {
  vm.Vector3 color = vm.Vector3(1, 1, 1);
  vm.Vector2 location = vm.Vector2(0, 0);
  vm.Vector2 uTangent = vm.Vector2(0, 0);
  vm.Vector2 vTangent = vm.Vector2(0, 0);
  
  double _uRot = 0;
  double _vRot = 0;
  double _uScale = 1;
  double _vScale = 1;
  
  double get uRot => _uRot;
  set uRot(double value) {
    _uRot = value;
    _updateUTangent();
  }
  
  double get vRot => _vRot;
  set vRot(double value) {
    _vRot = value;
    _updateVTangent();
  }
  
  double get uScale => _uScale;
  set uScale(double value) {
    _uScale = value;
    _updateUTangent();
  }
  
  double get vScale => _vScale;
  set vScale(double value) {
    _vScale = value;
    _updateVTangent();
  }
  
  void _updateUTangent() {
    uTangent.x = cos(_uRot) * _uScale;
    uTangent.y = sin(_uRot) * _uScale;
  }
  
  void _updateVTangent() {
    vTangent.x = -sin(_vRot) * _vScale;
    vTangent.y = cos(_vRot) * _vScale;
  }
}

class ControlPointConf {
  final int cx, cy;
  final double x, y;
  final double ur, vr;
  final double up, vp;
  
  ControlPointConf({
    required this.cx, required this.cy,
    required this.x, required this.y,
    required this.ur, required this.vr,
    required this.up, required this.vp,
  });
  
  ControlPoint toControlPoint() {
    final cp = ControlPoint();
    cp.location.x = x;
    cp.location.y = y;
    cp.uRot = (ur * pi) / 180;
    cp.vRot = (vr * pi) / 180;
    cp.uScale = up;
    cp.vScale = vp;
    return cp;
  }
}
```

## Phase 3: Mesh Implementation

### 3.1 Bicubic Hermite Patch Mesh

```dart
// lib/rendering/mesh_gradient/bhp_mesh.dart

import 'package:vector_math/vector_math.dart' as vm;
import 'dart:typed_data';

class BHPMesh {
  int _subdivisions = 10;
  late List<List<ControlPoint>> _controlPointGrid;
  
  late Float32List _vertexData;
  late Uint16List _indexData;
  
  int _cpWidth = 3;
  int _cpHeight = 3;
  
  BHPMesh({int cpWidth = 3, int cpHeight = 3}) {
    _cpWidth = cpWidth;
    _cpHeight = cpHeight;
    _resizeControlPoints(cpWidth, cpHeight);
    _resizeVertices();
  }
  
  /// Resize the control point grid
  void _resizeControlPoints(int width, int height) {
    if (width < 2 || height < 2) {
      throw ArgumentError('Control point grid must be at least 2x2');
    }
    
    _cpWidth = width;
    _cpHeight = height;
    _controlPointGrid = List.generate(
      height,
      (y) => List.generate(
        width,
        (x) {
          final cp = ControlPoint();
          cp.location.x = (x / (width - 1)) * 2 - 1;
          cp.location.y = (y / (height - 1)) * 2 - 1;
          cp.uTangent.x = 2 / (width - 1);
          cp.vTangent.y = 2 / (height - 1);
          return cp;
        },
      ),
    );
  }
  
  /// Resize vertex buffer
  void _resizeVertices() {
    final vertexCount = _cpWidth * _cpHeight * (_subdivisions * _subdivisions);
    final floatCount = vertexCount * 7; // pos(2) + color(3) + uv(2)
    
    _vertexData = Float32List(floatCount);
    
    final indexCount = (_cpWidth - 1) * (_cpHeight - 1) * (_subdivisions - 1) * (_subdivisions - 1) * 6;
    _indexData = Uint16List(indexCount);
  }
  
  /// Update mesh geometry from control points
  void updateMesh() {
    const invSubDiv = 1.0 / (_subdivisions - 1);
    
    int vertexIndex = 0;
    int indexIndex = 0;
    
    // Pre-compute power values
    final normPowers = Float32List(_subdivisions * 4);
    for (int i = 0; i < _subdivisions; i++) {
      final norm = i * invSubDiv;
      normPowers[i * 4 + 0] = norm * norm * norm;
      normPowers[i * 4 + 1] = norm * norm;
      normPowers[i * 4 + 2] = norm;
      normPowers[i * 4 + 3] = 1.0;
    }
    
    // For each control point patch
    for (int py = 0; py < _cpHeight - 1; py++) {
      for (int px = 0; px < _cpWidth - 1; px++) {
        final p00 = _controlPointGrid[py][px];
        final p01 = _controlPointGrid[py + 1][px];
        final p10 = _controlPointGrid[py][px + 1];
        final p11 = _controlPointGrid[py + 1][px + 1];
        
        // Compute coefficients for this patch
        final coefX = _meshCoefficients(p00, p01, p10, p11, 0);
        final coefY = _meshCoefficients(p00, p01, p10, p11, 1);
        final coefR = _colorCoefficients(p00, p01, p10, p11, 0);
        final coefG = _colorCoefficients(p00, p01, p10, p11, 1);
        final coefB = _colorCoefficients(p00, p01, p10, p11, 2);
        
        // Precompute accumulated matrices
        final accX = HermiteMath.precomputeCoefficients(coefX);
        final accY = HermiteMath.precomputeCoefficients(coefY);
        final accR = HermiteMath.precomputeCoefficients(coefR);
        final accG = HermiteMath.precomputeCoefficients(coefG);
        final accB = HermiteMath.precomputeCoefficients(coefB);
        
        // Generate vertices for this patch
        for (int u = 0; u < _subdivisions; u++) {
          for (int v = 0; v < _subdivisions; v++) {
            final uNorm = u * invSubDiv;
            final vNorm = v * invSubDiv;
            
            final px = _evaluateSurface(accX, uNorm, vNorm);
            final py = _evaluateSurface(accY, uNorm, vNorm);
            final pr = _evaluateSurface(accR, uNorm, vNorm).clamp(0, 1);
            final pg = _evaluateSurface(accG, uNor
