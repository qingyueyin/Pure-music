import 'dart:math' show cos, exp, max, pi, sin, sqrt;

import 'package:flutter/foundation.dart'
    show Listenable, ValueListenable, visibleForTesting;
import 'package:flutter/material.dart';

import 'package:pure_music/core/app_fonts.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/zh_converter.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_painter_params.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/play_service/lyric_service.dart'
    show lyricHighlightCatchUpDurationMs, lyricHighlightFinishLeadMs;

const lyricBackgroundVocalEntryDuration = Duration(milliseconds: 400);
const _bgEntryDuration = 400.0;
const lyricBackgroundVocalExitDuration = Duration(milliseconds: 400);

bool lyricLineHasBackgroundVocal(LyricLine line) {
  if (line is! SyncLyricLine) return false;
  return line.bgWords.isNotEmpty ||
      line.bgText?.isNotEmpty == true ||
      line.bgTranslation?.isNotEmpty == true ||
      line.bg != null;
}

double lyricBackgroundStartMs(SyncLyricLine line) {
  return (line.bgStart ?? line.bg?.start ?? line.start).inMilliseconds
      .toDouble();
}

double lyricBackgroundEndMs(SyncLyricLine line) {
  var end = (line.bgEnd ?? line.bg?.end ?? (line.start + line.length))
      .inMilliseconds
      .toDouble();
  if (line.bgWords.isNotEmpty) {
    final last = line.bgWords.last;
    final lastEnd = (last.start.inMilliseconds + last.length.inMilliseconds)
        .toDouble();
    if (lastEnd > end) end = lastEnd;
  }
  return end;
}

double lyricBackgroundExitVisibility(double elapsedMs) {
  final progress = (elapsedMs / lyricBackgroundVocalExitDuration.inMilliseconds)
      .clamp(0.0, 1.0);
  return 1.0 - Curves.easeInCubic.transform(progress);
}

double lyricBackgroundExitElapsedMs(double visibility) {
  final target = visibility.clamp(0.0, 1.0);
  final duration = lyricBackgroundVocalExitDuration.inMilliseconds.toDouble();
  if (target >= 0.999) return 0.0;
  if (target <= 0.001) return duration;
  var lo = 0.0;
  var hi = duration;
  for (var i = 0; i < 16; i++) {
    final mid = (lo + hi) / 2;
    if (lyricBackgroundExitVisibility(mid) > target) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return (lo + hi) / 2;
}

double lyricBackgroundHeightFactor({
  required double currentTimeMs,
  required double startMs,
  required double endMs,
  required bool isMainLine,
  bool isBackgroundActive = false,
  bool? isBackgroundVisible,
  double? exitVisibility,
}) {
  if (exitVisibility != null) return exitVisibility.clamp(0.0, 1.0);
  if (endMs <= startMs) return 0.0;
  // 显示跟主行：主行还在当前组时，不按 bg 自己的结束时间提前收。
  // TTML 用 isBackgroundVisible；其他格式没有组标记时，当前主行也可托住。
  final hosted = isMainLine || isBackgroundVisible == true;
  if (!hosted || currentTimeMs < startMs) return 0.0;
  return Curves.easeOutBack.transform(
    ((currentTimeMs - startMs) / _bgEntryDuration).clamp(0.0, 1.0),
  );
}

@visibleForTesting
List<double> debugLyricCharYLifts = const [];

@visibleForTesting
double? debugLyricTranslationY;

double lyricExitLift(double lastLift, double floatProgress) {
  if (lastLift == 0) return 0;
  final t = floatProgress.clamp(0.0, 1.0);
  return lastLift * t;
}

double lyricGatedLiftPx(double lift, double gate) {
  if (gate <= 0) return 0;
  if (gate >= 1) return lift;
  return lift * gate;
}

const lyricEffectWarpLead = 0.08;
const lyricLiftSettleEpsilon = 0.004;
const lyricGlowHoldFadeMs = 200.0;

double lyricWordProgress({
  required double nowMs,
  required double wordStartMs,
  required double wordEndMs,
}) {
  if (nowMs < wordStartMs) return 0.0;
  if (nowMs >= wordEndMs) return 1.0;
  final duration = wordEndMs - wordStartMs;
  if (duration <= 0) return 1.0;
  return ((nowMs - wordStartMs) / duration).clamp(0.0, 1.0);
}

double lyricCharWaveProgress({
  required double wordProgress,
  required int charIndex,
  required int charCount,
}) {
  const stepRatio = 0.1;
  final n = charCount < 1 ? 1 : charCount;
  final waveWidth = 1.0 / (stepRatio * (n - 1) + 1.0);
  final windowStart = charIndex * stepRatio * waveWidth;
  return ((wordProgress - windowStart) / waveWidth).clamp(0.0, 1.0);
}

/// 缩放/辉光仍走字波浪进度，只限制尾加速最多超前实时进度。
double lyricCappedEffectProgress({
  required double warpedProgress,
  required double realProgress,
}) {
  if (warpedProgress <= realProgress) return warpedProgress;
  final capped = (realProgress + lyricEffectWarpLead).clamp(0.0, 1.0);
  return warpedProgress < capped ? warpedProgress : capped;
}

double lyricExitScale(double scale, double exitProgress) {
  final t = exitProgress.clamp(0.0, 1.0);
  return 1.0 + (scale - 1.0) * t;
}

double lyricExitGlowAlpha(double alpha, double exitProgress) {
  return alpha * exitProgress.clamp(0.0, 1.0);
}

bool lyricVerticalLiftSettled({
  required double nowMs,
  required double wordStartMs,
  required double wordDurationSec,
  required int syllableCount,
  required bool softLift,
  required double liftPeak,
}) {
  final n = syllableCount < 1 ? 1 : syllableCount;
  final lift = lyricVerticalCharLiftPx(
    nowMs: nowMs,
    wordStartMs: wordStartMs,
    wordDurationSec: wordDurationSec,
    syllableIndex: n - 1,
    syllableCount: n,
    softLift: softLift,
    liftPeak: liftPeak,
  );
  return (lift + liftPeak).abs() <= 0.02;
}

bool lyricLineEffectsNeedFrame({
  required Iterable<SyncLyricWord> words,
  required double nowMs,
  required Duration lineMedianDuration,
  required bool enableGlow,
  required bool liftActive,
  required double liftPeak,
}) {
  var index = 0;
  final count = words.length;
  var lastWordEndMs = 0.0;
  var hasScaleGlow = false;
  for (final word in words) {
    final start = word.start.inMilliseconds.toDouble();
    final durationMs = word.length.inMilliseconds.toDouble();
    final end = start + durationMs;
    if (end > lastWordEndMs) lastWordEndMs = end;
    if (nowMs >= start && nowMs <= end) return true;
    if (liftActive && durationMs > 0) {
      if (!lyricVerticalLiftSettled(
        nowMs: nowMs,
        wordStartMs: start,
        wordDurationSec: durationMs / 1000.0,
        syllableCount: lyricSungUnitCount(word.content).clamp(1, 64),
        softLift: lyricUsesSoftLift(word.content),
        liftPeak: liftPeak,
      )) {
        return true;
      }
    }
    if (enableGlow) {
      final effect = lyricWordEffect(
        duration: word.length,
        lineMedianDuration: lineMedianDuration,
        isLineEnding: index == count - 1,
        sungUnitCount: lyricSungUnitCount(word.content),
      );
      if (effect != LyricWordEffect.none) {
        hasScaleGlow = true;
        final progress = lyricWordProgress(
          nowMs: nowMs,
          wordStartMs: start,
          wordEndMs: end,
        );
        if (progress > 0.0 && progress < 1.0) return true;
      }
    }
    index++;
  }
  if (enableGlow &&
      hasScaleGlow &&
      nowMs >= lastWordEndMs - lyricHighlightCatchUpDurationMs &&
      nowMs <=
          lastWordEndMs + lyricHighlightFinishLeadMs + lyricGlowHoldFadeMs) {
    return true;
  }
  return false;
}

// 汉字和假名用更慢的音节错开，不含谚文。
bool lyricUsesSoftLift(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x3040 && rune <= 0x30FF) ||
        (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0x4E00 && rune <= 0x9FFF)) {
      return true;
    }
  }
  return false;
}

double lyricDurationLiftSpring(double tSec, double wordDurationSec) {
  if (tSec <= 0) return 0;
  final d = wordDurationSec < 0.001
      ? 0.001
      : (wordDurationSec > 3.0 ? 3.0 : wordDurationSec);
  final w = 2 * pi / d;
  final value = 1 - (1 + w * tSec) * exp(-w * tSec);
  return value >= 1 - lyricLiftSettleEpsilon ? 1.0 : value;
}

double lyricSoftLiftSpring(double tSec) {
  if (tSec <= 0) return 0;
  const stiffness = 14.0;
  const damping = 7.0;
  final omega0 = sqrt(stiffness);
  final zeta = damping / (2 * omega0);
  final wd = omega0 * sqrt(1 - zeta * zeta);
  final decay = exp(-zeta * omega0 * tSec);
  final b = -zeta * omega0 / wd;
  final value = 1 + decay * (-cos(wd * tSec) + b * sin(wd * tSec));
  return value >= 1 - lyricLiftSettleEpsilon ? 1.0 : value;
}

// 按词时长错开抬升，抬满后停住；组内保持仍由行状态负责。
double lyricVerticalCharLiftPx({
  required double nowMs,
  required double wordStartMs,
  required double wordDurationSec,
  required int syllableIndex,
  required int syllableCount,
  required bool softLift,
  required double liftPeak,
}) {
  final n = syllableCount < 1 ? 1 : syllableCount;
  final d = wordDurationSec <= 0 ? 0.001 : wordDurationSec;
  final step = d / n * (softLift ? 0.8 : 0.4);
  final tSec = (nowMs - wordStartMs) / 1000.0 - (syllableIndex + 1) * step;
  final spring = softLift
      ? lyricSoftLiftSpring(tSec)
      : lyricDurationLiftSpring(tSec, d);
  return -spring * liftPeak;
}

const lyricLiftWindowFonts = 3.0;

double lyricCosineLiftPx({
  required double charCenter,
  required double cursorX,
  required double lineEndX,
  required double fontSize,
  required double liftPeak,
  double? lineLeft,
}) {
  final windowPx = lyricLiftWindowFonts * fontSize;
  final lead = windowPx / 2;
  // 行首没有窗口前的那段距离。不把起点夹到行左边，第一个字会从曲线最陡处弹起。
  final rampStart = lineLeft == null
      ? charCenter - lead
      : (lineLeft > charCenter - lead ? lineLeft : charCenter - lead);
  final u = 1 - (cursorX - rampStart) / windowPx;
  final remaining = lineEndX - cursorX;
  final q = remaining < windowPx / 2
      ? (1.0 - remaining / (windowPx / 2)).clamp(0.0, 1.0)
      : 0.0;
  final q2 = q * q;
  final factor = switch (u) {
    <= 0.0 => 1.0,
    >= 1.0 => 0.0,
    _ => cos(pi * u) * (1 - q2) / 2 + (1 + q2) / 2,
  };
  final maxLift = (liftPeak / 2.0 * 0.10 * fontSize).roundToDouble();
  return -(factor * maxLift);
}

@visibleForTesting
double lyricFollowLiftCursor({
  required double target,
  required double previous,
  required double fontSize,
  required bool restoreFromPlayback,
}) {
  if (restoreFromPlayback) return target;
  final limit = fontSize * 0.45;
  return previous + (target - previous).clamp(-limit, limit);
}

class LyricCharLiftCache {
  List<double> values = const [];
  List<double> effectProgress = const [];
  double? cursor;
  final Map<int, double> rowCursors = {};
  bool restoreCursorFromPlayback = false;

  void resetCursor() {
    cursor = null;
    rowCursors.clear();
  }
}

double lyricHighlightTimeMs({
  required double currentTimeMs,
  required double lineStartMs,
  required double lastWordEndMs,
  required double? deadlineMs,
  bool usesAuthoredTiming = false,
}) {
  if (usesAuthoredTiming) return currentTimeMs;
  if (deadlineMs == null || deadlineMs <= lineStartMs) return currentTimeMs;
  if (lastWordEndMs < deadlineMs - lyricHighlightFinishLeadMs ||
      currentTimeMs < deadlineMs - lyricHighlightCatchUpDurationMs) {
    return currentTimeMs;
  }
  final catchUpStart = deadlineMs - lyricHighlightCatchUpDurationMs;
  final catchUpEnd = deadlineMs - lyricHighlightFinishLeadMs;
  final t = ((currentTimeMs - catchUpStart) / (catchUpEnd - catchUpStart))
      .clamp(0.0, 1.0);
  final eased = Curves.easeIn.transform(t);
  final targetEnd = max(lastWordEndMs, deadlineMs);
  final adjusted = currentTimeMs + (targetEnd - currentTimeMs) * eased;
  return adjusted < currentTimeMs ? currentTimeMs : adjusted;
}

/// 折行后按整词字符顺序计算本段应点亮的字数，避免两行按同一进度并排高亮。
double lyricWrappedWordReveal({
  required double wordProgress,
  required int wordCharIndex,
  required int segmentLength,
  required int wordPlacedCount,
}) {
  if (segmentLength <= 0 || wordPlacedCount <= 0) return 0.0;
  final wp = wordProgress.clamp(0.0, 1.0);
  if (wp <= 0.0) return 0.0;
  final globalReveal = wordPlacedCount * wp;
  return (globalReveal - wordCharIndex).clamp(0.0, segmentLength.toDouble());
}

/// 折行按缩放后的可视宽度算，避免当前行放大后顶出栏外。
double lyricScaledContentWidth({
  required double layoutWidth,
  required double scale,
  required double paddingHorizontal,
}) {
  final safeScale = scale <= 0 ? 1.0 : scale;
  final width = layoutWidth / safeScale - paddingHorizontal;
  return width < 1.0 ? 1.0 : width;
}

