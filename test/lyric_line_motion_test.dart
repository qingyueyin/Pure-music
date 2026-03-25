import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_line_motion.dart';

void main() {
  test('LyricLineVisualStateTween interpolates opacity blur and scale', () {
    final tween = LyricLineVisualStateTween(
      begin: LyricLineVisualState(opacity: 1.0, blurSigma: 0.0, scale: 1.1),
      end: LyricLineVisualState(opacity: 0.4, blurSigma: 6.0, scale: 1.0),
    );

    expect(
      tween.lerp(0.5),
      const LyricLineVisualState(opacity: 0.7, blurSigma: 3.0, scale: 1.05),
    );
  });

  testWidgets('LyricLineSpringMotion animates toward next target state',
      (tester) async {
    const spring = LyricSpringDescription(
      stiffness: 220.0,
      damping: 26.0,
      mass: 1.0,
    );
    const begin =
        LyricLineVisualState(opacity: 1.0, blurSigma: 0.0, scale: 1.1);
    const end = LyricLineVisualState(opacity: 0.4, blurSigma: 5.0, scale: 1.0);

    Widget buildMotion(LyricLineVisualState state) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              child: LyricLineSpringMotion(
                targetState: state,
                spring: spring,
                alignment: Alignment.centerLeft,
                child: const Text('Hello'),
              ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildMotion(begin));

    final motionFinder = find.byType(LyricLineSpringMotion);
    final opacityFinder =
        find.descendant(of: motionFinder, matching: find.byType(Opacity));
    final transformFinder =
        find.descendant(of: motionFinder, matching: find.byType(Transform));

    final initialOpacity = tester.widget<Opacity>(opacityFinder);
    expect(initialOpacity.opacity, 1.0);
    expect(find.byType(ImageFiltered), findsNothing);

    final initialTransform = tester.widget<Transform>(transformFinder);
    expect(initialTransform.transform.storage[0], closeTo(1.1, 1e-3));

    await tester.pumpWidget(buildMotion(end));

    final immediateOpacity = tester.widget<Opacity>(opacityFinder);
    expect(immediateOpacity.opacity, 1.0);

    await tester.pump(const Duration(milliseconds: 96));

    final midOpacity = tester.widget<Opacity>(opacityFinder);
    expect(midOpacity.opacity, lessThan(1.0));
    expect(midOpacity.opacity, greaterThan(0.4));
    expect(find.byType(ImageFiltered), findsOneWidget);

    final midTransform = tester.widget<Transform>(transformFinder);
    expect(midTransform.transform.storage[0], lessThan(1.1));
    expect(midTransform.transform.storage[0], greaterThan(1.0));

    await tester.pumpAndSettle();

    final settledOpacity = tester.widget<Opacity>(opacityFinder);
    expect(settledOpacity.opacity, closeTo(0.4, 0.02));

    final settledTransform = tester.widget<Transform>(transformFinder);
    expect(settledTransform.transform.storage[0], closeTo(1.0, 0.02));
  });

  testWidgets('LyricLineSpringMotion can disable spring and snap immediately',
      (tester) async {
    const spring = LyricSpringDescription(
      stiffness: 220.0,
      damping: 26.0,
      mass: 1.0,
    );
    const end = LyricLineVisualState(opacity: 0.4, blurSigma: 5.0, scale: 1.0);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricLineSpringMotion(
            targetState: end,
            spring: spring,
            alignment: Alignment.centerLeft,
            enabled: false,
            child: const Text('Hello'),
          ),
        ),
      ),
    );

    final opacity = tester.widget<Opacity>(find.byType(Opacity));
    expect(opacity.opacity, 0.4);
  });
}
