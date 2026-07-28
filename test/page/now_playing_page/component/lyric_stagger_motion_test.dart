import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_stagger_motion.dart';

void main() {
  group('lyricStaggerDelayMs', () {
    test('uses cumulative delay from the visible start line', () {
      expect(lyricStaggerDelayMs(itemIndex: 4, visibleStartIndex: 4), 0);
      expect(lyricStaggerDelayMs(itemIndex: 5, visibleStartIndex: 4), 50);
      expect(lyricStaggerDelayMs(itemIndex: 6, visibleStartIndex: 4), 97);
      expect(lyricStaggerDelayMs(itemIndex: 7, visibleStartIndex: 4), 142);
    });
  });

  group('canStartLyricStagger', () {
    test('accepts a valid nearby line change', () {
      expect(
        canStartLyricStagger(
          enabled: true,
          previousIndex: 3,
          nextIndex: 7,
          isUserDragging: false,
          skipNextAfterDrag: false,
        ),
        isTrue,
      );
    });

    test('rejects invalid, large and post-drag changes', () {
      bool decide({
        required int previousIndex,
        required int nextIndex,
        bool enabled = true,
        bool isUserDragging = false,
        bool skipNextAfterDrag = false,
      }) {
        return canStartLyricStagger(
          enabled: enabled,
          previousIndex: previousIndex,
          nextIndex: nextIndex,
          isUserDragging: isUserDragging,
          skipNextAfterDrag: skipNextAfterDrag,
        );
      }

      expect(decide(previousIndex: -1, nextIndex: 1), isFalse);
      expect(decide(previousIndex: 3, nextIndex: 3), isFalse);
      expect(decide(previousIndex: 3, nextIndex: 14), isFalse);
      expect(
        decide(previousIndex: 3, nextIndex: 4, enabled: false),
        isFalse,
      );
      expect(
        decide(previousIndex: 3, nextIndex: 4, isUserDragging: true),
        isFalse,
      );
      expect(
        decide(previousIndex: 3, nextIndex: 4, skipNextAfterDrag: true),
        isFalse,
      );
    });
  });

  testWidgets('a new generation starts from the captured displacement',
      (tester) async {
    Widget host({
      required int generation,
      required double shiftY,
      Duration delay = Duration.zero,
    }) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: LyricStaggerTransition(
          enabled: true,
          generation: generation,
          shiftY: shiftY,
          delay: delay,
          child: const SizedBox(key: ValueKey('line'), width: 20, height: 20),
        ),
      );
    }

    await tester.pumpWidget(host(generation: 0, shiftY: 0));
    await tester.pumpWidget(host(generation: 1, shiftY: 120));

    expect(_translationY(tester), 120);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_translationY(tester), lessThan(120));
    expect(_translationY(tester), greaterThan(0));
    await tester.pumpAndSettle();
    expect(_translationY(tester), closeTo(0, 0.01));
  });

  testWidgets('a newer generation cancels the previous delayed spring',
      (tester) async {
    Widget host({
      required int generation,
      required double shiftY,
      required Duration delay,
    }) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: LyricStaggerTransition(
          enabled: true,
          generation: generation,
          shiftY: shiftY,
          delay: delay,
          child: const SizedBox(key: ValueKey('line'), width: 20, height: 20),
        ),
      );
    }

    await tester.pumpWidget(
      host(generation: 0, shiftY: 0, delay: Duration.zero),
    );
    await tester.pumpWidget(
      host(
        generation: 1,
        shiftY: 120,
        delay: const Duration(milliseconds: 500),
      ),
    );
    await tester.pumpWidget(
      host(generation: 2, shiftY: 40, delay: Duration.zero),
    );

    expect(_translationY(tester), 40);
    await tester.pumpAndSettle();
    expect(_translationY(tester), closeTo(0, 0.01));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_translationY(tester), closeTo(0, 0.01));
  });

  testWidgets('disabling the effect cancels a delayed spring immediately',
      (tester) async {
    Widget host({required bool enabled}) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: LyricStaggerTransition(
          enabled: enabled,
          generation: 1,
          shiftY: 80,
          delay: const Duration(milliseconds: 500),
          child: const SizedBox(key: ValueKey('line'), width: 20, height: 20),
        ),
      );
    }

    await tester.pumpWidget(host(enabled: true));
    expect(_translationY(tester), 80);
    await tester.pumpWidget(host(enabled: false));
    expect(_translationY(tester), 0);
    await tester.pump(const Duration(milliseconds: 600));
    expect(_translationY(tester), 0);
  });
}

double _translationY(WidgetTester tester) {
  final transform = tester.widget<Transform>(find.byType(Transform));
  return transform.transform.getTranslation().y;
}
