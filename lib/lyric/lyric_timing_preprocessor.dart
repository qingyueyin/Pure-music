import 'dart:math';

import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';

class LyricTimingPreprocessResult {
  final List<int> rawLineStartMs;
  final List<int> effectiveLineStartMs;
  final List<int> lineEndMs;

  const LyricTimingPreprocessResult({
    required this.rawLineStartMs,
    required this.effectiveLineStartMs,
    required this.lineEndMs,
  });
}

class LyricTimingPreprocessor {
  final int advanceMs;
  final int interludeThresholdMs;
  final int interludeAdvanceCapMs;
  final int maxOverlapMs;
  final int minLineSpacingMs;

  const LyricTimingPreprocessor({
    this.advanceMs = 220,
    this.interludeThresholdMs = 3200,
    this.interludeAdvanceCapMs = 80,
    this.maxOverlapMs = 120,
    this.minLineSpacingMs = 16,
  });

  LyricTimingPreprocessResult preprocess(Lyric lyric) {
    if (lyric.lines.isEmpty) {
      return const LyricTimingPreprocessResult(
        rawLineStartMs: [],
        effectiveLineStartMs: [],
        lineEndMs: [],
      );
    }

    final rawStartMs =
        lyric.lines.map((line) => line.start.inMilliseconds).toList();
    final lineEndMs = _buildLineEndMs(lyric.lines, rawStartMs);
    final effectiveStartMs = List<int>.filled(rawStartMs.length, 0);

    for (var i = 0; i < rawStartMs.length; i++) {
      final rawStart = rawStartMs[i];
      if (i == 0) {
        effectiveStartMs[i] = max(rawStart, 0);
        continue;
      }

      final line = lyric.lines[i];
      final previousEffective = effectiveStartMs[i - 1];
      final previousEnd = lineEndMs[i - 1];
      final gapToPrevEnd = rawStart - previousEnd;

      var appliedAdvance = _shouldAdvanceLine(line) ? advanceMs : 0;
      if (gapToPrevEnd > interludeThresholdMs) {
        appliedAdvance = min(appliedAdvance, interludeAdvanceCapMs);
      }

      var candidate = rawStart - appliedAdvance;
      candidate = max(candidate, previousEffective + minLineSpacingMs);
      candidate = max(candidate, previousEnd - maxOverlapMs);
      effectiveStartMs[i] = max(candidate, 0);
    }

    return LyricTimingPreprocessResult(
      rawLineStartMs: rawStartMs,
      effectiveLineStartMs: effectiveStartMs,
      lineEndMs: lineEndMs,
    );
  }

  static List<int> _buildLineEndMs(List<LyricLine> lines, List<int> startMs) {
    final endMs = List<int>.filled(lines.length, 0);

    for (var i = 0; i < lines.length; i++) {
      final start = startMs[i];
      final durationMs = max(lines[i].length.inMilliseconds, 0);
      var naturalEnd = start + durationMs;
      if (naturalEnd <= start && i < lines.length - 1) {
        naturalEnd = max(startMs[i + 1], start);
      }
      endMs[i] = max(naturalEnd, start);
    }

    return endMs;
  }

  bool _shouldAdvanceLine(LyricLine line) {
    if (line is LrcLine) {
      return !line.isBlank;
    }
    if (line is SyncLyricLine) {
      return line.words.isNotEmpty;
    }
    if (line is UnsyncLyricLine) {
      return line.content.trim().isNotEmpty;
    }
    return true;
  }
}
