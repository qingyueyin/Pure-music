import 'dart:async';
import 'dart:math';

import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_line_motion.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

/// 统一歌词样式生成器
TextStyle _lyricTextStyle({
  required LyricRenderConfig config,
  required Color color,
  required double fontSize,
  required int weight,
  required ColorScheme scheme,
  double? height,
}) {
  final w = weight.clamp(100, 900);
  return TextStyle(
    fontFamily: 'sans-serif',
    color: color,
    fontSize: fontSize,
    fontVariations: [FontVariation('wght', w.toDouble())],
    fontWeight: config.discreteFontWeight(w),
    height: height ?? config.translationLineHeight(w),
    letterSpacing: config.letterSpacing(fontSize: fontSize, weight: w),
  );
}

class LyricViewTile extends StatefulWidget {
  const LyricViewTile({
    super.key,
    required this.line,
    required this.opacity,
    this.distance,
    this.lineOffsetY = 0.0,
    this.staggerDelay = Duration.zero,
    this.onTap,
  });

  final LyricLine line;
  final double opacity;
  final int? distance;
  final double lineOffsetY;
  final Duration staggerDelay;
  final void Function()? onTap;

  @override
  State<LyricViewTile> createState() => _LyricViewTileState();
}

class _LyricViewTileState extends State<LyricViewTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideController;
  late Animation<double> _offsetYAnimation;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _offsetYAnimation = Tween<double>(
      begin: 0.0,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
    ));
    _slideController.value = 1.0;
  }

  @override
  void didUpdateWidget(LyricViewTile oldWidget) {
    super.didUpdateWidget(oldWidget);

    final newOffset = widget.lineOffsetY;
    final wasActive = oldWidget.lineOffsetY.abs() <= 0.001;
    final isActive = newOffset.abs() <= 0.001;

    if (!isActive && newOffset != 0) {
      _offsetYAnimation = Tween<double>(
        begin: 0.0,
        end: newOffset,
      ).animate(CurvedAnimation(
        parent: _slideController,
        curve: Curves.easeOutCubic,
      ));
      _slideController.value = 0.0;
      _slideController.forward();
    } else if (isActive && !wasActive) {
      _offsetYAnimation = Tween<double>(
        begin: oldWidget.lineOffsetY,
        end: 0.0,
      ).animate(CurvedAnimation(
        parent: _slideController,
        curve: Curves.easeOutCubic,
      ));
      _slideController.value = 0.0;
      _slideController.forward();
    } else {
      _slideController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lyricViewController = context.watch<LyricViewController>();
    final config = lyricViewController.renderConfig;
    final d = widget.distance ?? (widget.opacity == 1.0 ? 0 : 999);
    final isMainLine = d == 0;
    final blurSigma = config.blurSigmaForDistance(d);

    Widget content = InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(12.0),
      child: widget.line is SyncLyricLine
          ? _SyncLineContent(
              syncLine: widget.line as SyncLyricLine,
              isMainLine: isMainLine,
            )
          : _LrcLineContent(
              lrcLine: widget.line as LrcLine,
              isMainLine: isMainLine,
            ),
    );

    final alignment = switch (config.textAlign) {
      LyricTextAlign.left => Alignment.centerLeft,
      LyricTextAlign.center => Alignment.center,
      LyricTextAlign.right => Alignment.centerRight,
    };

    double computeSafeScale(BoxConstraints constraints) {
      return config.enableLineScale
          ? (isMainLine
              ? config.activeLineScaleMultiplier
              : config.inactiveLineScaleMultiplier)
          : 1.0;
    }

    return Align(
      alignment: alignment,
      child: SizedBox(
        width: double.infinity,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scale = computeSafeScale(constraints);
            final slideContent = AnimatedBuilder(
              animation: _slideController,
              builder: (context, child) {
                final offsetY = _offsetYAnimation.value;
                return Transform.translate(
                  offset: Offset(0, offsetY),
                  child: child,
                );
              },
              child: content,
            );
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: LyricLineSpringMotion(
                targetState: LyricLineVisualState(
                  opacity: widget.opacity,
                  blurSigma: blurSigma,
                  scale: scale,
                  offsetY: 0.0,
                ),
                spring: config.lineSpring,
                alignment: alignment,
                enabled: config.enableLineSpring,
                staggerDelay: widget.staggerDelay,
                child: slideContent,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SyncLineContent extends StatelessWidget {
  const _SyncLineContent({required this.syncLine, required this.isMainLine});

  final SyncLyricLine syncLine;
  final bool isMainLine;

  @override
  Widget build(BuildContext context) {
    if (syncLine.words.isEmpty) {
      if (syncLine.length > const Duration(seconds: 5) && isMainLine) {
        return LyricTransitionTile(syncLine: syncLine);
      } else {
        return const SizedBox.shrink();
      }
    }

    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();
    final config = lyricViewController.renderConfig;

    final alignment = config.textAlign;
    final showTranslation = config.showTranslation;
    final showRoman = config.showRoman;
    final fontWeight = config.fontWeight;
    final primarySize = config.primaryFontSize(isMainLine: isMainLine);
    final translationSize = config.translationFontSize(isMainLine: isMainLine);
    final verticalPad = config.syncVerticalPadding(isMainLine: isMainLine);

    if (!isMainLine) {
      if (syncLine.words.isEmpty) {
        return const SizedBox.shrink();
      }

      final List<Widget> wordWidgets = [];
      for (var word in syncLine.words) {
        final chars = word.content.characters.toList();
        final wordStart = word.start.inMilliseconds.toDouble();
        final wordEnd = wordStart + max(word.length.inMilliseconds.toDouble(), 1.0);
        
        final List<Widget> charItems = [];
        for (var i = 0; i < chars.length; i++) {
          charItems.add(
            _ReferenceCharItem(
              char: chars[i],
              charIndex: i,
              totalChars: chars.length,
              wordStart: wordStart,
              wordEnd: wordEnd,
              positionMs: null,
              fontSize: primarySize,
              config: config,
            ),
          );
        }
        
        wordWidgets.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: charItems,
          ),
        );
        wordWidgets.add(SizedBox(width: primarySize * 0.12));
      }

      final List<Widget> contents = [
        Wrap(
          alignment: _getWrapAlignment(config.textAlign),
          crossAxisAlignment: WrapCrossAlignment.end,
          children: wordWidgets,
        ),
      ];
      if (showTranslation && syncLine.translation != null) {
        contents.add(
          SizedBox(height: config.syncTranslationGap(isMainLine: false)),
        );
        contents.add(buildSecondaryText(
          syncLine.translation!,
          scheme,
          alignment,
          translationSize,
          fontWeight,
          config: config,
          opacity: 0.5,
        ));
      }
      if (showRoman &&
          syncLine.romanLyric != null &&
          syncLine.romanLyric!.isNotEmpty) {
        contents.add(SizedBox(height: 4.0));
        contents.add(buildSecondaryText(
          syncLine.romanLyric!,
          scheme,
          alignment,
          translationSize * 0.85,
          fontWeight - 100,
          config: config,
          opacity: 0.35,
        ));
      }

      return Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: switch (alignment) {
            LyricTextAlign.left => CrossAxisAlignment.start,
            LyricTextAlign.center => CrossAxisAlignment.center,
            LyricTextAlign.right => CrossAxisAlignment.end,
          },
          children: contents,
        ),
      );
    }

    final wordsWidget = StreamBuilder<double>(
      stream: PlayService.instance.playbackService.positionStream,
      builder: (context, snapshot) {
        final posMs = (snapshot.data ?? 0.0) * 1000;
        
        final List<Widget> wordWidgets = [];
        for (var word in syncLine.words) {
          final chars = word.content.characters.toList();
          final wordStart = word.start.inMilliseconds.toDouble();
          final wordEnd = wordStart + max(word.length.inMilliseconds.toDouble(), 1.0);

          final List<Widget> charItems = [];
          for (var i = 0; i < chars.length; i++) {
            charItems.add(
              _ReferenceCharItem(
                char: chars[i],
                charIndex: i,
                totalChars: chars.length,
                wordStart: wordStart,
                wordEnd: wordEnd,
                positionMs: posMs,
                fontSize: primarySize,
                config: config,
              ),
            );
          }

          wordWidgets.add(
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: charItems,
            ),
          );
          wordWidgets.add(SizedBox(width: primarySize * 0.12));
        }

        return Wrap(
          alignment: _getWrapAlignment(alignment),
          crossAxisAlignment: WrapCrossAlignment.end,
          children: wordWidgets,
        );
      },
    );

    final List<Widget> contents = [
      wordsWidget,
    ];
    if (showTranslation && syncLine.translation != null) {
      contents.add(
        SizedBox(height: config.syncTranslationGap(isMainLine: true)),
      );
      contents.add(buildSecondaryText(
        syncLine.translation!,
        scheme,
        alignment,
        translationSize,
        fontWeight,
        config: config,
      ));
    }
    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPad, horizontal: 12.0),
      child: Column(
        crossAxisAlignment: switch (alignment) {
          LyricTextAlign.left => CrossAxisAlignment.start,
          LyricTextAlign.center => CrossAxisAlignment.center,
          LyricTextAlign.right => CrossAxisAlignment.end,
        },
        children: contents,
      ),
    );
  }

  Text buildPrimaryText(
    String text,
    ColorScheme scheme,
    LyricTextAlign align,
    double fontSize,
    int fontWeight, {
    required LyricRenderConfig config,
    double opacity = 1.0,
  }) {
    return Text(
      text,
      softWrap: true,
      overflow: TextOverflow.clip,
      textAlign: switch (align) {
        LyricTextAlign.left => TextAlign.left,
        LyricTextAlign.center => TextAlign.center,
        LyricTextAlign.right => TextAlign.right,
      },
      style: _lyricTextStyle(
        config: config,
        color: scheme.onSurface.withValues(alpha: opacity),
        fontSize: fontSize,
        weight: fontWeight,
        scheme: scheme,
        height: config.primaryLineHeight(fontWeight),
      ),
    );
  }

  Text buildSecondaryText(
    String text,
    ColorScheme scheme,
    LyricTextAlign align,
    double fontSize,
    int fontWeight, {
    required LyricRenderConfig config,
    double opacity = 0.70,
  }) {
    final translationWeight = (fontWeight - 50).clamp(100, 900);
    return Text(
      text,
      softWrap: true,
      overflow: TextOverflow.clip,
      textAlign: switch (align) {
        LyricTextAlign.left => TextAlign.left,
        LyricTextAlign.center => TextAlign.center,
        LyricTextAlign.right => TextAlign.right,
      },
      style: _lyricTextStyle(
        config: config,
        color: scheme.onSurface.withValues(alpha: opacity),
        fontSize: fontSize,
        weight: translationWeight,
        scheme: scheme,
        height: config.translationLineHeight(fontWeight),
      ),
    );
  }
}

