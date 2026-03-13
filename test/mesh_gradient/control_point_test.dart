import 'package:flutter_test/flutter_test.dart';
import 'dart:math' as math;
import 'package:pure_music/mesh_gradient/core/control_point.dart';

void main() {
  group('ControlPoint', () {
    test('ControlPoint creation stores all values correctly', () {
      final cp = ControlPoint(
        x: 1.5,
        y: 2.5,
        r: 0.8,
        g: 0.6,
        b: 0.4,
        uRot: 0.5,
        vRot: 1.0,
        uScale: 0.7,
        vScale: 0.9,
      );

      expect(cp.x, equals(1.5));
      expect(cp.y, equals(2.5));
      expect(cp.r, equals(0.8));
      expect(cp.g, equals(0.6));
      expect(cp.b, equals(0.4));
      expect(cp.uRot, equals(0.5));
      expect(cp.vRot, equals(1.0));
      expect(cp.uScale, equals(0.7));
      expect(cp.vScale, equals(0.9));
    });

    test('getUTangent computes correct tangent vector', () {
      // Create a control point with known rotation and scale
      // For testing: uRot = 0 (cos(0) = 1, sin(0) = 0), uScale = 2
      // Expected: uTangent = (1 * 2, 0 * 2) = (2, 0)
      final cp = ControlPoint(
        x: 0, y: 0,
        r: 0, g: 0, b: 0,
        uRot: 0,
        vRot: 0,
        uScale: 2,
        vScale: 1,
      );

      final tangent = cp.getUTangent();
      expect(tangent.x, closeTo(2.0, 1e-10));
      expect(tangent.y, closeTo(0.0, 1e-10));
    });

    test('getUTangent with 90 degree rotation', () {
      // For testing: uRot = π/2 (cos(π/2) = 0, sin(π/2) = 1), uScale = 3
      // Expected: uTangent = (0 * 3, 1 * 3) = (0, 3)
      final cp = ControlPoint(
        x: 0, y: 0,
        r: 0, g: 0, b: 0,
        uRot: math.pi / 2,
        vRot: 0,
        uScale: 3,
        vScale: 1,
      );

      final tangent = cp.getUTangent();
      expect(tangent.x, closeTo(0.0, 1e-10));
      expect(tangent.y, closeTo(3.0, 1e-10));
    });

    test('getVTangent computes correct tangent vector', () {
      // For testing: vRot = 0 (-sin(0) = 0, cos(0) = 1), vScale = 2
      // Expected: vTangent = (0 * 2, 1 * 2) = (0, 2)
      final cp = ControlPoint(
        x: 0, y: 0,
        r: 0, g: 0, b: 0,
        uRot: 0,
        vRot: 0,
        uScale: 1,
        vScale: 2,
      );

      final tangent = cp.getVTangent();
      expect(tangent.x, closeTo(0.0, 1e-10));
      expect(tangent.y, closeTo(2.0, 1e-10));
    });

    test('getVTangent with 90 degree rotation', () {
      // For testing: vRot = π/2 (-sin(π/2) = -1, cos(π/2) = 0), vScale = 3
      // Expected: vTangent = (-1 * 3, 0 * 3) = (-3, 0)
      final cp = ControlPoint(
        x: 0, y: 0,
        r: 0, g: 0, b: 0,
        uRot: 0,
        vRot: math.pi / 2,
        uScale: 1,
        vScale: 3,
      );

      final tangent = cp.getVTangent();
      expect(tangent.x, closeTo(-3.0, 1e-10));
      expect(tangent.y, closeTo(0.0, 1e-10));
    });

    test('clone creates independent copy', () {
      final original = ControlPoint(
        x: 1.0, y: 2.0,
        r: 0.5, g: 0.6, b: 0.7,
        uRot: 0.1, vRot: 0.2,
        uScale: 1.5, vScale: 2.5,
      );

      final cloned = original.clone();

      // Verify all values are copied
      expect(cloned.x, equals(original.x));
      expect(cloned.y, equals(original.y));
      expect(cloned.r, equals(original.r));
      expect(cloned.g, equals(original.g));
      expect(cloned.b, equals(original.b));
      expect(cloned.uRot, equals(original.uRot));
      expect(cloned.vRot, equals(original.vRot));
      expect(cloned.uScale, equals(original.uScale));
      expect(cloned.vScale, equals(original.vScale));

      // Verify they are independent objects
      cloned.x = 99.0;
      expect(original.x, isNot(equals(99.0)));
    });

    test('lerp interpolates between two control points', () {
      final cp1 = ControlPoint(
        x: 0.0, y: 0.0,
        r: 0.0, g: 0.0, b: 0.0,
        uRot: 0.0, vRot: 0.0,
        uScale: 1.0, vScale: 1.0,
      );

      final cp2 = ControlPoint(
        x: 10.0, y: 20.0,
        r: 1.0, g: 1.0, b: 1.0,
        uRot: 6.28, vRot: 6.28,
        uScale: 2.0, vScale: 2.0,
      );

      // Test t = 0 (should return cp1)
      final lerp0 = ControlPoint.lerp(cp1, cp2, 0.0);
      expect(lerp0.x, closeTo(0.0, 1e-10));
      expect(lerp0.y, closeTo(0.0, 1e-10));

      // Test t = 1 (should return cp2)
      final lerp1 = ControlPoint.lerp(cp1, cp2, 1.0);
      expect(lerp1.x, closeTo(10.0, 1e-10));
      expect(lerp1.y, closeTo(20.0, 1e-10));

      // Test t = 0.5 (midpoint)
      final lerp05 = ControlPoint.lerp(cp1, cp2, 0.5);
      expect(lerp05.x, closeTo(5.0, 1e-10));
      expect(lerp05.y, closeTo(10.0, 1e-10));
      expect(lerp05.r, closeTo(0.5, 1e-10));
      expect(lerp05.g, closeTo(0.5, 1e-10));
      expect(lerp05.b, closeTo(0.5, 1e-10));
    });

    test('toString provides readable representation', () {
      final cp = ControlPoint(
        x: 1.0, y: 2.0,
        r: 0.5, g: 0.6, b: 0.7,
        uRot: 0.1, vRot: 0.2,
        uScale: 1.5, vScale: 2.5,
      );

      final str = cp.toString();
      expect(str, contains('ControlPoint'));
      expect(str, contains('1.0'));
      expect(str, contains('0.5'));
    });
  });

  group('Map2D', () {
    test('Map2D creation and access', () {
      final map = Map2D<int>(width: 3, height: 2, initialValue: 0);

      expect(map.width, equals(3));
      expect(map.height, equals(2));
      expect(map.at(0, 0), equals(0));
      expect(map.at(2, 1), equals(0));
    });

    test('Map2D set and get', () {
      final map = Map2D<String>(width: 3, height: 3, initialValue: 'empty');

      map.set(1, 1, 'center');
      expect(map.at(1, 1), equals('center'));
      expect(map.at(0, 0), equals('empty'));
    });

    test('Map2D out of bounds throws error', () {
      final map = Map2D<int>(width: 3, height: 3, initialValue: 0);

      expect(() => map.at(-1, 0), throwsA(isA<RangeError>()));
      expect(() => map.at(3, 0), throwsA(isA<RangeError>()));
      expect(() => map.at(0, -1), throwsA(isA<RangeError>()));
      expect(() => map.at(0, 3), throwsA(isA<RangeError>()));
    });

    test('Map2D forEach iteration', () {
      final map = Map2D<int>(width: 2, height: 2, initialValue: 0);
      map.set(0, 0, 1);
      map.set(1, 0, 2);
      map.set(0, 1, 3);
      map.set(1, 1, 4);

      final values = <int>[];
      map.forEach((x, y, value) {
        values.add(value);
      });

      expect(values, equals([1, 2, 3, 4]));
    });

    test('Map2D toList', () {
      final map = Map2D<int>(width: 2, height: 2, initialValue: 5);

      final list = map.toList();
      expect(list.length, equals(4));
      expect(list, equals([5, 5, 5, 5]));
    });

    test('Map2D atWrapped with modulo operation', () {
      final map = Map2D<int>(width: 3, height: 3, initialValue: 0);
      map.set(0, 0, 1);
      map.set(1, 1, 5);
      map.set(2, 2, 9);

      // Test wrapping positive indices
      expect(map.atWrapped(3, 3), equals(1)); // (3, 3) wraps to (0, 0)
      expect(map.atWrapped(4, 4), equals(5)); // (4, 4) wraps to (1, 1)

      // Test wrapping negative indices
      expect(map.atWrapped(-1, -1), equals(9)); // (-1, -1) wraps to (2, 2)
    });

    test('Map2D with ControlPoint type', () {
      final cp = ControlPoint(
        x: 1, y: 2,
        r: 0.5, g: 0.5, b: 0.5,
        uRot: 0, vRot: 0,
        uScale: 1, vScale: 1,
      );

      final map = Map2D<ControlPoint>(width: 2, height: 2, initialValue: cp);

      final retrieved = map.at(0, 0);
      expect(retrieved.x, equals(1));
      expect(retrieved.y, equals(2));
    });
  });
}
