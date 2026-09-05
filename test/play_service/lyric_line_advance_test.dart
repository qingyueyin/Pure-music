import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/lyric_service.dart';

void main() {
  group('lyricLineAdvanceIsSeekJump', () {
    test('1s timer jitter at 1x is sequential, not a seek', () {
      expect(
        lyricLineAdvanceIsSeekJump(
          previousPositionSec: 10.0,
          nextPositionSec: 11.02,
          rate: 1.0,
        ),
        isFalse,
      );
    });

    test('1s timer tick at 2x is sequential, not a seek', () {
      expect(
        lyricLineAdvanceIsSeekJump(
          previousPositionSec: 10.0,
          nextPositionSec: 12.0,
          rate: 2.0,
        ),
        isFalse,
      );
    });

    test('backward movement is a seek', () {
      expect(
        lyricLineAdvanceIsSeekJump(
          previousPositionSec: 10.0,
          nextPositionSec: 8.5,
          rate: 1.0,
        ),
        isTrue,
      );
    });

    test('large forward skip is a seek', () {
      expect(
        lyricLineAdvanceIsSeekJump(
          previousPositionSec: 10.0,
          nextPositionSec: 18.0,
          rate: 1.0,
        ),
        isTrue,
      );
    });
  });

  group('lyricSwitchCursorAt', () {
    test('hint advances at the next line pre-switch', () {
      expect(
        lyricSwitchCursorAt(
          timeMs: 4680,
          switchStartMs: const [0, 4680, 8000],
          lineEndMs: const [5000, 8200, 11000],
          hintLineIndex: 0,
        ),
        2,
      );
    });

    test(
      'hint does not stick to the current line after the next switch start',
      () {
        expect(
          lyricSwitchCursorAt(
            timeMs: 2100,
            switchStartMs: const [0, 1800, 2000, 6000],
            lineEndMs: const [5000, 1950, 4000, 8000],
            hintLineIndex: 0,
          ),
          3,
        );
      },
    );

    test('stays on the current line before the next switch', () {
      expect(
        lyricSwitchCursorAt(
          timeMs: 1200,
          switchStartMs: const [0, 1800, 4000],
          lineEndMs: const [2000, 3800, 6000],
          hintLineIndex: 0,
        ),
        1,
      );
    });
  });
}
