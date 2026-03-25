class LyricViewportRange {
  final int start;
  final int end;

  const LyricViewportRange({
    required this.start,
    required this.end,
  });

  bool contains(int line) => line >= start && line <= end;
}

class LyricViewportFollowDecision {
  final bool shouldScroll;
  final LyricViewportRange nextRange;

  const LyricViewportFollowDecision({
    required this.shouldScroll,
    required this.nextRange,
  });
}

class LyricViewportStrategy {
  final int leadingLines;
  final int trailingLines;
  final double overscanScreens;
  final Duration userScrollHoldDuration;

  const LyricViewportStrategy({
    required this.leadingLines,
    required this.trailingLines,
    required this.overscanScreens,
    required this.userScrollHoldDuration,
  });

  LyricViewportRange rangeForMainLine({
    required int mainLine,
    required int totalLines,
  }) {
    if (totalLines <= 0) {
      return const LyricViewportRange(start: 0, end: 0);
    }

    final clampedLine = mainLine.clamp(0, totalLines - 1);
    final start = (clampedLine - leadingLines).clamp(0, totalLines - 1);
    final end = (clampedLine + trailingLines).clamp(0, totalLines - 1);
    return LyricViewportRange(start: start, end: end);
  }

  bool shouldRealign(LyricViewportRange currentRange, int mainLine) {
    return !currentRange.contains(mainLine);
  }

  LyricViewportFollowDecision followDecision({
    required LyricViewportRange currentRange,
    required int nextMainLine,
    required int totalLines,
  }) {
    final nextRange = shouldRealign(currentRange, nextMainLine)
        ? rangeForMainLine(mainLine: nextMainLine, totalLines: totalLines)
        : currentRange;
    return LyricViewportFollowDecision(
      shouldScroll: true,
      nextRange: nextRange,
    );
  }

  double cacheExtent(double viewportHeight) {
    return viewportHeight * overscanScreens;
  }
}
