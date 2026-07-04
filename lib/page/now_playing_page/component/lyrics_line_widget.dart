import 'dart:ui' show ImageFilter;

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
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late final LyricRenderConfig _config;
  Ticker? _ticker;
  double _currentTimeMs = 0;

  // 缓存 Painter，避免每帧重建
  LyricsLinePainter? _cachedPainter;

  @override
  bool get wantKeepAlive {
    // 只保留当前行附近的 Widget（前后各 2 行），远离的可以销毁以节省内存
    final dist = (widget.distance ?? 999).abs();
    final shouldKeep = dist <= 2;

    // 如果从 keepAlive 变为不 keepAlive，主动清理缓存
      if (!shouldKeep && _cachedPainter != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _cachedPainter = null;
        }
      });
    }

    return shouldKeep;
  }

  @override
  void initState() {
    super.initState();
    _config = context.read<LyricViewController>().renderConfig;
    _initTicker();
  }

  void _initTicker() {
    if (widget.distance == 0 && _ticker == null) {
      _ticker = createTicker(_onTick);
      _ticker!.start();
    }
  }

  double _targetOpacity() {
    final dist = (widget.distance ?? 0).abs();
    if (dist == 0) return 1.0;
    return (widget.opacity).clamp(0.0, 1.0);
  }

  void _onTick(Duration elapsed) {
    final newTimeMs = PlayService.instance.playbackService.position * 1000.0;
    // 只在时间变化超过 16ms（约 1 帧）时才更新，避免无意义的重建
    if ((newTimeMs - _currentTimeMs).abs() >= 16.0) {
      _currentTimeMs = newTimeMs;
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant LyricsLineWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    final isActive = widget.distance == 0;
    final wasActive = oldWidget.distance == 0;

    if (isActive != wasActive) {
      if (isActive) {
        (_ticker ??= createTicker(_onTick)).start();
      } else {
        _ticker?.stop();
      }

      if (!isActive) {
        _cachedPainter = null;
      }
    }

    if (widget.line != oldWidget.line) {
      _cachedPainter = null;
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _cachedPainter = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 必需

    final dist = (widget.distance ?? 0).abs();
    final active = widget.distance == 0;

    final renderConfig = context.watch<LyricViewController>().renderConfig;

    final effectiveTextAlign = renderConfig.hasMultipleAgents && widget.line is SyncLyricLine
        ? switch ((widget.line as SyncLyricLine).agent) {
            'v2' => LyricTextAlign.right,
            'v1' => LyricTextAlign.left,
            _ => renderConfig.textAlign,
          }
        : renderConfig.textAlign;

    final scaleAlignment = switch (effectiveTextAlign) {
      LyricTextAlign.left => Alignment.centerLeft,
      LyricTextAlign.center => Alignment.center,
      LyricTextAlign.right => Alignment.centerRight,
    };
    final scheme = Theme.of(context).colorScheme;
    final blurSigma = widget.isUserScrolling
        ? 0.0
        : (active ? 0.0 : renderConfig.blurSigmaForDistance(dist));

    final isTransitionLine = _isTransitionLine(widget.line, active);
    if (isTransitionLine) {
      // 匹配 Widget 模式：短空白行在非主行时完全隐藏
      if (!active) {
        return const SizedBox.shrink();
      }

      final verticalPad = widget.line is SyncLyricLine
          ? renderConfig.syncVerticalPadding(isMainLine: true)
          : renderConfig.lrcVerticalPadding();

      // 普通歌词遮罩在外层 12px padding 内，painter 内容再内缩 12px；间奏行保持同样结构。
      const double outerHorizontalPad = transitionTileMargin;
      const double innerHorizontalPad = transitionTileMargin;

      final transitionContent = SizedBox(
        height: transitionTileHeight,
        child: widget.line is SyncLyricLine
            ? LyricTransitionTile(
                key: ValueKey(widget.line),
                syncLine: widget.line as SyncLyricLine,
                alignment: effectiveTextAlign,
                useMaterialYouColor:
                    AppSettings.instance.useMaterialYouForTransition,
              )
            : LyricTransitionTile(
                key: ValueKey(widget.line),
                lrcLine: widget.line as LrcLine,
                alignment: effectiveTextAlign,
                useMaterialYouColor:
                    AppSettings.instance.useMaterialYouForTransition,
              ),
      );

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: outerHorizontalPad),
        child: _LocalHoverMask(
          onTap: widget.onTap,
          color: scheme.onSurface.withValues(alpha: 0.08),
          child: Padding(
            padding: EdgeInsets.only(
                left: innerHorizontalPad,
                right: innerHorizontalPad,
                top: verticalPad,
                bottom: verticalPad),
            child: Align(
              alignment: scaleAlignment,
              child: transitionContent,
            ),
          ),
        ),
      );
    }

    // 匹配 Widget 模式：短空白行直接隐藏
    final isShortBlank = widget.line is SyncLyricLine
        ? (widget.line as SyncLyricLine).words.isEmpty
        : widget.line is LrcLine && (widget.line as LrcLine).isBlank;
    if (isShortBlank) {
      return const SizedBox.shrink();
    }

    Widget inner = LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final fontFamily = theme.textTheme.bodyMedium?.fontFamily ??
            theme.textTheme.bodySmall?.fontFamily;

        final lineWidth = constraints.maxWidth;

        if (_cachedPainter == null ||
            _cachedPainter!.line != widget.line ||
            _cachedPainter!.currentTimeMs != _currentTimeMs ||
            _cachedPainter!.blurSigma != blurSigma ||
            _cachedPainter!.config != renderConfig ||
            _cachedPainter!.isMainLine != active ||
            _cachedPainter!.useMaterialYouColor != AppSettings.instance.useMaterialYouForLyrics ||
            _cachedPainter!.fontFamily != fontFamily ||
            _cachedPainter!.agent != (widget.line is SyncLyricLine ? (widget.line as SyncLyricLine).agent : null)) {
          _cachedPainter = LyricsLinePainter(
            line: widget.line,
            currentTimeMs: _currentTimeMs,
            blurSigma: blurSigma,
            config: renderConfig,
            scheme: scheme,
            isMainLine: active,
            useMaterialYouColor: AppSettings.instance.useMaterialYouForLyrics,
            fontFamily: fontFamily,
            agent: widget.line is SyncLyricLine ? (widget.line as SyncLyricLine).agent : null,
          );
        }

        final lineHeight = _cachedPainter!.measureHeight(lineWidth);

        Widget painted = CustomPaint(
          painter: _cachedPainter,
          size: Size(lineWidth, lineHeight),
        );

        painted = TweenAnimationBuilder<double>(
          tween: Tween(begin: blurSigma, end: blurSigma),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          builder: (context, sigma, child) {
            if (sigma > 0.01) {
              return ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: sigma,
                  sigmaY: sigma,
                  tileMode: TileMode.clamp,
                ),
                child: child!,
              );
            }
            return child!;
          },
          child: painted,
        );

        painted = SizedBox(
          height: lineHeight,
          child: painted,
        );

        return painted;
      },
    );

    // AnimatedScale/Opacity 在外层，确保 setState 时 didUpdateWidget 被调用
    inner = AnimatedScale(
      scale: active
          ? _config.mainLineScale * _config.activeLineScaleMultiplier
          : _config.subLineScale * _config.inactiveLineScaleMultiplier,
      alignment: scaleAlignment,
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      child: inner,
    );

    inner = AnimatedOpacity(
      opacity: widget.isHovered ? 1.0 : _targetOpacity(),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      child: inner,
    );

    if (widget.isHovered && widget.onTap != null) {
      inner = Container(
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12.0),
        ),
        child: inner,
      );
    }

    inner = GestureDetector(
      onTap: widget.onTap,
      child: inner,
    );

    if (widget.onHoverChanged != null) {
      inner = MouseRegion(
        onEnter: (_) => widget.onHoverChanged!(true),
        onExit: (_) => widget.onHoverChanged!(false),
        child: inner,
      );
    }

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: transitionTileMargin),
        child: inner,
      ),
    );
  }

  bool _isTransitionLine(LyricLine line, bool isMainLine) {
    if (!isMainLine) return false;
    if (line is SyncLyricLine) {
      return line.words.isEmpty && line.length > const Duration(seconds: 3);
    } else if (line is LrcLine) {
      return line.isBlank &&
          line.length > const Duration(seconds: 3) &&
          line.start == Duration.zero;
    }
    return false;
  }
}

class _LocalHoverMask extends StatefulWidget {
  const _LocalHoverMask({
    required this.child,
    required this.color,
    this.onTap,
  });

  final Widget child;
  final Color color;
  final VoidCallback? onTap;

  @override
  State<_LocalHoverMask> createState() => _LocalHoverMaskState();
}

class _LocalHoverMaskState extends State<_LocalHoverMask> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: _hovered && widget.onTap != null ? widget.color : null,
            borderRadius: BorderRadius.circular(12.0),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
