import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/title_bar.dart';
import 'package:pure_music/core/settings.dart';

Finder _titleBarBackdrop() => find.descendant(
  of: find.byType(TitleBar),
  matching: find.byType(BackdropFilter),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'EnableTitleBarFrostedGlass': false,
    });
  });

  tearDown(() async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'EnableTitleBarFrostedGlass': false,
    });
  });

  testWidgets('title bar frosted glass updates without leaving the page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          appBar: PreferredSize(
            preferredSize: Size.fromHeight(48),
            child: TitleBar(),
          ),
          body: SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    expect(_titleBarBackdrop(), findsNothing);

    AppSettings.instance.enableTitleBarFrostedGlass = true;
    AppSettings.backgroundNotifier.rebuild();
    await tester.pump();

    expect(_titleBarBackdrop(), findsOneWidget);

    AppSettings.instance.enableTitleBarFrostedGlass = false;
    AppSettings.backgroundNotifier.rebuild();
    await tester.pump();

    expect(_titleBarBackdrop(), findsNothing);
  });
}