/// 单个字符的优雅动画组件 - 基于歌词时间轴的逐字渲染
class _ReferenceCharItem extends StatelessWidget {
  const _ReferenceCharItem({
    required this.char,
    required this.charIndex,
    required this.totalChars,
    required this.wordStart,
    required this.wordEnd,
    required this.positionMs,
    required this.fontSize,
    required this.config,
  });

  final String char;
  final int charIndex;
  final int totalChars;
  final double wordStart;
  final double wordEnd;
  final double? positionMs;
  final double fontSize;
  final LyricRenderConfig config;

  double _calcCharProgress() {
    if (positionMs == null) return 0.0;
    final wordDuration = wordEnd - wordStart;
    if (wordDuration <= 0) return positionMs! >= wordStart ? 1.0 : 0.0;
    
    final wordProgress = ((positionMs! - wordStart) / wordDuration).clamp(0.0, 1.0);
    if (wordProgress <= 0.0) return 0.0;
    
    final charThreshold = (charIndex + 1) / totalChars;
    if (wordProgress >= charThreshold) return 1.0;
    
    final charStartThreshold = charIndex / totalChars;
    final charSegmentProgress = ((wordProgress - charStartThreshold) / (charThreshold - charStartThreshold)).clamp(0.0, 1.0);
    return charSegmentProgress;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDarkMode = scheme.brightness == Brightness.dark;
    final highlightColor = isDarkMode ? Colors.white : Colors.black;

    final baseStyle = _lyricTextStyle(
      config: config,
      color: scheme.onSurface.withValues(alpha: 0.25),
      fontSize: fontSize,
      weight: config.fontWeight,
      scheme: scheme,
      height: config.primaryLineHeight(config.fontWeight),
    );
    final overlayStyle = _lyricTextStyle(
      config: config,
      color: highlightColor,
      fontSize: fontSize,
      weight: config.fontWeight,
      scheme: scheme,
      height: config.primaryLineHeight(config.fontWeight),
    );

    final progress = _calcCharProgress();
    final isStarted = progress > 0.0;

    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 700),
      curve: const Cubic(0.2, 0, 0.3, 1),
      tween: Tween(begin: 0.0, end: isStarted ? -3.0 : 0.0),
      builder: (context, yOffset, child) {
        return Transform.translate(
          offset: Offset(0, yOffset),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Text(char, style: baseStyle),
              if (progress > 0.0)
                ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (bounds) {
                    return LinearGradient(
                      colors: const [
                        Colors.white,
                        Colors.white,
                        Colors.transparent,
                        Colors.transparent,
                      ],
                      stops: [0.0, progress, progress, 1.0],
                    ).createShader(bounds);
                  },
                  child: Text(char, style: overlayStyle),
                ),
            ],
          ),
        );
      },
    );
  }
}

