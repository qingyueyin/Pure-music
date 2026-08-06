import 'package:pure_player_lyric/component/foreground.dart';
import 'package:pure_player_lyric/component/lyric_transition_dots.dart';
import 'package:pure_player_lyric/component/word_lyric_text.dart';
import 'package:pure_player_lyric/message.dart';
import 'package:pure_player_lyric/desktop_lyric_controller.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

const _lyricSwitchDuration = Duration(milliseconds: 700);
const _lyricSwitchCurve = Cubic(0.25, 0, 0.2, 1);
const _verticalTravel = 18.0;
const _horizontalTravel = 28.0;
const _absorbScaleDelta = 0.04;

class LyricLineDisplayArea extends StatelessWidget {
  const LyricLineDisplayArea({super.key});

  @override
  Widget build(BuildContext context) {
    final textDisplayController = context.watch<TextDisplayController>();
    final theme = context.watch<ThemeChangedMessage>();

    final playedColor = textDisplayController.hasSpecifiedPlayedColor
        ? textDisplayController.playedColor
        : Color(theme.primary).withValues(alpha: 1.0);
    final unplayedColor = textDisplayController.hasSpecifiedUnplayedColor
        ? textDisplayController.unplayedColor
        : playedColor;
    final outlineColor = lyricOutlineColor(
      textDisplayController.useLightOutline,
    );
    final textAlign = switch (textDisplayController.lyricTextAlign) {
      LyricTextAlign.left => TextAlign.left,
      LyricTextAlign.center => TextAlign.center,
      LyricTextAlign.right => TextAlign.right,
    };
    final crossAxisAlignment = switch (textDisplayController.lyricTextAlign) {
      LyricTextAlign.left => CrossAxisAlignment.start,
      LyricTextAlign.center => CrossAxisAlignment.center,
      LyricTextAlign.right => CrossAxisAlignment.end,
    };
    final switchAlignment = switch (textDisplayController.lyricTextAlign) {
      LyricTextAlign.left => Alignment.centerLeft,
      LyricTextAlign.center => Alignment.center,
      LyricTextAlign.right => Alignment.centerRight,
    };

    return ValueListenableBuilder(
      valueListenable: DesktopLyricController.instance.lyricLine,
      builder: (context, lyricLine, _) {
        final lyricProgress = DesktopLyricController.instance.progressForLine(
          lyricLine.lineId,
        );
        final style = TextStyle(
          color: playedColor,
          fontSize: textDisplayController.lyricFontSize,
          fontWeight: lyricFontWeightFromInt(
            textDisplayController.lyricFontWeight,
          ),
        );
        final hasWords = lyricLine.words?.isNotEmpty ?? false;
        final isTransition =
            lyricLine.content.trim().isEmpty &&
            !hasWords &&
            lyricLine.length > const Duration(seconds: 3);

        final childKey = ValueKey<Object>(
          lyricLine.lineId ??
              (isTransition
                  ? "TRANSITION_${lyricLine.length.inMilliseconds}"
                  : "${lyricLine.content}|${lyricLine.translation}|${lyricLine.romanLyric}"),
        );

        final hasRoman =
            !isTransition &&
            textDisplayController.showRoman &&
            lyricLine.romanLyric != null;
        final hasTranslation =
            !isTransition &&
            textDisplayController.showLyricTranslation &&
            lyricLine.translation != null;

        Widget? romanWidget;
        if (hasRoman) {
          romanWidget = outlinedText(
            text: lyricLine.romanLyric!,
            style: TextStyle(
              color: playedColor,
              fontSize: textDisplayController.translationFontSize,
              fontWeight: lyricFontWeightFromInt(
                textDisplayController.lyricFontWeight,
              ),
            ),
            outlineColor: outlineColor,
            outlineWidth: lyricOutlineWidth(
              textDisplayController.translationFontSize,
            ),
            maxLines: 1,
            overflow: TextOverflow.clip,
            textAlign: textAlign,
            softWrap: false,
            enableOutline: textDisplayController.enableStroke,
          );
        }

        Widget? translationWidget;
        if (hasTranslation) {
          translationWidget = outlinedText(
            text: lyricLine.translation!,
            style: TextStyle(
              color: playedColor,
              fontSize: textDisplayController.translationFontSize,
              fontWeight: lyricFontWeightFromInt(
                textDisplayController.lyricFontWeight,
              ),
            ),
            outlineColor: outlineColor,
            outlineWidth: lyricOutlineWidth(
              textDisplayController.translationFontSize,
            ),
            maxLines: 1,
            overflow: TextOverflow.clip,
            textAlign: textAlign,
            softWrap: false,
            enableOutline: textDisplayController.enableStroke,
          );
        }

        final children = <Widget>[
          if (isTransition)
            LyricTransitionDots(
              length: lyricLine.length,
              progress: lyricProgress,
              color: playedColor,
              isPlaying: DesktopLyricController.instance.isPlaying,
              lineId: lyricLine.lineId,
            )
          else ...[
            if (hasRoman &&
                textDisplayController.romanPosition == RomanPosition.aboveText)
              romanWidget!,
            if (lyricLine.isWordByWord && hasWords)
              WordLyricText(
                line: lyricLine,
                color: unplayedColor,
                playedColor: playedColor,
                fontSize: textDisplayController.lyricFontSize,
                fontWeight: textDisplayController.lyricFontWeight,
                textAlign: textAlign,
                isPlaying: DesktopLyricController.instance.isPlaying,
                progress: lyricProgress,
                enableOutline: textDisplayController.enableStroke,
                outlineColor: outlineColor,
              )
            else
              outlinedText(
                text: lyricLine.content,
                style: style,
                outlineColor: outlineColor,
                outlineWidth: lyricOutlineWidth(
                  textDisplayController.lyricFontSize,
                ),
                maxLines: 1,
                overflow: TextOverflow.clip,
                textAlign: textAlign,
                softWrap: false,
                enableOutline: textDisplayController.enableStroke,
              ),
            if (hasRoman &&
                textDisplayController.romanPosition == RomanPosition.between)
              romanWidget!,
            if (hasTranslation) translationWidget!,
            if (hasRoman &&
                textDisplayController.romanPosition ==
                    RomanPosition.belowTranslation)
              romanWidget!,
          ],
        ];

        final child = Column(
          key: childKey,
          crossAxisAlignment: crossAxisAlignment,
          children: children,
        );

        return _LyricLineTransition(
          animation: textDisplayController.lyricAnimation,
          alignment: switchAlignment,
          child: child,
        );
      },
    );
  }
}

