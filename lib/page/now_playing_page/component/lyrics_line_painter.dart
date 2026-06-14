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

  // 复用 TextPainter 实例，避免频繁创建销毁
  static final _textPainterPool = <TextPainter>[];
  static const _maxPoolSize = 3; // 从 4 降到 3，进一步减少内存
  static int _poolHitCount = 0; // 池命中计数
  static int _poolMissCount = 0; // 池未命中计数

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

  /// 清空对象池（歌曲切换时调用）
  static void clearPool() {
    for (final tp in _textPainterPool) {
      tp.dispose();
    }
    _textPainterPool.clear();
    _poolHitCount = 0;
    _poolMissCount = 0;
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
    final hitRate = total > 0 ? (_poolHitCount / total * 100).toStringAsFixed(1) : '0.0';
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
    // 非当前行歌词在浅色模式下需要更高不透明度以保持可读性
    final unplayedColor = useMaterialYouColor
        ? scheme.onSurface
            .withValues(alpha: isDarkMode ? opacity * 0.22 : opacity * 0.45)
        : scheme.onSurface
            .withValues(alpha: isDarkMode ? opacity * 0.18 : opacity * 0.35);
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
        measureTp.text =
            TextSpan(text: char, style: measureStyle(fontSize, fontWeight));
        measureTp.layout();
        convertedChars.add(char);
        charWidths.add(measureTp.width);
        wordWidth += measureTp.width;
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
    void paintWord(List<_CharInfo> wc, TextStyle style, bool useLift) {
      if (useLift) {
        for (final info in wc) {
          tp.text = TextSpan(text: info.char, style: style);
          tp.layout();
          tp.paint(canvas, Offset(info.x, info.y + info.yLift));
        }
      } else {
        final text = wc.map((c) => c.char).join();
        tp.text = TextSpan(text: text, style: style);
        tp.layout();
        tp.paint(canvas, Offset(wc.first.x, wc.first.y));
      }
    }

    // ── Per visual line ────────────────────────────────────────────────────
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
        continue;
      }

      // ── Gradient (2.1.3 formula) ───────────────────────────────────────
      final bounds = Rect.fromLTRB(left, top, right, bottom);
      final bw = bounds.width <= 0 ? 1.0 : bounds.width;
      final sweepP = ((highlightR - left) / bw).clamp(0.0, 1.0);
      final feather = (24.0 / bw).clamp(0.035, 0.14);
      final p0 = (sweepP - feather).clamp(0.0, sweepP);
      final p1 = (sweepP + feather * 0.35).clamp(sweepP, 1.0);
      final shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Colors.white,
          Colors.white,
          Colors.white.withValues(alpha: 0.65),
          Colors.transparent
        ],
        stops: [0.0, p0, sweepP, p1],
      ).createShader(bounds);

      // ── Pass 1: dim ──────────────────────────────────────────────────
      for (final entry in words) {
        paintWord(
            entry.value, dimStyle, entry.value.any((c) => c.yLift != 0.0));
      }

      // ── Pass 2: saveLayer + played ────────────────────────────────────
      if (highlightR >= right - 0.5) {
        for (final entry in words) {
          paintWord(
              entry.value, playedStyle, entry.value.any((c) => c.yLift != 0.0));
        }
      } else {
        canvas.save();
        canvas.clipRect(bounds);
        canvas.saveLayer(bounds, Paint());
        for (final entry in words) {
          paintWord(
              entry.value, playedStyle, entry.value.any((c) => c.yLift != 0.0));
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

    // 回收 TextPainter
    _recycleTextPainter(measureTp);
    _recycleTextPainter(tp);

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
        ? scheme.onSurface
            .withValues(alpha: isDarkMode ? opacity * 0.22 : opacity * 0.45)
        : scheme.onSurface
            .withValues(alpha: isDarkMode ? opacity * 0.18 : opacity * 0.35);
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
      displayedColor,
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
        _recycleTextPainter(tTp);
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
      _recycleTextPainter(rTp);
    }

    // 回收主行 TextPainter
    _recycleTextPainter(mainTp);

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
          _recycleTextPainter(tTp);
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
          _recycleTextPainter(rTp);
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
          _recycleTextPainter(tTp);
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
        _recycleTextPainter(rTp);
      }
      _recycleTextPainter(mainTp);
      return height;
    }
    return 60;
  }
}
