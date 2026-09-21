import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/uni_detail_header_blur.dart';

Future<ui.Image> _solidImage(Color color, {int size = 32}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = color,
  );
  return recorder.endRecording().toImage(size, size);
}

void main() {
  testWidgets('blurCoverImage writes a fixed-size static texture', (
    tester,
  ) async {
    late ui.Image source;
    late ui.Image blurred;
    await tester.runAsync(() async {
      source = await _solidImage(const Color(0xFFCC5533));
      blurred = await blurCoverImage(source);
    });
    addTearDown(() {
      source.dispose();
      blurred.dispose();
    });
    expect(blurred.width, kDetailHeaderBlurOutputSize);
    expect(blurred.height, kDetailHeaderBlurOutputSize);
  });

  testWidgets('missing cover does not paint a RawImage', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.expand(
          child: DetailCoverAtmosphere(pic: Future<ImageProvider?>.value(null)),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(RawImage), findsNothing);
  });
}
