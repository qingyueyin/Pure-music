import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_player_lyric/component/foreground.dart';
import 'package:pure_player_lyric/component/lyric_line_display_area.dart';
import 'package:pure_player_lyric/component/lyric_transition_dots.dart';
import 'package:pure_player_lyric/component/word_lyric_text.dart';
import 'package:pure_player_lyric/desktop_lyric_controller.dart';
import 'package:pure_player_lyric/message.dart';

void main() {
  Widget buildSubject() => ChangeNotifierProvider.value(
    value: textDisplayController,
    child: ValueListenableProvider.value(
      value: DesktopLyricController.instance.theme,
      child: const MaterialApp(home: Scaffold(body: LyricLineDisplayArea())),
    ),
  );

  testWidgets('switches translated lines without duplicate keys', (
    tester,
  ) async {
    DesktopLyricController.instance.lyricLine.value =
        const LyricLineChangedMessage('第一行', Duration(seconds: 3), '翻译一');

    await tester.pumpWidget(buildSubject());

    DesktopLyricController.instance.lyricLine.value =
        const LyricLineChangedMessage('第二行', Duration(seconds: 3), '翻译二');
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'fade keeps the departing highlight frozen and removes it on time',
    (tester) async {
      final previousAnimation = textDisplayController.lyricAnimation;
      addTearDown(() {
        textDisplayController.lyricAnimation = previousAnimation;
      });
      textDisplayController.lyricAnimation = LyricSwitchAnimation.fade;
      DesktopLyricController.instance.isPlaying.value = true;
      DesktopLyricController.instance.lyricProgress.value =
          LyricProgressChangedMessage(
            1500,
            DateTime.now().millisecondsSinceEpoch,
            1,
            true,
            1,
          );
      DesktopLyricController.instance.lyricLine.value =
          LyricLineChangedMessage.fromJson({
            'content': 'first',
            'length': const Duration(seconds: 3).inMicroseconds,
            'words': [
              {'startMs': 0, 'lengthMs': 3000, 'content': 'first'},
            ],
            'isWordByWord': true,
            'lineId': 1,
          });
      await tester.pumpWidget(buildSubject());
      final initialPaint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(WordLyricText),
          matching: find.byType(CustomPaint),
        ),
      );
      final initialProgress =
          (initialPaint.painter as dynamic).progressMs as int;
      expect(initialProgress, greaterThanOrEqualTo(1500));

      DesktopLyricController.instance.lyricProgress.value =
          LyricProgressChangedMessage(
            0,
            DateTime.now().millisecondsSinceEpoch,
            1,
            true,
            2,
          );
      DesktopLyricController.instance.lyricLine.value =
          LyricLineChangedMessage.fromJson({
            'content': 'second',
            'length': const Duration(seconds: 3).inMicroseconds,
            'words': [
              {'startMs': 0, 'lengthMs': 3000, 'content': 'second'},
            ],
            'isWordByWord': true,
            'lineId': 2,
          });
      await tester.pump();

      final departingLine = find.byWidgetPredicate(
        (widget) => widget is WordLyricText && widget.line.lineId == 1,
      );
      final departingPaint = tester.widget<CustomPaint>(
        find.descendant(of: departingLine, matching: find.byType(CustomPaint)),
      );
      final frozenProgress =
          (departingPaint.painter as dynamic).progressMs as int;
      expect(frozenProgress, greaterThanOrEqualTo(initialProgress));

      await tester.pump(const Duration(milliseconds: 200));
      final midwayPaint = tester.widget<CustomPaint>(
        find.descendant(of: departingLine, matching: find.byType(CustomPaint)),
      );
      final midwayProgress = (midwayPaint.painter as dynamic).progressMs as int;
      expect(midwayProgress, frozenProgress);

      await tester.pump(const Duration(milliseconds: 501));
      expect(find.byType(WordLyricText), findsOneWidget);
    },
  );

  testWidgets('uses word rendering for an explicit word-by-word lyric', (
    tester,
  ) async {
    DesktopLyricController.instance.lyricLine.value =
        LyricLineChangedMessage.fromJson({
          'content': '逐字歌词',
          'length': const Duration(seconds: 3).inMicroseconds,
          'words': [
            {'startMs': 0, 'lengthMs': 3000, 'content': '逐字歌词'},
          ],
          'isWordByWord': true,
        });

    await tester.pumpWidget(buildSubject());

    expect(find.byType(WordLyricText), findsOneWidget);
  });

  testWidgets('uses line rendering when lyric type is explicitly line-based', (
    tester,
  ) async {
    DesktopLyricController.instance.lyricLine.value =
        LyricLineChangedMessage.fromJson({
          'content': '逐行歌词',
          'length': const Duration(seconds: 3).inMicroseconds,
          'words': [
            {'startMs': 0, 'lengthMs': 3000, 'content': '逐行歌词'},
          ],
          'isWordByWord': false,
        });

    await tester.pumpWidget(buildSubject());

    expect(find.byType(WordLyricText), findsNothing);
    expect(find.text('逐行歌词'), findsWidgets);
  });

  testWidgets('shows the same opening interlude threshold as the player', (
    tester,
  ) async {
    DesktopLyricController.instance.lyricLine.value =
        const LyricLineChangedMessage('', Duration(seconds: 4));

    await tester.pumpWidget(buildSubject());

    expect(find.byType(LyricTransitionDots), findsOneWidget);
  });

  test('infers word-by-word mode for legacy messages', () {
    final message = LyricLineChangedMessage.fromJson({
      'content': '旧消息',
      'length': const Duration(seconds: 3).inMicroseconds,
      'words': [
        {'startMs': 0, 'lengthMs': 3000, 'content': '旧消息'},
      ],
    });

    expect(message.isWordByWord, isTrue);
  });
}
