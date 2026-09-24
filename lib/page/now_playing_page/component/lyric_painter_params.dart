import 'package:flutter/foundation.dart';

import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lyric.dart';

/// LyricsLinePainter 的不可变参数配置
///
/// 封装所有影响 painter 渲染的参数，用于缓存判断和 shouldRepaint。
@immutable
class LyricPainterParams {
  final LyricLine line;
  final double currentTimeMs;
  final ValueListenable<double>? currentTimeListenable;
  final ValueListenable<double>? backgroundVocalVisibilityListenable;
  final double blurSigma;
  final LyricRenderConfig config;
  final bool isMainLine;
  final bool isHighlightActive;
  final bool accelerateTailHighlight;
  final bool useMaterialYouColor;
  final String? fontFamily;
  final String? agent;
  final double opacity;
  final double? highlightDeadlineMs;
  final Duration lineMedianWordDuration;
  final ValueListenable<double>? liftDecayListenable;

  const LyricPainterParams({
    required this.line,
    required this.currentTimeMs,
    this.currentTimeListenable,
    this.backgroundVocalVisibilityListenable,
    required this.blurSigma,
    required this.config,
    required this.isMainLine,
    required this.isHighlightActive,
    required this.accelerateTailHighlight,
    required this.useMaterialYouColor,
    this.fontFamily,
    this.agent,
    required this.opacity,
    this.highlightDeadlineMs,
    required this.lineMedianWordDuration,
    this.liftDecayListenable,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LyricPainterParams &&
        other.line == line &&
        other.currentTimeListenable == currentTimeListenable &&
        other.backgroundVocalVisibilityListenable ==
            backgroundVocalVisibilityListenable &&
        (currentTimeListenable != null ||
            other.currentTimeMs == currentTimeMs) &&
        other.blurSigma == blurSigma &&
        other.config == config &&
        other.isMainLine == isMainLine &&
        other.isHighlightActive == isHighlightActive &&
        other.accelerateTailHighlight == accelerateTailHighlight &&
        other.useMaterialYouColor == useMaterialYouColor &&
        other.fontFamily == fontFamily &&
        other.agent == agent &&
        other.opacity == opacity &&
        other.highlightDeadlineMs == highlightDeadlineMs &&
        other.lineMedianWordDuration == lineMedianWordDuration &&
        other.liftDecayListenable == liftDecayListenable;
  }

  @override
  int get hashCode => Object.hash(
        line,
        currentTimeListenable,
        backgroundVocalVisibilityListenable,
        currentTimeListenable == null ? currentTimeMs : null,
        blurSigma,
        config,
        Object.hash(
          isMainLine,
          isHighlightActive,
          accelerateTailHighlight,
          useMaterialYouColor,
          fontFamily,
          agent,
        ),
        Object.hash(
          opacity,
          highlightDeadlineMs,
          lineMedianWordDuration,
          liftDecayListenable,
        ),
      );
}
