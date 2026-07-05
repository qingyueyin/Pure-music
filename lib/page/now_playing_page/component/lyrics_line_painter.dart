import 'package:flutter/material.dart';

import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/zh_converter.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';

class _CharInfo {
  final String char;
  final double x;
  final double y;
  final double width;
  final double yLift;
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
  final double blurSigma;
  final LyricRenderConfig config;
  final ColorScheme scheme;
  final bool isMainLine;
  final bool useMaterialYouColor;
  final String? fontFamily;
  final String? agent;

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

  const LyricsLinePainter({
    required this.line,
    required this.currentTimeMs,
    required this.blurSigma,
    required this.config,
    required this.scheme,
    this.isMainLine = false,
    this.useMaterialYouColor = false,
    this.fontFamily,
    this.agent,
  });

  /// 清空对象池（歌曲切换时调用）
  static void clearPool() {
    for (final tp in _textPainterPool) {
      tp.dispose();
    }
    _textPainterPool.clear();
    _poolHitCount = 0;
    _poolMissCount = 0;
    _measureCache.clear();
  }

  /// 压缩对象池（主动瘦身，保留最少必要对象）
  static void trimPool() {
    // 只保留 1 个对象，其余全部释放
    while (_textPainterPool.length > 1) {
      final tp = _textPainterPool.removeAt(0);
      tp.dispose();
    }
  }

  /// 获取池使用统计（用于调试和优化）
  static String getPoolStats() {
    final total = _poolHitCount + _poolMissCount;
    final hitRate =
        total > 0 ? (_poolHitCount / total * 100).toStringAsFixed(1) : '0.0';
    return 'Pool: size=${_textPainterPool.length}/$_maxPoolSize, hit=$hitRate%';
  }

  static TextPainter _obtainTextPainter() {
    if (_textPainterPool.isNotEmpty) {
      _poolHitCount++;
      return _textPainterPool.removeLast();
    }
    _poolMissCount++;
    return TextPainter(textDirection: TextDirection.ltr);
  }

