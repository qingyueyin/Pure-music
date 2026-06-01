import 'package:flutter/material.dart';

import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';

class _CharInfo {
  final String char;
  final double x;
  final double y;
  final double width;
  final double yLift;
  final double charProgress;
  final bool isPlaying;

  _CharInfo({
    required this.char,
    required this.x,
    required this.y,
    required this.width,
    required this.yLift,
    required this.charProgress,
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
    canvas.scale(scale);

    final fontSize = config.primaryFontSize(isMainLine: isMainLine);
    final letterSpace = config.letterSpacing(fontSize: fontSize);
    final fontWeight = config.discreteFontWeight(config.fontWeight);
    final verticalPad = config.syncVerticalPadding(isMainLine: isMainLine);
    final padding = EdgeInsets.only(left: 12.0, right: 12.0, top: verticalPad, bottom: verticalPad);

    final playedColor = useMaterialYouColor
        ? scheme.primary.withValues(alpha: opacity)
        : (isMainLine
            ? Colors.white.withValues(alpha: opacity)
            : scheme.onSurface.withValues(alpha: opacity * 0.85));
    final unplayedColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: opacity * 0.35)
        : scheme.onSurface.withValues(alpha: opacity * 0.35);
    final secondaryColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: opacity * 0.35)
        : scheme.onSurface.withValues(alpha: opacity * 0.35);
    final translationColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: opacity * 0.60)
        : scheme.onSurface.withValues(alpha: opacity * 0.70);

    final lineHeight = fontSize * config.primaryLineHeight();
    final maxWidth = size.width - padding.horizontal;

    // ── Collect all character positions ─────────────────────────────────────
    final charInfos = <_CharInfo>[];
    double cursorX = padding.left;
    double cursorY = padding.top;
    bool firstOnLine = true;

    for (final word in syncLine.words) {
      final isObscene = word.obscene;
      final chars = isObscene
          ? List.filled(word.content.runes.length, '_')
          : word.content.characters.toList();
      if (chars.isEmpty) continue;

      final wordTotalChars = chars.length;
      final wordStartMs = word.start.inMilliseconds.toDouble();
      final wordEndMs = wordStartMs + word.length.inMilliseconds.toDouble();

      for (int i = 0; i < chars.length; i++) {
        final char = chars[i];
        if (char == ' ' && firstOnLine) continue;

        final charProgress = _calcCharProgress(
          currentTimeMs, wordStartMs, wordEndMs, i, wordTotalChars,
        );
        final isPlaying = currentTimeMs >= wordStartMs && currentTimeMs < wordEndMs;
        final easedProgress = Curves.easeOutCubic.transform(charProgress);
        final bool isCharActive = charProgress > 0;
        final bool isCharPlayed = charProgress >= 1.0;
        final yLift = (isMainLine && isPlaying && isCharActive)
            ? easedProgress * -1.5
            : (isMainLine && isCharPlayed ? -1.5 : 0.0);

        final tpDim = _buildTextPainter(
            char, unplayedColor, fontSize, fontWeight, letterSpace);
        tpDim.layout();
        final charWidth = tpDim.width;
        final isSpace = char == ' ';

        if (!firstOnLine && !isSpace && cursorX + charWidth > maxWidth) {
          cursorX = padding.left;
          cursorY += lineHeight;
          firstOnLine = true;
        }

        if (isSpace && firstOnLine) continue;

        charInfos.add(_CharInfo(
          char: char,
          x: cursorX,
          y: cursorY,
          width: charWidth,
          yLift: yLift,
          charProgress: charProgress,
          isPlaying: isPlaying,
        ));

        cursorX += charWidth;
        firstOnLine = false;
      }
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

    // ── Apply text alignment ─────────────────────────────────────────────────
    if (config.textAlign != LyricTextAlign.left) {
      // Calculate actual width of each visual line
      final lineInfos = <({double lineLeft, double lineRight, double lineWidth})>[];
      for (final group in lineGroups) {
        if (group.chars.isEmpty) continue;
        final left = group.chars.map((c) => c.x).reduce((a, b) => a < b ? a : b);
        final right = group.chars.map((c) => c.x + c.width).reduce((a, b) => a > b ? a : b);
        lineInfos.add((lineLeft: left, lineRight: right, lineWidth: right - left));
      }

      // Find the widest visual line to determine block width
      double blockWidth = 0;
      for (final info in lineInfos) {
        if (info.lineWidth > blockWidth) blockWidth = info.lineWidth;
      }

      // Calculate block start position based on textAlign
      double blockStartX;
      switch (config.textAlign) {
        case LyricTextAlign.center:
          blockStartX = padding.left + (maxWidth - blockWidth) / 2;
        case LyricTextAlign.right:
          blockStartX = padding.left + maxWidth - blockWidth;
        case LyricTextAlign.left:
          blockStartX = padding.left;
      }

      // Adjust each visual line's characters
      for (int g = 0; g < lineGroups.length; g++) {
        if (lineInfos.length <= g) break;
        final lineInfo = lineInfos[g];
        // Align each line to the block's start (natural text flow)
        final offset = blockStartX - lineInfo.lineLeft;

        for (int i = 0; i < lineGroups[g].chars.length; i++) {
          final original = lineGroups[g].chars[i];
          lineGroups[g].chars[i] = _CharInfo(
            char: original.char,
            x: original.x + offset,
            y: original.y,
            width: original.width,
            yLift: original.yLift,
            charProgress: original.charProgress,
            isPlaying: original.isPlaying,
          );
        }
      }
    }

    // ── Pass 1: draw all dim (unplayed) characters ──────────────────────────
    for (final info in charInfos) {
      final tp = _buildTextPainter(
          info.char, unplayedColor, fontSize, fontWeight, letterSpace);
      tp.layout();
      tp.paint(canvas, Offset(info.x, info.y + info.yLift));
    }

    // ── Pass 2: draw bright (played) characters with smooth gradient ────────
    for (final group in lineGroups) {
      if (group.chars.isEmpty) continue;

      final leftMost = group.chars.map((c) => c.x).reduce((a, b) => a < b ? a : b);
      final rightMost = group.chars.map((c) => c.x + c.width).reduce((a, b) => a > b ? a : b);
      final lineRenderWidth = rightMost - leftMost;
      if (lineRenderWidth <= 0) continue;

      double playedWidth = 0;
      for (final info in group.chars) {
        if (info.charProgress >= 1.0) {
          playedWidth += info.width;
        } else if (info.isPlaying) {
          playedWidth += info.width * info.charProgress;
          break;
        } else {
          break;
        }
      }

      if (playedWidth < 0.01) continue;

      final overallProgress = (playedWidth / lineRenderWidth).clamp(0.0, 1.0);
      final totalCharsInGroup = group.chars.length;
      final fadeRatio = (1.0 / totalCharsInGroup * 0.5).clamp(0.03, 0.25);

      // Compute bounds including yLift
      double minY = group.y;
      double maxY = group.y + lineHeight;
      for (final info in group.chars) {
        final liftedY = info.y + info.yLift;
        if (liftedY < minY) minY = liftedY;
        if (liftedY + lineHeight > maxY) maxY = liftedY + lineHeight;
      }

      const boundsPad = 4.0;
      final boundsX = leftMost - boundsPad;
      final boundsW = lineRenderWidth + boundsPad * 2;
      final boundsY = minY - boundsPad;
      final boundsH = (maxY - minY) + boundsPad * 2;

      final maskRect = Rect.fromLTWH(boundsX, boundsY, boundsW, boundsH);

      canvas.saveLayer(maskRect, Paint());

      for (final info in group.chars) {
        final tp = _buildTextPainter(
            info.char, playedColor, fontSize, fontWeight, letterSpace);
        tp.layout();
        tp.paint(canvas, Offset(info.x, info.y + info.yLift));
      }

      canvas.saveLayer(maskRect, Paint()..blendMode = BlendMode.dstIn);

      final gradientRect = Rect.fromLTWH(leftMost, boundsY, lineRenderWidth, boundsH);
      canvas.drawRect(gradientRect, Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const [
            Colors.white, Colors.white,
            Colors.transparent, Colors.transparent,
          ],
          stops: [
            0.0,
            overallProgress,
            (overallProgress + fadeRatio).clamp(0.0, 1.0),
            1.0,
          ],
        ).createShader(gradientRect));

      canvas.restore();
      canvas.restore();
    }

    // ── Translation / Roman ──────────────────────────────────────────────────
    if ((config.showTranslation && syncLine.translation != null) ||
        (config.showRoman && syncLine.romanLyric != null)) {
      final gap = config.syncTranslationGap(isMainLine: isMainLine);
      if (config.showTranslation && syncLine.translation != null) {
        final translationFontSize =
            config.translationFontSize(isMainLine: isMainLine);
        final tp = _buildTextPainter(
          syncLine.translation!,
          translationColor,
          translationFontSize,
          fontWeight,
          letterSpace,
        );
        tp.layout(maxWidth: maxWidth);
        final x = _alignText(tp.width, maxWidth, padding.left);
        tp.paint(canvas, Offset(x, cursorY));
        cursorY += tp.height + gap;
      }
      if (config.showRoman && syncLine.romanLyric != null) {
        final romanFontSize =
            config.translationFontSize(isMainLine: isMainLine);
        final tp = _buildTextPainter(
          syncLine.romanLyric!,
          secondaryColor,
          romanFontSize,
          fontWeight,
          letterSpace,
        );
        tp.layout(maxWidth: maxWidth);
        final x = _alignText(tp.width, maxWidth, padding.left);
        tp.paint(canvas, Offset(x, cursorY));
      }
    }

    canvas.restore();
  }

  void _paintLrcLine(Canvas canvas, Size size) {
    final lrcLine = line as LrcLine;

    canvas.save();
    canvas.translate(0, offsetY);
    canvas.scale(scale);

    final fontSize = config.primaryFontSize(isMainLine: isMainLine);
    final letterSpace = config.letterSpacing(fontSize: fontSize);
    final fontWeight = config.discreteFontWeight(config.fontWeight);
    final verticalPad = config.lrcVerticalPadding();
    final padding = EdgeInsets.only(left: 12.0, right: 12.0, top: verticalPad, bottom: verticalPad);

    final lineStartMs = lrcLine.start.inMilliseconds.toDouble();
    final lineEndMs = lineStartMs + lrcLine.length.inMilliseconds.toDouble();
    final progress = _lineProgress(currentTimeMs, lineStartMs, lineEndMs);

    final playedColor = useMaterialYouColor
        ? scheme.primary.withValues(alpha: opacity)
        : (isMainLine
            ? Colors.white.withValues(alpha: opacity)
            : scheme.onSurface.withValues(alpha: opacity * 0.85));
    final unplayedColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: opacity * 0.35)
        : scheme.onSurface.withValues(alpha: opacity * 0.35);
    final secondaryColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: opacity * 0.35)
        : scheme.onSurface.withValues(alpha: opacity * 0.35);
    final translationColor = useMaterialYouColor
        ? scheme.onSurface.withValues(alpha: opacity * 0.60)
        : scheme.onSurface.withValues(alpha: opacity * 0.70);

    final displayedColor = isMainLine
        ? playedColor
        : Color.lerp(unplayedColor, playedColor, progress)!;
    final maxWidth = size.width - padding.horizontal;

    final tp = _buildTextPainter(
      lrcLine.content,
      displayedColor,
      fontSize,
      fontWeight,
      letterSpace,
    );
    tp.layout(maxWidth: maxWidth);
    final x = _alignText(tp.width, maxWidth, padding.left);
    tp.paint(canvas, Offset(x, padding.top));

    double cursorY = padding.top + tp.height;

    if ((config.showTranslation && lrcLine.translation != null) ||
        (config.showRoman && lrcLine.romanLyric != null)) {
      if (config.showTranslation && lrcLine.translation != null) {
        final translationFontSize =
            config.translationFontSize(isMainLine: isMainLine);
        final tTp = _buildTextPainter(
          lrcLine.translation!,
          translationColor,
          translationFontSize,
          fontWeight,
          letterSpace,
        );
        tTp.layout(maxWidth: maxWidth);
        final tx = _alignText(tTp.width, maxWidth, padding.left);
        tTp.paint(canvas, Offset(tx, cursorY));
        cursorY += tTp.height + config.lrcTranslationGap(isMainLine: isMainLine, translationIndex: 0);
      }
      if (config.showRoman && lrcLine.romanLyric != null) {
        final romanFontSize =
            config.translationFontSize(isMainLine: isMainLine);
        final rTp = _buildTextPainter(
          lrcLine.romanLyric!,
          secondaryColor,
          romanFontSize,
          fontWeight,
          letterSpace,
        );
        rTp.layout(maxWidth: maxWidth);
        final rx = _alignText(rTp.width, maxWidth, padding.left);
        rTp.paint(canvas, Offset(rx, cursorY));
      }
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
    if (currentMs < wordStartMs) return 0.0;
    if (currentMs >= wordEndMs) return 1.0;
    final wordDuration = wordEndMs - wordStartMs;
    if (wordDuration <= 0) return 1.0;
    final wordProgress = ((currentMs - wordStartMs) / wordDuration).clamp(0.0, 1.0);
    final charEndThreshold = (charIndex + 1) / totalChars;
    if (wordProgress >= charEndThreshold) return 1.0;
    final charStartThreshold = charIndex / totalChars;
    return ((wordProgress - charStartThreshold) /
            (charEndThreshold - charStartThreshold))
        .clamp(0.0, 1.0);
  }

  double _lineProgress(double currentMs, double lineStartMs, double lineEndMs) {
    if (currentMs < lineStartMs) return 0.0;
    if (currentMs >= lineEndMs || lineEndMs <= lineStartMs) return 1.0;
    return ((currentMs - lineStartMs) / (lineEndMs - lineStartMs))
        .clamp(0.0, 1.0);
  }

  TextPainter _buildTextPainter(
    String text,
    Color color,
    double fontSize,
    FontWeight fontWeight,
    double letterSpacing,
  ) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: fontWeight,
          letterSpacing: letterSpacing,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: null,
    );
  }

  double _alignText(double textWidth, double maxWidth, double paddingLeft) {
    return switch (config.textAlign) {
      LyricTextAlign.center => paddingLeft + (maxWidth - textWidth) / 2,
      LyricTextAlign.right => paddingLeft + maxWidth - textWidth,
      LyricTextAlign.left => paddingLeft,
    };
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
        useMaterialYouColor != oldDelegate.useMaterialYouColor;
  }

  double measureHeight(double maxWidth) {
    final double verticalPad;
    if (line is SyncLyricLine) {
      verticalPad = config.syncVerticalPadding(isMainLine: isMainLine);
    } else {
      verticalPad = config.lrcVerticalPadding();
    }
    final padding = EdgeInsets.only(left: 12.0, right: 12.0, top: verticalPad, bottom: verticalPad);
    final lineWidth = maxWidth - padding.horizontal;

    if (line is SyncLyricLine) {
      final syncLine = line as SyncLyricLine;
      if (syncLine.words.isEmpty) return 0;

      final fontSize = config.primaryFontSize(isMainLine: isMainLine);
      final lineHeight = fontSize * config.primaryLineHeight();
      int lineCount = 1;
      double cursorX = padding.left;
      final fontWeight = config.discreteFontWeight(config.fontWeight);
      final letterSpacing = config.letterSpacing(fontSize: fontSize);

      for (final word in syncLine.words) {
        final chars = word.obscene
            ? List.filled(word.content.runes.length, '_')
            : word.content.characters.toList();
        for (final char in chars) {
          if (char == ' ') continue;
          final tp = _buildTextPainter(
            char,
            useMaterialYouColor ? scheme.primary : scheme.onSurface,
            fontSize,
            fontWeight,
            letterSpacing,
          );
          tp.layout();
          if (cursorX + tp.width > lineWidth && cursorX > padding.left) {
            lineCount++;
            cursorX = padding.left;
          }
          cursorX += tp.width;
        }
      }

      double height = padding.vertical + lineHeight * lineCount;
      if ((config.showTranslation && syncLine.translation != null) ||
          (config.showRoman && syncLine.romanLyric != null)) {
        final translationFontSize =
            config.translationFontSize(isMainLine: isMainLine);
        if (config.showTranslation && syncLine.translation != null) {
          height += translationFontSize * 1.3 + 4;
        }
        if (config.showRoman && syncLine.romanLyric != null) {
          height += translationFontSize * 1.3 + 4;
        }
      }
      return height;
    } else if (line is LrcLine) {
      final lrcLine = line as LrcLine;
      final fontSize = config.primaryFontSize(isMainLine: isMainLine);
      double height = padding.vertical + fontSize * config.primaryLineHeight();
      if ((config.showTranslation && lrcLine.translation != null) ||
          (config.showRoman && lrcLine.romanLyric != null)) {
        final translationFontSize =
            config.translationFontSize(isMainLine: isMainLine);
        if (config.showTranslation && lrcLine.translation != null) {
          height += translationFontSize * 1.3 + 4;
        }
        if (config.showRoman && lrcLine.romanLyric != null) {
          height += translationFontSize * 1.3 + 4;
        }
      }
      return height;
    }
    return 60;
  }
}
