import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/cover_pointer_sheen.dart';

CoverPointerSheenPainter? _sheenPainter(WidgetTester tester) {
  for (final paint in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    final painter = paint.painter;
    if (painter is CoverPointerSheenPainter) return painter;
  }
  return null;
}

Future<void> _hoverAt(WidgetTester tester, Finder finder, Offset local) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  final origin = tester.getTopLeft(finder);
  await gesture.moveTo(origin + local);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
}

Widget _harness({
  required Widget child,
  bool disableAnimations = false,
  bool scrollable = false,
}) {
  Widget body = Center(
    child: SizedBox(width: 180, height: 180, child: child),
  );
  if (scrollable) {
    body = SizedBox(
      height: 400,
      child: ListView(
        children: [
          SizedBox(width: 180, height: 180, child: child),
          const SizedBox(height: 1200),
        ],
      ),
    );
  }
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(body: body),
    ),
  );
}

void main() {
  testWidgets('paints a sheen under the pointer after hover', (tester) async {
    await tester.pumpWidget(
      _harness(
        child: const CoverPointerSheen(
          child: ColoredBox(color: Color(0xFF101010)),
        ),
      ),
    );

    expect(_sheenPainter(tester), isNull);

    await _hoverAt(tester, find.byType(CoverPointerSheen), const Offset(90, 60));

    final painter = _sheenPainter(tester);
    expect(painter, isNotNull);
    expect(painter!.opacity, greaterThan(0.5));
    expect(painter.center.dx, closeTo(90, 1));
    expect(painter.center.dy, closeTo(60, 1));
  });

  testWidgets('does not paint when disabled', (tester) async {
    await tester.pumpWidget(
      _harness(
        child: const CoverPointerSheen(
          enabled: false,
          child: ColoredBox(color: Color(0xFF101010)),
        ),
      ),
    );

    await _hoverAt(tester, find.byType(CoverPointerSheen), const Offset(90, 90));

    expect(_sheenPainter(tester), isNull);
  });

  testWidgets('does not paint when animations are disabled', (tester) async {
    await tester.pumpWidget(
      _harness(
        disableAnimations: true,
        child: const CoverPointerSheen(
          child: ColoredBox(color: Color(0xFF101010)),
        ),
      ),
    );

    await _hoverAt(tester, find.byType(CoverPointerSheen), const Offset(90, 90));

    expect(_sheenPainter(tester), isNull);
  });

  testWidgets('hides sheen while the parent list is scrolling', (tester) async {
    await tester.pumpWidget(
      _harness(
        scrollable: true,
        child: const CoverPointerSheen(
          child: ColoredBox(color: Color(0xFF101010)),
        ),
      ),
    );

    await _hoverAt(tester, find.byType(CoverPointerSheen), const Offset(90, 90));
    expect(_sheenPainter(tester), isNotNull);

    // 用 startGesture 手动控制滚动，在滚动进行中断言
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    // 此时滚动正在进行，光斑应被隐藏
    expect(_sheenPainter(tester), isNull);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  });
}
