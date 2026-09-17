import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_tile.dart';

void main() {
  test('interlude ticks skip a stale jump after the window was hidden', () {
    expect(shouldIgnoreStaleInterludeTick(Duration.zero), isFalse);
    expect(
      shouldIgnoreStaleInterludeTick(const Duration(milliseconds: 16)),
      isFalse,
    );
    expect(
      shouldIgnoreStaleInterludeTick(const Duration(milliseconds: 200)),
      isFalse,
    );
    expect(
      shouldIgnoreStaleInterludeTick(const Duration(seconds: 10)),
      isTrue,
    );
  });
}