  static void _recycleTextPainter(TextPainter tp) {
    if (_textPainterPool.length < _maxPoolSize) {
      tp.text = null; // 清空引用
      _textPainterPool.add(tp);
    } else {
      tp.dispose(); // 池满直接 dispose，不再累积
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (line is SyncLyricLine) {
      _paintSyncLine(canvas, size);
    } else if (line is LrcLine) {
      _paintLrcLine(canvas, size);
    }
  }

  void _paintSyncLine(Canvas canvas, Size size) {
    final syncLine = line as SyncLyricLine;
    if (syncLine.words.isEmpty) return;

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

    final mainPlayedColor = isDarkMode
        ? Colors.white.withValues(alpha: 1.0)
        : Colors.black.withValues(alpha: 1.0);
    final playedColor = useMaterialYouColor
        ? scheme.primary.withValues(alpha: 1.0)
        : mainPlayedColor;
    final unplayedColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: isDarkMode ? 0.40 : 0.50)
        : scheme.onSurface.withValues(alpha: isDarkMode ? 0.35 : 0.45);
    final secondaryColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: 0.35)
        : scheme.onSurface.withValues(alpha: 0.25);
    final translationColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: 0.60)
        : scheme.onSurface.withValues(alpha: 0.70);

    final maxWidth = size.width - padding.horizontal;

    final zhMode = LyricViewController.instance.zhConversionMode;

    // ── Shared measurer (avoids creating one TextPainter per character) ──
    final measureTp = _obtainTextPainter();
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
    double cursorY = padding.top;
    bool firstOnLine = true;

    for (int wordIndex = 0; wordIndex < syncLine.words.length; wordIndex++) {
      final word = syncLine.words[wordIndex];
      final isObscene = word.obscene;
      final chars = isObscene
          ? List.filled(word.content.runes.length, '_')
          : word.content.characters.toList();
      if (chars.isEmpty) continue;

      final wordTotalChars = chars.length;
      final wordStartMs = word.start.inMilliseconds.toDouble();
      final wordEndMs = wordStartMs + word.length.inMilliseconds.toDouble();
      final wordDurationSec = word.length.inMilliseconds / 1000.0;

      // 单词级别的上抬动画：高亮与上抬同源
      // - 使用 _calcCharProgress 同一个进度值，永远同步
      // - 波浪感由各字不同的 charProgress 自然产生
      // - easeOutCubic 让抬升有加速收尾的丝滑感
      const liftPeak = -2.0;

      final convertedChars = <String>[];
      final charWidths = <double>[];
      double wordWidth = 0.0;
      for (final rawChar in chars) {
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
        if (_isPunctuation(char) && prevNonPunctProgress != null) {
          charProgress = prevNonPunctProgress;
        } else {
          charProgress = computedProgress;
          if (!_isPunctuation(char)) {
            prevNonPunctProgress = computedProgress;
          }
        }

        final liftProgress = _calcLiftProgress(charProgress, wordProgress);
        final isPlaying =
            currentTimeMs >= wordStartMs && currentTimeMs < wordEndMs;

        final double yLift;
        if (isMainLine && liftProgress > 0.0) {
          yLift = Curves.easeOutCubic.transform(liftProgress) * liftPeak;
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
        final left =
            group.chars.map((c) => c.x).reduce((a, b) => a < b ? a : b);
        final right = group.chars
            .map((c) => c.x + c.width)
            .reduce((a, b) => a > b ? a : b);
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
    final tp = _obtainTextPainter();
    final dimStyle = TextStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
      color: unplayedColor,
      fontWeight: fontWeight,
      letterSpacing: 0,
      height: config.primaryLineHeight(),
      fontVariations: fontFamily == null
          ? [FontVariation('wght', fontWeight.value.toDouble())]
          : null,
    );
    final playedStyle = TextStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
      color: playedColor,
      fontWeight: fontWeight,
      letterSpacing: 0,
      height: config.primaryLineHeight(),
      fontVariations: fontFamily == null
          ? [FontVariation('wght', fontWeight.value.toDouble())]
          : null,
    );

    // ── Helper: paint one word with a given style ─────────────────────────
    void paintWord(List<_CharInfo> wc, TextStyle style, bool useLift,
        {bool applyScale = false, Color? glowColor, double glowAlpha = 0.0}) {
      final bool useGlow = glowColor != null && glowAlpha > 0.02;

      if (useLift) {
        final wordDurationSec = wc.first.wordDurationSec;
        final isMerged = wc.first.isMerged;
        const rippleThreshold = 1.5;
        final enableEffect =
            applyScale && (isMerged || wordDurationSec >= rippleThreshold);

        for (final info in wc) {
          final charProgress = info.charProgress;
          double scale = 1.0;
          if (enableEffect && charProgress > 0.0 && charProgress < 1.0) {
            final effectRatio = (((wordDurationSec - rippleThreshold) /
                    (3.0 - rippleThreshold)))
                .clamp(0.0, 1.0);
            final ripplesScaleMax = 1.1 + 0.05 * effectRatio;

            double animationCurve;
            if (charProgress < 0.6) {
              animationCurve = Curves.easeOut.transform(charProgress / 0.6);
            } else {
              animationCurve =
                  1.0 - Curves.easeIn.transform((charProgress - 0.6) / 0.4);
            }
            scale = 1.0 + (ripplesScaleMax - 1.0) * animationCurve;
          }

          final charStyle = useGlow && charProgress > 0.0 && charProgress < 1.0
              ? style.copyWith(
                  color: style.color,
                  shadows: [
                    Shadow(
                      color: glowColor.withValues(alpha: glowAlpha * 0.6),
                      blurRadius: 4,
                      offset: Offset.zero,
                    ),
                    Shadow(
                      color: glowColor.withValues(alpha: glowAlpha),
                      blurRadius: 8,
                      offset: Offset.zero,
                    ),
                  ],
                )
              : style;

          tp.text = TextSpan(text: info.char, style: charStyle);
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
        if (useGlow &&
            wc.any((c) => c.charProgress > 0.0 && c.charProgress < 1.0)) {
          for (final info in wc) {
            final charStyle = style.copyWith(
              color: style.color,
              shadows: [
                Shadow(
                  color: glowColor.withValues(alpha: glowAlpha * 0.6),
                  blurRadius: 4,
                  offset: Offset.zero,
                ),
                Shadow(
                  color: glowColor.withValues(alpha: glowAlpha),
                  blurRadius: 8,
                  offset: Offset.zero,
                ),
              ],
            );
            tp.text = TextSpan(text: info.char, style: charStyle);
            tp.layout();
            tp.paint(canvas, Offset(info.x, info.y));
          }
        } else {
          final text = wc.map((c) => c.char).join();
          tp.text = TextSpan(text: text, style: style);
          tp.layout();
          tp.paint(canvas, Offset(wc.first.x, wc.first.y));
        }
      }
    }

    // ── Per visual line ────────────────────────────────────────────────────
    _CharInfo? prevGlowTailPos; // 上一行末合并词的尾字位置，用于行间辉光桥接
    for (final group in lineGroups) {
      if (group.chars.isEmpty) continue;

      final wordMap = <int, List<_CharInfo>>{};
      for (final info in group.chars) {
        wordMap.putIfAbsent(info.wordIndex, () => []).add(info);
      }
      final words = wordMap.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));

      if (!isMainLine) {
        for (final entry in words) {
          paintWord(entry.value, dimStyle, false);
        }
        continue;
      }

      // ── Compute bounds & sweep position ────────────────────────────────
      double left = double.infinity, top = double.infinity;
      double right = double.negativeInfinity, bottom = double.negativeInfinity;
      for (final entry in words) {
        final wc = entry.value;
        final text = wc.map((c) => c.char).join();
        tp.text = TextSpan(text: text, style: playedStyle);
        tp.layout();
        final w = tp.width;
        final h = tp.height;
        final wx = wc.first.x;
        final wy = wc.first.y;
        left = left < wx ? left : wx;
        top = top < wy ? top : wy;
        right = right > wx + w ? right : wx + w;
        bottom = bottom > wy + h ? bottom : wy + h;
      }

      const gapUnits = 0.45;
      final segStarts = <double>[], segEnds = <double>[], segUnits = <double>[];
      double? prevR;
      double reveal = 0.0;
      for (int wi = 0; wi < words.length; wi++) {
        final wc = words[wi].value;
        final wp = wc.first.wordProgress.clamp(0.0, 1.0);
        if (wp <= 0.0) break;
        final wL = wc.map((c) => c.x).reduce((a, b) => a < b ? a : b);
        final wR = wc.map((c) => c.x + c.width).reduce((a, b) => a > b ? a : b);
        final wU =
            wc.length.toDouble() + (wi > 0 && prevR != null ? gapUnits : 0.0);
        reveal += wU * wp;
        if (wi > 0 && prevR != null) {
          segStarts.add(prevR);
          segEnds.add(wL);
          segUnits.add(gapUnits);
        }
        for (final info in wc) {
          segStarts.add(info.x);
          segEnds.add(info.x + info.width);
          segUnits.add(1.0);
        }
        prevR = wR;
      }
      if (reveal <= 0.0 || segStarts.isEmpty) {
        for (final entry in words) {
          paintWord(entry.value, dimStyle, false);
        }
        continue;
      }

      const prerollUnits = 0.35;
      {
        final firstCharLeft = segStarts.first;
        segStarts.insert(0, firstCharLeft - 16.0);
        segEnds.insert(0, firstCharLeft);
        segUnits.insert(0, prerollUnits);
      }

      double highlightR = segStarts.first;
      var rem = reveal;
      for (int i = 0; i < segStarts.length; i++) {
        if (rem >= segUnits[i]) {
          highlightR = segEnds[i];
          rem -= segUnits[i];
        } else {
          final lp = (rem / segUnits[i]).clamp(0.0, 1.0);
          highlightR = segStarts[i] + (segEnds[i] - segStarts[i]) * lp;
          break;
        }
      }
      if (highlightR <= left) {
        for (final entry in words) {
          paintWord(entry.value, dimStyle, false);
        }
        if (config.enableGlow) {
          final hasCurrPlayingMerged = words
              .any((e) => e.value.first.isPlaying && e.value.first.isMerged);
          if (prevGlowTailPos != null && hasCurrPlayingMerged) {
            _paintGlowTail(canvas, prevGlowTailPos, playedStyle);
          }
        }
        final lastWordEntry = words.lastOrNull;
        if (lastWordEntry != null) {
          final lw = lastWordEntry.value;
          final lwMerged = lw.first.isMerged;
          final lwPlayed = lw.first.wordProgress >= 1.0;
          if (lwMerged && lwPlayed) {
            prevGlowTailPos = lw.last;
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
      final shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: const [
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
        stops: [0.0, sweepP, p1],
      ).createShader(bounds);

      // ── Pass 1: dim（与 played 共用 scale，避免分层）────────────
      for (final entry in words) {
        paintWord(entry.value, dimStyle, entry.value.any((c) => c.yLift != 0.0),
            applyScale: config.enableGlow);
      }

      // ── Compute glow（TTML merge 词不限时长，其余格式需 ≥1.5s）───
      final glowColor = playedStyle.color;
      double lineGlowAlpha = 0.0;
      if (config.enableGlow) {
        for (final entry in words) {
          final wc = entry.value;
          if (wc.isEmpty) continue;
          final wp = wc.first.wordProgress;
          if (wp <= 0.0 || wp >= 1.0) continue;
          final isMerged = wc.first.isMerged;
          final wordDurationSec = wc.first.wordDurationSec;
          if (!isMerged && wordDurationSec < 1.5) continue;
          double maxP = 0.0;
          for (final c in wc) {
            if (c.charProgress > maxP) maxP = c.charProgress;
          }
          if (maxP <= 0.0) continue;
          double curve;
          if (maxP < 0.6) {
            curve = Curves.easeOut.transform(maxP / 0.6);
          } else {
            curve = 1.0 - Curves.easeIn.transform((maxP - 0.6) / 0.4);
          }
          final wa = (0.5 * curve).clamp(0.0, 1.0);
          if (wa > lineGlowAlpha) lineGlowAlpha = wa;
        }
      }
      final bool showGlow = config.enableGlow && lineGlowAlpha > 0.02;

      // 行间辉光桥接
      if (config.enableGlow) {
        final hasPlayingMerged =
            words.any((e) => e.value.first.isPlaying && e.value.first.isMerged);
        if (prevGlowTailPos != null && hasPlayingMerged) {
          _paintGlowTail(canvas, prevGlowTailPos, playedStyle);
        }
      }
      // 记录上一行末合并词的尾字
      final lastWordEntry = words.lastOrNull;
      if (lastWordEntry != null) {
        final lw = lastWordEntry.value;
        final lwMerged = lw.first.isMerged;
        final lwPlayed = lw.first.wordProgress >= 1.0;
        if (lwMerged && lwPlayed) {
          prevGlowTailPos = lw.last;
        } else {
          prevGlowTailPos = null;
        }
      }

      // ── Pass 2: played 文字层（含辉光 shadow）────────────────────
      if (highlightR >= right - 0.5) {
        for (final entry in words) {
          paintWord(
              entry.value, playedStyle, entry.value.any((c) => c.yLift != 0.0),
              applyScale: config.enableGlow,
              glowColor: showGlow ? glowColor : null,
              glowAlpha: lineGlowAlpha);
        }
      } else {
        canvas.save();
        canvas.clipRect(bounds);
        canvas.saveLayer(bounds, Paint());
        for (final entry in words) {
          paintWord(
              entry.value, playedStyle, entry.value.any((c) => c.yLift != 0.0),
              applyScale: config.enableGlow,
              glowColor: showGlow ? glowColor : null,
              glowAlpha: lineGlowAlpha);
        }
        canvas.drawRect(
            bounds,
            Paint()
              ..blendMode = BlendMode.dstIn
              ..shader = shader);
        canvas.restore();
        canvas.restore();
      }
    }

    // ── Translation / Roman ──────────────────────────────────────────────────
    if ((config.showTranslation && syncLine.translation != null) ||
        (config.showRoman && syncLine.romanLyric != null)) {
      final gap = config.syncTranslationGap(isMainLine: true);
      final translationWeight =
          config.discreteFontWeight((config.fontWeight - 50).clamp(100, 900));
      final blockTextAlign = switch (_effectiveTextAlign) {
        LyricTextAlign.left => TextAlign.left,
        LyricTextAlign.center => TextAlign.center,
        LyricTextAlign.right => TextAlign.right,
      };
      if (config.showTranslation && syncLine.translation != null) {
        cursorY += gap; // 原文与翻译之间的间隙
        final translated = ZhConverter.convert(syncLine.translation!, zhMode);
        final translationFontSize =
            config.translationFontSize(isMainLine: isMainLine);
        final transTp = _buildTextPainter(
          translated,
          translationColor,
          translationFontSize,
          translationWeight,
          letterSpace,
          isTranslation: true,
          textAlign: blockTextAlign,
        );
        transTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
        transTp.paint(canvas, Offset(padding.left, cursorY));
        cursorY += transTp.height;
        _recycleTextPainter(transTp);
      }
      if (config.showRoman && syncLine.romanLyric != null) {
        if (config.showTranslation && syncLine.translation != null) {
          cursorY += 4.0;
        }
        final romanText = ZhConverter.convert(syncLine.romanLyric!, zhMode);
        final romanFontSize =
            config.translationFontSize(isMainLine: isMainLine) * 0.85;
        final romanWeight = config
            .discreteFontWeight((config.fontWeight - 100).clamp(100, 900));
        final romanTp = _buildTextPainter(
          romanText,
          secondaryColor,
          romanFontSize,
          romanWeight,
          letterSpace,
          isTranslation: true,
          textAlign: blockTextAlign,
        );
        romanTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
        romanTp.paint(canvas, Offset(padding.left, cursorY));
        _recycleTextPainter(romanTp);
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
      final bgAlpha = isMainLine ? 1.0 : 0.0;
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
            color.withValues(alpha: color.a * bgAlpha),
            size,
            bgWeight,
            letterSpace,
            textAlign: blockTextAlign,
          );
          tp.layout(minWidth: maxWidth, maxWidth: maxWidth);
          cursorY += bgFontSize * 0.45; // gap
          tp.paint(canvas, Offset(padding.left, cursorY));
          cursorY += tp.height;
          _recycleTextPainter(tp);
        }

        cursorY += bgFontSize * 0.35; // extra top gap before bg block
        if (hasBg) {
          final bgVocal = syncLine.bg;
          if (bgVocal != null && bgVocal.words.isNotEmpty) {
            final baseColor = useMaterialYouColor
                ? scheme.primary
                : (isDarkMode ? Colors.white : Colors.black);
            final unplayedColor = baseColor.withValues(alpha: 0.3);
            final spans = bgVocal.words.map((w) {
              final ws = w.start.inMilliseconds.toDouble();
              final we = ws + w.length.inMilliseconds.toDouble();
              final p = _calcWordProgress(currentTimeMs, ws, we);
              final c = Color.lerp(unplayedColor, baseColor, p)!;
              return TextSpan(
                text: ZhConverter.convert(w.content, zhMode),
                style: TextStyle(
                  color: c.withValues(alpha: bgAlpha),
                  fontSize: bgFontSize,
                  fontWeight: bgWeight,
                  letterSpacing: letterSpace,
                ),
              );
            }).toList();
            final tp = _obtainTextPainter();
            tp.text = TextSpan(children: spans);
            tp.textDirection = TextDirection.ltr;
            tp.textAlign = blockTextAlign;
            tp.layout(minWidth: maxWidth, maxWidth: maxWidth);
            cursorY += bgFontSize * 0.45;
            tp.paint(canvas, Offset(padding.left, cursorY));
            cursorY += tp.height;
            _recycleTextPainter(tp);
          } else {
            paintBgLine(
              bgText,
              bgFontSize,
              useMaterialYouColor
                  ? scheme.primary
                  : (isDarkMode ? Colors.white : Colors.black),
            );
          }
        }
        if (hasBgTranslation) {
          paintBgLine(
            bgTranslation,
            bgFontSize * 0.90,
            secondaryColor,
          );
        }
      }
    }

    // 回收 TextPainter
    _recycleTextPainter(measureTp);
    _recycleTextPainter(tp);

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

    final mainPlayedColor = isDarkMode
        ? Colors.white.withValues(alpha: 1.0)
        : Colors.black.withValues(alpha: 1.0);
    final playedColor = useMaterialYouColor
        ? scheme.primary.withValues(alpha: 1.0)
        : mainPlayedColor;
    final unplayedColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: isDarkMode ? 0.40 : 0.50)
        : scheme.onSurface.withValues(alpha: isDarkMode ? 0.35 : 0.45);
    final dimColor = unplayedColor;
    final mainColor = isMainLine ? playedColor : dimColor;
    final metadataColor = scheme.onSurface.withValues(alpha: 0.70);
    final secondaryColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: 0.35)
        : scheme.onSurface.withValues(alpha: 0.25);
    final translationColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: 0.60)
        : scheme.onSurface.withValues(alpha: 0.70);

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
      _recycleTextPainter(metaTp);
      canvas.restore();
      return;
    }

    // ── 多翻译 ┃ 分离（匹配 Widget）──────────────────────────────────────
    final splited = lrcLine.content.split('┃');
    final mainText = ZhConverter.convert(splited.first, zhMode);

    final mainTp = _buildTextPainter(
      mainText,
      mainColor,
      fontSize,
      fontWeight,
      letterSpace,
      textAlign: blockTextAlign,
    );
    mainTp.layout(minWidth: maxWidth, maxWidth: maxWidth);
    mainTp.paint(canvas, Offset(padding.left, padding.top));

    double cursorY = padding.top + mainTp.height;

    final translationWeight =
        config.discreteFontWeight((config.fontWeight - 50).clamp(100, 900));
    final romanWeight =
        config.discreteFontWeight((config.fontWeight - 100).clamp(100, 900));

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

    if (config.showTranslation && transTexts.isNotEmpty) {
      final translationFontSize = config.translationFontSize(isMainLine: true);
      for (final trans in transTexts) {
        cursorY += config.lrcTranslationGap(
          isMainLine: true,
          translationIndex: 0,
        ); // 原文底部与翻译之间的间隙
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
        _recycleTextPainter(tTp);
      }
    }

    if (config.showRoman && lrcLine.romanLyric != null) {
      if (config.showTranslation && transTexts.isNotEmpty) {
        cursorY += 4.0;
      }
      final romanText = ZhConverter.convert(lrcLine.romanLyric!, zhMode);
      final romanFontSize = config.translationFontSize(isMainLine: true) * 0.85;
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
      _recycleTextPainter(rTp);
    }

    // 回收主行 TextPainter
    _recycleTextPainter(mainTp);

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
    final baseColor = playedStyle.color ?? Colors.white;
    const tailAlpha = 0.15;
    if (tailAlpha <= 0.02) return;

    final tp = _obtainTextPainter();
    tp.text = TextSpan(
      text: info.char,
      style: playedStyle.copyWith(
        color: Colors.transparent,
        shadows: [
          Shadow(
            color: baseColor.withValues(alpha: tailAlpha * 0.6),
            blurRadius: 4,
            offset: Offset.zero,
          ),
          Shadow(
            color: baseColor.withValues(alpha: tailAlpha),
            blurRadius: 8,
            offset: Offset.zero,
          ),
        ],
      ),
    );
    tp.layout();
    tp.paint(canvas, Offset(info.x, info.y + info.yLift));
    _recycleTextPainter(tp);
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

  double _calcLiftProgress(double charProgress, double wordProgress) {
    const wordBlend = 0.65;
    return (charProgress * (1.0 - wordBlend) + wordProgress * wordBlend)
        .clamp(0.0, 1.0);
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
    final tp = _obtainTextPainter();
    tp.text = TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize,
        color: color,
        fontWeight: fontWeight,
        letterSpacing: letterSpacing,
        fontVariations: fontFamily == null
            ? [FontVariation('wght', fontWeight.value.toDouble())]
            : null,
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
    return currentTimeMs != oldDelegate.currentTimeMs ||
        blurSigma != oldDelegate.blurSigma ||
        line != oldDelegate.line ||
        config != oldDelegate.config ||
        useMaterialYouColor != oldDelegate.useMaterialYouColor ||
        fontFamily != oldDelegate.fontFamily ||
        agent != oldDelegate.agent ||
        isMainLine != oldDelegate.isMainLine;
  }

  double measureHeight(double maxWidth) {
    final double verticalPad;
    if (line is SyncLyricLine) {
      verticalPad = config.syncVerticalPadding(isMainLine: true);
    } else {
      verticalPad = config.lrcVerticalPadding();
    }
    final padding = EdgeInsets.only(
        left: 12.0, right: 12.0, top: verticalPad, bottom: verticalPad);
    final lineWidth = maxWidth - padding.horizontal;

    if (line is SyncLyricLine) {
      final syncLine = line as SyncLyricLine;
      if (syncLine.words.isEmpty) return 0;

      final fontSize = config.primaryFontSize(isMainLine: isMainLine);
      final fontWeight = config.discreteFontWeight(config.fontWeight);
      final lineH = fontSize * config.primaryLineHeight();

      // 穷举每个字 + 词间 gap，与 _paintSyncLine 完全一致的换行逻辑
      double curX = padding.left;
      int visualLines = 1;
      final charTp = _obtainTextPainter(); // 复用单个 TextPainter 测量字符宽度
      for (final word in syncLine.words) {
        final content = word.obscene
            ? String.fromCharCodes(List.filled(word.content.runes.length, 0x5F))
            : word.content;
        final chars = content.characters.toList();
        double wordWidth = 0;
        for (final ch in chars) {
          charTp.text = TextSpan(
              text: ch,
              style: TextStyle(
                fontFamily: fontFamily,
                fontSize: fontSize,
                fontWeight: fontWeight,
                letterSpacing: 0,
                height: config.primaryLineHeight(),
                fontVariations: fontFamily == null
                    ? [FontVariation('wght', fontWeight.value.toDouble())]
                    : null,
              ));
          charTp.layout();
          wordWidth += charTp.width;
        }
        final needsWrap = curX + wordWidth > padding.left + lineWidth - 1.0;
        if (needsWrap && curX > padding.left) {
          visualLines++;
          curX = padding.left;
        }
        curX += wordWidth + fontSize * 0.12;
      }
      _recycleTextPainter(charTp);

      final double mainHeight = visualLines * lineH;
      double height = padding.vertical + mainHeight;

      if ((config.showTranslation && syncLine.translation != null) ||
          (config.showRoman && syncLine.romanLyric != null)) {
        final translationFontSize =
            config.translationFontSize(isMainLine: true);
        if (config.showTranslation && syncLine.translation != null) {
          final translationWeight = config
              .discreteFontWeight((config.fontWeight - 50).clamp(100, 900));
          final tTp = _buildTextPainter(
            syncLine.translation!,
            useMaterialYouColor ? scheme.primary : scheme.onSurface,
            translationFontSize,
            translationWeight,
            config.letterSpacing(fontSize: translationFontSize),
            isTranslation: true,
          );
          tTp.layout(maxWidth: lineWidth);
          height += tTp.height + config.syncTranslationGap(isMainLine: true);
          _recycleTextPainter(tTp);
        }
        if (config.showRoman && syncLine.romanLyric != null) {
          final romanFontSize =
              config.translationFontSize(isMainLine: true) * 0.85;
          final romanWeight = config
              .discreteFontWeight((config.fontWeight - 100).clamp(100, 900));
          final rTp = _buildTextPainter(
            syncLine.romanLyric!,
            useMaterialYouColor ? scheme.primary : scheme.onSurface,
            romanFontSize,
            romanWeight,
            config.letterSpacing(fontSize: romanFontSize),
            isTranslation: true,
          );
          rTp.layout(maxWidth: lineWidth);
          height += rTp.height;
          if (config.showTranslation && syncLine.translation != null) {
            height += 4.0; // roman gap
          }
          _recycleTextPainter(rTp);
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
        if (syncLine.bgText != null && syncLine.bgText!.isNotEmpty) {
          final bgTp = _buildTextPainter(
            syncLine.bgText!,
            scheme.onSurface,
            bgFontSize,
            bgWeight,
            config.letterSpacing(fontSize: bgFontSize),
          );
          bgTp.layout(maxWidth: lineWidth);
          height += gap + bgTp.height;
          _recycleTextPainter(bgTp);
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
          height += bgFontSize * 0.45 + bgTransTp.height;
          _recycleTextPainter(bgTransTp);
        }
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

      if (config.showTranslation && transTexts.isNotEmpty) {
        final translationFontSize =
            config.translationFontSize(isMainLine: true);
        final translationWeight =
            config.discreteFontWeight((config.fontWeight - 50).clamp(100, 900));
        for (final trans in transTexts) {
          final tTp = _buildTextPainter(
            trans,
            useMaterialYouColor ? scheme.primary : scheme.onSurface,
            translationFontSize,
            translationWeight,
            config.letterSpacing(fontSize: translationFontSize),
            isTranslation: true,
          );
          tTp.layout(maxWidth: lineWidth);
          height += tTp.height +
              config.lrcTranslationGap(isMainLine: true, translationIndex: 0);
          _recycleTextPainter(tTp);
        }
      }
      if (config.showRoman && lrcLine.romanLyric != null) {
        final romanFontSize =
            config.translationFontSize(isMainLine: true) * 0.85;
        final romanWeight = config
            .discreteFontWeight((config.fontWeight - 100).clamp(100, 900));
        final rTp = _buildTextPainter(
          lrcLine.romanLyric!,
          useMaterialYouColor ? scheme.primary : scheme.onSurface,
          romanFontSize,
          romanWeight,
          config.letterSpacing(fontSize: romanFontSize),
          isTranslation: true,
        );
        rTp.layout(maxWidth: lineWidth);
        height += rTp.height;
        if (config.showTranslation && transTexts.isNotEmpty) {
          height += 4.0;
        }
        _recycleTextPainter(rTp);
      }
      _recycleTextPainter(mainTp);
      return height;
    }
    return 60;
  }
}
