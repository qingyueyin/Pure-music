import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/vertical_lyric_view.dart';
import 'package:pure_music/play_service/lyric_service.dart';

void main() {
  test('paused position sync does not force lyric scroll', () {
    expect(shouldForceLyricScrollForPositionSync(PlayerState.paused), isFalse);
  });

  test('force jump does not cut a scroll already moving to the same line', () {
    expect(
      shouldSnapLyricScroll(
        distancePx: 80,
        forceJump: true,
        animatingToSameTarget: true,
      ),
      isFalse,
    );
    expect(
      shouldSnapLyricScroll(
        distancePx: 80,
        forceJump: true,
        animatingToSameTarget: false,
      ),
      isTrue,
    );
    expect(
      shouldSnapLyricScroll(
        distancePx: 0.2,
        forceJump: false,
        animatingToSameTarget: false,
      ),
      isTrue,
    );
  });

  test('next pre-switch does not take over a single-word line early', () {
    expect(
      lyricLineSwitchStartMs(
        previousSwitchStartMs: 212506,
        previousLineEndMs: 212978,
        nextLineStartMs: 212978,
        preserveSingleWordTiming: true,
      ),
      212978,
    );
    expect(
      lyricLineSwitchStartMs(
        previousSwitchStartMs: 212506,
        previousLineEndMs: 212978,
        nextLineStartMs: 212978,
        preserveSingleWordTiming: false,
      ),
      212658,
    );
  });

  test('TTML primary line follows the frozen parallel group', () {
    expect(
      lyricDisplayPrimaryIndex(
        fallbackPrimaryIndex: 82,
        lineCount: 88,
        groupedLines: {82, 84, 85},
      ),
      82,
    );
    expect(
      lyricDisplayPrimaryIndex(
        fallbackPrimaryIndex: 85,
        lineCount: 88,
        groupedLines: {82, 84, 85},
      ),
      82,
    );
    expect(
      lyricDisplayPrimaryIndex(
        fallbackPrimaryIndex: 86,
        lineCount: 88,
        groupedLines: {},
      ),
      86,
    );
  });
}
