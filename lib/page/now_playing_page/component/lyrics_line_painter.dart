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
  });
}

class _LineGroup {
  final double y;
  final List<_CharInfo> chars;

  _LineGroup({required this.y, required this.chars});
}

class LyricsLinePainter extends CustomPainter {
  final LyricLine line;
  final double currentTimeMs;
  final double opacity;
  final double blurSigma;
  final double scale;
  final double offsetY;
  final LyricRenderConfig config;
  final ColorScheme scheme;
  final bool isMainLine;
  final bool useMaterialYouColor;
  final String? fontFamily;

  const LyricsLinePainter({
    required this.line,
    required this.currentTimeMs,
    required this.opacity,
    required this.blurSigma,
    required this.scale,
    required this.offsetY,
    required this.config,
    required this.scheme,
    this.isMainLine = false,
    this.useMaterialYouColor = false,
    this.fontFamily,
  });

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
    canvas.translate(0, offsetY);
    // scale 以对齐点为原点，避免缩放后居中/右对齐偏移（Widget 的 Transform.scale 有 alignment 参数）
    final scaleOriginX = switch (config.textAlign) {
      LyricTextAlign.left => 0.0,
      LyricTextAlign.center => size.width / 2,
      LyricTextAlign.right => size.width,
    };
    canvas.translate(scaleOriginX, 0);
    canvas.scale(scale);
    canvas.translate(-scaleOriginX, 0);

    final fontSize = config.primaryFontSize(isMainLine: isMainLine);
    final letterSpace = config.letterSpacing(fontSize: fontSize);
    final fontWeight = config.discreteFontWeight(config.fontWeight);
    final verticalPad =
        isMainLine ? config.syncVerticalPadding(isMainLine: true) : 12.0;
    final padding = EdgeInsets.only(
        left: 12.0, right: 12.0, top: verticalPad, bottom: verticalPad);
    // 行高：TextStyle.height=1.2 → fontSize*1.2，与 TextPainter.layout 结果等价
    final lineHeight = fontSize * config.primaryLineHeight();

