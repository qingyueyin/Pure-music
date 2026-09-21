import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/vertical_lyric_view.dart';
import 'package:pure_music/play_service/lyric_service.dart';

void main() {
  group('initial lyric scroll completion', () {
    bool finished({
      bool hasContentDimensions = true,
      double viewportDimension = 600,
      double targetHeight = 64,
      double requestedOffset = 420,
      double appliedOffset = 420,
    }) => shouldFinishInitialLyricScroll(
      hasContentDimensions: hasContentDimensions,
      viewportDimension: viewportDimension,
      targetHeight: targetHeight,
      requestedOffset: requestedOffset,
      appliedOffset: appliedOffset,
    );

    test('waits for the interlude to expand before ending restoration', () {
      expect(finished(targetHeight: 0), isFalse);
      expect(finished(targetHeight: 40), isTrue);
    });

    test('waits for scroll content and viewport layout', () {
      expect(finished(hasContentDimensions: false), isFalse);
      expect(finished(viewportDimension: 0), isFalse);
      expect(finished(viewportDimension: 1), isFalse);
      expect(finished(viewportDimension: double.infinity), isFalse);
      expect(finished(), isTrue);
    });

    test('does not finish at a temporarily clamped or estimated offset', () {
      expect(finished(appliedOffset: 0), isFalse);
      expect(finished(appliedOffset: 400), isFalse);
      expect(finished(appliedOffset: 419.75), isTrue);
      expect(finished(appliedOffset: 420.25), isTrue);
      expect(finished(appliedOffset: 420.5), isFalse);
    });

    test('rejects non-finite geometry', () {
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(finished(targetHeight: value), isFalse);
        expect(finished(requestedOffset: value), isFalse);
        expect(finished(appliedOffset: value), isFalse);
      }
    });
  });

  test('paused position sync does not force lyric scroll', () {
    expect(shouldForceLyricScrollForPositionSync(PlayerState.paused), isFalse);
  });

  test('playing position sync does not steal a user lyric browse', () {
    expect(shouldForceLyricScrollForPositionSync(PlayerState.playing), isFalse);
  });

  test(
    'user browsing still blocks follow even before the first line settles',
    () {
      expect(
        shouldIgnoreLyricFollowWhileUserScrolling(isUserDragging: true),
        isTrue,
      );
      expect(
        shouldIgnoreLyricFollowWhileUserScrolling(isUserDragging: false),
        isFalse,
      );
    },
  );

  test('viewport height jitter does not force lyric scroll', () {
    expect(shouldForceLyricScrollForViewportChange(), isFalse);
  });

  test('entering the page still force-scrolls after viewport settles', () {
    expect(
      shouldForceLyricScrollForViewportChange(needsInitialScroll: true),
      isTrue,
    );
  });

  test('position sync still force-scrolls until the first line is found', () {
    expect(
      shouldForceLyricScrollForPositionSync(
        PlayerState.playing,
        needsInitialScroll: true,
      ),
      isTrue,
    );
    expect(
      shouldForceLyricScrollForPositionSync(
        PlayerState.paused,
        needsInitialScroll: true,
      ),
      isTrue,
    );
  });

  test('playing resync does not skip the first current-line scroll', () {
    expect(
      shouldEnqueuePlayingLyricResync(
        forceScroll: false,
        needsInitialScroll: true,
        isPlaying: true,
      ),
      isFalse,
    );
    expect(
      shouldEnqueuePlayingLyricResync(
        forceScroll: false,
        needsInitialScroll: false,
        isPlaying: true,
      ),
      isTrue,
    );
    expect(
      shouldEnqueuePlayingLyricResync(
        forceScroll: true,
        needsInitialScroll: false,
        isPlaying: true,
      ),
      isFalse,
    );
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

  test(
    'same-frame lyric updates keep intermediate lines and merge one line',
    () {
      const first = LyricLineUpdate(
        primaryIndex: 1,
        activeIndices: [1],
        positionMs: 1000,
      );
      const second = LyricLineUpdate(
        primaryIndex: 2,
        activeIndices: [2],
        positionMs: 1016,
      );
      var queued = lyricLineUpdateQueueAfterEnqueue(
        queued: const <LyricLineUpdate>[],
        update: first,
        currentIndex: 0,
        isPlaying: true,
      );
      queued = lyricLineUpdateQueueAfterEnqueue(
        queued: queued,
        update: second,
        currentIndex: 0,
        isPlaying: true,
      );

      expect(queued.map((update) => update.primaryIndex), [1, 2]);

      const merged = LyricLineUpdate(
        primaryIndex: 2,
        activeIndices: [2, 3],
        positionMs: 1020,
      );
      queued = lyricLineUpdateQueueAfterEnqueue(
        queued: queued,
        update: merged,
        currentIndex: 0,
        isPlaying: true,
      );
      expect(queued, hasLength(2));
      expect(queued.last.activeIndices, [2, 3]);

      const stale = LyricLineUpdate(
        primaryIndex: 1,
        activeIndices: [1],
        positionMs: 1021,
      );
      queued = lyricLineUpdateQueueAfterEnqueue(
        queued: queued,
        update: stale,
        currentIndex: 0,
        isPlaying: true,
      );
      expect(queued.map((update) => update.primaryIndex), [1, 2]);
    },
  );

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

  test('offset computation still force-scrolls the first current line', () {
    expect(
      shouldForceLyricScrollAfterOffsetsComputed(
        needsInitialScroll: true,
        isUserDragging: false,
      ),
      isTrue,
    );
    expect(
      shouldForceLyricScrollAfterOffsetsComputed(
        needsInitialScroll: true,
        isUserDragging: true,
      ),
      isFalse,
    );
    expect(
      shouldForceLyricScrollAfterOffsetsComputed(
        needsInitialScroll: false,
        isUserDragging: false,
      ),
      isFalse,
    );
  });
}
