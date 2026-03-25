import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_tile.dart';

void main() {
  testWidgets('Inactive sync lyric line keeps word-based wrap layout',
      (tester) async {
    final controller = LyricViewController.instance;
    final line = SyncLyricLine(
      const Duration(seconds: 1),
      const Duration(seconds: 2),
      [
        SyncLyricWord(const Duration(seconds: 1),
            const Duration(milliseconds: 800), 'You '),
        SyncLyricWord(const Duration(milliseconds: 1800),
            const Duration(milliseconds: 900), 'love '),
        SyncLyricWord(const Duration(milliseconds: 2700),
            const Duration(milliseconds: 900), 'me'),
      ],
      '你给我爱',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: ChangeNotifierProvider.value(
            value: controller,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: LyricViewTile(
                line: line,
                opacity: 0.6,
                distance: 1,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Wrap), findsOneWidget);
    expect(find.text('You '), findsOneWidget);
    expect(find.text('love '), findsOneWidget);
    expect(find.text('me'), findsOneWidget);
  });
}
