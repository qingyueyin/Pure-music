import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';
import 'package:pure_music/mesh_gradient/core/hermite_math.dart';

void main() {
  group('HermiteMath', () {
    test('Hermite basis matrix has correct values', () {
      final matrix = HermiteMath.hermiteBasis;
      
      // Verify specific matrix elements (column-major order in Matrix4)
      // H = [[2, -3, 0, 1], [-2, 3, 0, 0], [1, -2, 1, 0], [1, -1, 0, 0]]
      expect(matrix.entry(0, 0), equals(2));   // H[0,0]
      expect(matrix.entry(1, 0), equals(-2));  // H[1,0]
      expect(matrix.entry(2, 0), equals(1));   // H[2,0]
      expect(matrix.entry(3, 0), equals(1));   // H[3,0]
      
      expect(matrix.entry(0, 1), equals(-3));  // H[0,1]
      expect(matrix.entry(1, 1), equals(3));   // H[1,1]
      expect(matrix.entry(2, 1), equals(-2));  // H[2,1]
      expect(matrix.entry(3, 1), equals(-1));  // H[3,1]
      
      expect(matrix.entry(0, 2), equals(0));   // H[0,2]
      expect(matrix.entry(1, 2), equals(0));   // H[1,2]
      expect(matrix.entry(2, 2), equals(1));   // H[2,2]
      expect(matrix.entry(3, 2), equals(0));   // H[3,2]
      
      expect(matrix.entry(0, 3), equals(1));   // H[0,3]
      expect(matrix.entry(1, 3), equals(0));   // H[1,3]
      expect(matrix.entry(2, 3), equals(0));   // H[2,3]
      expect(matrix.entry(3, 3), equals(0));   // H[3,3]
    });

    test('Hermite basis transpose has correct values', () {
      final matrix = HermiteMath.hermiteBasisTranspose;
      
      // Verify H^T matrix elements
      // H^T = [[2, -2, 1, 1], [-3, 3, -2, -1], [0, 0, 1, 0], [1, 0, 0, 0]]
      expect(matrix.entry(0, 0), equals(2));   // H^T[0,0]
      expect(matrix.entry(1, 0), equals(-3));  // H^T[1,0]
      expect(matrix.entry(2, 0), equals(0));   // H^T[2,0]
      expect(matrix.entry(3, 0), equals(1));   // H^T[3,0]
      
      expect(matrix.entry(0, 1), equals(-2));  // H^T[0,1]
      expect(matrix.entry(1, 1), equals(3));   // H^T[1,1]
      expect(matrix.entry(2, 1), equals(0));   // H^T[2,1]
      expect(matrix.entry(3, 1), equals(0));   // H^T[3,1]
      
      expect(matrix.entry(0, 2), equals(1));   // H^T[0,2]
      expect(matrix.entry(1, 2), equals(-2));  // H^T[1,2]
      expect(matrix.entry(2, 2), equals(1));   // H^T[2,2]
      expect(matrix.entry(3, 2), equals(0));   // H^T[3,2]
      
      expect(matrix.entry(0, 3), equals(1));   // H^T[0,3]
      expect(matrix.entry(1, 3), equals(-1));  // H^T[1,3]
      expect(matrix.entry(2, 3), equals(0));   // H^T[2,3]
      expect(matrix.entry(3, 3), equals(0));   // H^T[3,3]
    });

    test('computePowerValues generates correct length list', () {
      final subdivisions = 32;
      final powerValues = HermiteMath.computePowerValues(subdivisions);
      
      // Should have subdivisions + 1 values (0 to 1 inclusive)
      expect(powerValues.length, equals(subdivisions + 1));
    });

    test('computePowerValues generates correct u values', () {
      final subdivisions = 4;
      final powerValues = HermiteMath.computePowerValues(subdivisions);
      
      // Check first power vector (u = 0)
      final v0 = powerValues[0];
      expect(v0.x, closeTo(0.0, 1e-10)); // u³
      expect(v0.y, closeTo(0.0, 1e-10)); // u²
      expect(v0.z, closeTo(0.0, 1e-10)); // u
      expect(v0.w, equals(1.0)); // 1
      
      // Check middle power vector (u = 0.5)
      final v2 = powerValues[2];
      expect(v2.x, closeTo(0.125, 1e-10)); // 0.5³
      expect(v2.y, closeTo(0.25, 1e-10)); // 0.5²
      expect(v2.z, closeTo(0.5, 1e-10)); // 0.5
      expect(v2.w, equals(1.0)); // 1
      
      // Check last power vector (u = 1)
      final v4 = powerValues[4];
      expect(v4.x, closeTo(1.0, 1e-10)); // 1³
      expect(v4.y, closeTo(1.0, 1e-10)); // 1²
      expect(v4.z, closeTo(1.0, 1e-10)); // 1
      expect(v4.w, equals(1.0)); // 1
    });

    test('precomputeAccelerationMatrix produces Matrix4', () {
      // Create identity matrix as test input
      final testMatrix = Matrix4.identity();
      final accMatrix = HermiteMath.precomputeAccelerationMatrix(testMatrix);
      
      expect(accMatrix, isA<Matrix4>());
    });

    test('precomputeAccelerationMatrix is consistent across calls', () {
      final testMatrix = Matrix4.identity();
      
      final acc1 = HermiteMath.precomputeAccelerationMatrix(testMatrix);
      final acc2 = HermiteMath.precomputeAccelerationMatrix(testMatrix);
      
      // Results should be identical
      for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
          expect(acc1.entry(i, j), equals(acc2.entry(i, j)));
        }
      }
    });

    test('evaluateVertex returns reasonable values', () {
      // Create test acceleration matrix (identity)
      final accMatrix = Matrix4.identity();
      final uPowers = Vector4(0.125, 0.25, 0.5, 1.0); // u = 0.5
      final vPowers = Vector4(0.125, 0.25, 0.5, 1.0); // v = 0.5
      
      final result = HermiteMath.evaluateVertex(accMatrix, uPowers, vPowers);
      
      // With identity matrix, result should be vPowers dot uPowers
      // This is just a sanity check that it runs without error
      expect(result, isA<double>());
    });

    test('batchEvaluateVertices populates output list', () {
      const subdivisions = 2;
      final posAccMatrix = Matrix4.identity();
      final colorAccMatrix = Matrix4.identity();
      
      final uPowersList = HermiteMath.computePowerValues(subdivisions);
      final vPowersList = HermiteMath.computePowerValues(subdivisions);
      
      // Each vertex needs 7 floats: x, y, r, g, b, u, v
      // Grid is (subdivisions+1) x (subdivisions+1) = 3x3 = 9 vertices
      final vertexCount = (subdivisions + 1) * (subdivisions + 1);
      final outputVertices = List<double>.filled(vertexCount * 7, 0.0);
      
      HermiteMath.batchEvaluateVertices(
        posAccMatrix: posAccMatrix,
        colorAccMatrix: colorAccMatrix,
        uPowersList: uPowersList,
        vPowersList: vPowersList,
        subdivisions: subdivisions,
        outputVertices: outputVertices,
      );
      
      // Verify the output list was populated
      expect(outputVertices.length, equals(9 * 7));
      
      // Check that some values are not all zeros
      bool hasNonZero = outputVertices.any((v) => v != 0.0);
      expect(hasNonZero, isTrue);
      
      // Verify UV coordinates (last 2 floats per vertex)
      // First vertex (0, 0)
      expect(outputVertices[5], equals(0.0)); // u = 0
      expect(outputVertices[6], equals(0.0)); // v = 0
      
      // Last vertex (1, 1)
      final lastVIdx = 8; // 9 vertices, 0-indexed
      expect(outputVertices[lastVIdx * 7 + 5], equals(1.0)); // u = 1
      expect(outputVertices[lastVIdx * 7 + 6], equals(1.0)); // v = 1
    });
  });
}
