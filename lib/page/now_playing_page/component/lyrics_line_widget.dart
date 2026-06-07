import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_tile.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';
import 'package:pure_music/page/now_playing_page/component/value_transition.dart';
import 'package:pure_music/play_service/play_service.dart';

class LyricsLineWidget extends StatefulWidget {
  const LyricsLineWidget({
    super.key,
    required this.line,
    required this.opacity,
    this.distance,
    this.lineOffsetY = 0.0,
    this.staggerDelay = Duration.zero,
    this.isUserScrolling = false,
    this.isHovered = false,
    this.onHoverChanged,
    this.onTap,
  });

  final LyricLine line;
  final double opacity;
  final int? distance;
  final double lineOffsetY;
  final Duration staggerDelay;
  final bool isUserScrolling;
  final bool isHovered;
  final void Function(bool)? onHoverChanged;
  final void Function()? onTap;

  @override
  State<LyricsLineWidget> createState() => _LyricsLineWidgetState();
}

class _LyricsLineWidgetState extends State<LyricsLineWidget>
    with SingleTickerProviderStateMixin {
  late final ValueTransition<double> _offsetYTransition;
  late final ValueTransition<double> _scaleTransition;
  late final ValueTransition<double> _opacityTransition;
  late final LyricRenderConfig _config;
  Ticker? _ticker;
  double _currentTimeMs = 0;

  @override
  void initState() {
    super.initState();
    _config = context.read<LyricViewController>().renderConfig;

    _offsetYTransition = ValueTransition<double>(
      begin: widget.lineOffsetY,
      interpolator: (t, begin, end) => begin + (end - begin) * _easeOutCubic(t),
      duration: const Duration(milliseconds: 380),
    );

    _scaleTransition = ValueTransition<double>(
      begin: _targetScale(),
      interpolator: _lerpInterpolator,
      duration: _config.implicitAnimationDuration,
    );

    _opacityTransition = ValueTransition<double>(
      begin: widget.opacity,
      interpolator: _lerpInterpolator,
      duration: _config.implicitAnimationDuration,
    );

    _initTicker();
  }

  void _initTicker() {
    final active = widget.distance == 0;
    if (active) {
      _ticker = createTicker(_onTick);
      _ticker!.start();
    }
  }

  double _targetScale() {
    final active = widget.distance == 0;
    if (active) return _config.mainLineScale * _config.activeLineScaleMultiplier;
    return _config.subLineScale * _config.inactiveLineScaleMultiplier;
  }

  double _targetOpacity() {
    final dist = (widget.distance ?? 0).abs();
    if (dist == 0) return 1.0;
    return (widget.opacity).clamp(0.0, 1.0);
  }

  double _easeOutCubic(double t) {
    return 1 - (1 - t) * (1 - t) * (1 - t);
  }

  double _lerpInterpolator(double t, double begin, double end) {
    return begin + (end - begin) * t;
  }

  void _onTick(Duration elapsed) {
    _currentTimeMs =
        PlayService.instance.playbackService.position * 1000.0;
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant LyricsLineWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.lineOffsetY != oldWidget.lineOffsetY) {
      _offsetYTransition.start(widget.lineOffsetY);
    }
    if (widget.opacity != oldWidget.opacity) {
      _opacityTransition.start(_targetOpacity());
    }
    if (widget.distance != oldWidget.distance) {
      _scaleTransition.start(_targetScale());
    }

    final isActive = widget.distance == 0;
    if (isActive && _ticker == null) {
      _initTicker();
    } else if (!isActive && _ticker != null) {
      _ticker!.dispose();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dist = (widget.distance ?? 0).abs();
    final active = widget.distance == 0;
    if (dist == 0 && !_offsetYTransition.isActive) {
      _offsetYTransition.jumpTo(widget.lineOffsetY);
    }
    if (!_opacityTransition.isActive) {
      _opacityTransition.jumpTo(_targetOpacity());
    }
    if (!_scaleTransition.isActive) {
      _scaleTransition.jumpTo(_targetScale());
    }

    final renderConfig = context.watch<LyricViewController>().renderConfig;
    final scheme = Theme.of(context).colorScheme;
    final blurSigma = widget.isUserScrolling
        ? 0.0
        : (active ? 0.0 : renderConfig.blurSigmaForDistance(dist));

    final effectiveOpacity = widget.isHovered
        ? 1.0
        : _opacityTransition.value;

    final isTransitionLine = _isTransitionLine(widget.line, active);
    if (isTransitionLine) {
      return GestureDetector(
        onTap: widget.onTap,
        child: Align(
          alignment: switch (renderConfig.textAlign) {
            LyricTextAlign.left => Alignment.centerLeft,
            LyricTextAlign.center => Alignment.center,
            LyricTextAlign.right => Alignment.centerRight,
          },
          child: SizedBox(
            height: 40.0,
            child: widget.line is SyncLyricLine
                ? LyricTransitionTile(
                    syncLine: widget.line as SyncLyricLine,
                    useMaterialYouColor: AppSettings.instance.useMaterialYouForTransition,
                  )
                : LyricTransitionTile(
                    lrcLine: widget.line as LrcLine,
                    useMaterialYouColor: AppSettings.instance.useMaterialYouForTransition,
                  ),
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final lineWidth = constraints.maxWidth;
          final lineHeight = LyricsLinePainter(
            line: widget.line,
            currentTimeMs: _currentTimeMs,
            opacity: effectiveOpacity,
            blurSigma: blurSigma,
            scale: _scaleTransition.value,
            offsetY: _offsetYTransition.value,
            config: renderConfig,
            scheme: scheme,
            isMainLine: active,
            useMaterialYouColor: AppSettings.instance.useMaterialYouForLyrics,
          ).measureHeight(lineWidth);

          Widget painted = GestureDetector(
            onTap: widget.onTap,
            child: SizedBox(
              height: lineHeight,
              child: CustomPaint(
                painter: LyricsLinePainter(
                  line: widget.line,
                  currentTimeMs: _currentTimeMs,
                  opacity: effectiveOpacity,
                  blurSigma: blurSigma,
                  scale: _scaleTransition.value,
                  offsetY: _offsetYTransition.value,
                  config: renderConfig,
                  scheme: scheme,
                  isMainLine: active,
                  useMaterialYouColor: AppSettings.instance.useMaterialYouForLyrics,
                ),
                size: Size(lineWidth, lineHeight),
              ),
            ),
          );

          if (widget.onHoverChanged != null) {
            painted = MouseRegion(
              onEnter: (_) => widget.onHoverChanged!(true),
              onExit: (_) => widget.onHoverChanged!(false),
              child: painted,
            );
          }

          return painted;
        },
      ),
    );
  }

  bool _isTransitionLine(LyricLine line, bool isMainLine) {
    if (!isMainLine) return false;
    if (line is SyncLyricLine) {
      return line.words.isEmpty && line.length > const Duration(seconds: 3);
    } else if (line is LrcLine) {
      return line.isBlank && line.length > const Duration(seconds: 3);
    }
    return false;
  }
}