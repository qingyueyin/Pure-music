import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/mini_now_playing.dart';

void main() {
  test('resolves adjacent track changes to the playback direction', () {
    expect(
      miniNowPlayingSlideDirection(
        previousIndex: 2,
        currentIndex: 1,
        playlistLength: 5,
      ),
      MiniNowPlayingSlideDirection.previous,
    );
    expect(
      miniNowPlayingSlideDirection(
        previousIndex: 2,
        currentIndex: 3,
        playlistLength: 5,
      ),
      MiniNowPlayingSlideDirection.next,
    );
  });

  test('resolves wrapped track changes without animating arbitrary jumps', () {
    expect(
      miniNowPlayingSlideDirection(
        previousIndex: 0,
        currentIndex: 4,
        playlistLength: 5,
      ),
      MiniNowPlayingSlideDirection.previous,
    );
    expect(
      miniNowPlayingSlideDirection(
        previousIndex: 4,
        currentIndex: 0,
        playlistLength: 5,
      ),
      MiniNowPlayingSlideDirection.next,
    );
    expect(
      miniNowPlayingSlideDirection(
        previousIndex: 1,
        currentIndex: 4,
        playlistLength: 5,
      ),
      MiniNowPlayingSlideDirection.none,
    );
  });
}