/// 已播放和未播放用同一套折行宽度，取更大缩放以免当前行顶出。
double lyricUnifiedWrapScale({
  required double activeScale,
  required double inactiveScale,
}) {
  final active = activeScale <= 0 ? 1.0 : activeScale;
  final inactive = inactiveScale <= 0 ? 1.0 : inactiveScale;
  return active > inactive ? active : inactive;
}

/// 折行字号取主行/副行里更大的那个，避免切到当前行时字变大把词挤去下一行。
double lyricLayoutFontSize({
  required double mainFontSize,
  required double subFontSize,
}) {
  final main = mainFontSize <= 0 ? 1.0 : mainFontSize;
  final sub = subFontSize <= 0 ? 1.0 : subFontSize;
  return main > sub ? main : sub;
}

/// 从行顶放大，切到当前行时字往下长，不会整行往上跳。
Alignment lyricLineScaleAlignment(LyricTextAlign align) {
  return switch (align) {
    LyricTextAlign.left => Alignment.topLeft,
    LyricTextAlign.center => Alignment.topCenter,
    LyricTextAlign.right => Alignment.topRight,
  };
}

enum LyricWordEffect { none, scale, scaleAndGlow }

bool _isCjkSungSyllable(String grapheme) {
  if (grapheme.isEmpty) return false;
  final rune = grapheme.runes.first;
  return (rune >= 0x3400 && rune <= 0x9FFF) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0x3040 && rune <= 0x30FF) ||
      (rune >= 0x31F0 && rune <= 0x31FF) ||
      (rune >= 0xAC00 && rune <= 0xD7AF);
}

bool _isLatinLetter(String grapheme) {
  if (grapheme.isEmpty) return false;
  final rune = grapheme.runes.first;
  return (rune >= 0x41 && rune <= 0x5A) ||
      (rune >= 0x61 && rune <= 0x7A) ||
      (rune >= 0xC0 && rune <= 0x024F);
}

bool _continuesLatinWord(String grapheme) {
  return grapheme == "'" || grapheme == '’' || grapheme == '-';
}

/// 汉字、假名、谚文各算一个演唱单位，连续拉丁字母算一个。
int lyricSungUnitCount(String content) {
  var units = 0;
  var inLatin = false;
  for (final char in content.characters) {
    if (_isCjkSungSyllable(char)) {
      if (inLatin) {
        units++;
        inLatin = false;
      }
      units++;
    } else if (_isLatinLetter(char) || (inLatin && _continuesLatinWord(char))) {
      inLatin = true;
    } else if (inLatin) {
      units++;
      inLatin = false;
    }
  }
  if (inLatin) units++;
  return units;
}

LyricWordEffect lyricWordEffect({
  required Duration duration,
  required Duration lineMedianDuration,
  required bool isLineEnding,
  int sungUnitCount = 1,
}) {
  const scaleFloor = Duration(milliseconds: 750);
  const scaleThreshold = Duration(milliseconds: 950);
  const glowFloor = Duration(milliseconds: 1200);
  const glowThreshold = Duration(milliseconds: 1600);
  if (duration <= Duration.zero) return LyricWordEffect.none;

  // 行尾时间戳会把整句收成一个词。辉光缩放只作用于单个字或单个拉丁词。
  if (sungUnitCount > 1) return LyricWordEffect.none;

  final medianMicros = lineMedianDuration.inMicroseconds;
  final relativeDuration = medianMicros > 0
      ? duration.inMicroseconds / medianMicros
      : 1.0;
  final isRelativeGlow = duration >= glowFloor && relativeDuration >= 2.4;
  final isEndingGlow =
      isLineEnding && duration >= glowFloor && relativeDuration >= 1.8;
  if (duration >= glowThreshold || isRelativeGlow || isEndingGlow) {
    return LyricWordEffect.scaleAndGlow;
  }
  if (duration >= scaleThreshold ||
      (duration >= scaleFloor && relativeDuration >= 1.8)) {
    return LyricWordEffect.scale;
  }
  return LyricWordEffect.none;
}

double lyricCharacterScale({
  required LyricWordEffect effect,
  required Duration duration,
  required Duration lineMedianDuration,
  required double progress,
}) {
  if (effect == LyricWordEffect.none || progress <= 0.0 || progress >= 1.0) {
    return 1.0;
  }
  final strength = _lyricWordEffectStrength(duration, lineMedianDuration);
  final maxScale = switch (effect) {
    LyricWordEffect.none => 1.0,
    LyricWordEffect.scale => 1.12 + 0.08 * strength,
    LyricWordEffect.scaleAndGlow => 1.15 + 0.11 * strength,
  };
  return 1.0 + (maxScale - 1.0) * _lyricEffectParabola(progress);
}

double _lyricWordEffectStrength(
  Duration duration,
  Duration lineMedianDuration,
) {
  final absoluteStrength = ((duration.inMilliseconds - 750) / 1750)
      .clamp(0.0, 1.0)
      .toDouble();
  final medianMicros = lineMedianDuration.inMicroseconds;
  final relativeDuration = medianMicros > 0
      ? duration.inMicroseconds / medianMicros
      : 1.0;
  final relativeStrength = ((relativeDuration - 1.8) / 1.7)
      .clamp(0.0, 1.0)
      .toDouble();
  return max(absoluteStrength, relativeStrength);
}

/// 前半鼓起到峰值，中段托住，尾段按抛物线右半段收回。
double _lyricEffectParabola(double progress) {
  if (progress <= 0.0 || progress >= 1.0) return 0.0;
  const riseEnd = 0.5;
  const releaseStart = 0.62;
  if (progress < riseEnd) {
    final t = progress / riseEnd;
    return t * t * (3.0 - 2.0 * t);
  }
  if (progress <= releaseStart) return 1.0;
  final t = (progress - releaseStart) / (1.0 - releaseStart);
  return 1.0 - t * t;
}

Duration lyricMedianWordDuration(List<SyncLyricWord> words) {
  final durations =
      words
          .map((word) => word.length.inMicroseconds)
          .where((duration) => duration > 0)
          .toList()
        ..sort();
  if (durations.isEmpty) return Duration.zero;
  final middle = durations.length ~/ 2;
  final medianMicros = durations.length.isOdd
      ? durations[middle]
      : (durations[middle - 1] + durations[middle]) ~/ 2;
  return Duration(microseconds: medianMicros);
}

List<LyricLineTrack> _activeLineTracks(
  LyricRenderConfig config, {
  required bool hasTranslation,
  required bool hasRoman,
}) {
  return config.normalizedLineOrder.where((t) {
    switch (t) {
      case LyricLineTrack.original:
        return true;
      case LyricLineTrack.translation:
        return config.showTranslation && hasTranslation;
      case LyricLineTrack.romanization:
        return config.showRoman && hasRoman;
    }
  }).toList();
}

List<LyricLineTrack> _postOriginalTracks(List<LyricLineTrack> active) {
  return active.skipWhile((t) => t != LyricLineTrack.original).skip(1).toList();
}

List<LyricLineTrack> _preOriginalTracks(List<LyricLineTrack> active) {
  return active.takeWhile((t) => t != LyricLineTrack.original).toList();
}

class _CharInfo {
  final String char;
  final double x;
  final double y;
  final double width;
  double yLift;
  final double charProgress;
  final double wordProgress;
  double effectProgress;
  final int wordIndex;
  final int wordCharIndex;
  final double wordDurationSec; // 词时长（秒），用于逐字效果分档

  _CharInfo({
    required this.char,
    required this.x,
    required this.y,
    required this.width,
    required this.yLift,
    required this.charProgress,
    required this.wordProgress,
    required this.effectProgress,
    required this.wordIndex,
    required this.wordCharIndex,
    required this.wordDurationSec,
  });
}

class _LineGroup {
  final double y;
  final List<_CharInfo> chars;

  _LineGroup({required this.y, required this.chars});
}

class _WordPaintInfo {
  final List<_CharInfo> chars;
  final String text;
  bool hasLift;
  final double wordProgress;
  final double wordDurationSec;

  _WordPaintInfo({
    required this.chars,
    required this.text,
    required this.hasLift,
    required this.wordProgress,
    required this.wordDurationSec,
  });

  int get length => chars.length;
  _CharInfo get first => chars.first;
  _CharInfo get last => chars.last;
}

bool _isZeroWidth(String ch) {
  if (ch.isEmpty) return false;
  final c = ch.codeUnitAt(0);
  return c == 0x200B || // zero width space
      c == 0x200C || // zero width non-joiner
      c == 0x200D || // zero width joiner
      c == 0x2060 || // word joiner
      c == 0xFEFF || // zero width no-break space
      c == 0x00AD; // soft hyphen
}

bool _isPunctuation(String ch) {
  if (ch.isEmpty) return false;
  final c = ch.codeUnitAt(0);
  return (c >= 0x2000 && c <= 0x206F) ||
      (c >= 0x3000 && c <= 0x303F) ||
      (c >= 0xFF00 && c <= 0xFFEF) ||
      c == 0x002C || // ,
      c == 0x002E || // .
      c == 0x0021 || // !
      c == 0x003F || // ?
      c == 0x003B || // ;
      c == 0x003A || // :
      c == 0x0027 || // '
      c == 0x0022 || // "
      c == 0xFF0C || // ，
      c == 0x3002 || // 。
      c == 0xFF01 || // ！
      c == 0xFF1F || // ？
      c == 0x3001 || // 、
      c == 0xFF1B || // ；
      c == 0xFF1A || // ：
      c == 0x300C || // 「
      c == 0x300D || // 」
      c == 0x300E || // 『
      c == 0x300F || // 』
      c == 0x2018 || // '
      c == 0x2019 || // '
      c == 0x201C || // "
      c == 0x201D || // "
      c == 0x2026 || // …
      c == 0x2014 || // —
      c == 0x2013 || // –
      c == 0x3010 || // 【
      c == 0x3011 || // 】
      c == 0xFF08 || // （
      c == 0xFF09 || // ）
      c == 0x300A || // 《
      c == 0x300B || // 》
      c == 0x0028 || // (
      c == 0x0029 || // )
      c == 0x005B || // [
      c == 0x005D; // ]
}

class LyricWordLayoutCursor {
  LyricWordLayoutCursor({
    required this.x,
    required this.y,
    required this.firstOnLine,
    this.visualLineCount = 1,
  });

  double x;
  double y;
  bool firstOnLine;
  int visualLineCount;
}

bool _isWrapTokenChar(String char) => char != ' ' && !_isZeroWidth(char);

double _tokenWidthFrom(List<String> chars, List<double> widths, int start) {
  var width = 0.0;
  for (int i = start; i < chars.length && i < widths.length; i++) {
    if (!_isWrapTokenChar(chars[i])) break;
    width += widths[i];
  }
  return width;
}

/// 超宽逐词按空格折行，无空格才按字切。短词保持整词不拆。
void layoutTimedWordChars({
  required List<String> chars,
  required List<double> widths,
  required double contentLeft,
  required double contentRight,
  required double lineHeight,
  required LyricWordLayoutCursor cursor,
  void Function(int index, double x, double y)? onPlace,
}) {
  void wrap() {
    cursor.x = contentLeft;
    cursor.y += lineHeight;
    cursor.firstOnLine = true;
    cursor.visualLineCount++;
  }

  for (int i = 0; i < chars.length && i < widths.length; i++) {
    final char = chars[i];
    final width = widths[i];
    if (_isZeroWidth(char)) continue;
    if (char == ' ' && cursor.firstOnLine) continue;

    final tokenStart =
        _isWrapTokenChar(char) && (i == 0 || !_isWrapTokenChar(chars[i - 1]));
    if (tokenStart &&
        !cursor.firstOnLine &&
        cursor.x + _tokenWidthFrom(chars, widths, i) > contentRight - 1.0) {
      wrap();
    }

    if (!cursor.firstOnLine && cursor.x + width > contentRight - 1.0) {
      wrap();
      if (char == ' ') continue;
    }

    onPlace?.call(i, cursor.x, cursor.y);
    cursor.x += width;
    cursor.firstOnLine = false;
  }
}

class LyricsLinePainter extends CustomPainter {
  final LyricPainterParams params;
  final ColorScheme scheme;
  final LyricCharLiftCache? liftCache;

  // 快捷访问器，避免大面积修改 paint 逻辑
  LyricLine get line => params.line;
  double get currentTimeMs => params.currentTimeMs;
  ValueListenable<double>? get currentTimeListenable =>
      params.currentTimeListenable;
  ValueListenable<double>? get backgroundVocalVisibilityListenable =>
      params.backgroundVocalVisibilityListenable;
  double get blurSigma => params.blurSigmaListenable?.value ?? params.blurSigma;
  LyricRenderConfig get config => params.config;
  bool get isMainLine => params.isMainLine;
  bool get isHighlightActive => params.isHighlightActive;
  bool get isMainVocalActive => params.isMainVocalActive ?? isHighlightActive;
  bool get isBackgroundActive => params.isBackgroundActive;
  bool get accelerateTailHighlight => params.accelerateTailHighlight;
  bool get useMaterialYouColor => params.useMaterialYouColor;
  String? get fontFamily => params.fontFamily;
  String? get agent => params.agent;
  double get opacity => params.opacity;
  double? get highlightDeadlineMs => params.highlightDeadlineMs;
  Duration get lineMedianWordDuration => params.lineMedianWordDuration;
  ValueListenable<double>? get liftDecayListenable =>
      params.liftDecayListenable;
  ValueListenable<double>? get liftGateListenable => params.liftGateListenable;

  // 多声部时按 agent 强制对齐：v1 左对齐，v2 右对齐
  LyricTextAlign get _effectiveTextAlign {
    if (config.hasMultipleAgents) {
      if (agent == 'v2') return LyricTextAlign.right;
      if (agent == 'v1') return LyricTextAlign.left;
    }
    return config.textAlign;
  }

