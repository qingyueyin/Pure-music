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
import 'package:pure_music/page/now_playing_page/component/value_transition.dart';
import 'package:pure_music/play_service/play_service.dart';

// ===== 全局共享的 ImageFilter 池 =====
// 避免每个 Widget 都创建相同 sigma 的 ImageFilter
final Map<double, ImageFilter> _sharedBlurFilters = {};

ImageFilter _getSharedBlurFilter(double sigma) {
  // 四舍五入到 0.1 精度，避免浮点误差
  final key = (sigma * 10).round() / 10.0;
  return _sharedBlurFilters.putIfAbsent(key, () {
    return ImageFilter.blur(
      sigmaX: key,
      sigmaY: key,
      tileMode: TileMode.clamp,
    );
  });
}

void clearBlurFilterPool() {
  _sharedBlurFilters.clear();
}
// ===== 全局共享池结束 =====

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
  late final ValueTransition<double> _offsetYTransition;
  late final ValueTransition<double> _scaleTransition;
  late final ValueTransition<double> _opacityTransition;
  late final LyricRenderConfig _config;
  Ticker? _ticker;
  double _currentTimeMs = 0;

  // 缓存 Painter，避免每帧重建（ImageFilter 使用全局共享池）
  LyricsLinePainter? _cachedPainter;

  @override
  bool get wantKeepAlive {
    // 只保留当前行附近的 Widget（前后各 2 行），远离的可以销毁以节省内存
    final dist = (widget.distance ?? 999).abs();
    final shouldKeep = dist <= 2;

    // 如果从 keepAlive 变为不 keepAlive，主动清理缓存
    if (!shouldKeep) {
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
    if (active && _ticker == null) {
      _ticker = createTicker(_onTick);
      _ticker!.start();
    } else if (!active && _ticker != null) {
      _ticker!.stop();
    }
  }

  double _targetScale() {
    final active = widget.distance == 0;
    if (active) {
      return _config.mainLineScale * _config.activeLineScaleMultiplier;
    }
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
    final wasActive = oldWidget.distance == 0;

    // 只在活动状态变化时处理 Ticker，避免频繁创建销毁
    if (isActive != wasActive) {
      if (isActive && _ticker == null) {
        _ticker = createTicker(_onTick);
        _ticker!.start();
      } else if (!isActive && _ticker != null) {
        _ticker!.stop();
      }

      // 非当前行时清空缓存，释放内存
      if (!isActive) {
        _cachedPainter = null;
      }
    }

    // 行内容变化时清空缓存
    if (widget.line != oldWidget.line) {
      _cachedPainter = null;
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    // Painter 缓存清空，ImageFilter 使用全局共享池
    _cachedPainter = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 必需

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

    final effectiveOpacity = widget.isHovered ? 1.0 : _opacityTransition.value;

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
      const double outerHorizontalPad = 12.0;
      const double innerHorizontalPad = 12.0;

      final transitionContent = SizedBox(
        height: 40.0,
        child: widget.line is SyncLyricLine
            ? LyricTransitionTile(
                key: ValueKey(widget.line),
                syncLine: widget.line as SyncLyricLine,
                alignment: renderConfig.textAlign,
                useMaterialYouColor:
                    AppSettings.instance.useMaterialYouForTransition,
              )
            : LyricTransitionTile(
                key: ValueKey(widget.line),
                lrcLine: widget.line as LrcLine,
                alignment: renderConfig.textAlign,
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
              alignment: switch (renderConfig.textAlign) {
                LyricTextAlign.left => Alignment.centerLeft,
                LyricTextAlign.center => Alignment.center,
                LyricTextAlign.right => Alignment.centerRight,
              },
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

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final theme = Theme.of(context);
            final fontFamily = theme.textTheme.bodyMedium?.fontFamily ??
                theme.textTheme.bodySmall?.fontFamily;

            final lineWidth = constraints.maxWidth;

            // 复用或创建 painter，利用 shouldRepaint 优化
            if (_cachedPainter == null ||
                _cachedPainter!.line != widget.line ||
                _cachedPainter!.currentTimeMs != _currentTimeMs ||
                _cachedPainter!.opacity != effectiveOpacity ||
                _cachedPainter!.blurSigma != blurSigma ||
                _cachedPainter!.scale != _scaleTransition.value ||
                _cachedPainter!.offsetY != _offsetYTransition.value ||
                _cachedPainter!.config != renderConfig ||
                _cachedPainter!.isMainLine != active ||
                _cachedPainter!.useMaterialYouColor != AppSettings.instance.useMaterialYouForLyrics ||
                _cachedPainter!.fontFamily != fontFamily ||
                _cachedPainter!.agent != (widget.line is SyncLyricLine ? (widget.line as SyncLyricLine).agent : null)) {
              _cachedPainter = LyricsLinePainter(
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
                fontFamily: fontFamily,
                agent: widget.line is SyncLyricLine ? (widget.line as SyncLyricLine).agent : null,
              );
            }

            final lineHeight = _cachedPainter!.measureHeight(lineWidth);

            Widget painted = CustomPaint(
              painter: _cachedPainter,
              size: Size(lineWidth, lineHeight),
            );

            // 模糊：使用全局共享的 ImageFilter 池
            if (blurSigma > 0.01) {
              painted = ImageFiltered(
                imageFilter: _getSharedBlurFilter(blurSigma),
                child: painted,
              );
            }

            painted = SizedBox(
              height: lineHeight,
              child: painted,
            );

            // 悬停背景高亮，匹配 Widget 路径的 InkWell
            if (widget.isHovered && widget.onTap != null) {
              painted = Container(
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12.0),
                ),
                child: painted,
              );
            }

            painted = GestureDetector(
              onTap: widget.onTap,
              child: painted,
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
