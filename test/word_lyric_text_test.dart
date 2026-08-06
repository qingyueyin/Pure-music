import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_player_lyric/component/word_lyric_text.dart';
import 'package:pure_player_lyric/message.dart';

void main() {
  test('preserves the configured unplayed color opacity', () {
    const color = Color(0x73000000);

    expect(applyLyricOpacity(color, 1), color);
    expect(applyLyricOpacity(color, 0.5).a, closeTo(color.a * 0.5, 0.001));
  });

  test('matches the player catch-up strategy and preserves the final line', () {
    final adjusted = desktopLyricHighlightTimeMs(
      progressMs: 1800,
      lastWordEndMs: 2100,
      deadlineMs: 2000,
      catchUpDurationMs: 260,
      finishLeadMs: 32,
    );

    expect(adjusted, greaterThan(1800));
    expect(
      desktopLyricHighlightTimeMs(
        progressMs: 1800,
        lastWordEndMs: 2100,
        deadlineMs: null,
      ),
      1800,
    );
  });

  testWidgets('renders complete Unicode characters without an exception', (
    tester,
  ) async {
    final isPlaying = ValueNotifier(false);
    final progress = ValueNotifier(
      LyricProgressChangedMessage(
        0,
        DateTime.now().millisecondsSinceEpoch,
        1.0,
        false,
      ),
    );
    addTearDown(isPlaying.dispose);
    addTearDown(progress.dispose);
    const line = LyricLineChangedMessage('A🎵𠀋B', Duration(seconds: 4), null, [
      LyricWord(0, 4000, 'A🎵𠀋B'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WordLyricText(
            line: line,
            color: Colors.white,
            playedColor: Colors.blue,
            fontSize: 24,
            fontWeight: 700,
            textAlign: TextAlign.center,
            isPlaying: isPlaying,
            progress: progress,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('advances calibrated progress at the playback rate', (
    tester,
  ) async {
    final isPlaying = ValueNotifier(true);
    final progress = ValueNotifier(
      LyricProgressChangedMessage(
        1000,
        DateTime.now().millisecondsSinceEpoch,
        2.0,
        true,
      ),
    );
    addTearDown(isPlaying.dispose);
    addTearDown(progress.dispose);
    const line = LyricLineChangedMessage('AB', Duration(seconds: 4), null, [
      LyricWord(0, 4000, 'AB'),
    ], 1000);

    Widget buildSubject() => MaterialApp(
      home: Scaffold(
        body: WordLyricText(
          line: line,
          color: Colors.white,
          playedColor: Colors.blue,
          fontSize: 24,
          fontWeight: 700,
          textAlign: TextAlign.center,
          isPlaying: isPlaying,
          progress: progress,
        ),
      ),
    );

    await tester.pumpWidget(buildSubject());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();

    final paint = tester.widget<CustomPaint>(find.byType(CustomPaint).last);
    final painter = paint.painter!;
    final renderedProgress = (painter as dynamic).progressMs as int;
    expect(renderedProgress, greaterThanOrEqualTo(1400));
  });

  testWidgets('freezes a departing line when progress switches line id', (
    tester,
  ) async {
    final isPlaying = ValueNotifier(true);
    final progress = ValueNotifier(
      LyricProgressChangedMessage(
        1000,
        DateTime.now().millisecondsSinceEpoch,
        1.0,
        true,
        1,
      ),
    );
    addTearDown(isPlaying.dispose);
    addTearDown(progress.dispose);
    final line = LyricLineChangedMessage.fromJson({
      'content': 'AB',
      'length': const Duration(seconds: 4).inMicroseconds,
      'words': [
        {'startMs': 0, 'lengthMs': 4000, 'content': 'AB'},
      ],
      'progressMs': 1000,
      'isWordByWord': true,
      'lineId': 1,
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WordLyricText(
            line: line,
            color: Colors.white,
            playedColor: Colors.blue,
            fontSize: 24,
            fontWeight: 700,
            textAlign: TextAlign.center,
            isPlaying: isPlaying,
            progress: progress,
          ),
        ),
      ),
    );
    final beforePaint = tester.widget<CustomPaint>(
      find.byType(CustomPaint).last,
    );
    final before = (beforePaint.painter as dynamic).progressMs as int;

    progress.value = LyricProgressChangedMessage(
      200,
      DateTime.now().millisecondsSinceEpoch,
      1.0,
      true,
      2,
    );
    await tester.pump(const Duration(milliseconds: 100));

    final afterPaint = tester.widget<CustomPaint>(
      find.byType(CustomPaint).last,
    );
    final after = (afterPaint.painter as dynamic).progressMs as int;
    expect(after, before);
  });
}