class _LyricLineTransition extends StatefulWidget {
  const _LyricLineTransition({
    required this.animation,
    required this.alignment,
    required this.child,
  });

  final LyricSwitchAnimation animation;
  final Alignment alignment;
  final Widget child;

  @override
  State<_LyricLineTransition> createState() => _LyricLineTransitionState();
}

class _LyricLineTransitionState extends State<_LyricLineTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Widget _currentChild;
  Widget? _previousChild;

  @override
  void initState() {
    super.initState();
    _currentChild = widget.child;
    _controller =
        AnimationController(vsync: this, duration: _lyricSwitchDuration)
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed && mounted) {
              setState(() => _previousChild = null);
            }
          });
  }

  @override
  void didUpdateWidget(covariant _LyricLineTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_currentChild.key == widget.child.key) {
      _currentChild = widget.child;
      return;
    }
    _previousChild = _currentChild;
    _currentChild = widget.child;
    _controller.forward(from: 0);
  }

  Widget _buildLayer(
    Widget child,
    double motion,
    double fade, {
    required bool isPrevious,
  }) {
    final opacity = isPrevious ? 1.0 - fade : fade;
    switch (widget.animation) {
      case LyricSwitchAnimation.slideUp:
        return Transform.translate(
          offset: Offset(
            0,
            isPrevious
                ? -motion * _verticalTravel
                : (1.0 - motion) * _verticalTravel,
          ),
          child: Opacity(opacity: opacity, child: child),
        );
      case LyricSwitchAnimation.slideDown:
        return Transform.translate(
          offset: Offset(
            0,
            isPrevious
                ? motion * _verticalTravel
                : (motion - 1.0) * _verticalTravel,
          ),
          child: Opacity(opacity: opacity, child: child),
        );
      case LyricSwitchAnimation.fade:
        return Opacity(opacity: opacity, child: child);
      case LyricSwitchAnimation.absorb:
        final scale = isPrevious
            ? 1.0 - motion * _absorbScaleDelta
            : 1.0 - (1.0 - motion) * _absorbScaleDelta;
        return Transform.scale(
          alignment: widget.alignment,
          scale: scale,
          child: Opacity(opacity: opacity, child: child),
        );
      case LyricSwitchAnimation.slideLeft:
        return Transform.translate(
          offset: Offset(
            isPrevious
                ? -motion * _horizontalTravel
                : (1.0 - motion) * _horizontalTravel,
            0,
          ),
          child: Opacity(opacity: opacity, child: child),
        );
      case LyricSwitchAnimation.slideRight:
        return Transform.translate(
          offset: Offset(
            isPrevious
                ? motion * _horizontalTravel
                : (motion - 1.0) * _horizontalTravel,
            0,
          ),
          child: Opacity(opacity: opacity, child: child),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final previousChild = _previousChild;
    return ClipRect(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          if (previousChild == null) {
            return Stack(
              alignment: widget.alignment,
              children: [_currentChild],
            );
          }
          final motion = _lyricSwitchCurve.transform(_controller.value);
          final fade = Curves.easeInOutSine.transform(_controller.value);
          return Stack(
            alignment: widget.alignment,
            children: [
              _buildLayer(previousChild, motion, fade, isPrevious: true),
              _buildLayer(_currentChild, motion, fade, isPrevious: false),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
