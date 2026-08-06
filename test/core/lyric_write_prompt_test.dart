import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/utils.dart';

void main() {
  testWidgets('lyric write prompt accepts the write action', (tester) async {
    var writePressed = false;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: routerKey,
        scaffoldMessengerKey: scaffoldMessengerKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );

    showLyricWritePrompt(
      title: 'Song',
      onWrite: () => writePressed = true,
      onDismiss: () {},
    );
    await tester.pump();

    await tester.tap(find.text('写入'), warnIfMissed: false);
    await tester.pump();

    expect(writePressed, isTrue);
  });

  testWidgets('lyric write prompt uses the app toast surface', (tester) async {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.green);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: routerKey,
        scaffoldMessengerKey: scaffoldMessengerKey,
        theme: ThemeData(colorScheme: scheme),
        home: const Scaffold(body: SizedBox()),
      ),
    );

    showLyricWritePrompt(
      title: 'Song',
      onWrite: () {},
      onDismiss: () {},
    );
    await tester.pump();

    final promptContainer = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('写入标签？'),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = promptContainer.decoration! as BoxDecoration;
    expect(decoration.color, scheme.inverseSurface);

    await tester.tap(find.text('写入'));
    await tester.pump();
  });

  testWidgets('lyric write prompt can be removed when the song changes',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: routerKey,
        scaffoldMessengerKey: scaffoldMessengerKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );

    final shown = showLyricWritePrompt(
      title: 'Song',
      onWrite: () {},
      onDismiss: () {},
    );
    await tester.pump();
    expect(shown, isTrue);
    expect(find.text('写入标签？'), findsOneWidget);

    hideLyricWritePrompt();
    await tester.pump();

    expect(find.text('写入标签？'), findsNothing);
  });
}
