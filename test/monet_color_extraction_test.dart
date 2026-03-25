import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/advanced_color_extraction.dart';

Future<Uint8List> _renderTestPng({
  required int width,
  required int height,
  required Color background,
  required Rect patchRect,
  required Color patchColor,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = background,
  );
  canvas.drawRect(
    patchRect,
    Paint()..color = patchColor,
  );

  final picture = recorder.endRecording();
  final img = await picture.toImage(width, height);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull);
  return bytes!.buffer.asUint8List();
}

int _ch(Color c, double v) => (v * 255.0).round().clamp(0, 255);

bool _isNearlyWhite(Color c) =>
    _ch(c, c.r) > 240 && _ch(c, c.g) > 240 && _ch(c, c.b) > 240;

void main() {
  testWidgets('extractMonetScheme does not pick tiny white highlight', (tester) async {
    final png = await tester.runAsync(() async {
      return _renderTestPng(
        width: 96,
        height: 96,
        background: const Color(0xFF0D47A1), // deep blue dominates
        patchRect: const Rect.fromLTWH(2, 2, 8, 8),
        patchColor: const Color(0xFFFFFFFF),
      );
    });

    final scheme = await tester.runAsync(() async {
      return AdvancedColorExtractionService().extractMonetScheme(png!);
    });
    expect(scheme, isNotNull);
    expect(scheme!.primarySwatch.length, 13);
    expect(_isNearlyWhite(scheme.primary), isFalse);
    expect(scheme.primary.b > scheme.primary.r, isTrue);
  });

  testWidgets('extractMonetScheme prefers background over large skin patch', (tester) async {
    final png = await tester.runAsync(() async {
      return _renderTestPng(
        width: 120,
        height: 120,
        background: const Color(0xFF6A1B9A), // purple background dominates
        patchRect: const Rect.fromLTWH(10, 10, 60, 80), // big skin-ish patch
        patchColor: const Color(0xFFF2C9A0),
      );
    });

    final scheme = await tester.runAsync(() async {
      return AdvancedColorExtractionService().extractMonetScheme(png!);
    });
    expect(scheme, isNotNull);

    final hsl = HSLColor.fromColor(scheme!.primary);
    // Expect a purple-ish hue (roughly 250-320 degrees).
    expect(hsl.hue >= 250 && hsl.hue <= 320, isTrue);
  });

  testWidgets('extractMonetScheme marks grayscale-heavy cover as monochrome',
      (tester) async {
    final png = await tester.runAsync(() async {
      return _renderTestPng(
        width: 120,
        height: 120,
        background: const Color(0xFF6C6C6C),
        patchRect: const Rect.fromLTWH(24, 18, 42, 68),
        patchColor: const Color(0xFFF2C9A0),
      );
    });

    final scheme = await tester.runAsync(() async {
      return AdvancedColorExtractionService().extractMonetScheme(png!);
    });

    expect(scheme, isNotNull);
    expect(scheme!.isMonochrome, isTrue);
    expect(HSLColor.fromColor(scheme.primary).saturation, lessThan(0.14));
  });
}
