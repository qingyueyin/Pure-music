import 'dart:math' show cos, pi;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/zh_converter.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/ttml.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';

const _bgEnterMs = 650.0;
const _bgExitMs = 1400.0;
const _bgExitHoldMs = 600.0;
const _bgEnterOffsetY = 8.0;
const _bgScaleRange = 0.08;

enum LyricWordEffect { none, scale, scaleAndGlow }

LyricWordEffect lyricWordEffect({
  required bool isTtml,
  required bool isMerged,
  required Duration duration,
}) {
  const scaleThreshold = Duration(milliseconds: 800);
  const glowThreshold = Duration(milliseconds: 1200);
  if (isTtml) {
    if (isMerged) return LyricWordEffect.scaleAndGlow;
    return duration >= scaleThreshold
        ? LyricWordEffect.scale
        : LyricWordEffect.none;
  }
  if (duration >= glowThreshold) return LyricWordEffect.scaleAndGlow;
  if (duration >= scaleThreshold) return LyricWordEffect.scale;
  return LyricWordEffect.none;
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
  final int wordIndex;
  final bool isPlaying;
  final double wordDurationSec; // 词时长（秒），用于辉光阈值判断
  final bool isMerged; // 多 span 合并产生（TTML），决定辉光

  _CharInfo({
    required this.char,
    required this.x,
    required this.y,
    required this.width,
    required this.yLift,
    required this.charProgress,
    required this.wordProgress,
    required this.wordIndex,
    required this.isPlaying,
    required this.wordDurationSec,
    required this.isMerged,
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
  final double maxCharProgress;
  final bool isPlayingMerged;
  final bool isMerged;
  final bool isPlayed;
  final double wordProgress;
  final double wordDurationSec;

  _WordPaintInfo({
    required this.chars,
    required this.text,
    required this.hasLift,
    required this.maxCharProgress,
    required this.isPlayingMerged,
    required this.isMerged,
    required this.isPlayed,
    required this.wordProgress,
    required this.wordDurationSec,
  });

  bool get isEmpty => chars.isEmpty;
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

class LyricsLinePainter extends CustomPainter {
  final LyricLine line;
  final double currentTimeMs;
  final ValueListenable<double>? currentTimeListenable;
  final double blurSigma;
  final LyricRenderConfig config;
  final ColorScheme scheme;
  final bool isMainLine;
  final bool useMaterialYouColor;
  final String? fontFamily;
  final String? agent;
  final double opacity;

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
  static const _maxBlurFilterCacheSize = 12;
  static final _blurPaintCache = <int, Paint>{};
  static const _maxBlurPaintCacheSize = 64;

  const LyricsLinePainter({
    required this.line,
    required this.currentTimeMs,
    this.currentTimeListenable,
    required this.blurSigma,
    required this.config,
    required this.scheme,
    this.isMainLine = false,
    this.useMaterialYouColor = false,
    this.fontFamily,
    this.agent,
    this.opacity = 1.0,
  }) : super(repaint: currentTimeListenable);

  double get _effectiveCurrentTimeMs =>
      currentTimeListenable?.value ?? currentTimeMs;

  double get _opacityFactor => opacity.clamp(0.0, 1.0).toDouble();

  Color _applyOpacity(Color color) {
    final factor = _opacityFactor;
    if (factor >= 0.999) return color;
    return color.withValues(alpha: color.a * factor);
  }

  Paint? _blurForeground(Color color) {
    if (blurSigma <= 0.01 || color.a <= 0.0) return null;
    final sigmaKey = (blurSigma * 2).round();
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
    return TextStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
      color: foreground == null ? color : null,
      foreground: foreground,
      fontWeight: fontWeight,
      letterSpacing: letterSpacing,
      shadows: shadows,
      height: height,
      fontVariations: fontFamily == null
          ? [FontVariation('wght', fontWeight.value.toDouble())]
          : null,
    );
  }

  TextStyle _copyTextStyleWithForeground(
    TextStyle base,
    Paint foreground, {
    List<Shadow>? shadows,
  }) {
    return TextStyle(
      fontFamily: base.fontFamily,
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

  static MaskFilter _blurFilter(double sigma) {
    final key = (sigma * 2).roundToDouble() / 2;
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
    final hitRate =
        total > 0 ? (_poolHitCount / total * 100).toStringAsFixed(1) : '0.0';
    return 'Pool: size=${_textPainterPool.length}/$_maxPoolSize, hit=$hitRate%';
  }

  double _bgMotionValue(SyncLyricLine syncLine) {
    if (!isMainLine) return 0.0;
    final currentTimeMs = _effectiveCurrentTimeMs;
    final start = (syncLine.bgStart ?? syncLine.bg?.start ?? syncLine.start)
        .inMilliseconds
        .toDouble();
    final end = _bgEndMs(syncLine);
    if (end <= start) return 1.0;
    final enter = Curves.easeOutCubic
        .transform(((currentTimeMs - start) / _bgEnterMs).clamp(0.0, 1.0));
    if (currentTimeMs <= end) return enter;
    final exit = Curves.easeInCubic.transform(
      ((end + _bgExitHoldMs + _bgExitMs - currentTimeMs) / _bgExitMs)
          .clamp(0.0, 1.0),
    );
    return enter * exit;
  }

  double _bgEndMs(SyncLyricLine syncLine) {
    var end = (syncLine.bgEnd ??
            syncLine.bg?.end ??
            (syncLine.start + syncLine.length))
        .inMilliseconds
        .toDouble();
    if (syncLine.bgWords.isNotEmpty) {
      final last = syncLine.bgWords.last;
      final lastEnd =
          (last.start.inMilliseconds + last.length.inMilliseconds).toDouble();
      if (lastEnd > end) end = lastEnd;
    }
    return end;
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

  @override
  void paint(Canvas canvas, Size size) {
    if (line is SyncLyricLine &&
        config.displayMode == LyricDisplayMode.wordByWord) {
      _paintSyncLine(canvas, size);
    } else if (line is SyncLyricLine) {
      _paintSyncLineAsPlain(canvas, size);
    } else if (line is LrcLine) {
      _paintLrcLine(canvas, size);
    }
  }

  void _paintSyncLine(Canvas canvas, Size size) {
    final syncLine = line as SyncLyricLine;
    if (syncLine.words.isEmpty) return;
    final isTtml = syncLine is TtmlLine;

    LyricWordEffect effectFor({
      required bool isMerged,
      required double wordDurationSec,
    }) {
      return lyricWordEffect(
        isTtml: isTtml,
        isMerged: isMerged,
        duration: Duration(
          microseconds:
              (wordDurationSec * Duration.microsecondsPerSecond).round(),
        ),
      );
    }

    canvas.save();

    final fontSize = config.primaryFontSize(isMainLine: isMainLine);
    final letterSpace = config.letterSpacing(fontSize: fontSize);
    final fontWeight = config.discreteFontWeight(config.fontWeight);
    final verticalPad = config.syncVerticalPadding(isMainLine: true);
    final padding = EdgeInsets.only(
        left: 12.0, right: 12.0, top: verticalPad, bottom: verticalPad);
    // 行高：TextStyle.height=1.2 → fontSize*1.2，与 TextPainter.layout 结果等价
    final lineHeight = fontSize * config.primaryLineHeight();

    final isDarkMode = scheme.brightness == Brightness.dark;

    final mainPlayedColor = _applyOpacity(scheme.onSurface.withValues(alpha: 1.0));
    final playedColor = useMaterialYouColor
        ? _applyOpacity(scheme.primary.withValues(alpha: 1.0))
        : mainPlayedColor;
    final unplayedColor = _applyOpacity(useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: isDarkMode ? 0.40 : 0.50)
        : scheme.onSurface.withValues(alpha: isDarkMode ? 0.35 : 0.45));
    final secondaryColor = _applyOpacity(useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: 0.35)
        : scheme.onSurface.withValues(alpha: 0.25));
    final translationColor = _applyOpacity(useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: 0.60)
        : scheme.onSurface.withValues(alpha: 0.70));

    final maxWidth = size.width - padding.horizontal;

    final zhMode = LyricViewController.instance.zhConversionMode;

    final translationWeight =
        config.discreteFontWeight((config.fontWeight - 50).clamp(100, 900));
    final romanWeight =
        config.discreteFontWeight((config.fontWeight - 100).clamp(100, 900));

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
      final translationFontSize =
          config.translationFontSize(isMainLine: isMainLine);
      final romanFontSize = translationFontSize * 0.85;
      var hasPrev = false;
      for (final track in preTracks) {
        if (hasPrev) preCursorY += 4.0;
        hasPrev = true;
        if (track == LyricLineTrack.translation && syncLine.translation != null) {
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
        } else if (track == LyricLineTrack.romanization && syncLine.romanLyric != null) {
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
    TextStyle measureStyle(double fs, FontWeight fw) => TextStyle(
          fontFamily: fontFamily,
          fontSize: fs,
          fontWeight: fw,
          letterSpacing: 0,
          height: config.primaryLineHeight(),
          fontVariations: fontFamily == null
              ? [FontVariation('wght', fw.value.toDouble())]
              : null,
        );

    // ── Collect all character positions ─────────────────────────────────────
    final charInfos = <_CharInfo>[];
    double cursorX = padding.left;
    double cursorY = preTracks.isNotEmpty ? preCursorY : padding.top;
    bool firstOnLine = true;
    final currentTimeMs = _effectiveCurrentTimeMs;

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
          measureTp.text =
              TextSpan(text: char, style: measureStyle(fontSize, fontWeight));
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

      final contentRight = padding.left + maxWidth;
      if (!firstOnLine && cursorX + wordWidth > contentRight - 1.0) {
        cursorX = padding.left;
        cursorY += lineHeight;
        firstOnLine = true;
      }

      // ── 词级波浪窗口进度计算 ───────────────────────────
      // stepRatio = 0.1：前一个字动画跑到 10% 时，后一个字开始
      // waveWidth = 1.0 / (stepRatio * (charCount - 1) + 1.0)
      // windowStart[i] = i * stepRatio * waveWidth
      // charProgress = (wordProgress - windowStart[i]) / waveWidth
      const stepRatio = 0.1;
      final waveWidth = 1.0 / (stepRatio * (wordTotalChars - 1) + 1.0);

      final wordProgress = _calcWordProgress(
        currentTimeMs,
        wordStartMs,
        wordEndMs,
      );

      double? prevNonPunctProgress;
      int animIndex = 0;

      for (int i = 0; i < convertedChars.length; i++) {
        final char = convertedChars[i];
        if (char == ' ' && firstOnLine) continue;
        if (_isZeroWidth(char)) continue;

        // 词级波浪窗口：每个字符有启动偏移，形成连贯波浪
        final windowStart = animIndex * stepRatio * waveWidth;
        final computedProgress =
            ((wordProgress - windowStart) / waveWidth).clamp(0.0, 1.0);

        final double charProgress;
        final isPunctuation = _isPunctuation(char);
        if (isPunctuation && prevNonPunctProgress != null) {
          charProgress = prevNonPunctProgress;
        } else {
          charProgress = computedProgress;
          if (!isPunctuation) {
            prevNonPunctProgress = computedProgress;
          }
        }

        final liftProgress = _calcLiftProgress(charProgress, wordProgress);
        final isPlaying =
            currentTimeMs >= wordStartMs && currentTimeMs < wordEndMs;

        final double yLift;
        if (isMainLine && config.liftStyle == LyricLiftStyle.cosine) {
          yLift = 0.0;
        } else if (isMainLine && liftProgress > 0.0) {
          final elapsedMs = currentTimeMs - wordStartMs;
          final durationProgress =
              (elapsedMs / config.liftDurationMs).clamp(0.0, 1.0).toDouble();
          final blended =
              _calcLiftProgress(charProgress, durationProgress);
          yLift = Curves.easeOutCubic.transform(blended) * -config.liftPeak;
        } else {
          yLift = 0.0;
        }

        final charWidth = charWidths[i];
        final isSpace = char == ' ';

        if (isSpace && firstOnLine) continue;

        charInfos.add(_CharInfo(
          char: char,
          x: cursorX,
          y: cursorY,
          width: charWidth,
          yLift: yLift,
          charProgress: charProgress,
          wordProgress: wordProgress,
          wordIndex: wordIndex,
          isPlaying: isPlaying,
          wordDurationSec: wordDurationSec,
          isMerged: word.isMerged,
        ));

        cursorX += charWidth;
        firstOnLine = false;
        animIndex++;
      }
      // 词间间距，匹配 Widget 路径的 SizedBox(width: primarySize * 0.12)
      cursorX += fontSize * 0.12;
    }
    cursorY += lineHeight;

    if (charInfos.isEmpty) {
      recycleTextPainter(measureTp);
      canvas.restore();
      return;
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
            wordIndex: original.wordIndex,
            isPlaying: original.isPlaying,
            wordDurationSec: original.wordDurationSec,
            isMerged: original.isMerged,
          );
        }
      }
      // 重建 charInfos，确保 Pass 1 也使用对齐后的坐标
      charInfos.clear();
      for (final group in lineGroups) {
        charInfos.addAll(group.chars);
      }
    }

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
    void paintWord(_WordPaintInfo word, TextStyle style, bool useLift,
        {bool applyScale = false, Color? glowColor, double glowAlpha = 0.0}) {
      final wc = word.chars;
      final bool hasGlow = glowColor != null && glowAlpha > 0.02;

      if (useLift) {
        final wordDurationSec = wc.first.wordDurationSec;
        final effect = effectFor(
          isMerged: wc.first.isMerged,
          wordDurationSec: wordDurationSec,
        );
        final enableEffect = applyScale && effect != LyricWordEffect.none;

        for (final info in wc) {
          final charProgress = info.charProgress;
          final isPlaying = charProgress > 0.0 && charProgress < 1.0;
          double scale = 1.0;
          if (enableEffect && isPlaying) {
            final effectRatio =
                ((wordDurationSec - 0.8) / (3.0 - 0.8))
                    .clamp(0.0, 1.0);
            final ripplesScaleMax = 1.1 + 0.05 * effectRatio;

            final animationCurve = _liftEffectCurve(
              charProgress, config.liftStyle);
            scale = 1.0 + (ripplesScaleMax - 1.0) * animationCurve;
          }

          // ── Glow layer (rendered first, behind text) ────────────────
          if (hasGlow && isPlaying) {
            final glowAlphaAdjusted = glowColor.a * glowAlpha;
            if (glowAlphaAdjusted > 0.02) {
              final gp = Paint()
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
                ..color = glowColor.withValues(alpha: glowAlphaAdjusted);
              tp.text = TextSpan(
                text: info.char,
                style: style.copyWith(
                  color: null,
                  foreground: gp,
                  shadows: null,
                ),
              );
              tp.layout();
              if (scale != 1.0) {
                canvas.save();
                final cx = info.x + tp.width / 2;
                final by = info.y + info.yLift + tp.height;
                canvas.translate(cx, by);
                canvas.scale(scale);
                canvas.translate(-cx, -by);
              }
              tp.paint(canvas, Offset(info.x, info.y + info.yLift));
              if (scale != 1.0) canvas.restore();
            }
          }

          // ── Main text layer ─────────────────────────────────────────
          tp.text = TextSpan(text: info.char, style: style);
          tp.layout();

          if (scale != 1.0) {
            canvas.save();
            final centerX = info.x + tp.width / 2;
            final bottomY = info.y + info.yLift + tp.height;
            canvas.translate(centerX, bottomY);
            canvas.scale(scale);
            canvas.translate(-centerX, -bottomY);
          }

          tp.paint(canvas, Offset(info.x, info.y + info.yLift));

          if (scale != 1.0) {
            canvas.restore();
          }
        }
      } else {
        var hasActiveGlowChar = false;
        if (hasGlow) {
          for (final info in wc) {
            if (info.charProgress > 0.0 && info.charProgress < 1.0) {
              hasActiveGlowChar = true;
              break;
            }
          }
        }
        if (hasGlow && hasActiveGlowChar) {
          for (final info in wc) {
            final isPlaying =
                info.charProgress > 0.0 && info.charProgress < 1.0;
            if (isPlaying) {
              final glowAlphaAdjusted = glowColor.a * glowAlpha;
              if (glowAlphaAdjusted > 0.02) {
                final gp = Paint()
                  ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
                  ..color = glowColor.withValues(alpha: glowAlphaAdjusted);
                tp.text = TextSpan(
                  text: info.char,
                  style: style.copyWith(
                    color: null,
                    foreground: gp,
                    shadows: null,
                  ),
                );
                tp.layout();
                tp.paint(canvas, Offset(info.x, info.y));
              }
            }
            tp.text = TextSpan(text: info.char, style: style);
            tp.layout();
            tp.paint(canvas, Offset(info.x, info.y));
          }
        } else {
          tp.text = TextSpan(text: word.text, style: style);
          tp.layout();
          tp.paint(canvas, Offset(wc.first.x, wc.first.y));
        }
      }
    }

    // ── Per visual line ────────────────────────────────────────────────────
    _CharInfo? prevGlowTailPos; // 上一行末合并词的尾字位置，用于行间辉光桥接
    for (final group in lineGroups) {
      if (group.chars.isEmpty) continue;

      final words = <_WordPaintInfo>[];
      List<_CharInfo>? currentChars;
      StringBuffer? currentText;
      var currentHasLift = false;
      var currentMaxCharProgress = 0.0;
      int? currentWordIndex;
      var lineHasPlayingMerged = false;
      var lineFullyPlayed = true;
      void finishWord() {
        final chars = currentChars;
        final text = currentText;
        if (chars == null || text == null || chars.isEmpty) return;
        final first = chars.first;
        final word = _WordPaintInfo(
          chars: chars,
          text: text.toString(),
          hasLift: currentHasLift,
          maxCharProgress: currentMaxCharProgress,
          isPlayingMerged: first.isPlaying && first.isMerged,
          isMerged: first.isMerged,
          isPlayed: first.wordProgress >= 1.0,
          wordProgress: first.wordProgress,
          wordDurationSec: first.wordDurationSec,
        );
        words.add(word);
        lineHasPlayingMerged = lineHasPlayingMerged || word.isPlayingMerged;
        lineFullyPlayed = lineFullyPlayed && word.wordProgress >= 0.999;
      }

      for (final info in group.chars) {
        if (currentChars == null || info.wordIndex != currentWordIndex) {
          finishWord();
          currentChars = <_CharInfo>[];
          currentText = StringBuffer();
          currentHasLift = false;
          currentMaxCharProgress = 0.0;
          currentWordIndex = info.wordIndex;
        }
        currentChars.add(info);
        currentText!.write(info.char);
        currentHasLift = currentHasLift || info.yLift != 0.0;
        if (info.charProgress > currentMaxCharProgress) {
          currentMaxCharProgress = info.charProgress;
        }
      }
      finishWord();

      if (!isMainLine) {
        for (final wc in words) {
          paintWord(wc, dimStyle, false);
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
        reveal += wc.length.toDouble() * wp;
        prevR = wR;
      }
      if (reveal <= 0.0) {
        for (final wc in words) {
          paintWord(wc, dimStyle, false);
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
          paintWord(wc, dimStyle, false);
        }
        if (config.enableGlow) {
          if (prevGlowTailPos != null && lineHasPlayingMerged) {
            _paintGlowTail(canvas, prevGlowTailPos, playedStyle);
          }
        }
        final lastWord = words.lastOrNull;
        if (lastWord != null) {
          if (lastWord.isMerged && lastWord.isPlayed) {
            prevGlowTailPos = lastWord.last;
          } else {
            prevGlowTailPos = null;
          }
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

      // ── Cosine lift recomputation (needs final X + highlightR) ──
      if (config.liftStyle == LyricLiftStyle.cosine && isMainLine) {
        for (final wc in words) {
          for (final info in wc.chars) {
    info.yLift = _calcCosineLift(
      info.x + info.width / 2, highlightR, right, fontSize);
            if (info.yLift != 0.0) wc.hasLift = true;
          }
        }
      }

      // ── Pass 1: dim（与 played 共用 scale，避免分层）────────────
      for (final wc in words) {
        paintWord(wc, dimStyle, wc.hasLift, applyScale: config.enableGlow);
      }

      final glowColor = playedTextColor;
      double glowAlphaFor(_WordPaintInfo word) {
        if (!config.enableGlow ||
            effectFor(
                  isMerged: word.isMerged,
                  wordDurationSec: word.wordDurationSec,
                ) !=
                LyricWordEffect.scaleAndGlow) {
          return 0.0;
        }
        final progress = word.wordProgress;
        if (progress <= 0.0 || progress >= 1.0) return 0.0;
        final maxProgress = word.maxCharProgress;
        if (maxProgress <= 0.0) return 0.0;
        final curve = _liftEffectCurve(maxProgress, config.liftStyle);
        return (0.5 * curve).clamp(0.0, 1.0);
      }

      // 行间辉光桥接
      if (config.enableGlow) {
        if (prevGlowTailPos != null && lineHasPlayingMerged) {
          _paintGlowTail(canvas, prevGlowTailPos, playedStyle);
        }
      }
      // 记录上一行末合并词的尾字
      final lastWord = words.lastOrNull;
      if (lastWord != null) {
        if (lastWord.isMerged && lastWord.isPlayed) {
          prevGlowTailPos = lastWord.last;
        } else {
          prevGlowTailPos = null;
        }
      }

      // ── Pass 2: played 文字层（含辉光 shadow）────────────────────
      void paintPlayedLayer(TextStyle style, {bool glow = true}) {
        for (final wc in words) {
          final glowAlpha = glow ? glowAlphaFor(wc) : 0.0;
          paintWord(
            wc,
            style,
            wc.hasLift,
            applyScale: config.enableGlow,
            glowColor: glowAlpha > 0.02 ? glowColor : null,
            glowAlpha: glowAlpha,
          );
        }
      }

      // Soft sweep highlight: old visual feel without saveLayer masking.
      if (lineFullyPlayed || clippedHighlightR >= right - 0.5) {
        paintPlayedLayer(playedStyle);
      } else if (clippedHighlightR > left) {
        canvas.save();
        canvas.clipRect(playedClip);
        paintPlayedLayer(gradientPlayedStyle, glow: true);
        canvas.restore();
      }
    }

    // ── Post-original sub-tracks ─────────────────────────────────────────────
    if (postTracks.isNotEmpty) {
      final blockTextAlign = switch (_effectiveTextAlign) {
        LyricTextAlign.left => TextAlign.left,
        LyricTextAlign.center => TextAlign.center,
        LyricTextAlign.right => TextAlign.right,
      };
      final translationFontSize =
          config.translationFontSize(isMainLine: isMainLine);
      final romanFontSize = translationFontSize * 0.85;
      cursorY += config.syncTranslationGap(isMainLine: true);
      var hasPrev = false;
      for (final track in postTracks) {
        if (hasPrev) cursorY += 4.0;
        hasPrev = true;
        if (track == LyricLineTrack.translation && syncLine.translation != null) {
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
          tp.paint(canvas, Offset(padding.left, cursorY));
          cursorY += tp.height;
          recycleTextPainter(tp);
        } else if (track == LyricLineTrack.romanization && syncLine.romanLyric != null) {
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

    // ── Background vocal (和声) ─────────────────────────────────────────────
    // 顺序：原文 -> 翻译 -> 和声 -> 和声翻译
    // 和声默认不显示，当前行激活时随整体透明度平滑切入
    final bgText = syncLine.bgText;
    final bgTranslation = syncLine.bgTranslation;
    final hasBg = bgText != null && bgText.isNotEmpty;
    final hasBgTranslation = bgTranslation != null && bgTranslation.isNotEmpty;
    if (hasBg || hasBgTranslation) {
      final bgMotion = _bgMotionValue(syncLine);
      final bgAlpha = bgMotion;
      if (bgAlpha > 0.001) {
        final bgFontSize = fontSize * 0.60;
        final bgWeight = config.discreteFontWeight(
          (config.fontWeight - 150).clamp(100, 900),
        );
        final blockTextAlign = switch (_effectiveTextAlign) {
          LyricTextAlign.left => TextAlign.left,
          LyricTextAlign.center => TextAlign.center,
          LyricTextAlign.right => TextAlign.right,
        };

        void paintBgLine(String text, double size, Color color) {
          final tp = _buildTextPainter(
            ZhConverter.convert(text, zhMode),
            color.withValues(alpha: color.a * bgAlpha * _opacityFactor),
            size,
            bgWeight,
            letterSpace,
            textAlign: blockTextAlign,
          );
          tp.layout(minWidth: maxWidth, maxWidth: maxWidth);
          cursorY += bgFontSize * 0.45; // gap
          tp.paint(canvas, Offset(padding.left, cursorY));
          cursorY += tp.height;
          recycleTextPainter(tp);
        }

        cursorY += bgFontSize * 0.35; // extra top gap before bg block
        canvas.save();
        final bgOffsetY = (1.0 - bgMotion) * _bgEnterOffsetY;
        final bgScale = 1.0 - (1.0 - bgMotion) * _bgScaleRange;
        final scaleX = switch (_effectiveTextAlign) {
          LyricTextAlign.left => padding.left,
          LyricTextAlign.center => size.width / 2,
          LyricTextAlign.right => size.width - padding.right,
        };
        canvas.translate(scaleX, cursorY + bgOffsetY);
        canvas.scale(bgScale, bgScale);
        canvas.translate(-scaleX, -cursorY);
        if (hasBg) {
          paintBgLine(
            bgText,
            bgFontSize,
            secondaryColor,
          );
          // 回收 TextPainter
        }
        if (hasBgTranslation) {
          paintBgLine(
            bgTranslation,
            bgFontSize * 0.90,
            secondaryColor,
          );
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
        left: 12.0, right: 12.0, top: verticalPad, bottom: verticalPad);

    final isDarkMode = scheme.brightness == Brightness.dark;

    final mainPlayedColor = _applyOpacity(scheme.onSurface.withValues(alpha: 1.0));
    final playedColor = useMaterialYouColor
        ? _applyOpacity(scheme.primary.withValues(alpha: 1.0))
        : mainPlayedColor;
    final unplayedColor = _applyOpacity(useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: isDarkMode ? 0.40 : 0.50)
        : scheme.onSurface.withValues(alpha: isDarkMode ? 0.35 : 0.45));
    final dimColor = unplayedColor;
    final mainColor = isMainLine ? playedColor : dimColor;
    final metadataColor =
        _applyOpacity(scheme.onSurface.withValues(alpha: 0.70));
    final secondaryColor = _applyOpacity(useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: 0.35)
        : scheme.onSurface.withValues(alpha: 0.25));
    final translationColor = _applyOpacity(useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: 0.60)
        : scheme.onSurface.withValues(alpha: 0.70));

    final maxWidth = size.width - padding.horizontal;
    final blockTextAlign = switch (_effectiveTextAlign) {
      LyricTextAlign.left => TextAlign.left,
      LyricTextAlign.center => TextAlign.center,
      LyricTextAlign.right => TextAlign.right,
    };

    // ── 元数据行：特殊样式（匹配 Widget isMetadata 分支）──────────────────
    if (lrcLine.isMetadata) {
      final metaFontSize = fontSize * 0.85;
      final metaWeight =
          config.discreteFontWeight((config.fontWeight - 100).clamp(100, 900));
      final metaText = ZhConverter.convert(lrcLine.content, zhMode);
      final metaTp = _buildTextPainter(
        metaText,
        metadataColor,
        metaFontSize,
        metaWeight,
        letterSpace,
        textAlign: blockTextAlign,
      );
      metaTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
      metaTp.paint(canvas, Offset(padding.left, padding.top));
      recycleTextPainter(metaTp);
      canvas.restore();
      return;
    }

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

    final translationWeight =
        config.discreteFontWeight((config.fontWeight - 50).clamp(100, 900));
    final romanWeight =
        config.discreteFontWeight((config.fontWeight - 100).clamp(100, 900));
    final translationFontSize = config.translationFontSize(isMainLine: true);
    final romanFontSize = translationFontSize * 0.85;

    // ── Paint pre-original sub-tracks (before main text) ─────────────────────
    double lrcPreY = padding.top;
    for (final track in preTracks) {
      if (lrcPreY > padding.top) lrcPreY += 2.0;
      if (track == LyricLineTrack.translation && transTexts.isNotEmpty) {
        for (final trans in transTexts) {
          final translated = ZhConverter.convert(trans, zhMode);
          final tTp = _buildTextPainter(
            translated, translationColor, translationFontSize,
            translationWeight, letterSpace,
            isTranslation: true, textAlign: blockTextAlign,
          );
          tTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
          tTp.paint(canvas, Offset(padding.left, lrcPreY));
          lrcPreY += tTp.height;
          recycleTextPainter(tTp);
        }
      } else if (track == LyricLineTrack.romanization && lrcLine.romanLyric != null) {
        final romanText = ZhConverter.convert(lrcLine.romanLyric!, zhMode);
        final rTp = _buildTextPainter(
          romanText, secondaryColor, romanFontSize,
          romanWeight, letterSpace,
          isTranslation: true, textAlign: blockTextAlign,
        );
        rTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
        rTp.paint(canvas, Offset(padding.left, lrcPreY));
        lrcPreY += rTp.height;
        recycleTextPainter(rTp);
      }
    }

    // ── Main text ───────────────────────────────────────────────────────────
    final mainTp = _buildTextPainter(
      mainText, mainColor, fontSize, fontWeight, letterSpace,
      textAlign: blockTextAlign,
    );
    mainTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
    mainTp.paint(canvas, Offset(padding.left, lrcPreY));

    double cursorY = lrcPreY + mainTp.height;

    // ── Post-original sub-tracks ─────────────────────────────────────────
    if (postTracks.isNotEmpty) {
      cursorY += config.lrcTranslationGap(isMainLine: true, translationIndex: 0);
      for (final track in postTracks) {
        if (track == LyricLineTrack.translation && transTexts.isNotEmpty) {
          for (final trans in transTexts) {
            final translated = ZhConverter.convert(trans, zhMode);
            final tTp = _buildTextPainter(
              translated, translationColor, translationFontSize,
              translationWeight, letterSpace,
              isTranslation: true, textAlign: blockTextAlign,
            );
            tTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
            tTp.paint(canvas, Offset(padding.left, cursorY));
            cursorY += tTp.height;
            recycleTextPainter(tTp);
            if (transTexts.length > 1) {
              cursorY += config.lrcTranslationGap(isMainLine: true, translationIndex: 0);
            }
          }
        } else if (track == LyricLineTrack.romanization && lrcLine.romanLyric != null) {
          final romanText = ZhConverter.convert(lrcLine.romanLyric!, zhMode);
          final rTp = _buildTextPainter(
            romanText, secondaryColor, romanFontSize,
            romanWeight, letterSpace,
            isTranslation: true, textAlign: blockTextAlign,
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
        left: 12.0, right: 12.0, top: verticalPad, bottom: verticalPad);

    final isDarkMode = scheme.brightness == Brightness.dark;
    final mainPlayedColor = _applyOpacity(scheme.onSurface.withValues(alpha: 1.0));
    final playedColor = useMaterialYouColor
        ? _applyOpacity(scheme.primary.withValues(alpha: 1.0))
        : mainPlayedColor;
    final unplayedColor = _applyOpacity(useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: isDarkMode ? 0.40 : 0.50)
        : scheme.onSurface.withValues(alpha: isDarkMode ? 0.35 : 0.45));
    final dimColor = unplayedColor;
    final mainColor = isMainLine ? playedColor : dimColor;
    final secondaryColor = _applyOpacity(useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: 0.35)
        : scheme.onSurface.withValues(alpha: 0.25));
    final translationColor = _applyOpacity(useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: 0.60)
        : scheme.onSurface.withValues(alpha: 0.70));

    final maxWidth = size.width - padding.horizontal;
    final blockTextAlign = switch (_effectiveTextAlign) {
      LyricTextAlign.left => TextAlign.left,
      LyricTextAlign.center => TextAlign.center,
      LyricTextAlign.right => TextAlign.right,
    };

    final mainText = ZhConverter.convert(syncLine.content, zhMode);
    final hasTranslation = config.showTranslation &&
        syncLine.translation != null &&
        syncLine.translation!.trim().isNotEmpty;
    final hasRoman = config.showRoman &&
        syncLine.romanLyric != null &&
        syncLine.romanLyric!.isNotEmpty;

    final activeTracks = _activeLineTracks(
      config,
      hasTranslation: hasTranslation,
      hasRoman: hasRoman,
    );
    final preTracks = _preOriginalTracks(activeTracks);
    final postTracks = _postOriginalTracks(activeTracks);

    final translationWeight =
        config.discreteFontWeight((config.fontWeight - 50).clamp(100, 900));
    final romanWeight =
        config.discreteFontWeight((config.fontWeight - 100).clamp(100, 900));
    final translationFontSize = config.translationFontSize(isMainLine: true);
    final romanFontSize = translationFontSize * 0.85;

    double preY = padding.top;
    for (final track in preTracks) {
      if (preY > padding.top) preY += 2.0;
      if (track == LyricLineTrack.translation && hasTranslation) {
        final translated = ZhConverter.convert(syncLine.translation!, zhMode);
        final tTp = _buildTextPainter(
          translated, translationColor, translationFontSize,
          translationWeight, letterSpace,
          isTranslation: true, textAlign: blockTextAlign,
        );
        tTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
        tTp.paint(canvas, Offset(padding.left, preY));
        preY += tTp.height;
        recycleTextPainter(tTp);
      } else if (track == LyricLineTrack.romanization && hasRoman) {
        final romanText = ZhConverter.convert(syncLine.romanLyric!, zhMode);
        final rTp = _buildTextPainter(
          romanText, secondaryColor, romanFontSize,
          romanWeight, letterSpace,
          isTranslation: true, textAlign: blockTextAlign,
        );
        rTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
        rTp.paint(canvas, Offset(padding.left, preY));
        preY += rTp.height;
        recycleTextPainter(rTp);
      }
    }

    final mainTp = _buildTextPainter(
      mainText, mainColor, fontSize, fontWeight, letterSpace,
      textAlign: blockTextAlign,
    );
    mainTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
    mainTp.paint(canvas, Offset(padding.left, preY));

    double cursorY = preY + mainTp.height;
    if (postTracks.isNotEmpty) {
      cursorY += config.lrcTranslationGap(isMainLine: true, translationIndex: 0);
      for (final track in postTracks) {
        if (track == LyricLineTrack.translation && hasTranslation) {
          final translated = ZhConverter.convert(syncLine.translation!, zhMode);
          final tTp = _buildTextPainter(
            translated, translationColor, translationFontSize,
            translationWeight, letterSpace,
            isTranslation: true, textAlign: blockTextAlign,
          );
          tTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
          tTp.paint(canvas, Offset(padding.left, cursorY));
          cursorY += tTp.height;
          recycleTextPainter(tTp);
        } else if (track == LyricLineTrack.romanization && hasRoman) {
          final romanText = ZhConverter.convert(syncLine.romanLyric!, zhMode);
          final rTp = _buildTextPainter(
            romanText, secondaryColor, romanFontSize,
            romanWeight, letterSpace,
            isTranslation: true, textAlign: blockTextAlign,
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

  /// 行间辉光桥接：在上一行末尾字位置绘制残留尾辉光
  ///
  /// 当合并词在换行时播完、下一行合并词开始播放时，
  /// 保持一个淡出的尾辉光视觉连续性
  void _paintGlowTail(
    Canvas canvas,
    _CharInfo info,
    TextStyle playedStyle,
  ) {
    final baseColor = _styleColor(playedStyle, scheme.onSurface);
    const tailAlpha = 0.12;
    if (tailAlpha <= 0.02) return;

    final gp = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5)
      ..color = baseColor.withValues(alpha: baseColor.a * tailAlpha);
    final tp = obtainTextPainter();
    tp.text = TextSpan(
      text: info.char,
      style: _copyTextStyleWithForeground(
        playedStyle,
        gp,
        shadows: null,
      ),
    );
    tp.layout();
    tp.paint(canvas, Offset(info.x, info.y + info.yLift));
    recycleTextPainter(tp);
  }

  double _calcWordProgress(
    double currentMs,
    double wordStartMs,
    double wordEndMs,
  ) {
    if (currentMs < wordStartMs) return 0.0;
    if (currentMs >= wordEndMs) return 1.0;
    final wordDuration = wordEndMs - wordStartMs;
    if (wordDuration <= 0) return 1.0;
    return ((currentMs - wordStartMs) / wordDuration).clamp(0.0, 1.0);
  }

  double _calcLiftProgress(double charProgress, double baseProgress) {
    const wordBlend = 0.65;
    return (charProgress * (1.0 - wordBlend) + baseProgress * wordBlend)
        .clamp(0.0, 1.0);
  }

  static double _liftEffectCurve(
    double charProgress,
    LyricLiftStyle liftStyle,
  ) {
    if (liftStyle == LyricLiftStyle.cosine) {
      if (charProgress <= 0.0 || charProgress >= 1.0) return 0.0;
      if (charProgress < 0.6) {
        return Curves.easeOut.transform(charProgress / 0.6) * 0.6;
      }
      return 0.6 * (1.0 - Curves.easeIn.transform((charProgress - 0.6) / 0.4));
    }
    if (charProgress < 0.6) {
      return Curves.easeOut.transform(charProgress / 0.6);
    }
    return 1.0 - Curves.easeIn.transform((charProgress - 0.6) / 0.4);
  }

  double _calcCosineLift(
    double charCenter,
    double cursorX,
    double lineEndX,
    double fontSize,
  ) {
    const window = 3.0;
    final windowPx = window * fontSize;
    final u = (charCenter - cursorX + windowPx / 2) / windowPx;
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
    final maxLift = (config.liftPeak / 2.0 * 0.10 * fontSize).roundToDouble();
    return -(factor * maxLift);
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
    return currentTimeListenable != oldDelegate.currentTimeListenable ||
        (currentTimeListenable == null &&
            currentTimeMs != oldDelegate.currentTimeMs) ||
        blurSigma != oldDelegate.blurSigma ||
        line != oldDelegate.line ||
        config != oldDelegate.config ||
        useMaterialYouColor != oldDelegate.useMaterialYouColor ||
        opacity != oldDelegate.opacity ||
        fontFamily != oldDelegate.fontFamily ||
        agent != oldDelegate.agent ||
        isMainLine != oldDelegate.isMainLine;
  }

  double measureHeight(double maxWidth) {
    final isSyncLineByLine = line is SyncLyricLine &&
        config.displayMode == LyricDisplayMode.lineByLine;
    final double verticalPad;
    if (line is SyncLyricLine && !isSyncLineByLine) {
      verticalPad = config.syncVerticalPadding(isMainLine: true);
    } else {
      verticalPad = config.lrcVerticalPadding();
    }
    final padding = EdgeInsets.only(
        left: 12.0, right: 12.0, top: verticalPad, bottom: verticalPad);
    final lineWidth = maxWidth - padding.horizontal;

    if (line is SyncLyricLine && !isSyncLineByLine) {
      final syncLine = line as SyncLyricLine;
      if (syncLine.words.isEmpty) return 0;

      final fontSize = config.primaryFontSize(isMainLine: isMainLine);
      final fontWeight = config.discreteFontWeight(config.fontWeight);
      final lineH = fontSize * config.primaryLineHeight();

      // 穷举每个字 + 词间 gap，与 _paintSyncLine 完全一致的换行逻辑
      double curX = padding.left;
      int visualLines = 1;
      final charTp = obtainTextPainter(); // 复用单个 TextPainter 测量字符宽度
      final charStyle = TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize,
        fontWeight: fontWeight,
        letterSpacing: 0,
        height: config.primaryLineHeight(),
        fontVariations: fontFamily == null
            ? [FontVariation('wght', fontWeight.value.toDouble())]
            : null,
      );
      for (final word in syncLine.words) {
        double wordWidth = 0;
        void measureChar(String ch) {
          charTp.text = TextSpan(text: ch, style: charStyle);
          charTp.layout();
          wordWidth += charTp.width;
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
        final needsWrap = curX + wordWidth > padding.left + lineWidth - 1.0;
        if (needsWrap && curX > padding.left) {
          visualLines++;
          curX = padding.left;
        }
        curX += wordWidth + fontSize * 0.12;
      }
      recycleTextPainter(charTp);

      final double mainHeight = visualLines * lineH;
      double height = padding.vertical + mainHeight;

      final activeTracks = _activeLineTracks(
        config,
        hasTranslation: syncLine.translation != null,
        hasRoman: syncLine.romanLyric != null,
      );
      final preTracks = _preOriginalTracks(activeTracks);
      final postTracks = _postOriginalTracks(activeTracks);

      if (activeTracks.length > 1 || (activeTracks.length == 1 && activeTracks.first != LyricLineTrack.original)) {
        final translationFontSize =
            config.translationFontSize(isMainLine: true);
        final romanFontSize = translationFontSize * 0.85;
        final translationWeight = config
            .discreteFontWeight((config.fontWeight - 50).clamp(100, 900));
        final romanWeight = config
            .discreteFontWeight((config.fontWeight - 100).clamp(100, 900));

        // pre-original tracks: positioned BEFORE main text
        for (final track in preTracks) {
          if (height > padding.vertical + mainHeight) height += 4.0;
          if (track == LyricLineTrack.translation && syncLine.translation != null) {
            final tTp = _buildTextPainter(
              syncLine.translation!,
              useMaterialYouColor ? scheme.primary : scheme.onSurface,
              translationFontSize, translationWeight,
              config.letterSpacing(fontSize: translationFontSize),
              isTranslation: true,
            );
            tTp.layout(maxWidth: lineWidth);
            height += tTp.height;
            recycleTextPainter(tTp);
          } else if (track == LyricLineTrack.romanization && syncLine.romanLyric != null) {
            final rTp = _buildTextPainter(
              syncLine.romanLyric!,
              useMaterialYouColor ? scheme.primary : scheme.onSurface,
              romanFontSize, romanWeight,
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
            if (track == LyricLineTrack.translation && syncLine.translation != null) {
              final tTp = _buildTextPainter(
                syncLine.translation!,
                useMaterialYouColor ? scheme.primary : scheme.onSurface,
                translationFontSize, translationWeight,
                config.letterSpacing(fontSize: translationFontSize),
                isTranslation: true,
              );
              tTp.layout(maxWidth: lineWidth);
              height += tTp.height;
              recycleTextPainter(tTp);
            } else if (track == LyricLineTrack.romanization && syncLine.romanLyric != null) {
              final rTp = _buildTextPainter(
                syncLine.romanLyric!,
                useMaterialYouColor ? scheme.primary : scheme.onSurface,
                romanFontSize, romanWeight,
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

      // 和声 + 和声翻译高度（始终预留，避免行激活时布局跳动；绘制时才按透明度隐藏）
      if ((syncLine.bgText != null && syncLine.bgText!.isNotEmpty) ||
          (syncLine.bgTranslation != null &&
              syncLine.bgTranslation!.isNotEmpty)) {
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
        if (syncLine.bgTranslation != null &&
            syncLine.bgTranslation!.isNotEmpty) {
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
        height += bgHeight;
      }

      return height;
    } else if (line is LrcLine) {
      final lrcLine = line as LrcLine;
      final fontSize = config.primaryFontSize(isMainLine: isMainLine);
      // 元数据行
      if (lrcLine.isMetadata) {
        return padding.vertical + fontSize * 0.85 * config.primaryLineHeight();
      }

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

      if (activeTracks.length > 1 || (activeTracks.length == 1 && activeTracks.first != LyricLineTrack.original)) {
        final translationFontSize =
            config.translationFontSize(isMainLine: true);
        final romanFontSize = translationFontSize * 0.85;
        final translationWeight =
            config.discreteFontWeight((config.fontWeight - 50).clamp(100, 900));
        final romanWeight = config
            .discreteFontWeight((config.fontWeight - 100).clamp(100, 900));

        // pre-original tracks
        final lrcPreBase = height;
        for (final track in preTracks) {
          if (height > lrcPreBase) height += 2.0;
          if (track == LyricLineTrack.translation && transTexts.isNotEmpty) {
            for (final trans in transTexts) {
              final tTp = _buildTextPainter(
                trans, scheme.onSurface, translationFontSize,
                translationWeight, config.letterSpacing(fontSize: translationFontSize),
                isTranslation: true,
              );
              tTp.layout(maxWidth: lineWidth);
              height += tTp.height;
              recycleTextPainter(tTp);
            }
          } else if (track == LyricLineTrack.romanization && lrcLine.romanLyric != null) {
            final rTp = _buildTextPainter(
              lrcLine.romanLyric!, scheme.onSurface, romanFontSize,
              romanWeight, config.letterSpacing(fontSize: romanFontSize),
              isTranslation: true,
            );
            rTp.layout(maxWidth: lineWidth);
            height += rTp.height;
            recycleTextPainter(rTp);
          }
        }

        // post-original tracks
        if (postTracks.isNotEmpty) {
          height += config.lrcTranslationGap(isMainLine: true, translationIndex: 0);
          for (final track in postTracks) {
            if (track == LyricLineTrack.translation && transTexts.isNotEmpty) {
              for (final trans in transTexts) {
                final tTp = _buildTextPainter(
                  trans, scheme.onSurface, translationFontSize,
                  translationWeight, config.letterSpacing(fontSize: translationFontSize),
                  isTranslation: true,
                );
                tTp.layout(maxWidth: lineWidth);
                height += tTp.height;
                recycleTextPainter(tTp);
              }
            } else if (track == LyricLineTrack.romanization && lrcLine.romanLyric != null) {
              final rTp = _buildTextPainter(
                lrcLine.romanLyric!, scheme.onSurface, romanFontSize,
                romanWeight, config.letterSpacing(fontSize: romanFontSize),
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
        syncLine.content, scheme.onSurface, fontSize, fontWeight, letterSpace,
        textAlign: blockTextAlign,
      );
      mainTp.layout(maxWidth: lineWidth);
      double height = padding.vertical + mainTp.height;
      final hasTranslation = config.showTranslation &&
          syncLine.translation != null &&
          syncLine.translation!.trim().isNotEmpty;
      final hasRoman = config.showRoman &&
          syncLine.romanLyric != null &&
          syncLine.romanLyric!.isNotEmpty;
      final activeTracks = _activeLineTracks(
        config,
        hasTranslation: hasTranslation,
        hasRoman: hasRoman,
      );
      final preTracks = _preOriginalTracks(activeTracks);
      final postTracks = _postOriginalTracks(activeTracks);
      if (activeTracks.length > 1 || (activeTracks.length == 1 && activeTracks.first != LyricLineTrack.original)) {
        final translationFontSize = config.translationFontSize(isMainLine: true);
        final romanFontSize = translationFontSize * 0.85;
        final translationWeight = config.discreteFontWeight((config.fontWeight - 50).clamp(100, 900));
        final romanWeight = config.discreteFontWeight((config.fontWeight - 100).clamp(100, 900));
        for (final track in preTracks) {
          if (height > padding.vertical + mainTp.height) height += 2.0;
          if (track == LyricLineTrack.translation && hasTranslation) {
            final tTp = _buildTextPainter(
              syncLine.translation!, scheme.onSurface, translationFontSize,
              translationWeight, config.letterSpacing(fontSize: translationFontSize),
              isTranslation: true,
            );
            tTp.layout(maxWidth: lineWidth);
            height += tTp.height;
            recycleTextPainter(tTp);
          } else if (track == LyricLineTrack.romanization && hasRoman) {
            final rTp = _buildTextPainter(
              syncLine.romanLyric!, scheme.onSurface, romanFontSize,
              romanWeight, config.letterSpacing(fontSize: romanFontSize),
              isTranslation: true,
            );
            rTp.layout(maxWidth: lineWidth);
            height += rTp.height;
            recycleTextPainter(rTp);
          }
        }
        if (postTracks.isNotEmpty) {
          height += config.lrcTranslationGap(isMainLine: true, translationIndex: 0);
          for (final track in postTracks) {
            if (track == LyricLineTrack.translation && hasTranslation) {
              final tTp = _buildTextPainter(
                syncLine.translation!, scheme.onSurface, translationFontSize,
                translationWeight, config.letterSpacing(fontSize: translationFontSize),
                isTranslation: true,
              );
              tTp.layout(maxWidth: lineWidth);
              height += tTp.height;
              recycleTextPainter(tTp);
            } else if (track == LyricLineTrack.romanization && hasRoman) {
              final rTp = _buildTextPainter(
                syncLine.romanLyric!, scheme.onSurface, romanFontSize,
                romanWeight, config.letterSpacing(fontSize: romanFontSize),
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