    final isDarkMode = scheme.brightness == Brightness.dark;
    // 匹配 Widget 路径：_SyncWordWrap 使用 onSurface.alpha(0.25) 作暗淡色
    final unplayedColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: opacity * 0.35)
        : scheme.onSurface.withValues(alpha: opacity * 0.25);
    // 主行播放色：Widget 路径用 isDarkMode ? white : black
    final mainPlayedColor = isDarkMode
        ? Colors.white.withValues(alpha: opacity)
        : Colors.black.withValues(alpha: opacity);
    final playedColor = useMaterialYouColor
        ? scheme.primary.withValues(alpha: opacity)
        : (isMainLine
            ? mainPlayedColor
            : scheme.onSurface.withValues(alpha: opacity * 0.85));
    final secondaryColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: opacity * 0.35)
        : scheme.onSurface.withValues(alpha: opacity * 0.25);
    final translationColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: opacity * 0.60)
        : scheme.onSurface.withValues(alpha: opacity * 0.70);

    final maxWidth = size.width - padding.horizontal;

    final zhMode = LyricViewController.instance.zhConversionMode;

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
        final tpDim =
            _buildTextPainter(char, unplayedColor, fontSize, fontWeight, 0);
        tpDim.layout();
        convertedChars.add(char);
        charWidths.add(tpDim.width);
        wordWidth += tpDim.width;
      }

      final contentRight = padding.left + maxWidth;
      if (!firstOnLine && cursorX + wordWidth > contentRight - 1.0) {
        cursorX = padding.left;
        cursorY += lineHeight;
        firstOnLine = true;
      }

      for (int i = 0; i < convertedChars.length; i++) {
        final char = convertedChars[i];
        if (char == ' ' && firstOnLine) continue;

        final charProgress = _calcCharProgress(
          currentTimeMs,
          wordStartMs,
          wordEndMs,
          i,
          wordTotalChars,
        );
        final wordProgress = _calcWordProgress(
          currentTimeMs,
          wordStartMs,
          wordEndMs,
        );
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
        ));

        cursorX += charWidth;
        firstOnLine = false;
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
    if (config.textAlign != LyricTextAlign.left) {
      for (final group in lineGroups) {
        if (group.chars.isEmpty) continue;
        final left =
            group.chars.map((c) => c.x).reduce((a, b) => a < b ? a : b);
        final right = group.chars
            .map((c) => c.x + c.width)
            .reduce((a, b) => a > b ? a : b);
        final lineWidth = right - left;

        final lineStartX = switch (config.textAlign) {
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
          );
        }
      }
      // 重建 charInfos，确保 Pass 1 也使用对齐后的坐标
      charInfos.clear();
      for (final group in lineGroups) {
        charInfos.addAll(group.chars);
      }
    }

    // ── Pass 1: draw all dim (unplayed) characters ──────────────────────────
    for (final info in charInfos) {
      final tp =
          _buildTextPainter(info.char, unplayedColor, fontSize, fontWeight, 0);
      tp.layout();
      tp.paint(canvas, Offset(info.x, info.y + info.yLift));
    }

    // ── Pass 2: line-level highlight sweep (主行 only) ────────────────────────
    // 每个视觉行只做一次连续 mask，进度由当前词真实 wordProgress 决定，避免词切换时重复闪动。
    if (isMainLine) {
      for (final group in lineGroups) {
        if (group.chars.isEmpty) continue;
        double left = double.infinity;
        double top = double.infinity;
        double right = double.negativeInfinity;
        double bottom = double.negativeInfinity;
        for (final info in group.chars) {
          final tp = _buildTextPainter(
              info.char, playedColor, fontSize, fontWeight, 0);
          tp.layout();
          left = left < info.x ? left : info.x;
          top = top < info.y + info.yLift ? top : info.y + info.yLift;
          right = right > info.x + info.width ? right : info.x + info.width;
          bottom = bottom > info.y + info.yLift + tp.height
              ? bottom
              : info.y + info.yLift + tp.height;
        }

        double revealUnits = 0.0;
        final words = <int, List<_CharInfo>>{};
        for (final info in group.chars) {
          words.putIfAbsent(info.wordIndex, () => []).add(info);
        }

        const gapUnits = 0.45;
        final segmentStarts = <double>[];
        final segmentEnds = <double>[];
        final segmentUnits = <double>[];
        double? previousRight;

        for (int wordOrder = 0; wordOrder < words.values.length; wordOrder++) {
          final wordChars = words.values.elementAt(wordOrder);
          final progress = wordChars.first.wordProgress.clamp(0.0, 1.0);
          final wordLeft =
              wordChars.map((info) => info.x).reduce((a, b) => a < b ? a : b);
          final wordRight = wordChars
              .map((info) => info.x + info.width)
              .reduce((a, b) => a > b ? a : b);

          final wordUnits = wordChars.length.toDouble() +
              (wordOrder > 0 && previousRight != null ? gapUnits : 0.0);
          if (progress > 0.0) {
            revealUnits += wordUnits * progress;
          } else {
            break;
          }

          if (wordOrder > 0 && previousRight != null) {
            segmentStarts.add(previousRight);
            segmentEnds.add(wordLeft);
            segmentUnits.add(gapUnits);
          }
          for (final info in wordChars) {
            segmentStarts.add(info.x);
            segmentEnds.add(info.x + info.width);
            segmentUnits.add(1.0);
          }
          previousRight = wordRight;
        }

        if (revealUnits <= 0.0 || segmentStarts.isEmpty) continue;

        double highlightRight = segmentStarts.first;
        var remainingUnits = revealUnits;
        for (int i = 0; i < segmentStarts.length; i++) {
          final units = segmentUnits[i];
          if (remainingUnits >= units) {
            highlightRight = segmentEnds[i];
            remainingUnits -= units;
            continue;
          }
          final localProgress = (remainingUnits / units).clamp(0.0, 1.0);
          highlightRight = segmentStarts[i] +
              (segmentEnds[i] - segmentStarts[i]) * localProgress;
          break;
        }

        if (highlightRight <= left) continue;

        if (highlightRight >= right - 0.5) {
          for (final info in group.chars) {
            final tp = _buildTextPainter(
                info.char, playedColor, fontSize, fontWeight, 0);
            tp.layout();
            tp.paint(canvas, Offset(info.x, info.y + info.yLift));
          }
          continue;
        }

        final bounds = Rect.fromLTRB(left, top, right, bottom);
        final width = bounds.width <= 0 ? 1.0 : bounds.width;
        final sweepProgress = ((highlightRight - left) / width).clamp(0.0, 1.0);
        final feather = (32.0 / width).clamp(0.045, 0.16);
        final p0 = (sweepProgress - feather).clamp(0.0, sweepProgress);
        final p1 = (sweepProgress + feather * 0.45).clamp(sweepProgress, 1.0);
        final shader = LinearGradient(
          colors: [
            Colors.white,
            Colors.white,
            Colors.white.withValues(alpha: 0.48),
            Colors.transparent,
          ],
          stops: [0.0, p0, sweepProgress, p1],
        ).createShader(bounds);

        canvas.save();
        canvas.clipRect(bounds);
        canvas.saveLayer(bounds, Paint());
        for (final info in group.chars) {
          final tp = _buildTextPainter(
              info.char, playedColor, fontSize, fontWeight, 0);
          tp.layout();
          tp.paint(canvas, Offset(info.x, info.y + info.yLift));
        }
        final paint = Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = shader;
        canvas.drawRect(bounds, paint);
        canvas.restore();
        canvas.restore();
      }
    }

    // ── Translation / Roman ──────────────────────────────────────────────────
    if ((config.showTranslation && syncLine.translation != null) ||
        (config.showRoman && syncLine.romanLyric != null)) {
      final gap = config.syncTranslationGap(isMainLine: isMainLine);
      final translationWeight =
          config.discreteFontWeight((config.fontWeight - 50).clamp(100, 900));
      final blockTextAlign = switch (config.textAlign) {
        LyricTextAlign.left => TextAlign.left,
        LyricTextAlign.center => TextAlign.center,
        LyricTextAlign.right => TextAlign.right,
      };
      if (config.showTranslation && syncLine.translation != null) {
        cursorY += gap; // 原文与翻译之间的间隙
        final translated = ZhConverter.convert(syncLine.translation!, zhMode);
        final translationFontSize =
            config.translationFontSize(isMainLine: isMainLine);
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
      }
    }

    canvas.restore();
  }

  void _paintLrcLine(Canvas canvas, Size size) {
    final lrcLine = line as LrcLine;

    canvas.save();
    canvas.translate(0, offsetY);
    // scale 以对齐点为原点
    final scaleOriginX = switch (config.textAlign) {
      LyricTextAlign.left => 0.0,
      LyricTextAlign.center => size.width / 2,
      LyricTextAlign.right => size.width,
    };
    canvas.translate(scaleOriginX, 0);
    canvas.scale(scale);
    canvas.translate(-scaleOriginX, 0);

    final zhMode = LyricViewController.instance.zhConversionMode;
    final fontSize = config.primaryFontSize(isMainLine: isMainLine);
    final letterSpace = config.letterSpacing(fontSize: fontSize);
    final fontWeight = config.discreteFontWeight(config.fontWeight);
    final verticalPad = config.lrcVerticalPadding();
    final padding = EdgeInsets.only(
        left: 12.0, right: 12.0, top: verticalPad, bottom: verticalPad);

    final isDarkMode = scheme.brightness == Brightness.dark;
    final unplayedColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: opacity * 0.35)
        : scheme.onSurface.withValues(alpha: opacity * 0.25);
    final mainPlayedColor = isDarkMode
        ? Colors.white.withValues(alpha: opacity)
        : Colors.black.withValues(alpha: opacity);
    final metadataColor = scheme.onSurface.withValues(alpha: opacity * 0.70);
    final playedColor = useMaterialYouColor
        ? scheme.primary.withValues(alpha: opacity)
        : (isMainLine
            ? mainPlayedColor
            : scheme.onSurface.withValues(alpha: opacity * 0.85));
    final secondaryColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: opacity * 0.35)
        : scheme.onSurface.withValues(alpha: opacity * 0.25);
    final translationColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: opacity * 0.60)
        : scheme.onSurface.withValues(alpha: opacity * 0.70);

    final displayedColor = isMainLine ? playedColor : unplayedColor;
    final maxWidth = size.width - padding.horizontal;
    final blockTextAlign = switch (config.textAlign) {
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
      final tp = _buildTextPainter(
        metaText,
        metadataColor,
        metaFontSize,
        metaWeight,
        letterSpace,
        textAlign: blockTextAlign,
      );
      tp.layout(minWidth: maxWidth, maxWidth: maxWidth);
      tp.paint(canvas, Offset(padding.left, padding.top));
      canvas.restore();
      return;
    }

    // ── 多翻译 ┃ 分离（匹配 Widget）──────────────────────────────────────
    final splited = lrcLine.content.split('┃');
    final mainText = ZhConverter.convert(splited.first, zhMode);

    final tp = _buildTextPainter(
      mainText,
      displayedColor,
      fontSize,
      fontWeight,
      letterSpace,
      textAlign: blockTextAlign,
    );
    tp.layout(minWidth: maxWidth, maxWidth: maxWidth);
    tp.paint(canvas, Offset(padding.left, padding.top));

    double cursorY = padding.top + tp.height;

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
      final translationFontSize =
          config.translationFontSize(isMainLine: isMainLine);
      for (final trans in transTexts) {
        cursorY += config.lrcTranslationGap(
          isMainLine: isMainLine,
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
      }
    }

    if (config.showRoman && lrcLine.romanLyric != null) {
      if (config.showTranslation && transTexts.isNotEmpty) {
        cursorY += 4.0;
      }
      final romanText = ZhConverter.convert(lrcLine.romanLyric!, zhMode);
      final romanFontSize =
          config.translationFontSize(isMainLine: isMainLine) * 0.85;
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
    }

    canvas.restore();
  }

  double _calcCharProgress(
    double currentMs,
    double wordStartMs,
    double wordEndMs,
    int charIndex,
    int totalChars,
  ) {
    final wordProgress = _calcWordProgress(currentMs, wordStartMs, wordEndMs);
    final charEndThreshold = (charIndex + 1) / totalChars;
    if (wordProgress >= charEndThreshold) return 1.0;
    final charStartThreshold = charIndex / totalChars;
    return ((wordProgress - charStartThreshold) /
            (charEndThreshold - charStartThreshold))
        .clamp(0.0, 1.0);
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
    return TextPainter(
      text: TextSpan(
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
      ),
      textDirection: TextDirection.ltr,
      textAlign: textAlign,
      maxLines: null,
    );
  }

  @override
  bool shouldRepaint(covariant LyricsLinePainter oldDelegate) {
    return currentTimeMs != oldDelegate.currentTimeMs ||
        opacity != oldDelegate.opacity ||
        blurSigma != oldDelegate.blurSigma ||
        scale != oldDelegate.scale ||
        offsetY != oldDelegate.offsetY ||
        line != oldDelegate.line ||
        config != oldDelegate.config ||
        useMaterialYouColor != oldDelegate.useMaterialYouColor ||
        fontFamily != oldDelegate.fontFamily;
  }

  double measureHeight(double maxWidth) {
    final double verticalPad;
    if (line is SyncLyricLine) {
      verticalPad =
          isMainLine ? config.syncVerticalPadding(isMainLine: true) : 12.0;
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
      // 与 paint 模式用同样的 letterSpacing:0 算宽度
      const letterSpace = 0.0;
      final lineH = fontSize * config.primaryLineHeight();

      // 穷举每个字 + 词间 gap，与 _paintSyncLine 完全一致的换行逻辑
      double curX = padding.left;
      int visualLines = 1;
      for (final word in syncLine.words) {
        final content = word.obscene
            ? String.fromCharCodes(List.filled(word.content.runes.length, 0x5F))
            : word.content;
        final chars = content.characters.toList();
        double wordWidth = 0;
        for (final ch in chars) {
          final tp = _buildTextPainter(
              ch, scheme.onSurface, fontSize, fontWeight, letterSpace);
          tp.layout();
          wordWidth += tp.width;
        }
        final needsWrap = curX + wordWidth > padding.left + lineWidth - 1.0;
        if (needsWrap && curX > padding.left) {
          visualLines++;
          curX = padding.left;
        }
        curX += wordWidth + fontSize * 0.12;
      }

      final double mainHeight = visualLines * lineH;
      double height = padding.vertical + mainHeight;
      if ((config.showTranslation && syncLine.translation != null) ||
          (config.showRoman && syncLine.romanLyric != null)) {
        final translationFontSize =
            config.translationFontSize(isMainLine: isMainLine);
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
          height +=
              tTp.height + config.syncTranslationGap(isMainLine: isMainLine);
        }
        if (config.showRoman && syncLine.romanLyric != null) {
          final romanFontSize =
              config.translationFontSize(isMainLine: isMainLine) * 0.85;
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
      final blockTextAlign = switch (config.textAlign) {
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
            config.translationFontSize(isMainLine: isMainLine);
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
              config.lrcTranslationGap(
                  isMainLine: isMainLine, translationIndex: 0);
        }
      }
      if (config.showRoman && lrcLine.romanLyric != null) {
        final romanFontSize =
            config.translationFontSize(isMainLine: isMainLine) * 0.85;
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
      }
      return height;
    }
    return 60;
  }
}
