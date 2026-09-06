import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/vertical_lyric_view.dart';
import 'package:pure_music/play_service/lyric_service.dart';

void main() {
  test('paused position sync does not force lyric scroll', () {
    expect(shouldForceLyricScrollForPositionSync(PlayerState.paused), isFalse);
  });

  test('viewport height jitter does not force lyric scroll', () {
    expect(shouldForceLyricScrollForViewportChange(), isFalse);
  });

  test('offset cache measures wrapped lines at the tile content width', () {
    expect(lyricLineLayoutWidth(400), 376);
    expect(lyricLineLayoutWidth(20), 1);
  });

  test(
    'stagger compensation is the scroll delta, not zeroed for a real jump',
    () {
      expect(lyricStaggerJumpDeltaY(from: 80, to: 200), 120);
      expect(lyricStaggerJumpDeltaY(from: 80, to: 80.2), 0);
    },
  );

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

  test(
    'tiny remaining distance does not kill a scroll to a different line',
    () {
      expect(
        shouldSnapLyricScroll(
          distancePx: 0.2,
          forceJump: false,
          animatingToSameTarget: false,
          isAnimating: true,
        ),
        isFalse,
      );
    },
  );

  test('activity-only updates do not follow-scroll the current line', () {
    expect(
      shouldFollowLyricLineScroll(
        forceScroll: false,
        needsInitialScroll: false,
        mainLineChanged: false,
      ),
      isFalse,
    );
    expect(
      shouldFollowLyricLineScroll(
        forceScroll: false,
        needsInitialScroll: false,
        mainLineChanged: true,
      ),
      isTrue,
    );
  });

  test('an in-flight scroll to the same line is not restarted', () {
    expect(
      shouldRestartLyricScroll(animatingToSameTarget: true, forceJump: false),
      isFalse,
    );
    expect(
      shouldRestartLyricScroll(animatingToSameTarget: true, forceJump: true),
      isFalse,
    );
    expect(
      shouldRestartLyricScroll(animatingToSameTarget: false, forceJump: false),
      isTrue,
    );
    expect(
      shouldRestartLyricScroll(
        animatingToSameTarget: false,
        forceJump: false,
        isAnimating: true,
        distancePx: 0.2,
      ),
      isFalse,
    );
  });

  test('playing resync does not pull the current line backward', () {
    expect(
      shouldApplyPlaybackLyricResync(
        currentIndex: 8,
        resyncIndex: 7,
        isPlaying: true,
      ),
      isFalse,
    );
    expect(
      shouldApplyPlaybackLyricResync(
        currentIndex: 8,
        resyncIndex: 9,
        isPlaying: true,
      ),
      isTrue,
    );
    expect(
      shouldApplyPlaybackLyricResync(
        currentIndex: 8,
        resyncIndex: 7,
        isPlaying: false,
      ),
      isTrue,
    );
  });

  test('playing resync does not skip an intermediate line', () {
    expect(
      shouldApplyPlaybackLyricResync(
        currentIndex: 8,
        resyncIndex: 10,
        isPlaying: true,
      ),
      isFalse,
    );
    expect(
      shouldApplyPlaybackLyricResync(
        currentIndex: 8,
        resyncIndex: 10,
        isPlaying: false,
      ),
      isTrue,
    );
  });

  test('queued line updates wait for the applied frame to commit', () {
    expect(
      shouldScheduleQueuedLyricLineUpdate(
        awaitingAppliedUpdateFrame: true,
        alreadyScheduledForGeneration: false,
      ),
      isFalse,
    );
    expect(
      shouldScheduleQueuedLyricLineUpdate(
        awaitingAppliedUpdateFrame: false,
        alreadyScheduledForGeneration: true,
      ),
      isFalse,
    );
    expect(
      shouldScheduleQueuedLyricLineUpdate(
        awaitingAppliedUpdateFrame: false,
        alreadyScheduledForGeneration: false,
      ),
      isTrue,
    );
  });

  test('force resync only drops the queue on a real jump', () {
    expect(
      shouldDiscardQueuedLyricUpdatesForResync(
        forceScroll: true,
        currentIndex: 5,
        resyncIndex: 5,
      ),
      isFalse,
    );
    expect(
      shouldDiscardQueuedLyricUpdatesForResync(
        forceScroll: true,
        currentIndex: 5,
        resyncIndex: 6,
      ),
      isFalse,
    );
    expect(
      shouldDiscardQueuedLyricUpdatesForResync(
        forceScroll: true,
        currentIndex: 5,
        resyncIndex: 8,
      ),
      isTrue,
    );
    expect(
      shouldDiscardQueuedLyricUpdatesForResync(
        forceScroll: false,
        currentIndex: 5,
        resyncIndex: 8,
      ),
      isFalse,
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

  test('parallel group members use main-line visual distance', () {
    expect(
      lyricLineVisualDistance(
        index: 85,
        mainLine: 82,
        parallelGroupLines: {82, 84, 85},
      ),
      0,
    );
    expect(
      lyricLineVisualDistance(
        index: 86,
        mainLine: 82,
        parallelGroupLines: {82, 84, 85},
      ),
      4,
    );
  });
}