  // 复用 TextPainter 实例，避免频繁创建销毁
  static final _textPainterPool = <TextPainter>[];
  static const _maxPoolSize = 12;
  static int _poolHitCount = 0;
  static int _poolMissCount = 0;
  static final _measureCache = <String, double>{};
  static const _maxMeasureCacheSize = 500;
  static final _blurFilterCache = <double, MaskFilter>{};
  static const _maxBlurFilterCacheSize = 24;
  static final _blurPaintCache = <int, Paint>{};
  static const _maxBlurPaintCacheSize = 64;

  LyricsLinePainter({
    required this.params,
    required this.scheme,
    this.liftCache,
  }) : super(
         repaint: Listenable.merge([
           params.currentTimeListenable,
           params.backgroundVocalVisibilityListenable,
           params.liftDecayListenable,
           params.liftGateListenable,
           params.blurSigmaListenable,
         ]),
       );

  double get _effectiveCurrentTimeMs =>
      currentTimeListenable?.value ?? currentTimeMs;

  // 每一视觉行单独追上自己的唱标。折行后的字横坐标又从左边开始，不能共用上一行的唱标。
  double _followLiftCursor(
    double target,
    double fontSize, {
    required double originX,
    required int row,
  }) {
    final cache = liftCache;
    if (cache == null) return target;
    final prev = cache.rowCursors[row] ?? originX;
    final next = lyricFollowLiftCursor(
      target: target,
      previous: prev,
      fontSize: fontSize,
      restoreFromPlayback: cache.restoreCursorFromPlayback,
    );
    cache.rowCursors[row] = next;
    return next;
  }

  double get _opacityFactor => opacity.clamp(0.0, 1.0).toDouble();

  Color _applyOpacity(Color color) {
    final factor = _opacityFactor;
    if (factor >= 0.999) return color;
    return color.withValues(alpha: color.a * factor);
  }

  Color _unplayedLyricColor({
    required bool isDarkMode,
    required Color neutralBase,
  }) {
    // 深色主行未唱提高不透明度；浅色黑字保持原值，避免糊成一块
    final double alpha;
    if (isMainLine) {
      alpha = useMaterialYouColor
          ? (isDarkMode ? 0.55 : 0.50)
          : (isDarkMode ? 0.55 : 0.45);
    } else {
      alpha = useMaterialYouColor
          ? (isDarkMode ? 0.40 : 0.50)
          : (isDarkMode ? 0.35 : 0.45);
    }
    return _applyOpacity(
      useMaterialYouColor
          ? scheme.onSurface.withValues(alpha: alpha)
          : neutralBase.withValues(alpha: alpha),
    );
  }

  Paint? _blurForeground(Color color) {
    if (blurSigma <= 0.01 || color.a <= 0.0) return null;
    final sigmaKey = (blurSigma * 10).round();
    final key = color.toARGB32() * 31 + sigmaKey;
    final cached = _blurPaintCache[key];
    if (cached != null) {
      _blurPaintCache.remove(key);
      _blurPaintCache[key] = cached;
      return cached;
    }
    final paint = Paint()
      ..color = color
      ..maskFilter = _blurFilter(blurSigma);
    if (_blurPaintCache.length >= _maxBlurPaintCacheSize) {
      _blurPaintCache.remove(_blurPaintCache.keys.first);
    }
    _blurPaintCache[key] = paint;
    return paint;
  }

  TextStyle _textStyle({
    required Color color,
    required double fontSize,
    required FontWeight fontWeight,
    double letterSpacing = 0,
    double? height,
    List<Shadow>? shadows,
  }) {
    final foreground = _blurForeground(color);
    final family = lyricRenderFontFamily(fontFamily);
    return TextStyle(
      fontFamily: family,
      fontFamilyFallback: appFontFamilyFallback(family),
      fontSize: fontSize,
      color: foreground == null ? color : null,
      foreground: foreground,
      fontWeight: fontWeight,
      letterSpacing: letterSpacing,
      shadows: shadows,
      height: height,
      fontVariations: lyricWeightVariations(family, fontWeight.value),
    );
  }

  TextStyle _copyTextStyleWithForeground(
    TextStyle base,
    Paint foreground, {
    List<Shadow>? shadows,
  }) {
    return TextStyle(
      fontFamily: base.fontFamily,
      fontFamilyFallback: base.fontFamilyFallback,
      fontSize: base.fontSize,
      foreground: foreground,
      fontWeight: base.fontWeight,
      letterSpacing: base.letterSpacing,
      shadows: shadows ?? base.shadows,
      height: base.height,
      fontVariations: base.fontVariations,
    );
  }

  Color _styleColor(TextStyle style, Color fallback) {
    return style.color ?? style.foreground?.color ?? fallback;
  }

  /// 清空对象池（歌曲切换时调用）
  static void clearPool() {
    for (final tp in _textPainterPool) {
      tp.dispose();
    }
    _textPainterPool.clear();
    _poolHitCount = 0;
    _poolMissCount = 0;
    _measureCache.clear();
    _blurFilterCache.clear();
    _blurPaintCache.clear();
  }

  /// 压缩对象池（主动瘦身，保留最少必要对象）
  static void trimPool() {
    // 只保留 1 个对象，其余全部释放
    while (_textPainterPool.length > 1) {
      final tp = _textPainterPool.removeAt(0);
      tp.dispose();
    }
    while (_blurFilterCache.length > 4) {
      _blurFilterCache.remove(_blurFilterCache.keys.first);
    }
    while (_blurPaintCache.length > 16) {
      _blurPaintCache.remove(_blurPaintCache.keys.first);
    }
  }

  void _paintStableGlyph({
    required Canvas canvas,
    required TextPainter tp,
    required String char,
    required TextStyle style,
    required Offset offset,
  }) {
    tp.text = TextSpan(text: char, style: style);
    tp.layout();
    tp.paint(canvas, offset);
  }

  static MaskFilter _blurFilter(double sigma) {
    final key = (sigma * 10).roundToDouble() / 10;
    final cached = _blurFilterCache[key];
    if (cached != null) {
      _blurFilterCache.remove(key);
      _blurFilterCache[key] = cached;
      return cached;
    }
    if (_blurFilterCache.length >= _maxBlurFilterCacheSize) {
      _blurFilterCache.remove(_blurFilterCache.keys.first);
    }
    return _blurFilterCache[key] = MaskFilter.blur(BlurStyle.normal, key);
  }

  /// 获取池使用统计（用于调试和优化）
  static String getPoolStats() {
    final total = _poolHitCount + _poolMissCount;
    final hitRate = total > 0
        ? (_poolHitCount / total * 100).toStringAsFixed(1)
        : '0.0';
    return 'Pool: size=${_textPainterPool.length}/$_maxPoolSize, hit=$hitRate%';
  }

  double _bgOpacity(SyncLyricLine syncLine) {
    return _bgHeightFactor(syncLine);
  }

  double _bgHeightFactor(SyncLyricLine syncLine) {
    return lyricBackgroundHeightFactor(
      currentTimeMs: _effectiveCurrentTimeMs,
      startMs: lyricBackgroundStartMs(syncLine),
      endMs: lyricBackgroundEndMs(syncLine),
      isMainLine: isMainLine,
      isBackgroundActive: isBackgroundActive,
      isBackgroundVisible: params.isBackgroundVisible,
      exitVisibility: backgroundVocalVisibilityListenable?.value,
    );
  }

  static TextPainter obtainTextPainter() {
    if (_textPainterPool.isNotEmpty) {
      _poolHitCount++;
      return _textPainterPool.removeLast();
    }
    _poolMissCount++;
    return TextPainter(textDirection: TextDirection.ltr);
  }

  static void recycleTextPainter(TextPainter tp) {
    if (_textPainterPool.length < _maxPoolSize) {
      tp.text = null; // 清空引用
      _textPainterPool.add(tp);
    } else {
      tp.dispose(); // 池满直接 dispose，不再累积
    }
  }

