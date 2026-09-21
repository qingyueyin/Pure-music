import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/frosted_chrome.dart';
import 'package:pure_music/core/design_tokens.dart';

Widget _harness({required Widget child}) {
  return MaterialApp(
    home: Scaffold(backgroundColor: Colors.transparent, body: child),
  );
}

Finder _inChrome(Finder matching) =>
    find.descendant(of: find.byType(FrostedChrome), matching: matching);

void main() {
  testWidgets('MD3 chrome does not apply BackdropFilter', (tester) async {
    await tester.pumpWidget(
      _harness(
        child: const FrostedChrome(
          enabled: false,
          child: SizedBox(width: 40, height: 40),
        ),
      ),
    );

    expect(_inChrome(find.byType(BackdropFilter)), findsNothing);
  });

  testWidgets('frosted chrome applies BackdropFilter', (tester) async {
    await tester.pumpWidget(
      _harness(
        child: const FrostedChrome(
          enabled: true,
          child: SizedBox(width: 40, height: 40),
        ),
      ),
    );

    expect(_inChrome(find.byType(BackdropFilter)), findsOneWidget);
    expect(_inChrome(find.byType(ClipRect)), findsOneWidget);
  });

  testWidgets('frosted chrome with radius clips to rounded rect', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        child: FrostedChrome(
          enabled: true,
          borderRadius: AppRadius.mdCircular,
          child: const SizedBox(width: 40, height: 80),
        ),
      ),
    );

    expect(_inChrome(find.byType(BackdropFilter)), findsOneWidget);
    expect(_inChrome(find.byType(ClipRRect)), findsOneWidget);
    final clip = tester.widget<ClipRRect>(_inChrome(find.byType(ClipRRect)));
    expect(clip.borderRadius, AppRadius.mdCircular);
  });

  testWidgets('MD3 chrome with radius still clips without blur', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        child: FrostedChrome(
          enabled: false,
          borderRadius: AppRadius.mdCircular,
          child: const SizedBox(width: 40, height: 80),
        ),
      ),
    );

    expect(_inChrome(find.byType(BackdropFilter)), findsNothing);
    expect(_inChrome(find.byType(ClipRRect)), findsOneWidget);
  });

  testWidgets('frosted chrome keeps content outside the blur layer', (
    tester,
  ) async {
    const contentKey = Key('chrome-content');
    await tester.pumpWidget(
      _harness(
        child: const FrostedChrome(
          enabled: true,
          child: SizedBox(key: contentKey, width: 40, height: 80),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(BackdropFilter),
        matching: find.byKey(contentKey),
      ),
      findsNothing,
    );
    expect(find.byKey(contentKey), findsOneWidget);
    expect(_inChrome(find.byType(RepaintBoundary)), findsOneWidget);
  });
}
