import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/horizontal_lyric_view.dart';
import 'package:pure_music/core/design_tokens.dart';

ColorScheme _scheme(Brightness brightness) {
  return ColorScheme.fromSeed(
    seedColor: const Color(0xff3d5a5b),
    brightness: brightness,
  );
}

Finder _surfaceBoxes() => find.descendant(
  of: find.byType(TitleBarLyricStripSurface),
  matching: find.byType(DecoratedBox),
);

void main() {
  test('dark lyric strip well sits below the fill, not a lifted rim', () {
    final scheme = _scheme(Brightness.dark);
    final fill = scheme.secondaryContainer;
    final well = titleBarLyricStripWellColor(scheme);

    expect(well.a, 1.0);
    expect(well, isNot(fill));
    expect(well, Color.alphaBlend(scheme.shadow.withValues(alpha: 0.22), fill));
    expect(well.computeLuminance(), lessThan(fill.computeLuminance()));
  });

  test('light lyric strip well sits slightly below the fill', () {
    final scheme = _scheme(Brightness.light);
    final fill = scheme.secondaryContainer;
    final well = titleBarLyricStripWellColor(scheme);

    expect(well.a, 1.0);
    expect(well, isNot(fill));
    expect(
      well,
      Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.10), fill),
    );
    expect(well.computeLuminance(), lessThan(fill.computeLuminance()));
  });

  testWidgets('lyric strip is a single well with no stroked frame', (
    tester,
  ) async {
    final scheme = _scheme(Brightness.dark);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme),
        home: const TitleBarLyricStripSurface(child: SizedBox.expand()),
      ),
    );

    final boxes = tester.widgetList<DecoratedBox>(_surfaceBoxes()).toList();
    expect(boxes, hasLength(1));

    final decoration = boxes.single.decoration as BoxDecoration;
    expect(decoration.border, isNull);
    expect(decoration.gradient, isNull);
    expect(decoration.boxShadow, isNull);
    expect(decoration.color, titleBarLyricStripWellColor(scheme));
    expect(decoration.borderRadius, AppRadius.mdCircular);
  });
}
