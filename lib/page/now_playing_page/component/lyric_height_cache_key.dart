import 'package:flutter/foundation.dart';

import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lyric.dart';

@immutable
class LyricHeightCacheKey {
  final LyricLine line;
  final double lineWidth;
  final LyricRenderConfig config;
  final bool isMainLine;
  final bool useMaterialYouColor;
  final bool reserveBackgroundVocalHeight;
  final String? fontFamily;
  final String? agent;

  const LyricHeightCacheKey({
    required this.line,
    required this.lineWidth,
    required this.config,
    required this.isMainLine,
    required this.useMaterialYouColor,
    required this.reserveBackgroundVocalHeight,
    required this.fontFamily,
    required this.agent,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LyricHeightCacheKey &&
        identical(other.line, line) &&
        other.lineWidth == lineWidth &&
        other.config == config &&
        other.isMainLine == isMainLine &&
        other.useMaterialYouColor == useMaterialYouColor &&
        other.reserveBackgroundVocalHeight == reserveBackgroundVocalHeight &&
        other.fontFamily == fontFamily &&
        other.agent == agent;
  }

  @override
  int get hashCode => Object.hash(
    identityHashCode(line),
    lineWidth,
    config,
    isMainLine,
    useMaterialYouColor,
    reserveBackgroundVocalHeight,
    fontFamily,
    agent,
  );
}
