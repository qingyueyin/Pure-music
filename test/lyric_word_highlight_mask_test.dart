import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_word_highlight_mask.dart';

void main() {
  test(
      'LyricWordHighlightMask builds clamped stops from progress and fade width',
      () {
    const mask = LyricWordHighlightMask(progress: 0.45, fadeWidth: 0.12);

    expect(mask.shouldHighlight, isTrue);
    expect(mask.stops[0], 0.0);
    expect(mask.stops[1], 0.45);
    expect(mask.stops[2], closeTo(0.57, 1e-9));
    expect(mask.stops[3], 1.0);
  });

  test('LyricWordHighlightMask clamps fade tail at the right edge', () {
    const mask = LyricWordHighlightMask(progress: 0.96, fadeWidth: 0.12);

    expect(mask.stops, const [0.0, 0.96, 1.0, 1.0]);
  });

  test('LyricWordHighlightMask disables highlight when progress is zero', () {
    const mask = LyricWordHighlightMask(progress: 0.0, fadeWidth: 0.12);

    expect(mask.shouldHighlight, isFalse);
    expect(mask.stops, const [0.0, 0.0, 0.12, 1.0]);
  });

  test('LyricWordHighlightMask can derive fade width ratio from word metrics',
      () {
    final mask = LyricWordHighlightMask.fromMetrics(
      progress: 0.5,
      fadeScale: 0.5,
      wordWidth: 100,
      wordHeight: 20,
    );

    expect(mask.stops[1], 0.5);
    expect(mask.stops[2], closeTo(0.6, 1e-9));
  });
}
