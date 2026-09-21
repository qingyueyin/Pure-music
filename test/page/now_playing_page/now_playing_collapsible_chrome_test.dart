import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_collapsible_chrome.dart';

void main() {
  testWidgets('hidden chrome gives its height back to the sibling', (
    tester,
  ) async {
    const chromeKey = Key('chrome');
    const siblingKey = Key('sibling');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 200,
            child: Column(
              children: [
                NowPlayingCollapsibleChrome(
                  visible: false,
                  child: SizedBox(key: chromeKey, height: 48, width: 80),
                ),
                Expanded(child: SizedBox.expand(key: siblingKey)),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(chromeKey)).height, 48);
    expect(tester.getSize(find.byType(NowPlayingCollapsibleChrome)).height, 0);
    expect(tester.getSize(find.byKey(siblingKey)).height, 200);
  });

  testWidgets('visible chrome keeps its child height', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 200,
            child: Column(
              children: [
                NowPlayingCollapsibleChrome(
                  visible: true,
                  child: SizedBox(height: 48, width: 80),
                ),
                Expanded(child: SizedBox.expand()),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(NowPlayingCollapsibleChrome)).height, 48);
  });
}
