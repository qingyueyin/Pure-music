import 'dart:math';

class LyricWordHighlightMask {
  final double progress;
  final double fadeWidth;

  const LyricWordHighlightMask({
    required this.progress,
    required this.fadeWidth,
  });

  factory LyricWordHighlightMask.fromMetrics({
    required double progress,
    required double fadeScale,
    required double wordWidth,
    required double wordHeight,
  }) {
    final normalizedFadeWidth = wordWidth <= 0
        ? fadeScale
        : ((wordHeight * fadeScale) / wordWidth).clamp(0.0, 1.0).toDouble();
    return LyricWordHighlightMask(
      progress: progress,
      fadeWidth: normalizedFadeWidth,
    );
  }

  bool get shouldHighlight => progress > 0.0;

  List<double> get stops {
    final clampedProgress = progress.clamp(0.0, 1.0).toDouble();
    final clampedFadeWidth = fadeWidth.clamp(0.0, 1.0).toDouble();
    final fadeEnd = min(clampedProgress + clampedFadeWidth, 1.0);
    return <double>[0.0, clampedProgress, fadeEnd, 1.0];
  }
}
