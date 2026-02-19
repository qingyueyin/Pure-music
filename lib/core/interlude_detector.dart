import 'package:pure_music/lyric/lyric.dart';

class InterludeDetector {
  static const int defaultThresholdMs = 3000;

  static bool isInInterlude(
    Lyric lyric,
    Duration currentPosition, {
    int thresholdMs = defaultThresholdMs,
  }) {
    final lines = lyric.lines;
    if (lines.isEmpty) return false;

    final currentMs = currentPosition.inMilliseconds;

    int currentLineIndex = -1;
    for (int i = 0; i < lines.length; i++) {
      if (currentMs >= lines[i].start.inMilliseconds) {
        currentLineIndex = i;
      } else {
        break;
      }
    }

    if (currentLineIndex == -1) {
      return currentMs < lines.first.start.inMilliseconds &&
          (lines.first.start.inMilliseconds - currentMs) > thresholdMs;
    }

    if (currentLineIndex == lines.length - 1) {
      final lastLineEnd = lines.last.start.inMilliseconds +
          (lines.last.length?.inMilliseconds ?? 0);
      if (currentMs > lastLineEnd) {
        return (currentMs - lastLineEnd) > thresholdMs;
      }
      return false;
    }

    final currentLine = lines[currentLineIndex];
    final currentLineEnd =
        currentLine.start.inMilliseconds + (currentLine.length?.inMilliseconds ?? 0);
    final nextLineStart = lines[currentLineIndex + 1].start.inMilliseconds;
    final gap = nextLineStart - currentLineEnd;

    return currentMs > currentLineEnd &&
        currentMs < nextLineStart &&
        gap > thresholdMs;
  }

  static Duration? getNextLyricTime(
    Lyric lyric,
    Duration currentPosition,
  ) {
    final lines = lyric.lines;
    final currentMs = currentPosition.inMilliseconds;

    for (var line in lines) {
      if (line.start.inMilliseconds > currentMs) {
        return line.start;
      }
    }
    return null;
  }

  static Duration getInterludeRemaining(
    Lyric lyric,
    Duration currentPosition,
  ) {
    final lines = lyric.lines;
    if (lines.isEmpty) return Duration.zero;

    final currentMs = currentPosition.inMilliseconds;

    int currentLineIndex = -1;
    for (int i = 0; i < lines.length; i++) {
      if (currentMs >= lines[i].start.inMilliseconds) {
        currentLineIndex = i;
      } else {
        break;
      }
    }

    if (currentLineIndex == lines.length - 1) {
      if (currentMs >
          lines.last.start.inMilliseconds +
              (lines.last.length?.inMilliseconds ?? 0)) {
        return Duration.zero;
      }
    }

    if (currentLineIndex >= 0 && currentLineIndex < lines.length - 1) {
      final nextLineStart = lines[currentLineIndex + 1].start.inMilliseconds;
      final currentLineEnd = lines[currentLineIndex].start.inMilliseconds +
          (lines[currentLineIndex].length?.inMilliseconds ?? 0);
      if (currentMs < nextLineStart && currentMs > currentLineEnd) {
        return Duration(milliseconds: nextLineStart - currentMs);
      }
    }

    return Duration.zero;
  }
}