  double _wrapContentWidth(double layoutWidth, EdgeInsets padding) {
    return lyricScaledContentWidth(
      layoutWidth: layoutWidth,
      scale: lyricUnifiedWrapScale(
        activeScale: config.mainLineScale * config.activeLineScaleMultiplier,
        inactiveScale: config.subLineScale * config.inactiveLineScaleMultiplier,
      ),
      paddingHorizontal: padding.horizontal,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (line.isMetadata) {
      _paintMetadataLine(canvas, size);
    } else if (line is SyncLyricLine &&
        config.displayMode == LyricDisplayMode.wordByWord) {
      _paintSyncLine(canvas, size);
    } else if (line is SyncLyricLine) {
      _paintSyncLineAsPlain(canvas, size);
    } else if (line is LrcLine) {
      _paintLrcLine(canvas, size);
    }
  }

  /// 元数据行统一走纯文本样式，不参与逐字缩放/辉光
  void _paintMetadataLine(Canvas canvas, Size size) {
    final isSyncLineByLine =
        line is SyncLyricLine &&
        config.displayMode == LyricDisplayMode.lineByLine;
    final fontSize = config.primaryFontSize(isMainLine: isMainLine);
    final verticalPad = (line is SyncLyricLine && !isSyncLineByLine)
        ? config.syncVerticalPadding(isMainLine: true)
        : config.lrcVerticalPadding();
    final padding = EdgeInsets.only(
      left: 12.0,
      right: 12.0,
      top: verticalPad,
      bottom: verticalPad,
    );

    final isDarkMode = scheme.brightness == Brightness.dark;
    final neutralBase = isDarkMode ? Colors.white : Colors.black;
    final metadataColor = _applyOpacity(
      useMaterialYouColor
          ? scheme.onSurface.withValues(alpha: 0.70)
          : neutralBase.withValues(alpha: 0.70),
    );
    final blockTextAlign = switch (_effectiveTextAlign) {
      LyricTextAlign.left => TextAlign.left,
      LyricTextAlign.center => TextAlign.center,
      LyricTextAlign.right => TextAlign.right,
    };

    final metaTp = _buildTextPainter(
      ZhConverter.convert(
        _linePlainText(),
        LyricViewController.instance.zhConversionMode,
      ),
      metadataColor,
      fontSize * 0.85,
      config.discreteFontWeight((config.fontWeight - 100).clamp(100, 900)),
      config.letterSpacing(fontSize: fontSize),
      textAlign: blockTextAlign,
    );
    final maxWidth = _wrapContentWidth(size.width, padding);
    metaTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
    metaTp.paint(canvas, Offset(padding.left, padding.top));
    recycleTextPainter(metaTp);
  }

  String _linePlainText() {
    final current = line;
    if (current is SyncLyricLine) {
      return current.words.map((w) => w.content).join();
    }
    if (current is UnsyncLyricLine) {
      return current.content;
    }
    return '';
  }

  void _paintSyncLine(Canvas canvas, Size size) {
    final syncLine = line as SyncLyricLine;
    if (syncLine.words.isEmpty) return;

    LyricWordEffect effectFor({
      required int wordIndex,
      required double wordDurationSec,
    }) {
      return lyricWordEffect(
        duration: Duration(
          microseconds: (wordDurationSec * Duration.microsecondsPerSecond)
              .round(),
        ),
        lineMedianDuration: lineMedianWordDuration,
        isLineEnding: wordIndex == syncLine.words.length - 1,
        sungUnitCount: lyricSungUnitCount(syncLine.words[wordIndex].content),
      );
    }

    double? glowHoldFillMs;
    double? glowHoldWindowStartMs;
    if (!params.usesAuthoredTiming) {
      final lw = syncLine.words.last;
      final lastWordEndMs = (lw.start.inMilliseconds + lw.length.inMilliseconds)
          .toDouble();
      final double? deadline = accelerateTailHighlight
          ? lastWordEndMs + lyricHighlightFinishLeadMs
          : highlightDeadlineMs;
      if (deadline != null &&
          lastWordEndMs >= deadline - lyricHighlightFinishLeadMs) {
        glowHoldFillMs = deadline - lyricHighlightFinishLeadMs;
        glowHoldWindowStartMs = deadline - lyricHighlightCatchUpDurationMs;
      }
    }

    (double alpha, double hold) glowFor(_WordPaintInfo word) {
      if (!config.enableGlow ||
          effectFor(
                wordIndex: word.first.wordIndex,
                wordDurationSec: word.wordDurationSec,
              ) !=
              LyricWordEffect.scaleAndGlow) {
        return (0.0, 0.0);
      }
      if (word.wordProgress <= 0.0) return (0.0, 0.0);
      final duration = Duration(
        microseconds: (word.wordDurationSec * Duration.microsecondsPerSecond)
            .round(),
      );
      final strength = _lyricWordEffectStrength(
        duration,
        lineMedianWordDuration,
      );
      final base = 0.30 + 0.14 * strength;
      final fillMs = glowHoldFillMs;
      final windowStartMs = glowHoldWindowStartMs;
      if (fillMs != null && windowStartMs != null) {
        final w = syncLine.words[word.first.wordIndex];
        final wordEndMs = (w.start.inMilliseconds + w.length.inMilliseconds)
            .toDouble();
        if (wordEndMs >= windowStartMs) {
          final realNow = _effectiveCurrentTimeMs;
          if (realNow >= fillMs + lyricGlowHoldFadeMs) return (0.0, 0.0);
          final fade = realNow < fillMs
              ? 1.0
              : 1.0 - (realNow - fillMs) / lyricGlowHoldFadeMs;
          return (base * fade, fade);
        }
      }
      if (word.wordProgress >= 1.0) return (0.0, 0.0);
      return (base, 0.0);
    }

    canvas.save();

    final fontSize = lyricLayoutFontSize(
      mainFontSize: config.primaryFontSize(isMainLine: true),
      subFontSize: config.primaryFontSize(isMainLine: false),
    );
    final letterSpace = config.letterSpacing(fontSize: fontSize);
    final fontWeight = config.discreteFontWeight(config.fontWeight);
    final verticalPad = config.syncVerticalPadding(isMainLine: true);
    final padding = EdgeInsets.only(
      left: 12.0,
      right: 12.0,
      top: verticalPad,
      bottom: verticalPad,
    );
    // 行高：TextStyle.height=1.2 → fontSize*1.2，与 TextPainter.layout 结果等价
    final lineHeight = fontSize * config.primaryLineHeight();

    final isDarkMode = scheme.brightness == Brightness.dark;
    final neutralBase = isDarkMode ? Colors.white : Colors.black;

    final mainPlayedColor = _applyOpacity(neutralBase.withValues(alpha: 1.0));
    final playedColor = useMaterialYouColor
        ? _applyOpacity(scheme.primary.withValues(alpha: 1.0))
        : mainPlayedColor;
    final unplayedColor = _unplayedLyricColor(
      isDarkMode: isDarkMode,
      neutralBase: neutralBase,
    );
    final secondaryColor = _applyOpacity(
      useMaterialYouColor
          ? scheme.onSurface.withValues(alpha: 0.35)
          : neutralBase.withValues(alpha: 0.25),
    );
    final translationColor = _applyOpacity(
      useMaterialYouColor
          ? scheme.onSurface.withValues(alpha: 0.60)
          : neutralBase.withValues(alpha: 0.70),
    );

    final maxWidth = _wrapContentWidth(size.width, padding);

    final zhMode = LyricViewController.instance.zhConversionMode;

    final translationWeight = config.discreteFontWeight(
      (config.fontWeight - 50).clamp(100, 900),
    );
    final romanWeight = config.discreteFontWeight(
      (config.fontWeight - 100).clamp(100, 900),
    );

    // ── Determine active track display order ─────────────────────────────────
    final activeTracks = _activeLineTracks(
      config,
      hasTranslation: syncLine.translation != null,
      hasRoman: syncLine.romanLyric != null,
    );
    final preTracks = _preOriginalTracks(activeTracks);
    final postTracks = _postOriginalTracks(activeTracks);

    // ── Paint pre-original sub-tracks (before main text) ─────────────────────
    double preCursorY = padding.top;
    if (preTracks.isNotEmpty) {
      final blockTextAlign = switch (_effectiveTextAlign) {
        LyricTextAlign.left => TextAlign.left,
        LyricTextAlign.center => TextAlign.center,
        LyricTextAlign.right => TextAlign.right,
      };
      final translationFontSize = lyricLayoutFontSize(
        mainFontSize: config.translationFontSize(isMainLine: true),
        subFontSize: config.translationFontSize(isMainLine: false),
      );
      final romanFontSize = translationFontSize * 0.85;
      var hasPrev = false;
      for (final track in preTracks) {
        if (hasPrev) preCursorY += 4.0;
        hasPrev = true;
        if (track == LyricLineTrack.translation &&
            syncLine.translation != null) {
          final translated = ZhConverter.convert(syncLine.translation!, zhMode);
          final tp = _buildTextPainter(
            translated,
            translationColor,
            translationFontSize,
            translationWeight,
            letterSpace,
            isTranslation: true,
            textAlign: blockTextAlign,
          );
          tp.layout(minWidth: maxWidth, maxWidth: maxWidth);
          tp.paint(canvas, Offset(padding.left, preCursorY));
          preCursorY += tp.height;
          recycleTextPainter(tp);
        } else if (track == LyricLineTrack.romanization &&
            syncLine.romanLyric != null) {
          final romanText = ZhConverter.convert(syncLine.romanLyric!, zhMode);
          final tp = _buildTextPainter(
            romanText,
            secondaryColor,
            romanFontSize,
            romanWeight,
            letterSpace,
            isTranslation: true,
            textAlign: blockTextAlign,
          );
          tp.layout(minWidth: maxWidth, maxWidth: maxWidth);
          tp.paint(canvas, Offset(padding.left, preCursorY));
          preCursorY += tp.height;
          recycleTextPainter(tp);
        }
      }
    }

    // ── Shared measurer (avoids creating one TextPainter per character) ──
    final measureTp = obtainTextPainter();
    TextStyle measureStyle(double fs, FontWeight fw) {
      final family = lyricRenderFontFamily(fontFamily);
      return TextStyle(
        fontFamily: family,
        fontFamilyFallback: appFontFamilyFallback(family),
        fontSize: fs,
        fontWeight: fw,
        letterSpacing: 0,
        height: config.primaryLineHeight(),
        fontVariations: lyricWeightVariations(family, fw.value),
      );
    }

    // ── Collect all character positions ─────────────────────────────────────
    final charInfos = <_CharInfo>[];
    final contentRight = padding.left + maxWidth;
    final layoutCursor = LyricWordLayoutCursor(
      x: padding.left,
      y: preTracks.isNotEmpty ? preCursorY : padding.top,
      firstOnLine: true,
    );
    final currentTimeMs = _highlightTimeMs(
      syncLine,
      syncLine.words,
      _effectiveCurrentTimeMs,
    );
    for (int wordIndex = 0; wordIndex < syncLine.words.length; wordIndex++) {
      final word = syncLine.words[wordIndex];
      final isObscene = word.obscene;
      final wordTotalChars = isObscene
          ? word.content.runes.length
          : word.content.characters.length;
      if (wordTotalChars == 0) continue;
      final wordStartMs = word.start.inMilliseconds.toDouble();
      final wordEndMs = wordStartMs + word.length.inMilliseconds.toDouble();
      final wordDurationSec = word.length.inMilliseconds / 1000.0;

      // 单词级别的上抬动画：高亮与上抬同源

      final convertedChars = <String>[];
      final charWidths = <double>[];
      double wordWidth = 0.0;

      void measureRawChar(String rawChar) {
        final char = ZhConverter.convert(rawChar, zhMode);
        final ck = '$char|$fontSize|${fontWeight.value}|$fontFamily';
        final cached = _measureCache[ck];
        if (cached != null) {
          convertedChars.add(char);
          charWidths.add(cached);
          wordWidth += cached;
        } else {
          measureTp.text = TextSpan(
            text: char,
            style: measureStyle(fontSize, fontWeight),
          );
          measureTp.layout();
          final cw = measureTp.width;
          convertedChars.add(char);
          charWidths.add(cw);
          wordWidth += cw;
          _measureCache[ck] = cw;
          if (_measureCache.length > _maxMeasureCacheSize) {
            _measureCache.remove(_measureCache.keys.first);
          }
        }
      }

      if (isObscene) {
        for (var i = 0; i < wordTotalChars; i++) {
          measureRawChar('_');
        }
      } else {
        for (final rawChar in word.content.characters) {
          measureRawChar(rawChar);
        }
      }

      if (!layoutCursor.firstOnLine &&
          layoutCursor.x + wordWidth > contentRight - 1.0) {
        layoutCursor.x = padding.left;
        layoutCursor.y += lineHeight;
        layoutCursor.firstOnLine = true;
        layoutCursor.visualLineCount++;
      }

      // ── 词级波浪窗口进度计算 ───────────────────────────
      // stepRatio = 0.1：前一个字动画跑到 10% 时，后一个字开始
      // waveWidth = 1.0 / (stepRatio * (charCount - 1) + 1.0)
      // windowStart[i] = i * stepRatio * waveWidth
      // charProgress = (wordProgress - windowStart[i]) / waveWidth
      final wordProgress = _calcWordProgress(
        currentTimeMs,
        wordStartMs,
        wordEndMs,
      );
      final realWordProgress = _calcWordProgress(
        _effectiveCurrentTimeMs,
        wordStartMs,
        wordEndMs,
      );
      final wordEffect = effectFor(
        wordIndex: wordIndex,
        wordDurationSec: wordDurationSec,
      );

      double? prevNonPunctProgress;
      double? prevNonPunctEffect;
      int animIndex = 0;

      layoutTimedWordChars(
        chars: convertedChars,
        widths: charWidths,
        contentLeft: padding.left,
        contentRight: contentRight,
        lineHeight: lineHeight,
        cursor: layoutCursor,
        onPlace: (i, x, y) {
          final char = convertedChars[i];
          final computedProgress = lyricCharWaveProgress(
            wordProgress: wordProgress,
            charIndex: animIndex,
            charCount: wordTotalChars,
          );

          final double charProgress;
          final isPunctuation = _isPunctuation(char);
          if (isPunctuation && prevNonPunctProgress != null) {
            charProgress = prevNonPunctProgress!;
          } else {
            charProgress = computedProgress;
            if (!isPunctuation) {
              prevNonPunctProgress = computedProgress;
            }
          }

          // 上抬跟唱标走，不在排版时按词时长算。
          const yLift = 0.0;

          final double effectProgress;
          if (isPunctuation && prevNonPunctEffect != null) {
            effectProgress = prevNonPunctEffect!;
          } else {
            final realCharProgress = lyricCharWaveProgress(
              wordProgress: realWordProgress,
              charIndex: animIndex,
              charCount: wordTotalChars,
            );
            effectProgress = wordEffect == LyricWordEffect.none
                ? charProgress
                : lyricCappedEffectProgress(
                    warpedProgress: charProgress,
                    realProgress: realCharProgress,
                  );
            if (!isPunctuation) {
              prevNonPunctEffect = effectProgress;
            }
          }

          charInfos.add(
            _CharInfo(
              char: char,
              x: x,
              y: y,
              width: charWidths[i],
              yLift: yLift,
              charProgress: charProgress,
              wordProgress: wordProgress,
              effectProgress: effectProgress,
              wordIndex: wordIndex,
              wordCharIndex: animIndex,
              wordDurationSec: wordDurationSec,
            ),
          );
          animIndex++;
        },
      );
      // 词间间距，匹配 Widget 路径的 SizedBox(width: primarySize * 0.12)
      layoutCursor.x += fontSize * 0.12;
    }
    var cursorY = layoutCursor.y + lineHeight;

    if (charInfos.isEmpty) {
      recycleTextPainter(measureTp);
      canvas.restore();
      return;
    }

    final wordPlacedCounts = <int, int>{};
    for (final info in charInfos) {
      wordPlacedCounts[info.wordIndex] =
          (wordPlacedCounts[info.wordIndex] ?? 0) + 1;
    }

    // ── Group characters by visual line (Y position) ─────────────────────────
    final lineGroups = <_LineGroup>[];
    _LineGroup? currentGroup;
    for (final info in charInfos) {
      if (currentGroup == null || info.y != currentGroup.y) {
        currentGroup = _LineGroup(y: info.y, chars: []);
        lineGroups.add(currentGroup);
      }
      currentGroup.chars.add(info);
    }

    // ── Apply text alignment (per-line, matching Widget Wrap behavior) ───────
    // 所有值都在逻辑（缩放）空间中，直接计算即可
    if (_effectiveTextAlign != LyricTextAlign.left) {
      for (final group in lineGroups) {
        if (group.chars.isEmpty) continue;
        var left = double.infinity;
        var right = double.negativeInfinity;
        for (final char in group.chars) {
          if (char.x < left) left = char.x;
          final charRight = char.x + char.width;
          if (charRight > right) right = charRight;
        }
        final lineWidth = right - left;

        final lineStartX = switch (_effectiveTextAlign) {
          LyricTextAlign.center => padding.left + (maxWidth - lineWidth) / 2,
          LyricTextAlign.right => padding.left + maxWidth - lineWidth,
          LyricTextAlign.left => padding.left,
        };
        final offset = lineStartX - left;

        for (int i = 0; i < group.chars.length; i++) {
          final original = group.chars[i];
          group.chars[i] = _CharInfo(
            char: original.char,
            x: original.x + offset,
            y: original.y,
            width: original.width,
            yLift: original.yLift,
            charProgress: original.charProgress,
            wordProgress: original.wordProgress,
            effectProgress: original.effectProgress,
            wordIndex: original.wordIndex,
            wordCharIndex: original.wordCharIndex,
            wordDurationSec: original.wordDurationSec,
          );
        }
      }
      // 重建 charInfos，确保 Pass 1 也使用对齐后的坐标
      charInfos.clear();
      for (final group in lineGroups) {
        charInfos.addAll(group.chars);
      }
    }

    if (!isMainVocalActive) {
      _applyExitCharLifts(charInfos);
    }
    final exitMix = isMainVocalActive
        ? 1.0
        : (liftDecayListenable?.value ?? 0.0);

    // ── Pre-build shared TextPainter + styles ──────────────────────────────
    final tp = obtainTextPainter();
    final dimStyle = _textStyle(
      fontSize: fontSize,
      color: unplayedColor,
      fontWeight: fontWeight,
      letterSpacing: 0,
      height: config.primaryLineHeight(),
    );
    final playedStyle = _textStyle(
      fontSize: fontSize,
      color: playedColor,
      fontWeight: fontWeight,
      letterSpacing: 0,
      height: config.primaryLineHeight(),
    );
    final playedTextColor = _styleColor(playedStyle, playedColor);

    // ── Helper: paint one word with a given style ─────────────────────────
    void paintWord(
      _WordPaintInfo word,
      TextStyle style,
      bool useLift, {
      bool applyScale = false,
      Color? glowColor,
      double glowAlpha = 0.0,
      double glowHold = 0.0,
      bool paintText = true,
    }) {
      final wc = word.chars;
      if (wc.isEmpty) return;
      final resolvedGlowColor = glowColor;
      final hasGlow = resolvedGlowColor != null && glowAlpha > 0.02;
      if (!paintText && !hasGlow) return;

      final wordDuration = Duration(
        microseconds: (word.wordDurationSec * Duration.microsecondsPerSecond)
            .round(),
      );
      final effect = applyScale
          ? effectFor(
              wordIndex: wc.first.wordIndex,
              wordDurationSec: word.wordDurationSec,
            )
          : LyricWordEffect.none;
      final hasScale = effect != LyricWordEffect.none;
      if (!useLift && !hasScale && !hasGlow) {
        if (paintText) {
          // 按逐字布局坐标画，避免整词 TextSpan 的 kerning 和测量 x 不一致。
          for (final info in wc) {
            _paintStableGlyph(
              canvas: canvas,
              tp: tp,
              char: info.char,
              style: style,
              offset: Offset(info.x, info.y),
            );
          }
        }
        return;
      }

      final effectStrength = _lyricWordEffectStrength(
        wordDuration,
        lineMedianWordDuration,
      );
      final nearGlowSigma = (fontSize * (0.08 + 0.02 * effectStrength))
          .clamp(2.5, 5.0)
          .toDouble();
      final farGlowSigma = (fontSize * (0.22 + 0.05 * effectStrength))
          .clamp(7.0, 12.0)
          .toDouble();
      final nearGlowPaint = hasGlow
          ? (Paint()
              ..maskFilter = _blurFilter(nearGlowSigma)
              ..blendMode = BlendMode.screen)
          : null;
      final farGlowPaint = hasGlow
          ? (Paint()
              ..maskFilter = _blurFilter(farGlowSigma)
              ..blendMode = BlendMode.screen)
          : null;
      final nearGlowStyle = nearGlowPaint == null
          ? null
          : style.copyWith(
              color: null,
              foreground: nearGlowPaint,
              shadows: null,
            );
      final farGlowStyle = farGlowPaint == null
          ? null
          : style.copyWith(
              color: null,
              foreground: farGlowPaint,
              shadows: null,
            );
      for (final info in wc) {
        final paintOffset = Offset(info.x, info.y + info.yLift);
        final scale = lyricExitScale(
          lyricCharacterScale(
            effect: effect,
            duration: wordDuration,
            lineMedianDuration: lineMedianWordDuration,
            progress: info.effectProgress,
          ),
          exitMix,
        );
        final needsScale = (scale - 1.0).abs() > 0.005;
        if (needsScale) {
          canvas.save();
          final centerX = paintOffset.dx + info.width / 2;
          final baselineY = paintOffset.dy + lineHeight;
          canvas.translate(centerX, baselineY);
          canvas.scale(scale);
          canvas.translate(-centerX, -baselineY);
        }
        if (nearGlowPaint != null &&
            nearGlowStyle != null &&
            farGlowPaint != null &&
            farGlowStyle != null) {
          var pulse = _lyricEffectParabola(info.effectProgress);
          if (glowHold > 0.0) {
            pulse = max(pulse, info.charProgress * glowHold);
          }
          pulse = lyricExitGlowAlpha(pulse, exitMix);
          final adjustedAlpha = resolvedGlowColor!.a * glowAlpha * pulse;
          if (adjustedAlpha > 0.02) {
            farGlowPaint.color = resolvedGlowColor.withValues(
              alpha: adjustedAlpha * 0.55,
            );
            tp.text = TextSpan(text: info.char, style: farGlowStyle);
            tp.layout();
            tp.paint(canvas, paintOffset);
            nearGlowPaint.color = resolvedGlowColor.withValues(
              alpha: adjustedAlpha,
            );
            tp.text = TextSpan(text: info.char, style: nearGlowStyle);
            tp.layout();
            tp.paint(canvas, paintOffset);
          }
        }
        if (paintText) {
          _paintStableGlyph(
            canvas: canvas,
            tp: tp,
            char: info.char,
            style: style,
            offset: paintOffset,
          );
        }
        if (needsScale) {
          canvas.restore();
        }
      }
    }

    // ── Per visual line ────────────────────────────────────────────────────
    for (var groupIndex = 0; groupIndex < lineGroups.length; groupIndex++) {
      final group = lineGroups[groupIndex];
      if (group.chars.isEmpty) continue;

      final words = <_WordPaintInfo>[];
      List<_CharInfo>? currentChars;
      StringBuffer? currentText;
      var currentHasLift = false;
      int? currentWordIndex;
      void finishWord() {
        final chars = currentChars;
        final text = currentText;
        if (chars == null || text == null || chars.isEmpty) return;
        final first = chars.first;
        final word = _WordPaintInfo(
          chars: chars,
          text: text.toString(),
          hasLift: currentHasLift,
          wordProgress: first.wordProgress,
          wordDurationSec: first.wordDurationSec,
        );
        words.add(word);
      }

      for (final info in group.chars) {
        if (currentChars == null || info.wordIndex != currentWordIndex) {
          finishWord();
          currentChars = <_CharInfo>[];
          currentText = StringBuffer();
          currentHasLift = false;
          currentWordIndex = info.wordIndex;
        }
        currentChars.add(info);
        currentText!.write(info.char);
        currentHasLift = currentHasLift || info.yLift != 0.0;
      }
      finishWord();

      if (!isHighlightActive) {
        final fadeEffects = config.enableGlow && exitMix > 0.01;
        for (final wc in words) {
          if (!fadeEffects) {
            paintWord(wc, dimStyle, wc.hasLift);
            continue;
          }
          final (glowAlpha, glowHold) = glowFor(wc);
          paintWord(
            wc,
            dimStyle,
            wc.hasLift,
            applyScale: true,
            glowColor: glowAlpha > 0.02 ? playedTextColor : null,
            glowAlpha: glowAlpha,
            glowHold: glowHold,
          );
        }
        continue;
      }

      // ── Compute bounds & sweep position ────────────────────────────────
      double left = double.infinity, top = double.infinity;
      double right = double.negativeInfinity, bottom = double.negativeInfinity;
      for (final wc in words) {
        final wx = wc.first.x;
        final wy = wc.first.y;
        final wr = wc.last.x + wc.last.width;
        left = left < wx ? left : wx;
        top = top < wy ? top : wy;
        right = right > wr ? right : wr;
        bottom = bottom > wy + lineHeight ? bottom : wy + lineHeight;
      }

      const gapUnits = 0.45;
      double wordReveal(_WordPaintInfo wc) {
        return lyricWrappedWordReveal(
          wordProgress: wc.wordProgress,
          wordCharIndex: wc.first.wordCharIndex,
          segmentLength: wc.length,
          wordPlacedCount: wordPlacedCounts[wc.first.wordIndex] ?? wc.length,
        );
      }

      var lineFullyPlayed = true;
      for (final wc in words) {
        if (wordReveal(wc) < wc.length - 0.001) {
          lineFullyPlayed = false;
          break;
        }
      }

      double? prevR;
      double reveal = 0.0;
      for (int wi = 0; wi < words.length; wi++) {
        final wc = words[wi];
        final wp = wc.first.wordProgress.clamp(0.0, 1.0);
        if (wp <= 0.0) break;
        final wR = wc.last.x + wc.last.width;
        if (wi > 0 && prevR != null) {
          reveal += gapUnits;
        }
        reveal += wordReveal(wc);
        prevR = wR;
      }
      if (reveal <= 0.0) {
        for (final wc in words) {
          paintWord(wc, dimStyle, wc.hasLift);
        }
        continue;
      }

      double highlightR = words.first.first.x;
      var rem = reveal;
      prevR = null;
      for (int wi = 0; wi < words.length; wi++) {
        final wc = words[wi];
        final wp = wc.first.wordProgress.clamp(0.0, 1.0);
        if (wp <= 0.0) break;
        final wL = wc.first.x;
        final wR = wc.last.x + wc.last.width;
        if (wi > 0 && prevR != null) {
          if (rem >= gapUnits) {
            highlightR = wL;
            rem -= gapUnits;
          } else {
            final lp = (rem / gapUnits).clamp(0.0, 1.0);
            highlightR = prevR + (wL - prevR) * lp;
            break;
          }
        }
        for (final info in wc.chars) {
          if (rem >= 1.0) {
            highlightR = info.x + info.width;
            rem -= 1.0;
          } else {
            final lp = rem.clamp(0.0, 1.0);
            highlightR = info.x + info.width * lp;
            rem = 0.0;
            break;
          }
        }
        if (rem <= 0.0) break;
        prevR = wR;
      }
      if (highlightR <= left) {
        for (final wc in words) {
          paintWord(wc, dimStyle, wc.hasLift);
        }
        continue;
      }

      // ── Gradient ───────────────────────────────────────────────────────
      final bounds = Rect.fromLTRB(left, top, right, bottom);
      final bw = bounds.width <= 0 ? 1.0 : bounds.width;
      final sweepP = ((highlightR - left) / bw).clamp(0.0, 1.0);
      final feather = (32.0 / bw).clamp(0.04, 0.18);
      final p1 = (sweepP + feather * 0.35).clamp(sweepP, 1.0);
      final featherEnd = left + bw * p1;
      final clippedHighlightR = highlightR.clamp(left, right).toDouble();
      final clipPad = fontSize * 0.35 + 12.0;
      final playedClip = Rect.fromLTRB(
        left - 2.0,
        top - clipPad,
        (featherEnd + 8.0).clamp(left, right + 2.0).toDouble(),
        bottom + clipPad,
      );
      final gradientPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            playedTextColor,
            playedTextColor,
            playedTextColor.withValues(alpha: 0.0),
          ],
          stops: [0.0, sweepP, p1],
        ).createShader(bounds);
      if (blurSigma > 0.01) {
        gradientPaint.maskFilter = _blurFilter(blurSigma);
      }
      final gradientPlayedStyle = _copyTextStyleWithForeground(
        playedStyle,
        gradientPaint,
      );

      if (isMainVocalActive) {
        final lineEndX = identical(group, lineGroups.last)
            ? right
            : right + 3.0 * fontSize;
        // 这一视觉行只跟自己的唱标。还没唱到的折行保持原高度。
        final liftGate = liftGateListenable?.value ?? 1.0;
        final cursorX = _followLiftCursor(
          clippedHighlightR,
          fontSize,
          originX: left,
          row: groupIndex,
        );
        for (final wc in words) {
          for (final info in wc.chars) {
            info.yLift = lyricGatedLiftPx(
              lyricCosineLiftPx(
                charCenter: info.x + info.width / 2,
                cursorX: cursorX,
                lineEndX: lineEndX,
                fontSize: fontSize,
                liftPeak: config.liftPeak,
                lineLeft: left,
              ),
              liftGate,
            );
            if (info.yLift != 0.0) wc.hasLift = true;
          }
        }
      }

      // ── Pass 1: dim（与 played 共用 scale，避免分层）────────────
      for (final wc in words) {
        paintWord(wc, dimStyle, wc.hasLift, applyScale: config.enableGlow);
      }

      final glowColor = playedTextColor;
      for (final wc in words) {
        final (glowAlpha, glowHold) = glowFor(wc);
        if (glowAlpha > 0.02) {
          paintWord(
            wc,
            playedStyle,
            wc.hasLift,
            applyScale: config.enableGlow,
            glowColor: glowColor,
            glowAlpha: glowAlpha,
            glowHold: glowHold,
            paintText: false,
          );
        }
      }

      // ── Pass 2: played 文字层 ────────────────────────────────────────────
      void paintPlayedLayer(TextStyle style) {
        for (final wc in words) {
          paintWord(wc, style, wc.hasLift, applyScale: config.enableGlow);
        }
      }

      // Soft sweep highlight: old visual feel without saveLayer masking.
      if (lineFullyPlayed || clippedHighlightR >= right - 0.5) {
        paintPlayedLayer(playedStyle);
      } else if (clippedHighlightR > left) {
        canvas.save();
        canvas.clipRect(playedClip);
        paintPlayedLayer(gradientPlayedStyle);
        canvas.restore();
      }
    }