// 辅助转换函数
WrapAlignment _getWrapAlignment(LyricTextAlign align) => switch (align) {
  LyricTextAlign.left => WrapAlignment.start,
  LyricTextAlign.center => WrapAlignment.center,
  LyricTextAlign.right => WrapAlignment.end,
};

class _LrcLineContent extends StatelessWidget {
  const _LrcLineContent({
    required this.lrcLine,
    required this.isMainLine,
  });

  final LrcLine lrcLine;
  final bool isMainLine;

  @override
  Widget build(BuildContext context) {
    if (lrcLine.isBlank) {
      if (lrcLine.length > const Duration(seconds: 5) && isMainLine) {
        return LyricTransitionTile(lrcLine: lrcLine);
      } else {
        return const SizedBox.shrink();
      }
    }

    if (lrcLine.isMetadata) {
      final lyricViewController = context.watch<LyricViewController>();
      final config = lyricViewController.renderConfig;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: Text(
          lrcLine.content,
          style: _lyricTextStyle(
            config: config,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.70),
            fontSize: config.primaryFontSize(isMainLine: isMainLine) * 0.85,
            weight: config.fontWeight - 100,
            scheme: Theme.of(context).colorScheme,
          ),
          textAlign: config.textAlign == LyricTextAlign.left
              ? TextAlign.left
              : config.textAlign == LyricTextAlign.center
                  ? TextAlign.center
                  : TextAlign.right,
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final lyricViewController = context.watch<LyricViewController>();
    final config = lyricViewController.renderConfig;

    final alignment = config.textAlign;
    final showTranslation = config.showTranslation;
    final showRoman = config.showRoman;
    final fontWeight = config.fontWeight;
    final primarySize = config.primaryFontSize(isMainLine: isMainLine);
    final translationSize = config.translationFontSize(isMainLine: isMainLine);
    final verticalPad = config.lrcVerticalPadding();

    final splited = lrcLine.content.split("┃");
    final List<Widget> contents = [
      buildPrimaryText(
        splited.first,
        scheme,
        alignment,
        primarySize,
        fontWeight,
        config: config,
      )
    ];
    if (showTranslation) {
      for (var i = 1; i < splited.length; i++) {
        contents.add(SizedBox(
          height: config.lrcTranslationGap(
            isMainLine: isMainLine,
            translationIndex: i - 1,
          ),
        ));
        contents.add(buildSecondaryText(
          splited[i],
          scheme,
          alignment,
          translationSize,
          fontWeight,
          config: config,
        ));
      }
    }
    if (showRoman &&
        lrcLine.romanLyric != null &&
        lrcLine.romanLyric!.isNotEmpty) {
      contents.add(SizedBox(height: 4.0));
      contents.add(buildSecondaryText(
        lrcLine.romanLyric!,
        scheme,
        alignment,
        translationSize * 0.85,
        fontWeight - 100,
        config: config,
        opacity: 0.70 * 0.5,
      ));
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPad, horizontal: 12.0),
      child: Column(
        crossAxisAlignment: switch (alignment) {
          LyricTextAlign.left => CrossAxisAlignment.start,
          LyricTextAlign.center => CrossAxisAlignment.center,
          LyricTextAlign.right => CrossAxisAlignment.end,
        },
        children: contents,
      ),
    );
  }

