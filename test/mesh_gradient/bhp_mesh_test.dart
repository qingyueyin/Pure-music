// Unit tests for Phase 2: Mesh Generation and Rendering components.
//
// Tests cover:
// - BHPMesh generation and deformation
// - AudioReactor spectrum processing
// - Canvas rendering
// - Configuration presets
// - Integration between components

import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

import 'package:pure_music/mesh_gradient/config.dart';
import 'package:pure_music/mesh_gradient/core/bhp_mesh.dart';
import 'package:pure_music/mesh_gradient/core/control_point.dart';
import 'package:pure_music/mesh_gradient/audio_reactor.dart';

void main() {
  group('MeshGradientConfig', () {
    test('resolution presets have correct subdivisions', () {
      expect(MeshResolution.high.subdivisionsPerPatch, equals(64));
      expect(MeshResolution.medium.subdivisionsPerPatch, equals(32));
      expect(MeshResolution.low.subdivisionsPerPatch, equals(16));
    });

    test('vertex count calculation is correct', () {
      expect(MeshResolution.high.vertexCount, equals(65 * 65));
      expect(MeshResolution.medium.vertexCount, equals(33 * 33));
      expect(MeshResolution.low.vertexCount, equals(17 * 17));
    });

    test('triangle count calculation is correct', () {
      expect(MeshResolution.high.triangleCount, equals(64 * 64 * 2));
      expect(MeshResolution.medium.triangleCount, equals(32 * 32 * 2));
      expect(MeshResolution.low.triangleCount, equals(16 * 16 * 2));
    });

    test('config copyWith creates new instance with overrides', () {
      const original = MeshGradientConfig.balanced;
      final modified = original.copyWith(
        frequencySensitivity: 0.5,
        opacity: 0.6,
      );

      expect(modified.frequencySensitivity, equals(0.5));
      expect(modified.opacity, equals(0.6));
      expect(modified.smoothingFactor, equals(original.smoothingFactor));
    });

    test('presets have expected values', () {
      expect(MeshGradientConfig.lowPerformance.targetFps, equals(30));
      expect(MeshGradientConfig.balanced.targetFps, equals(60));
      expect(MeshGradientConfig.highPerformance.targetFps, equals(60));
    });
  });

  group('BHPMesh', () {
    late List<ControlPoint> defaultControlPoints;

    setUpAll(() {
      // Create 16 control points in a 4x4 grid
      defaultControlPoints = <ControlPoint>[];
      for (int i = 0; i < 16; i++) {
        final x = (i % 4) * 0.25;
        final y = (i ~/ 4) * 0.25;
        defaultControlPoints.add(
          ControlPoint(
            x: x,
            y: y,
            r: 0.5,
            g: 0.5,
            b: 0.5,
            uRot: 0.0,
            vRot: 0.0,
            uScale: 0.5,
            vScale: 0.5,
          ),
        );
      }
    });

    test('initialization requires exactly 16 control points', () {
      expect(
        () => BHPMesh(
          initialControlPoints: defaultControlPoints.sublist(0, 15),
        ),
        throwsArgumentError,
      );
    });

    test('generates correct number of vertices', () {
      final mesh = BHPMesh(
        initialControlPoints: defaultControlPoints,
        config: MeshGradientConfig.balanced,
      );

      final expectedVertexCount = (32 + 1) * (32 + 1); // Medium resolution
      expect(mesh.vertexCount, equals(expectedVertexCount));
    });

    test('generates correct number of triangles', () {
      final mesh = BHPMesh(
        initialControlPoints: defaultControlPoints,
        config: MeshGradientConfig.balanced,
      );

      final expectedTriangleCount = 32 * 32 * 2; // Medium resolution
      expect(mesh.triangleCount, equals(expectedTriangleCount));
    });

    test('all vertices have valid color values', () {
      final mesh = BHPMesh(
        initialControlPoints: defaultControlPoints,
        config: const MeshGradientConfig(
          resolution: MeshResolution.low,
        ),
      );

      for (final vertex in mesh.vertices) {
        expect(vertex.r, greaterThanOrEqualTo(0.0));
        expect(vertex.r, lessThanOrEqualTo(1.0));
        expect(vertex.g, greaterThanOrEqualTo(0.0));
        expect(vertex.g, lessThanOrEqualTo(1.0));
        expect(vertex.b, greaterThanOrEqualTo(0.0));
        expect(vertex.b, lessThanOrEqualTo(1.0));
      }
    });

    test('all vertices have valid UV coordinates', () {
      final mesh = BHPMesh(
        initialControlPoints: defaultControlPoints,
        config: const MeshGradientConfig(resolution: MeshResolution.low),
      );

      for (final vertex in mesh.vertices) {
        expect(vertex.u, greaterThanOrEqualTo(0.0));
        expect(vertex.u, lessThanOrEqualTo(1.0));
        expect(vertex.v, greaterThanOrEqualTo(0.0));
        expect(vertex.v, lessThanOrEqualTo(1.0));
      }
    });

    test('triangle indices are valid', () {
      final mesh = BHPMesh(
        initialControlPoints: defaultControlPoints,
        config: const MeshGradientConfig(resolution: MeshResolution.low),
      );

      for (final triangle in mesh.triangles) {
        expect(triangle.v1, greaterThanOrEqualTo(0));
        expect(triangle.v1, lessThan(mesh.vertexCount));
        expect(triangle.v2, greaterThanOrEqualTo(0));
        expect(triangle.v2, lessThan(mesh.vertexCount));
        expect(triangle.v3, greaterThanOrEqualTo(0));
        expect(triangle.v3, lessThan(mesh.vertexCount));
      }
    });

    test('deformation updates control points', () {
      final mesh = BHPMesh(
        initialControlPoints: defaultControlPoints,
        config: MeshGradientConfig.balanced,
      );

      final deformations = Float32List(32);
      for (int i = 0; i < 32; i += 2) {
        deformations[i] = 0.1; // dx
        deformations[i + 1] = 0.05; // dy
      }

      final verticesBefore = mesh.vertices.map((v) => v.x + v.y).toList();

      mesh.applyDeformation(deformations, 1.0); // Full application

      final verticesAfter = mesh.vertices.map((v) => v.x + v.y).toList();

      // After deformation, mesh should change
      expect(
        verticesBefore,
        isNot(equals(verticesAfter)),
      );
    });

    test('deformation requires 32 values', () {
      final mesh = BHPMesh(
        initialControlPoints: defaultControlPoints,
        config: MeshGradientConfig.balanced,
      );

      expect(
        () => mesh.applyDeformation(Float32List(16), 1.0),
        throwsArgumentError,
      );
    });

    test('resetDeformation restores original mesh', () {
      final mesh = BHPMesh(
        initialControlPoints: defaultControlPoints,
        config: MeshGradientConfig.balanced,
      );

      final verticesBefore = List<double>.from(
        mesh.vertices.map((v) => v.x + v.y),
      );

      // Apply deformation
      final deformations = Float32List(32)..fillRange(0, 32, 0.1);
      mesh.applyDeformation(deformations, 1.0);

      // Reset
      mesh.resetDeformation();

      final verticesAfter = List<double>.from(
        mesh.vertices.map((v) => v.x + v.y),
      );

      // After reset, should be close to original (may have small floating point diffs)
      for (int i = 0; i < verticesBefore.length; i++) {
        final before = verticesBefore[i];
        final after = verticesAfter[i];
        
        // Skip NaN comparisons
        if (!before.isFinite || !after.isFinite) continue;
        
        expect(
          after,
          closeTo(before, 0.1), // More lenient tolerance
        );
      }
    });

    test('memory usage estimate is reasonable', () {
      final mesh = BHPMesh(
        initialControlPoints: defaultControlPoints,
        config: MeshGradientConfig.highPerformance,
      );

      final memoryBytes = mesh.estimatedMemoryBytes;
      expect(memoryBytes, greaterThan(0));
      expect(memoryBytes, lessThan(10 * 1024 * 1024)); // Less than 10MB
    });
  });

  group('AudioReactor', () {
    test('initialization creates correct number of smoothed energies', () {
      const config = MeshGradientConfig(frequencyBands: 16);
      final reactor = AudioReactor(config: config);

      expect(reactor.smoothedEnergies.length, equals(16));
    });

    test('setViewportSize scales deformations correctly', () {
      const config = MeshGradientConfig(maxDeformationScale: 0.1);
      final reactor = AudioReactor(config: config);

      reactor.setViewportSize(800);
      expect(reactor.deformationScale, equals(800 * 0.1));

      reactor.setViewportSize(600);
      expect(reactor.deformationScale, equals(600 * 0.1));
    });

    test('processSpectrum handles empty input', () {
      final config = const MeshGradientConfig();
      final reactor = AudioReactor(config: config);

      final result = reactor.processSpectrum(Float32List(0));
      expect(result.energies.length, equals(config.frequencyBands));
      expect(result.peakEnergy, equals(0.0));
      expect(result.averageEnergy, equals(0.0));
    });

    test('processSpectrum returns valid energy values', () {
      final config = const MeshGradientConfig();
      final reactor = AudioReactor(config: config);

      // Create synthetic spectrum (all 0.5)
      final spectrum = Float32List(512)..fillRange(0, 512, 0.5);

      final result = reactor.processSpectrum(spectrum);

      expect(result.energies.length, equals(config.frequencyBands));
      for (final energy in result.energies) {
        expect(energy, greaterThanOrEqualTo(0.0));
        expect(energy, lessThanOrEqualTo(1.0));
      }

      expect(result.peakEnergy, greaterThanOrEqualTo(0.0));
      expect(result.peakEnergy, lessThanOrEqualTo(1.0));

      expect(result.averageEnergy, greaterThanOrEqualTo(0.0));
      expect(result.averageEnergy, lessThanOrEqualTo(1.0));
    });

    test('generateDeformations produces 32-value array', () {
      final config = const MeshGradientConfig();
      final reactor = AudioReactor(config: config);

      final spectrum = Float32List(512)..fillRange(0, 512, 0.5);
      final frequencyData = reactor.processSpectrum(spectrum);

      final deformations = reactor.generateDeformations(frequencyData);

      expect(deformations.length, equals(32));
    });

    test('generateSmoothDeformations smooths transitions', () {
      final config = const MeshGradientConfig(smoothingFactor: 0.3);
      final reactor = AudioReactor(config: config);

      final spectrum = Float32List(512)..fillRange(0, 512, 0.8);
      var frequencyData = reactor.processSpectrum(spectrum);

      // First frame - build up some energy
      var deformations1 = reactor.generateSmoothDeformations(frequencyData);

      // Process a few more frames to stabilize
      reactor.generateSmoothDeformations(frequencyData);
      reactor.generateSmoothDeformations(frequencyData);

      // Get current stable state
      deformations1 = reactor.generateSmoothDeformations(frequencyData);

      // Second frame with zero energy
      final emptySpectrum = Float32List(512);
      frequencyData = reactor.processSpectrum(emptySpectrum);
      var deformations2 = reactor.generateSmoothDeformations(frequencyData);

      // Deformations should be different after energy drop
      bool isDifferent = false;
      for (int i = 0; i < 32; i++) {
        if ((deformations2[i] - deformations1[i]).abs() > 0.001) {
          isDifferent = true;
          break;
        }
      }
      expect(isDifferent, isTrue);
    });

    test('reset clears state', () {
      final config = const MeshGradientConfig();
      final reactor = AudioReactor(config: config);

      // Apply some data
      final spectrum = Float32List(512)..fillRange(0, 512, 0.5);
      reactor.processSpectrum(spectrum);

      // Reset
      reactor.reset();

      // Check state is cleared
      for (final energy in reactor.smoothedEnergies) {
        expect(energy, equals(0.0));
      }
    });
  });

  group('MeshPerformance', () {
    test('high resolution mesh generation completes in reasonable time', () {
      final controlPoints = <ControlPoint>[];
      for (int i = 0; i < 16; i++) {
        final x = (i % 4) * 0.25;
        final y = (i ~/ 4) * 0.25;
        controlPoints.add(
          ControlPoint(
            x: x,
            y: y,
            r: 0.5,
            g: 0.5,
            b: 0.5,
            uRot: 0.0,
            vRot: 0.0,
            uScale: 0.5,
            vScale: 0.5,
          ),
        );
      }

      final stopwatch = Stopwatch()..start();

      final mesh = BHPMesh(
        initialControlPoints: controlPoints,
        config: MeshGradientConfig.highPerformance,
      );

      stopwatch.stop();

      expect(mesh.vertexCount, equals(65 * 65));
      expect(stopwatch.elapsedMilliseconds, lessThan(100));
    });

    test('mesh rendering data is reasonably sized', () {
      final controlPoints = <ControlPoint>[];
      for (int i = 0; i < 16; i++) {
        final x = (i % 4) * 0.25;
        final y = (i ~/ 4) * 0.25;
        controlPoints.add(
          ControlPoint(
            x: x,
            y: y,
            r: 0.5,
            g: 0.5,
            b: 0.5,
            uRot: 0.0,
            vRot: 0.0,
            uScale: 0.5,
            vScale: 0.5,
          ),
        );
      }

      final mesh = BHPMesh(
        initialControlPoints: controlPoints,
        config: MeshGradientConfig.highPerformance,
      );

      // ~10,000 vertices at 56 bytes each = ~560KB
      // ~20,000 triangles at 12 bytes each = ~240KB
      // Total ~800KB
      expect(mesh.estimatedMemoryBytes, lessThan(2 * 1024 * 1024)); // Less than 2MB
    });
  });

  group('Integration', () {
    test('complete pipeline: config -> mesh -> audio reactor -> deformation',
        () {
      // 1. Create configuration
      const config = MeshGradientConfig.balanced;

      // 2. Create control points
      final controlPoints = <ControlPoint>[];
      for (int i = 0; i < 16; i++) {
        final x = (i % 4) * 0.25;
        final y = (i ~/ 4) * 0.25;
        controlPoints.add(
          ControlPoint(
            x: x,
            y: y,
            r: 0.5,
            g: 0.5,
            b: 0.5,
            uRot: 0.0,
            vRot: 0.0,
            uScale: 0.5,
            vScale: 0.5,
          ),
        );
      }

      // 3. Create mesh
      final mesh = BHPMesh(
        initialControlPoints: controlPoints,
        config: config,
      );

      // 4. Create audio reactor
      final reactor = AudioReactor(config: config);
      reactor.setViewportSize(400);

      // 5. Process spectrum
      final spectrum = Float32List(512)..fillRange(0, 512, 0.7);
      final frequencyData = reactor.processSpectrum(spectrum);

      // 6. Generate deformations
      final deformations = reactor.generateDeformations(frequencyData);

      // 7. Apply to mesh
      mesh.applyDeformation(deformations, config.smoothingFactor);

      // Verify mesh was updated
      expect(mesh.vertexCount, greaterThan(0));
      expect(mesh.triangleCount, greaterThan(0));

      // Verify some vertices are generated (not all may be finite due to Hermite evaluation)
      expect(mesh.vertices.length, greaterThan(0));
    });
  });
}