    debugLyricCharYLifts = [for (final info in charInfos) info.yLift];
    if (isMainVocalActive) {
      _captureCharLifts(charInfos);
      liftCache?.restoreCursorFromPlayback = false;
    }

    // ── Post-original sub-tracks ─────────────────────────────────────────────
    if (postTracks.isNotEmpty) {
      final blockTextAlign = switch (_effectiveTextAlign) {
        LyricTextAlign.left => TextAlign.left,
        LyricTextAlign.center => TextAlign.center,
        LyricTextAlign.right => TextAlign.right,
      };
      final translationFontSize = lyricLayoutFontSize(
        mainFontSize: config.translationFontSize(isMainLine: true),
        subFontSize: config.translationFontSize(isMainLine: false),
      );
      final romanFontSize = translationFontSize * 0.85;
      cursorY += config.syncTranslationGap(isMainLine: true);
      var hasPrev = false;
      for (final track in postTracks) {
        if (hasPrev) cursorY += 4.0;
        hasPrev = true;
        if (track == LyricLineTrack.translation &&
            syncLine.translation != null) {
          final translated = ZhConverter.convert(syncLine.translation!, zhMode);
          final tp = _buildTextPainter(
            translated,
            translationColor,
            translationFontSize,
            translationWeight,
            letterSpace,
            isTranslation: true,
            textAlign: blockTextAlign,
          );
          tp.layout(minWidth: maxWidth, maxWidth: maxWidth);
          debugLyricTranslationY = cursorY;
          tp.paint(canvas, Offset(padding.left, cursorY));
          cursorY += tp.height;
          recycleTextPainter(tp);
        } else if (track == LyricLineTrack.romanization &&
            syncLine.romanLyric != null) {
          final romanText = ZhConverter.convert(syncLine.romanLyric!, zhMode);
          final tp = _buildTextPainter(
            romanText,
            secondaryColor,
            romanFontSize,
            romanWeight,
            letterSpace,
            isTranslation: true,
            textAlign: blockTextAlign,
          );
          tp.layout(minWidth: maxWidth, maxWidth: maxWidth);
          tp.paint(canvas, Offset(padding.left, cursorY));
          cursorY += tp.height;
          recycleTextPainter(tp);
        }
      }
    }