  Text buildPrimaryText(String text, ColorScheme scheme, LyricTextAlign align,
      double fontSize, int fontWeight,
      {required LyricRenderConfig config, double opacity = 1.0}) {
    return Text(
      text,
      softWrap: true,
      overflow: TextOverflow.clip,
      textAlign: switch (align) {
        LyricTextAlign.left => TextAlign.left,
        LyricTextAlign.center => TextAlign.center,
        LyricTextAlign.right => TextAlign.right,
      },
      style: _lyricTextStyle(
        config: config,
        color: scheme.onSurface.withValues(alpha: opacity),
        fontSize: fontSize,
        weight: fontWeight,
        scheme: scheme,
        height: config.primaryLineHeight(fontWeight),
      ),
    );
  }

  Text buildSecondaryText(String text, ColorScheme scheme, LyricTextAlign align,
      double fontSize, int fontWeight,
      {required LyricRenderConfig config, double opacity = 0.70}) {
    final translationWeight = (fontWeight - 50).clamp(100, 900);
    return Text(
      text,
      softWrap: true,
      overflow: TextOverflow.clip,
      textAlign: switch (align) {
        LyricTextAlign.left => TextAlign.left,
        LyricTextAlign.center => TextAlign.center,
        LyricTextAlign.right => TextAlign.right,
      },
      style: _lyricTextStyle(
        config: config,
        color: scheme.onSurface.withValues(alpha: opacity),
        fontSize: fontSize,
        weight: translationWeight,
        scheme: scheme,
        height: config.translationLineHeight(fontWeight),
      ),
    );
  }
}

