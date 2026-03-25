import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_viewport_strategy.dart';

void main() {
  test('LyricViewportStrategy creates buffered range around main line', () {
    const strategy = LyricViewportStrategy(
      leadingLines: 2,
      trailingLines: 3,
      overscanScreens: 1.25,
      userScrollHoldDuration: Duration(seconds: 2),
    );

    final range = strategy.rangeForMainLine(mainLine: 10, totalLines: 30);

    expect(range.start, 8);
    expect(range.end, 13);
    expect(range.contains(10), isTrue);
  });

  test('LyricViewportStrategy clamps range to list bounds', () {
    const strategy = LyricViewportStrategy(
      leadingLines: 3,
      trailingLines: 4,
      overscanScreens: 1.25,
      userScrollHoldDuration: Duration(seconds: 2),
    );

    expect(strategy.rangeForMainLine(mainLine: 1, totalLines: 5).start, 0);
    expect(strategy.rangeForMainLine(mainLine: 4, totalLines: 5).end, 4);
  });

  test('LyricViewportStrategy decides when realign is needed', () {
    const strategy = LyricViewportStrategy(
      leadingLines: 2,
      trailingLines: 2,
      overscanScreens: 1.25,
      userScrollHoldDuration: Duration(seconds: 2),
    );
    const currentRange = LyricViewportRange(start: 5, end: 9);

    expect(strategy.shouldRealign(currentRange, 7), isFalse);
    expect(strategy.shouldRealign(currentRange, 10), isTrue);
  });

  test('LyricViewportStrategy follow decision keeps auto-follow inside buffer',
      () {
    const strategy = LyricViewportStrategy(
      leadingLines: 2,
      trailingLines: 2,
      overscanScreens: 1.25,
      userScrollHoldDuration: Duration(seconds: 2),
    );
    const currentRange = LyricViewportRange(start: 5, end: 9);

    final decision = strategy.followDecision(
      currentRange: currentRange,
      nextMainLine: 7,
      totalLines: 30,
    );

    expect(decision.shouldScroll, isTrue);
    expect(decision.nextRange.start, 5);
    expect(decision.nextRange.end, 9);
  });

  test(
      'LyricViewportStrategy follow decision expands range when line leaves buffer',
      () {
    const strategy = LyricViewportStrategy(
      leadingLines: 2,
      trailingLines: 2,
      overscanScreens: 1.25,
      userScrollHoldDuration: Duration(seconds: 2),
    );
    const currentRange = LyricViewportRange(start: 5, end: 9);

    final decision = strategy.followDecision(
      currentRange: currentRange,
      nextMainLine: 11,
      totalLines: 30,
    );

    expect(decision.shouldScroll, isTrue);
    expect(decision.nextRange.start, 9);
    expect(decision.nextRange.end, 13);
  });

  test('LyricViewportStrategy derives cache extent from viewport height', () {
    const strategy = LyricViewportStrategy(
      leadingLines: 2,
      trailingLines: 2,
      overscanScreens: 1.5,
      userScrollHoldDuration: Duration(seconds: 2),
    );

    expect(strategy.cacheExtent(400), 600);
  });
}