    // ── Background vocal (和声) with word-by-word highlight ──
    final bgText = syncLine.bgText;
    final bgRomanLyric = syncLine.bg?.romanLyric;
    final bgTranslation = syncLine.bgTranslation;
    final hasBg = bgText != null && bgText.isNotEmpty;
    final hasBgRoman =
        config.showRoman && bgRomanLyric != null && bgRomanLyric.isNotEmpty;
    final hasBgTranslation = bgTranslation != null && bgTranslation.isNotEmpty;
    final hasBgWords = syncLine.bgWords.isNotEmpty;
    if (hasBg || hasBgRoman || hasBgTranslation || hasBgWords) {
      final bgOpacity = _bgOpacity(syncLine);
      if (bgOpacity > 0.001) {
        final bgFontSize = fontSize * 0.60;
        final bgWeight = config.discreteFontWeight(
          (config.fontWeight - 150).clamp(100, 900),
        );
        final blockTextAlign = switch (_effectiveTextAlign) {
          LyricTextAlign.left => TextAlign.left,
          LyricTextAlign.center => TextAlign.center,
          LyricTextAlign.right => TextAlign.right,
        };

        final bgUnplayedColor = _applyOpacity(
          useMaterialYouColor
              ? scheme.onSurface.withValues(alpha: 0.28)
              : neutralBase.withValues(alpha: 0.22),
        );
        final bgPlayedColor = _applyOpacity(
          useMaterialYouColor
              ? scheme.primary.withValues(alpha: 0.80)
              : neutralBase.withValues(alpha: 0.62),
        );

        void paintBgLine(String text, double size, Color color) {
          final tp = _buildTextPainter(
            ZhConverter.convert(text, zhMode),
            color.withValues(alpha: color.a * bgOpacity * _opacityFactor),
            size,
            bgWeight,
            letterSpace,
            textAlign: blockTextAlign,
          );
          tp.layout(minWidth: maxWidth, maxWidth: maxWidth);
          cursorY += bgFontSize * 0.45;
          tp.paint(canvas, Offset(padding.left, cursorY));
          cursorY += tp.height;
          recycleTextPainter(tp);
        }

        final bgBlockTop = cursorY;
        cursorY += bgFontSize * 0.35;
        canvas.save();
        final exitVisibility = backgroundVocalVisibilityListenable?.value;
        if (exitVisibility != null) {
          final visibility = exitVisibility.clamp(0.0, 1.0);
          final clipBottom =
              bgBlockTop +
              (size.height - bgBlockTop).clamp(0.0, double.infinity) *
                  (params.usesAuthoredTiming ? 1.0 : visibility);
          canvas.clipRect(Rect.fromLTRB(0.0, 0.0, size.width, clipBottom));
        }
        // 高度由 _bgHeightFactor 在 measureHeight 中控制，画布自然 clip

        final bgTracks = _activeLineTracks(
          config,
          hasTranslation: hasBgTranslation,
          hasRoman: hasBgRoman,
        );
        final bgPreTracks = _preOriginalTracks(bgTracks);
        final bgPostTracks = _postOriginalTracks(bgTracks);

        void paintBgSecondaryTrack(LyricLineTrack track) {
          switch (track) {
            case LyricLineTrack.original:
              return;
            case LyricLineTrack.translation:
              if (hasBgTranslation) {
                paintBgLine(bgTranslation, bgFontSize * 0.90, bgUnplayedColor);
              }
              return;
            case LyricLineTrack.romanization:
              if (hasBgRoman) {
                paintBgLine(bgRomanLyric, bgFontSize * 0.85, bgUnplayedColor);
              }
              return;
          }
        }

        for (final track in bgPreTracks) {
          paintBgSecondaryTrack(track);
        }

        if (hasBgWords &&
            (isMainLine ||
                isBackgroundActive ||
                params.isBackgroundVisible != null)) {
          cursorY += bgFontSize * 0.45;
          final bgWordY = cursorY;
          final currentMs = _effectiveCurrentTimeMs;
          final bgWordWidths = <double>[];
          double bgTotalWidth = 0.0;
          final bgWordGap = bgFontSize * 0.12;
          for (final word in syncLine.bgWords) {
            final char = ZhConverter.convert(
              word.obscene
                  ? String.fromCharCodes(
                      Iterable.generate(word.content.runes.length, (_) => 0x5F),
                    )
                  : word.content,
              zhMode,
            );
            final tp = _buildTextPainter(
              char,
              bgUnplayedColor,
              bgFontSize,
              bgWeight,
              letterSpace,
            );
            tp.layout();
            bgWordWidths.add(tp.width);
            bgTotalWidth += tp.width;
            recycleTextPainter(tp);
          }
          bgTotalWidth += bgWordGap * (syncLine.bgWords.length - 1);
          final startX = switch (_effectiveTextAlign) {
            LyricTextAlign.left => padding.left,
            LyricTextAlign.center =>
              padding.left + (maxWidth - bgTotalWidth) / 2,
            LyricTextAlign.right => padding.left + maxWidth - bgTotalWidth,
          };

          double reveal = 0.0;
          for (int i = 0; i < syncLine.bgWords.length; i++) {
            final word = syncLine.bgWords[i];
            final wordStartMs = word.start.inMilliseconds.toDouble();
            final wordEndMs = (wordStartMs + word.length.inMilliseconds)
                .toDouble();
            final progress = _calcWordProgress(
              currentMs,
              wordStartMs,
              wordEndMs,
            );
            if (progress <= 0.0) break;
            reveal += bgWordWidths[i] * progress;
            if (i < syncLine.bgWords.length - 1) reveal += bgWordGap;
          }

          void paintBgDim() {
            double cx = startX;
            for (int i = 0; i < syncLine.bgWords.length; i++) {
              final char = ZhConverter.convert(
                syncLine.bgWords[i].obscene
                    ? String.fromCharCodes(
                        Iterable.generate(
                          syncLine.bgWords[i].content.runes.length,
                          (_) => 0x5F,
                        ),
                      )
                    : syncLine.bgWords[i].content,
                zhMode,
              );
              final dimColor = bgUnplayedColor.withValues(
                alpha: bgUnplayedColor.a * bgOpacity * _opacityFactor,
              );
              final tp = _buildTextPainter(
                char,
                dimColor,
                bgFontSize,
                bgWeight,
                letterSpace,
              );
              tp.layout();
              tp.paint(canvas, Offset(cx, bgWordY));
              cx += bgWordWidths[i] + bgWordGap;
              recycleTextPainter(tp);
            }
          }

          void paintBgBright() {
            double cx = startX;
            for (int i = 0; i < syncLine.bgWords.length; i++) {
              final char = ZhConverter.convert(
                syncLine.bgWords[i].obscene
                    ? String.fromCharCodes(
                        Iterable.generate(
                          syncLine.bgWords[i].content.runes.length,
                          (_) => 0x5F,
                        ),
                      )
                    : syncLine.bgWords[i].content,
                zhMode,
              );
              final brightColor = bgPlayedColor.withValues(
                alpha: bgPlayedColor.a * bgOpacity * _opacityFactor,
              );
              final tp = _buildTextPainter(
                char,
                brightColor,
                bgFontSize,
                bgWeight,
                letterSpace,
              );
              tp.layout();
              tp.paint(canvas, Offset(cx, bgWordY));
              cx += bgWordWidths[i] + bgWordGap;
              recycleTextPainter(tp);
            }
          }

          paintBgDim();
          if (reveal > 0.0) {
            canvas.save();
            canvas.clipRect(
              Rect.fromLTRB(
                -1,
                bgWordY - 5,
                startX + reveal + 2,
                bgWordY + bgFontSize * 2,
              ),
            );
            paintBgBright();
            canvas.restore();
          }
          cursorY = bgWordY + bgFontSize * config.primaryLineHeight();
        } else if (hasBg) {
          paintBgLine(bgText, bgFontSize, bgUnplayedColor);
        }

        for (final track in bgPostTracks) {
          paintBgSecondaryTrack(track);
        }
        canvas.restore();
      }
    }

    // 回收 TextPainter
    recycleTextPainter(measureTp);
    recycleTextPainter(tp);