/// 歌词间奏表示
/// lrcLine 和 syncLine 必须有且只有一个不为空
class LyricTransitionTile extends StatefulWidget {
  final LrcLine? lrcLine;
  final SyncLyricLine? syncLine;
  const LyricTransitionTile({super.key, this.lrcLine, this.syncLine});

  @override
  State<LyricTransitionTile> createState() => _LyricTransitionTileState();
}

class _LyricTransitionTileState extends State<LyricTransitionTile> {
  late final LyricTransitionTileController controller;

  @override
  void initState() {
    super.initState();
    controller = LyricTransitionTileController(widget.lrcLine, widget.syncLine);
  }

  @override
  void didUpdateWidget(LyricTransitionTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lrcLine != widget.lrcLine ||
        oldWidget.syncLine != widget.syncLine) {
      controller.dispose();
      controller =
          LyricTransitionTileController(widget.lrcLine, widget.syncLine);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      height: 40.0,
      width: 80.0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 6),
        child: CustomPaint(
          painter: LyricTransitionPainter(
            scheme,
            controller,
          ),
        ),
      ),
    );
  }
}

class LyricTransitionPainter extends CustomPainter {
  final ColorScheme scheme;
  final LyricTransitionTileController controller;

  final Paint circlePaint1 = Paint();
  final Paint circlePaint2 = Paint();
  final Paint circlePaint3 = Paint();

  final double radius = 6;

  LyricTransitionPainter(this.scheme, this.controller)
      : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) {
    final a1 = (255 * (0.05 + min(controller.progress * 3, 1) * 0.95))
        .round()
        .clamp(0, 255);
    final a2 =
        (255 * (0.05 + min(max(controller.progress - 1 / 3, 0) * 3, 1) * 0.95))
            .round()
            .clamp(0, 255);
    final a3 =
        (255 * (0.05 + min(max(controller.progress - 2 / 3, 0) * 3, 1) * 0.95))
            .round()
            .clamp(0, 255);
    circlePaint1.color = scheme.onSecondaryContainer.withAlpha(a1);
    circlePaint2.color = scheme.onSecondaryContainer.withAlpha(a2);
    circlePaint3.color = scheme.onSecondaryContainer.withAlpha(a3);

    final rWithFactor = radius + controller.sizeFactor;
    final c1 = Offset(rWithFactor, 8);
    final c2 = Offset(4 * rWithFactor, 8);
    final c3 = Offset(7 * rWithFactor, 8);

    canvas.drawCircle(c1, rWithFactor, circlePaint1);
    canvas.drawCircle(c2, rWithFactor, circlePaint2);
    canvas.drawCircle(c3, rWithFactor, circlePaint3);
  }

  @override
  bool shouldRepaint(LyricTransitionPainter oldDelegate) => false;

  @override
  bool shouldRebuildSemantics(LyricTransitionPainter oldDelegate) => false;
}

class LyricTransitionTileController extends ChangeNotifier {
  final LrcLine? lrcLine;
  final SyncLyricLine? syncLine;

  final playbackService = PlayService.instance.playbackService;

  double progress = 0;
  late final StreamSubscription positionStreamSub;

  double sizeFactor = 0;
  double k = 1;
  late final Ticker factorTicker;

  LyricTransitionTileController([this.lrcLine, this.syncLine]) {
    positionStreamSub = playbackService.positionStream.listen(_updateProgress);
    factorTicker = Ticker((elapsed) {
      sizeFactor += k * 1 / 180;
      if (sizeFactor > 1) {
        k = -1;
        sizeFactor = 1;
      } else if (sizeFactor < 0) {
        k = 1;
        sizeFactor = 0;
      }
      notifyListeners();
    });
    factorTicker.start();
  }

  void _updateProgress(double position) {
    late int startInMs;
    late int lengthInMs;
    if (lrcLine != null) {
      startInMs = lrcLine!.start.inMilliseconds;
      lengthInMs = lrcLine!.length.inMilliseconds;
    } else {
      startInMs = syncLine!.start.inMilliseconds;
      lengthInMs = syncLine!.length.inMilliseconds;
    }
    final sinceStart = position * 1000 - startInMs;
    progress = max(sinceStart, 0) / lengthInMs;
    notifyListeners();

    if (progress >= 1) {
      dispose();
    }
  }

  @override
  void dispose() {
    positionStreamSub.cancel();
    factorTicker.dispose();
    super.dispose();
  }
}
