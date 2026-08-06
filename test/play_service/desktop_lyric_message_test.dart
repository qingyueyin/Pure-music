import 'package:desktop_lyric/message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/play_service/desktop_lyric_service.dart';
import 'package:pure_music/play_service/lyric_service.dart';

void main() {
  test('serializes the explicit lyric type', () {
    const message = LyricLineChangedMessage(
      'line',
      Duration(seconds: 3),
      null,
      [LyricWord(0, 3000, 'line')],
      0,
      null,
      null,
      null,
      null,
      null,
      false,
    );

    final json = message.toMessageJson();

    expect(json['isWordByWord'], isFalse);
    expect(LyricLineChangedMessage.fromJson(json).isWordByWord, isFalse);
  });

  test('infers the lyric type when reading a legacy message', () {
    final message = LyricLineChangedMessage.fromJson({
      'content': 'line',
      'length': const Duration(seconds: 3).inMicroseconds,
      'words': [
        {'startMs': 0, 'lengthMs': 3000, 'content': 'line'},
      ],
    });

    expect(message.isWordByWord, isTrue);
  });

  test('keeps the final word authored timing past the line duration', () {
    final line = SyncLyricLine(
      const Duration(seconds: 8),
      const Duration(seconds: 2),
      [
        SyncLyricWord(
          const Duration(seconds: 8),
          const Duration(seconds: 3),
          'line',
        ),
      ],
    );

    expect(desktopLyricHighlightDuration(line), const Duration(seconds: 3));
  });

  test('keeps the full opening interlude when desktop lyric starts late', () {
    final lyric = Lyric([
      SyncLyricLine(
        const Duration(seconds: 8),
        const Duration(seconds: 3),
        [
          SyncLyricWord(
            const Duration(seconds: 8),
            const Duration(seconds: 3),
            'line',
          ),
        ],
      ),
    ]);

    final prelude = desktopLyricPreludeLineAt(lyric, 3000);

    expect(prelude?.start, Duration.zero);
    expect(prelude?.length, const Duration(seconds: 8));
    expect(desktopLyricPreludeLineAt(lyric, 8000), isNull);
  });

  test('round-trips line identity and highlight strategy', () {
    const message = LyricLineChangedMessage(
      'line',
      Duration(seconds: 3),
      null,
      [LyricWord(0, 3000, 'line')],
      1200,
      null,
      null,
      null,
      null,
      null,
      true,
      7,
      2680,
      260,
      32,
    );

    final decoded = LyricLineChangedMessage.fromJson(message.toMessageJson());

    expect(decoded.lineId, 7);
    expect(decoded.highlightDeadlineMs, 2680);
    expect(decoded.highlightCatchUpDurationMs, 260);
    expect(decoded.highlightFinishLeadMs, 32);
  });

  test('uses the next renderable line as the highlight deadline', () {
    final lyric = Lyric([
      SyncLyricLine(
        const Duration(seconds: 8),
        const Duration(seconds: 3),
        [
          SyncLyricWord(
            const Duration(seconds: 8),
            const Duration(seconds: 1),
            'first',
          ),
          SyncLyricWord(
            const Duration(seconds: 9),
            const Duration(seconds: 2),
            'line',
          ),
        ],
      ),
      SyncLyricLine(
        const Duration(seconds: 10),
        const Duration(seconds: 2),
        [
          SyncLyricWord(
            const Duration(seconds: 10),
            const Duration(seconds: 2),
            'next',
          ),
        ],
      ),
    ]);

    expect(lyricHighlightDeadlineMsForLine(lyric, 0), 9680);
    expect(lyricHighlightDeadlineMsForLine(lyric, 1), isNull);
  });
}