    canvas.restore();
  }

  void _paintLrcLine(Canvas canvas, Size size) {
    final lrcLine = line as LrcLine;

    canvas.save();

    final zhMode = LyricViewController.instance.zhConversionMode;
    final fontSize = config.primaryFontSize(isMainLine: isMainLine);
    final letterSpace = config.letterSpacing(fontSize: fontSize);
    final fontWeight = config.discreteFontWeight(config.fontWeight);
    final verticalPad = config.lrcVerticalPadding();
    final padding = EdgeInsets.only(
      left: 12.0,
      right: 12.0,
      top: verticalPad,
      bottom: verticalPad,
    );

    final isDarkMode = scheme.brightness == Brightness.dark;
    final neutralBase = isDarkMode ? Colors.white : Colors.black;

    final mainPlayedColor = _applyOpacity(neutralBase.withValues(alpha: 1.0));
    final playedColor = useMaterialYouColor
        ? _applyOpacity(scheme.primary.withValues(alpha: 1.0))
        : mainPlayedColor;
    final unplayedColor = _unplayedLyricColor(
      isDarkMode: isDarkMode,
      neutralBase: neutralBase,
    );
    final dimColor = unplayedColor;
    final mainColor = isMainLine ? playedColor : dimColor;
    final secondaryColor = _applyOpacity(
      useMaterialYouColor
          ? scheme.onSurface.withValues(alpha: 0.35)
          : neutralBase.withValues(alpha: 0.25),
    );
    final translationColor = _applyOpacity(
      useMaterialYouColor
          ? scheme.onSurface.withValues(alpha: 0.60)
          : neutralBase.withValues(alpha: 0.70),
    );

    final maxWidth = _wrapContentWidth(size.width, padding);
    final blockTextAlign = switch (_effectiveTextAlign) {
      LyricTextAlign.left => TextAlign.left,
      LyricTextAlign.center => TextAlign.center,
      LyricTextAlign.right => TextAlign.right,
    };

    // ── 多翻译 ┃ 分离（匹配 Widget）──────────────────────────────────────
    final splited = lrcLine.content.split('┃');
    final mainText = ZhConverter.convert(splited.first, zhMode);

    // ── 收集所有翻译文本（含 ┃ 分隔的额外翻译）───────────────────────────
    final transTexts = <String>[];
    if (config.showTranslation &&
        lrcLine.translation != null &&
        lrcLine.translation!.trim().isNotEmpty) {
      transTexts.add(lrcLine.translation!);
    }
    for (var i = 1; i < splited.length; i++) {
      final part = splited[i].trim();
      if (part.isNotEmpty && !transTexts.contains(part)) {
        transTexts.add(part);
      }
    }

    final activeTracks = _activeLineTracks(
      config,
      hasTranslation: transTexts.isNotEmpty,
      hasRoman: lrcLine.romanLyric != null,
    );
    final preTracks = _preOriginalTracks(activeTracks);
    final postTracks = _postOriginalTracks(activeTracks);

    final translationWeight = config.discreteFontWeight(
      (config.fontWeight - 50).clamp(100, 900),
    );
    final romanWeight = config.discreteFontWeight(
      (config.fontWeight - 100).clamp(100, 900),
    );
    final translationFontSize = lyricLayoutFontSize(
      mainFontSize: config.translationFontSize(isMainLine: true),
      subFontSize: config.translationFontSize(isMainLine: false),
    );
    final romanFontSize = translationFontSize * 0.85;

    // ── Paint pre-original sub-tracks (before main text) ─────────────────────
    double lrcPreY = padding.top;
    for (final track in preTracks) {
      if (lrcPreY > padding.top) lrcPreY += 2.0;
      if (track == LyricLineTrack.translation && transTexts.isNotEmpty) {
        for (final trans in transTexts) {
          final translated = ZhConverter.convert(trans, zhMode);
          final tTp = _buildTextPainter(
            translated,
            translationColor,
            translationFontSize,
            translationWeight,
            letterSpace,
            isTranslation: true,
            textAlign: blockTextAlign,
          );
          tTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
          tTp.paint(canvas, Offset(padding.left, lrcPreY));
          lrcPreY += tTp.height;
          recycleTextPainter(tTp);
        }
      } else if (track == LyricLineTrack.romanization &&
          lrcLine.romanLyric != null) {
        final romanText = ZhConverter.convert(lrcLine.romanLyric!, zhMode);
        final rTp = _buildTextPainter(
          romanText,
          secondaryColor,
          romanFontSize,
          romanWeight,
          letterSpace,
          isTranslation: true,
          textAlign: blockTextAlign,
        );
        rTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
        rTp.paint(canvas, Offset(padding.left, lrcPreY));
        lrcPreY += rTp.height;
        recycleTextPainter(rTp);
      }
    }

    // ── Main text ───────────────────────────────────────────────────────────
    final mainTp = _buildTextPainter(
      mainText,
      mainColor,
      fontSize,
      fontWeight,
      letterSpace,
      textAlign: blockTextAlign,
    );
    mainTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
    mainTp.paint(canvas, Offset(padding.left, lrcPreY));

    double cursorY = lrcPreY + mainTp.height;

    // ── Post-original sub-tracks ─────────────────────────────────────────
    if (postTracks.isNotEmpty) {
      cursorY += config.lrcTranslationGap(
        isMainLine: true,
        translationIndex: 0,
      );
      for (final track in postTracks) {
        if (track == LyricLineTrack.translation && transTexts.isNotEmpty) {
          for (final trans in transTexts) {
            final translated = ZhConverter.convert(trans, zhMode);
            final tTp = _buildTextPainter(
              translated,
              translationColor,
              translationFontSize,
              translationWeight,
              letterSpace,
              isTranslation: true,
              textAlign: blockTextAlign,
            );
            tTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
            tTp.paint(canvas, Offset(padding.left, cursorY));
            cursorY += tTp.height;
            recycleTextPainter(tTp);
            if (transTexts.length > 1) {
              cursorY += config.lrcTranslationGap(
                isMainLine: true,
                translationIndex: 0,
              );
            }
          }
        } else if (track == LyricLineTrack.romanization &&
            lrcLine.romanLyric != null) {
          final romanText = ZhConverter.convert(lrcLine.romanLyric!, zhMode);
          final rTp = _buildTextPainter(
            romanText,
            secondaryColor,
            romanFontSize,
            romanWeight,
            letterSpace,
            isTranslation: true,
            textAlign: blockTextAlign,
          );
          rTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
          rTp.paint(canvas, Offset(padding.left, cursorY));
          cursorY += rTp.height;
          recycleTextPainter(rTp);
        }
      }
    }

    // 回收主行 TextPainter
    recycleTextPainter(mainTp);

    canvas.restore();
  }

  void _paintSyncLineAsPlain(Canvas canvas, Size size) {
    final syncLine = line as SyncLyricLine;
    if (syncLine.words.isEmpty) return;

    canvas.save();

    final zhMode = LyricViewController.instance.zhConversionMode;
    final fontSize = config.primaryFontSize(isMainLine: isMainLine);
    final letterSpace = config.letterSpacing(fontSize: fontSize);
    final fontWeight = config.discreteFontWeight(config.fontWeight);
    final verticalPad = config.lrcVerticalPadding();
    final padding = EdgeInsets.only(
      left: 12.0,
      right: 12.0,
      top: verticalPad,
      bottom: verticalPad,
    );

    final isDarkMode = scheme.brightness == Brightness.dark;
    final neutralBase = isDarkMode ? Colors.white : Colors.black;

    final mainPlayedColor = _applyOpacity(neutralBase.withValues(alpha: 1.0));
    final playedColor = useMaterialYouColor
        ? _applyOpacity(scheme.primary.withValues(alpha: 1.0))
        : mainPlayedColor;
    final unplayedColor = _unplayedLyricColor(
      isDarkMode: isDarkMode,
      neutralBase: neutralBase,
    );
    final dimColor = unplayedColor;
    final mainColor = isMainLine ? playedColor : dimColor;
    final secondaryColor = _applyOpacity(
      useMaterialYouColor
          ? scheme.onSurface.withValues(alpha: 0.35)
          : neutralBase.withValues(alpha: 0.25),
    );
    final translationColor = _applyOpacity(
      useMaterialYouColor
          ? scheme.onSurface.withValues(alpha: 0.60)
          : neutralBase.withValues(alpha: 0.70),
    );

    final maxWidth = _wrapContentWidth(size.width, padding);
    final blockTextAlign = switch (_effectiveTextAlign) {
      LyricTextAlign.left => TextAlign.left,
      LyricTextAlign.center => TextAlign.center,
      LyricTextAlign.right => TextAlign.right,
    };

    final mainText = ZhConverter.convert(syncLine.content, zhMode);
    final hasTranslation =
        config.showTranslation &&
        syncLine.translation != null &&
        syncLine.translation!.trim().isNotEmpty;
    final hasRoman =
        config.showRoman &&
        syncLine.romanLyric != null &&
        syncLine.romanLyric!.isNotEmpty;

    final activeTracks = _activeLineTracks(
      config,
      hasTranslation: hasTranslation,
      hasRoman: hasRoman,
    );
    final preTracks = _preOriginalTracks(activeTracks);
    final postTracks = _postOriginalTracks(activeTracks);

    final translationWeight = config.discreteFontWeight(
      (config.fontWeight - 50).clamp(100, 900),
    );
    final romanWeight = config.discreteFontWeight(
      (config.fontWeight - 100).clamp(100, 900),
    );
    final translationFontSize = lyricLayoutFontSize(
      mainFontSize: config.translationFontSize(isMainLine: true),
      subFontSize: config.translationFontSize(isMainLine: false),
    );
    final romanFontSize = translationFontSize * 0.85;

    double preY = padding.top;
    for (final track in preTracks) {
      if (preY > padding.top) preY += 2.0;
      if (track == LyricLineTrack.translation && hasTranslation) {
        final translated = ZhConverter.convert(syncLine.translation!, zhMode);
        final tTp = _buildTextPainter(
          translated,
          translationColor,
          translationFontSize,
          translationWeight,
          letterSpace,
          isTranslation: true,
          textAlign: blockTextAlign,
        );
        tTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
        tTp.paint(canvas, Offset(padding.left, preY));
        preY += tTp.height;
        recycleTextPainter(tTp);
      } else if (track == LyricLineTrack.romanization && hasRoman) {
        final romanText = ZhConverter.convert(syncLine.romanLyric!, zhMode);
        final rTp = _buildTextPainter(
          romanText,
          secondaryColor,
          romanFontSize,
          romanWeight,
          letterSpace,
          isTranslation: true,
          textAlign: blockTextAlign,
        );
        rTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
        rTp.paint(canvas, Offset(padding.left, preY));
        preY += rTp.height;
        recycleTextPainter(rTp);
      }
    }

    final mainTp = _buildTextPainter(
      mainText,
      mainColor,
      fontSize,
      fontWeight,
      letterSpace,
      textAlign: blockTextAlign,
    );
    mainTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
    mainTp.paint(canvas, Offset(padding.left, preY));

    double cursorY = preY + mainTp.height;
    if (postTracks.isNotEmpty) {
      cursorY += config.lrcTranslationGap(
        isMainLine: true,
        translationIndex: 0,
      );
      for (final track in postTracks) {
        if (track == LyricLineTrack.translation && hasTranslation) {
          final translated = ZhConverter.convert(syncLine.translation!, zhMode);
          final tTp = _buildTextPainter(
            translated,
            translationColor,
            translationFontSize,
            translationWeight,
            letterSpace,
            isTranslation: true,
            textAlign: blockTextAlign,
          );
          tTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
          tTp.paint(canvas, Offset(padding.left, cursorY));
          cursorY += tTp.height;
          recycleTextPainter(tTp);
        } else if (track == LyricLineTrack.romanization && hasRoman) {
          final romanText = ZhConverter.convert(syncLine.romanLyric!, zhMode);
          final rTp = _buildTextPainter(
            romanText,
            secondaryColor,
            romanFontSize,
            romanWeight,
            letterSpace,
            isTranslation: true,
            textAlign: blockTextAlign,
          );
          rTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
          rTp.paint(canvas, Offset(padding.left, cursorY));
          cursorY += rTp.height;
          recycleTextPainter(rTp);
        }
      }
    }

    recycleTextPainter(mainTp);
    canvas.restore();
  }

  double _calcWordProgress(
    double currentMs,
    double wordStartMs,
    double wordEndMs,
  ) {
    return lyricWordProgress(
      nowMs: currentMs,
      wordStartMs: wordStartMs,
      wordEndMs: wordEndMs,
    );
  }

  double _highlightTimeMs(
    SyncLyricLine syncLine,
    List<SyncLyricWord> words,
    double currentMs,
  ) {
    if (words.isEmpty) return currentMs;
    final lastWord = words.last;
    final lastWordEnd =
        (lastWord.start.inMilliseconds + lastWord.length.inMilliseconds)
            .toDouble();
    final deadlineMs = accelerateTailHighlight
        ? lastWordEnd + lyricHighlightFinishLeadMs
        : highlightDeadlineMs;
    return lyricHighlightTimeMs(
      currentTimeMs: currentMs,
      lineStartMs: syncLine.start.inMilliseconds.toDouble(),
      lastWordEndMs: lastWordEnd,
      deadlineMs: deadlineMs,
      usesAuthoredTiming: params.usesAuthoredTiming,
    );
  }

  TextPainter _buildTextPainter(
    String text,
    Color color,
    double fontSize,
    FontWeight fontWeight,
    double letterSpacing, {
    bool isTranslation = false,
    TextAlign textAlign = TextAlign.left,
  }) {
    final tp = obtainTextPainter();
    tp.text = TextSpan(
      text: text,
      style: _textStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight,
        letterSpacing: letterSpacing,
        height: isTranslation
            ? config.translationLineHeight(config.fontWeight)
            : config.primaryLineHeight(config.fontWeight),
      ),
    );
    tp.textDirection = TextDirection.ltr;
    tp.textAlign = textAlign;
    return tp;
  }

  @override
  bool shouldRepaint(covariant LyricsLinePainter oldDelegate) {
    return params != oldDelegate.params || liftCache != oldDelegate.liftCache;
  }

  void _captureCharLifts(List<_CharInfo> charInfos) {
    final cache = liftCache;
    if (cache == null) return;
    cache.values = [for (final info in charInfos) info.yLift];
    cache.effectProgress = [for (final info in charInfos) info.effectProgress];
  }

  void _applyExitCharLifts(List<_CharInfo> charInfos) {
    final cache = liftCache;
    if (cache == null || cache.values.isEmpty) return;
    final progress = liftDecayListenable?.value ?? 0.0;
    final last = cache.values;
    final n = charInfos.length < last.length ? charInfos.length : last.length;
    for (var i = 0; i < n; i++) {
      charInfos[i].yLift = lyricExitLift(last[i], progress);
    }
    final effects = cache.effectProgress;
    if (effects.isEmpty) return;
    final m = charInfos.length < effects.length
        ? charInfos.length
        : effects.length;
    for (var i = 0; i < m; i++) {
      charInfos[i].effectProgress = effects[i];
    }
  }

  /// 背景人声完整预留高度：只看内容，不随播放进度变化。
  double _measureBackgroundVocalHeight(
    SyncLyricLine syncLine,
    double lineWidth,
    double fontSize,
  ) {
    final bgFontSize = fontSize * 0.60;
    final bgWeight = config.discreteFontWeight(
      (config.fontWeight - 150).clamp(100, 900),
    );
    final gap = bgFontSize * 0.80; // top + between gaps approx
    var bgHeight = 0.0;
    if (syncLine.bgText != null && syncLine.bgText!.isNotEmpty) {
      final bgTp = _buildTextPainter(
        syncLine.bgText!,
        scheme.onSurface,
        bgFontSize,
        bgWeight,
        config.letterSpacing(fontSize: bgFontSize),
      );
      bgTp.layout(maxWidth: lineWidth);
      bgHeight += gap + bgTp.height;
      recycleTextPainter(bgTp);
    }
    final bgRomanLyric = syncLine.bg?.romanLyric;
    if (config.showRoman && bgRomanLyric != null && bgRomanLyric.isNotEmpty) {
      final bgRomanTp = _buildTextPainter(
        bgRomanLyric,
        scheme.onSurface,
        bgFontSize * 0.85,
        bgWeight,
        config.letterSpacing(fontSize: bgFontSize * 0.85),
      );
      bgRomanTp.layout(maxWidth: lineWidth);
      bgHeight += bgFontSize * 0.45 + bgRomanTp.height;
      recycleTextPainter(bgRomanTp);
    }
    if (syncLine.bgTranslation != null && syncLine.bgTranslation!.isNotEmpty) {
      final bgTransTp = _buildTextPainter(
        syncLine.bgTranslation!,
        scheme.onSurface,
        bgFontSize * 0.90,
        bgWeight,
        config.letterSpacing(fontSize: bgFontSize * 0.90),
      );
      bgTransTp.layout(maxWidth: lineWidth);
      bgHeight += bgFontSize * 0.45 + bgTransTp.height;
      recycleTextPainter(bgTransTp);
    }
    return bgHeight;
  }

  double measureHeight(
    double maxWidth, {
    bool reserveBackgroundVocalHeight = true,
  }) {
    final isSyncLineByLine =
        line is SyncLyricLine &&
        config.displayMode == LyricDisplayMode.lineByLine;
    final double verticalPad;
    if (line is SyncLyricLine && !isSyncLineByLine) {
      verticalPad = config.syncVerticalPadding(isMainLine: true);
    } else {
      verticalPad = config.lrcVerticalPadding();
    }
    final padding = EdgeInsets.only(
      left: 12.0,
      right: 12.0,
      top: verticalPad,
      bottom: verticalPad,
    );
    final lineWidth = _wrapContentWidth(maxWidth, padding);

    if (line.isMetadata) {
      final fontSize = config.primaryFontSize(isMainLine: isMainLine);
      return padding.vertical + fontSize * 0.85 * config.primaryLineHeight();
    }

    if (line is SyncLyricLine && !isSyncLineByLine) {
      final syncLine = line as SyncLyricLine;
      if (syncLine.words.isEmpty) return 0;

      final fontSize = lyricLayoutFontSize(
        mainFontSize: config.primaryFontSize(isMainLine: true),
        subFontSize: config.primaryFontSize(isMainLine: false),
      );
      final fontWeight = config.discreteFontWeight(config.fontWeight);
      final lineH = fontSize * config.primaryLineHeight();

      // 穷举每个字 + 词间 gap，与 _paintSyncLine 完全一致的换行逻辑
      final contentRight = padding.left + lineWidth;
      final layoutCursor = LyricWordLayoutCursor(
        x: padding.left,
        y: 0,
        firstOnLine: true,
      );
      final charTp = obtainTextPainter(); // 复用单个 TextPainter 测量字符宽度
      final family = lyricRenderFontFamily(fontFamily);
      final charStyle = TextStyle(
        fontFamily: family,
        fontFamilyFallback: appFontFamilyFallback(family),
        fontSize: fontSize,
        fontWeight: fontWeight,
        letterSpacing: 0,
        height: config.primaryLineHeight(),
        fontVariations: lyricWeightVariations(family, fontWeight.value),
      );
      final zhMode = LyricViewController.instance.zhConversionMode;
      final convertedChars = <String>[];
      final charWidths = <double>[];
      for (final word in syncLine.words) {
        final wordTotalChars = word.obscene
            ? word.content.runes.length
            : word.content.characters.length;
        if (wordTotalChars == 0) continue;
        convertedChars.clear();
        charWidths.clear();
        var wordWidth = 0.0;
        void measureChar(String ch) {
          final converted = ZhConverter.convert(ch, zhMode);
          final key = '$converted|$fontSize|${fontWeight.value}|$fontFamily';
          final cached = _measureCache[key];
          if (cached != null) {
            convertedChars.add(converted);
            charWidths.add(cached);
            wordWidth += cached;
            return;
          }
          charTp.text = TextSpan(text: converted, style: charStyle);
          charTp.layout();
          final width = charTp.width;
          convertedChars.add(converted);
          charWidths.add(width);
          wordWidth += width;
          _measureCache[key] = width;
          if (_measureCache.length > _maxMeasureCacheSize) {
            _measureCache.remove(_measureCache.keys.first);
          }
        }

        if (word.obscene) {
          final charCount = word.content.runes.length;
          for (var i = 0; i < charCount; i++) {
            measureChar('_');
          }
        } else {
          for (final ch in word.content.characters) {
            measureChar(ch);
          }
        }
        if (!layoutCursor.firstOnLine &&
            layoutCursor.x + wordWidth > contentRight - 1.0) {
          layoutCursor.x = padding.left;
          layoutCursor.y += lineH;
          layoutCursor.firstOnLine = true;
          layoutCursor.visualLineCount++;
        }
        layoutTimedWordChars(
          chars: convertedChars,
          widths: charWidths,
          contentLeft: padding.left,
          contentRight: contentRight,
          lineHeight: lineH,
          cursor: layoutCursor,
        );
        layoutCursor.x += fontSize * 0.12;
      }
      recycleTextPainter(charTp);
      final visualLines = layoutCursor.visualLineCount;

      final double mainHeight = visualLines * lineH;
      double height = padding.vertical + mainHeight;

      final activeTracks = _activeLineTracks(
        config,
        hasTranslation: syncLine.translation != null,
        hasRoman: syncLine.romanLyric != null,
      );
      final preTracks = _preOriginalTracks(activeTracks);
      final postTracks = _postOriginalTracks(activeTracks);

      if (activeTracks.length > 1 ||
          (activeTracks.length == 1 &&
              activeTracks.first != LyricLineTrack.original)) {
        final translationFontSize = lyricLayoutFontSize(
          mainFontSize: config.translationFontSize(isMainLine: true),
          subFontSize: config.translationFontSize(isMainLine: false),
        );
        final romanFontSize = translationFontSize * 0.85;
        final translationWeight = config.discreteFontWeight(
          (config.fontWeight - 50).clamp(100, 900),
        );
        final romanWeight = config.discreteFontWeight(
          (config.fontWeight - 100).clamp(100, 900),
        );

        // pre-original tracks: positioned BEFORE main text
        for (final track in preTracks) {
          if (height > padding.vertical + mainHeight) height += 4.0;
          if (track == LyricLineTrack.translation &&
              syncLine.translation != null) {
            final tTp = _buildTextPainter(
              syncLine.translation!,
              playerThemeForeground(scheme, enabled: useMaterialYouColor),
              translationFontSize,
              translationWeight,
              config.letterSpacing(fontSize: translationFontSize),
              isTranslation: true,
            );
            tTp.layout(maxWidth: lineWidth);
            height += tTp.height;
            recycleTextPainter(tTp);
          } else if (track == LyricLineTrack.romanization &&
              syncLine.romanLyric != null) {
            final rTp = _buildTextPainter(
              syncLine.romanLyric!,
              playerThemeForeground(scheme, enabled: useMaterialYouColor),
              romanFontSize,
              romanWeight,
              config.letterSpacing(fontSize: romanFontSize),
              isTranslation: true,
            );
            rTp.layout(maxWidth: lineWidth);
            height += rTp.height;
            recycleTextPainter(rTp);
          }
        }

        // post-original tracks: positioned AFTER main text
        if (postTracks.isNotEmpty) {
          height += config.syncTranslationGap(isMainLine: true);
          var postPrev = false;
          for (final track in postTracks) {
            if (postPrev) height += 4.0;
            postPrev = true;
            if (track == LyricLineTrack.translation &&
                syncLine.translation != null) {
              final tTp = _buildTextPainter(
                syncLine.translation!,
                playerThemeForeground(scheme, enabled: useMaterialYouColor),
                translationFontSize,
                translationWeight,
                config.letterSpacing(fontSize: translationFontSize),
                isTranslation: true,
              );
              tTp.layout(maxWidth: lineWidth);
              height += tTp.height;
              recycleTextPainter(tTp);
            } else if (track == LyricLineTrack.romanization &&
                syncLine.romanLyric != null) {
              final rTp = _buildTextPainter(
                syncLine.romanLyric!,
                playerThemeForeground(scheme, enabled: useMaterialYouColor),
                romanFontSize,
                romanWeight,
                config.letterSpacing(fontSize: romanFontSize),
                isTranslation: true,
              );
              rTp.layout(maxWidth: lineWidth);
              height += rTp.height;
              recycleTextPainter(rTp);
            }
          }
        }
      }

      // BG 高度跟随进出场因子变化，未开始时不提前占位。
      if (reserveBackgroundVocalHeight &&
          lyricLineHasBackgroundVocal(syncLine)) {
        final backgroundHeightFactor = _bgHeightFactor(syncLine);
        if (backgroundHeightFactor > 0.001) {
          height +=
              _measureBackgroundVocalHeight(syncLine, lineWidth, fontSize) *
              backgroundHeightFactor;
        }
      }

      return height;
    } else if (line is LrcLine) {
      final lrcLine = line as LrcLine;
      final fontSize = config.primaryFontSize(isMainLine: isMainLine);

      final fontWeight = config.discreteFontWeight(config.fontWeight);
      final letterSpace = config.letterSpacing(fontSize: fontSize);
      final blockTextAlign = switch (_effectiveTextAlign) {
        LyricTextAlign.left => TextAlign.left,
        LyricTextAlign.center => TextAlign.center,
        LyricTextAlign.right => TextAlign.right,
      };
      final mainTp = _buildTextPainter(
        lrcLine.content.split('┃').first,
        scheme.onSurface,
        fontSize,
        fontWeight,
        letterSpace,
        textAlign: blockTextAlign,
      );
      mainTp.layout(maxWidth: lineWidth);
      double height = padding.vertical + mainTp.height;

      // 收集所有翻译（含 ┃ 分隔）
      final splited = lrcLine.content.split('┃');
      final transTexts = <String>[];
      if (config.showTranslation &&
          lrcLine.translation != null &&
          lrcLine.translation!.trim().isNotEmpty) {
        transTexts.add(lrcLine.translation!);
      }
      for (var i = 1; i < splited.length; i++) {
        final part = splited[i].trim();
        if (part.isNotEmpty && !transTexts.contains(part)) {
          transTexts.add(part);
        }
      }

      final activeTracks = _activeLineTracks(
        config,
        hasTranslation: transTexts.isNotEmpty,
        hasRoman: lrcLine.romanLyric != null,
      );
      final preTracks = _preOriginalTracks(activeTracks);
      final postTracks = _postOriginalTracks(activeTracks);

      if (activeTracks.length > 1 ||
          (activeTracks.length == 1 &&
              activeTracks.first != LyricLineTrack.original)) {
        final translationFontSize = lyricLayoutFontSize(
          mainFontSize: config.translationFontSize(isMainLine: true),
          subFontSize: config.translationFontSize(isMainLine: false),
        );
        final romanFontSize = translationFontSize * 0.85;
        final translationWeight = config.discreteFontWeight(
          (config.fontWeight - 50).clamp(100, 900),
        );
        final romanWeight = config.discreteFontWeight(
          (config.fontWeight - 100).clamp(100, 900),
        );

        // pre-original tracks
        final lrcPreBase = height;
        for (final track in preTracks) {
          if (height > lrcPreBase) height += 2.0;
          if (track == LyricLineTrack.translation && transTexts.isNotEmpty) {
            for (final trans in transTexts) {
              final tTp = _buildTextPainter(
                trans,
                scheme.onSurface,
                translationFontSize,
                translationWeight,
                config.letterSpacing(fontSize: translationFontSize),
                isTranslation: true,
              );
              tTp.layout(maxWidth: lineWidth);
              height += tTp.height;
              recycleTextPainter(tTp);
            }
          } else if (track == LyricLineTrack.romanization &&
              lrcLine.romanLyric != null) {
            final rTp = _buildTextPainter(
              lrcLine.romanLyric!,
              scheme.onSurface,
              romanFontSize,
              romanWeight,
              config.letterSpacing(fontSize: romanFontSize),
              isTranslation: true,
            );
            rTp.layout(maxWidth: lineWidth);
            height += rTp.height;
            recycleTextPainter(rTp);
          }
        }

        // post-original tracks
        if (postTracks.isNotEmpty) {
          height += config.lrcTranslationGap(
            isMainLine: true,
            translationIndex: 0,
          );
          for (final track in postTracks) {
            if (track == LyricLineTrack.translation && transTexts.isNotEmpty) {
              for (final trans in transTexts) {
                final tTp = _buildTextPainter(
                  trans,
                  scheme.onSurface,
                  translationFontSize,
                  translationWeight,
                  config.letterSpacing(fontSize: translationFontSize),
                  isTranslation: true,
                );
                tTp.layout(maxWidth: lineWidth);
                height += tTp.height;
                recycleTextPainter(tTp);
              }
            } else if (track == LyricLineTrack.romanization &&
                lrcLine.romanLyric != null) {
              final rTp = _buildTextPainter(
                lrcLine.romanLyric!,
                scheme.onSurface,
                romanFontSize,
                romanWeight,
                config.letterSpacing(fontSize: romanFontSize),
                isTranslation: true,
              );
              rTp.layout(maxWidth: lineWidth);
              height += rTp.height;
              recycleTextPainter(rTp);
            }
            if (postTracks.length > 1) height += 4.0;
          }
        }
      }
      recycleTextPainter(mainTp);
      return height;
    } else if (line is SyncLyricLine) {
      final syncLine = line as SyncLyricLine;
      if (syncLine.words.isEmpty) return 0;
      final fontSize = config.primaryFontSize(isMainLine: isMainLine);
      final fontWeight = config.discreteFontWeight(config.fontWeight);
      final letterSpace = config.letterSpacing(fontSize: fontSize);
      final blockTextAlign = switch (_effectiveTextAlign) {
        LyricTextAlign.left => TextAlign.left,
        LyricTextAlign.center => TextAlign.center,
        LyricTextAlign.right => TextAlign.right,
      };
      final mainTp = _buildTextPainter(
        syncLine.content,
        scheme.onSurface,
        fontSize,
        fontWeight,
        letterSpace,
        textAlign: blockTextAlign,
      );
      mainTp.layout(maxWidth: lineWidth);
      double height = padding.vertical + mainTp.height;
      final hasTranslation =
          config.showTranslation &&
          syncLine.translation != null &&
          syncLine.translation!.trim().isNotEmpty;
      final hasRoman =
          config.showRoman &&
          syncLine.romanLyric != null &&
          syncLine.romanLyric!.isNotEmpty;
      final activeTracks = _activeLineTracks(
        config,
        hasTranslation: hasTranslation,
        hasRoman: hasRoman,
      );
      final preTracks = _preOriginalTracks(activeTracks);
      final postTracks = _postOriginalTracks(activeTracks);
      if (activeTracks.length > 1 ||
          (activeTracks.length == 1 &&
              activeTracks.first != LyricLineTrack.original)) {
        final translationFontSize = lyricLayoutFontSize(
          mainFontSize: config.translationFontSize(isMainLine: true),
          subFontSize: config.translationFontSize(isMainLine: false),
        );
        final romanFontSize = translationFontSize * 0.85;
        final translationWeight = config.discreteFontWeight(
          (config.fontWeight - 50).clamp(100, 900),
        );
        final romanWeight = config.discreteFontWeight(
          (config.fontWeight - 100).clamp(100, 900),
        );
        for (final track in preTracks) {
          if (height > padding.vertical + mainTp.height) height += 2.0;
          if (track == LyricLineTrack.translation && hasTranslation) {
            final tTp = _buildTextPainter(
              syncLine.translation!,
              scheme.onSurface,
              translationFontSize,
              translationWeight,
              config.letterSpacing(fontSize: translationFontSize),
              isTranslation: true,
            );
            tTp.layout(maxWidth: lineWidth);
            height += tTp.height;
            recycleTextPainter(tTp);
          } else if (track == LyricLineTrack.romanization && hasRoman) {
            final rTp = _buildTextPainter(
              syncLine.romanLyric!,
              scheme.onSurface,
              romanFontSize,
              romanWeight,
              config.letterSpacing(fontSize: romanFontSize),
              isTranslation: true,
            );
            rTp.layout(maxWidth: lineWidth);
            height += rTp.height;
            recycleTextPainter(rTp);
          }
        }
        if (postTracks.isNotEmpty) {
          height += config.lrcTranslationGap(
            isMainLine: true,
            translationIndex: 0,
          );
          for (final track in postTracks) {
            if (track == LyricLineTrack.translation && hasTranslation) {
              final tTp = _buildTextPainter(
                syncLine.translation!,
                scheme.onSurface,
                translationFontSize,
                translationWeight,
                config.letterSpacing(fontSize: translationFontSize),
                isTranslation: true,
              );
              tTp.layout(maxWidth: lineWidth);
              height += tTp.height;
              recycleTextPainter(tTp);
            } else if (track == LyricLineTrack.romanization && hasRoman) {
              final rTp = _buildTextPainter(
                syncLine.romanLyric!,
                scheme.onSurface,
                romanFontSize,
                romanWeight,
                config.letterSpacing(fontSize: romanFontSize),
                isTranslation: true,
              );
              rTp.layout(maxWidth: lineWidth);
              height += rTp.height;
              recycleTextPainter(rTp);
            }
            if (postTracks.length > 1) height += 4.0;
          }
        }
      }
      recycleTextPainter(mainTp);
      return height;
    }
    return 60;
  }
}
