import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_line_motion.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_word_highlight_mask.dart';
import 'package:pure_music/page/now_playing_page/component/word_emphasis_helper.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

TextStyle _lyricTextStyle({
  required LyricRenderConfig config,
  required Color color,
  required double fontSize,
  required int weight,
  double? height,
}) {
  final w = weight.clamp(100, 900);
  final shadowColor = color.computeLuminance() > 0.6
      ? Colors.black.withValues(alpha: 0.55)
      : Colors.white.withValues(alpha: 0.40);
  return TextStyle(
    color: color,
    fontSize: fontSize,
    fontVariations: [FontVariation('wght', w.toDouble())],
    fontWeight: config.discreteFontWeight(w),
    height: height ?? config.translationLineHeight(w),
    letterSpacing: config.letterSpacing(fontSize: fontSize, weight: w),
    shadows: [
      Shadow(
        color: shadowColor,
        blurRadius: 3.0,
        offset: const Offset(0, 1),
      ),
    ],
  );
}

class LyricViewTile extends StatelessWidget {
  const LyricViewTile({
    super.key,
    required this.line,
    required this.opacity,
    this.distance,
    this.onTap,
  });

  final LyricLine line;
  final double opacity;
  final int? distance;
  final void Function()? onTap;

  @override
  Widget build(BuildContext context) {
    final lyricViewController = context.watch<LyricViewController>();
    final config = lyricViewController.renderConfig;
    final d = distance ?? (opacity == 1.0 ? 0 : 999);
    final isMainLine = d == 0;
    final blurSigma = config.blurSigmaForDistance(d);

    Widget content = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12.0),
      child: line is SyncLyricLine
          ? _SyncLineContent(
              syncLine: line as SyncLyricLine,
              isMainLine: isMainLine,
            )
          : _LrcLineContent(
              lrcLine: line as LrcLine,
              isMainLine: isMainLine,
            ),
    );

    final alignment = switch (config.textAlign) {
      LyricTextAlign.left => Alignment.centerLeft,
      LyricTextAlign.center => Alignment.center,
      LyricTextAlign.right => Alignment.centerRight,
    };

    double measureTextWidth(String text, TextStyle style) {
      if (text.isEmpty) return 0.0;
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      return painter.width;
    }

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
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: LyricLineSpringMotion(
                targetState: LyricLineVisualState(
                  opacity: opacity,
                  blurSigma: blurSigma,
                  scale: scale,
                ),
                spring: config.lineSpring,
                alignment: alignment,
                enabled: config.enableLineSpring,
                child: content,
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

      final List<Widget> contents = [
        _SyncWordsWrap(
          syncLine: syncLine,
          alignment: alignment,
          config: config,
          primarySize: primarySize,
          fontWeight: fontWeight,
          inactiveOpacity: 0.6,
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

    final wordsWidget = config.enableAudioReactive
        ? StreamBuilder<Float32List>(
            stream: PlayService.instance.playbackService.spectrumStream,
            builder: (context, spectrumSnapshot) {
              return StreamBuilder(
                stream: PlayService.instance.playbackService.positionStream,
                builder: (context, snapshot) {
                  final posInMs = (snapshot.data ?? 0) * 1000;
                  return _SyncWordsWrap(
                    syncLine: syncLine,
                    alignment: alignment,
                    config: config,
                    primarySize: primarySize,
                    fontWeight: fontWeight,
                    positionMs: posInMs,
                    spectrumBands: spectrumSnapshot.data,
                  );
                },
              );
            },
          )
        : StreamBuilder(
            stream: PlayService.instance.playbackService.positionStream,
            builder: (context, snapshot) {
              final posInMs = (snapshot.data ?? 0) * 1000;
              return _SyncWordsWrap(
                syncLine: syncLine,
                alignment: alignment,
                config: config,
                primarySize: primarySize,
                fontWeight: fontWeight,
                positionMs: posInMs,
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
        color: Colors.white.withValues(alpha: opacity),
        fontSize: fontSize,
        weight: fontWeight,
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
        color: Colors.white.withValues(alpha: opacity),
        fontSize: fontSize,
        weight: translationWeight,
        height: config.translationLineHeight(fontWeight),
      ),
    );
  }
}

class _SyncWordsWrap extends StatelessWidget {
  const _SyncWordsWrap({
    required this.syncLine,
    required this.alignment,
    required this.config,
    required this.primarySize,
    required this.fontWeight,
    this.positionMs,
    this.spectrumBands,
    this.inactiveOpacity = 0.22,
  });

  final SyncLyricLine syncLine;
  final LyricTextAlign alignment;
  final LyricRenderConfig config;
  final double primarySize;
  final int fontWeight;
  final double? positionMs;
  final Float32List? spectrumBands;
  final double inactiveOpacity;

  @override
  Widget build(BuildContext context) {
    final strut = StrutStyle(
      fontSize: primarySize,
      height: config.primaryLineHeight(fontWeight),
      forceStrutHeight: false,
    );
    final inactiveStyle = _lyricTextStyle(
      config: config,
      color: Colors.white.withValues(alpha: inactiveOpacity),
      fontSize: primarySize,
      weight: fontWeight,
      height: config.primaryLineHeight(fontWeight),
    );
    final activeBaseStyle = _lyricTextStyle(
      config: config,
      color: Colors.white,
      fontSize: primarySize,
      weight: fontWeight,
      height: config.primaryLineHeight(fontWeight),
    );

    return Wrap(
      alignment: switch (alignment) {
        LyricTextAlign.left => WrapAlignment.start,
        LyricTextAlign.center => WrapAlignment.center,
        LyricTextAlign.right => WrapAlignment.end,
      },
      crossAxisAlignment: WrapCrossAlignment.center,
      children: List.generate(syncLine.words.length, (i) {
        final word = syncLine.words[i];
        final wordLenMs = word.length.inMilliseconds;
        final wordStartMs = word.start.inMilliseconds.toDouble();
        final wordEndMs = wordStartMs + wordLenMs;
        final progress = positionMs == null
            ? 0.0
            : wordLenMs <= 0
                ? (positionMs! >= wordEndMs ? 1.0 : 0.0)
                : ((positionMs! - wordStartMs) / wordLenMs).clamp(0.0, 1.0);

        final emphasis = WordEmphasisHelper.resolve(
          progress: progress,
          baseSize: primarySize,
          config: config,
          word: word,
          spectrumBands: spectrumBands,
        );
        final metrics = _measureWordMetrics(word.content, activeBaseStyle);
        final highlightMask = LyricWordHighlightMask.fromMetrics(
          progress: progress,
          fadeScale: config.wordFadeWidth,
          wordWidth: metrics.$1,
          wordHeight: metrics.$2,
        );
        final activeStyle = emphasis.glowAlpha > 0.0
            ? activeBaseStyle.copyWith(
                shadows: [
                  Shadow(
                    color: Colors.white.withValues(
                      alpha: emphasis.glowAlpha,
                    ),
                    blurRadius: emphasis.glowBlur,
                  ),
                  Shadow(
                    color: Colors.white.withValues(
                      alpha: emphasis.glowAlpha * 0.6,
                    ),
                    blurRadius: emphasis.glowBlur * 1.5,
                  ),
                ],
              )
            : activeBaseStyle;

        return Padding(
          padding: _wordVisualPadding(word),
          child: Transform.translate(
            offset: Offset(0, emphasis.yOffset),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _buildWordLayer(
                  word: word,
                  style: inactiveStyle,
                  strut: strut,
                  activeLayer: false,
                ),
                if (highlightMask.shouldHighlight)
                  Transform.scale(
                    scale: emphasis.scale,
                    alignment: Alignment.center,
                    child: ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (bounds) {
                        return LinearGradient(
                          colors: const [
                            Colors.white,
                            Colors.white,
                            Colors.transparent,
                            Colors.transparent
                          ],
                          stops: highlightMask.stops,
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ).createShader(bounds);
                      },
                      child: _buildWordLayer(
                        word: word,
                        style: activeStyle,
                        strut: strut,
                        activeLayer: true,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      }),
    );
  }

  (double, double) _measureWordMetrics(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return (painter.width, painter.height);
  }

  EdgeInsets _wordVisualPadding(SyncLyricWord word) {
    final emphasize = WordEmphasisHelper.shouldEmphasizeWord(word);
    final horizontal = emphasize ? primarySize * 0.06 : primarySize * 0.02;
    final top = emphasize ? primarySize * 0.18 : primarySize * 0.10;
    final bottom = emphasize ? primarySize * 0.24 : primarySize * 0.16;
    return EdgeInsets.fromLTRB(horizontal, top, horizontal, bottom);
  }

  Widget _buildWordLayer({
    required SyncLyricWord word,
    required TextStyle style,
    required StrutStyle strut,
    required bool activeLayer,
  }) {
    final content = word.content;
    final match = RegExp(r'^(\s*)(.*?)(\s*)$').firstMatch(content);
    final prefix = match?.group(1) ?? '';
    final core = match?.group(2) ?? content;
    final suffix = match?.group(3) ?? '';

    if (!activeLayer ||
        !WordEmphasisHelper.shouldEmphasizeWord(word) ||
        core.characters.length <= 1) {
      return Text(
        content,
        strutStyle: strut,
        style: style,
        textHeightBehavior: const TextHeightBehavior(
          applyHeightToFirstAscent: true,
          applyHeightToLastDescent: false,
        ),
      );
    }

    final chars = core.characters.toList(growable: false);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (prefix.isNotEmpty)
          Text(
            prefix,
            strutStyle: strut,
            style: style,
            textHeightBehavior: const TextHeightBehavior(
              applyHeightToFirstAscent: true,
              applyHeightToLastDescent: false,
            ),
          ),
        for (var i = 0; i < chars.length; i++)
          _buildCharacterLayer(
            word: word,
            style: style,
            strut: strut,
            content: chars[i],
            characterIndex: i,
            characterCount: chars.length,
          ),
        if (suffix.isNotEmpty)
          Text(
            suffix,
            strutStyle: strut,
            style: style,
            textHeightBehavior: const TextHeightBehavior(
              applyHeightToFirstAscent: true,
              applyHeightToLastDescent: false,
            ),
          ),
      ],
    );
  }

  Widget _buildCharacterLayer({
    required SyncLyricWord word,
    required TextStyle style,
    required StrutStyle strut,
    required String content,
    required int characterIndex,
    required int characterCount,
  }) {
    final wordLengthMs = word.length.inMilliseconds;
    final progress = positionMs == null || wordLengthMs <= 0
        ? 0.0
        : ((positionMs! - word.start.inMilliseconds) / wordLengthMs)
            .clamp(0.0, 1.0);
    final emphasis = WordEmphasisHelper.resolve(
      progress: progress,
      baseSize: primarySize,
      config: config,
      word: word,
      spectrumBands: spectrumBands,
      characterIndex: characterIndex,
      characterCount: characterCount,
    );
    return Transform.translate(
      offset: Offset(0, emphasis.yOffset * 0.35),
      child: Transform.scale(
        scale: 1.0 + ((emphasis.scale - 1.0) * 0.4),
        alignment: Alignment.center,
        child: Text(
          content,
          strutStyle: strut,
          style: style.copyWith(
            shadows: emphasis.glowAlpha > 0.0
                ? [
                    Shadow(
                      color: Colors.white.withValues(alpha: emphasis.glowAlpha),
                      blurRadius: emphasis.glowBlur,
                    ),
                  ]
                : style.shadows,
          ),
          textHeightBehavior: const TextHeightBehavior(
            applyHeightToFirstAscent: true,
            applyHeightToLastDescent: false,
          ),
        ),
      ),
    );
  }
}

class _LrcLineContent extends StatelessWidget {
  const _LrcLineContent({required this.lrcLine, required this.isMainLine});

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
      {required LyricRenderConfig config}) {
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
        color: Colors.white,
        fontSize: fontSize,
        weight: fontWeight,
        height: config.primaryLineHeight(fontWeight),
      ),
    );
  }

  Text buildSecondaryText(String text, ColorScheme scheme, LyricTextAlign align,
      double fontSize, int fontWeight,
      {required LyricRenderConfig config}) {
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
        color: Colors.white.withValues(alpha: 0.70),
        fontSize: fontSize,
        weight: translationWeight,
        height: config.translationLineHeight(fontWeight),
      ),
    );
  }
}

/// 歌词间奏表示
/// lrcLine 和 syncLine 必须有且只有一个不为空
class LyricTransitionTile extends StatelessWidget {
  final LrcLine? lrcLine;
  final SyncLyricLine? syncLine;
  const LyricTransitionTile({super.key, this.lrcLine, this.syncLine});

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
            LyricTransitionTileController(lrcLine, syncLine),
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
