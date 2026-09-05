import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/playback_service.dart';

void main() {
  test('fade/gapless handled completion does not auto-advance', () {
    expect(
      PlaybackService.shouldAutoAdvanceOnCompleted(
        smartHandled: false,
        transitionHandled: true,
        currentState: PlayerState.stopped,
      ),
      isFalse,
    );
  });

  test('stale completed while already playing does not auto-advance', () {
    expect(
      PlaybackService.shouldAutoAdvanceOnCompleted(
        smartHandled: false,
        transitionHandled: false,
        currentState: PlayerState.playing,
      ),
      isFalse,
    );
  });

  test('unhandled completion still auto-advances', () {
    expect(
      PlaybackService.shouldAutoAdvanceOnCompleted(
        smartHandled: false,
        transitionHandled: false,
        currentState: PlayerState.stopped,
      ),
      isTrue,
    );
  });

  test('smart-handled completion does not auto-advance', () {
    expect(
      PlaybackService.shouldAutoAdvanceOnCompleted(
        smartHandled: true,
        transitionHandled: false,
        currentState: PlayerState.stopped,
      ),
      isFalse,
    );
  });
}
