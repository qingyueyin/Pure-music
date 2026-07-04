import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/physics.dart';
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
  final VoidCallback? onTap;

  @override
  State<LyricsLineWidget> createState() => _LyricsLineWidgetState();
}

class _LyricsLineWidgetState extends State<LyricsLineWidget>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  static const int _blurFilterCacheMaxSize = 20;
  // Dart 的 Map 按插入顺序维护，remove 后重新插入即可实现 LRU
  static final Map<double, ImageFilter> _blurFilterCache = {};

  static double _roundSigma(double sigma) {
    return (sigma * 2).roundToDouble() / 2;
  }

  static ImageFilter _getBlurFilter(double sigma) {
    final key = _roundSigma(sigma);
    final cached = _blurFilterCache[key];
    if (cached != null) {
      // 移到末尾标记为最近使用
      _blurFilterCache.remove(key);
      _blurFilterCache[key] = cached;
      return cached;
    }
    if (_blurFilterCache.length >= _blurFilterCacheMaxSize) {
      _blurFilterCache.remove(_blurFilterCache.keys.first);
    }
    return _blurFilterCache[key] = ImageFilter.blur(
      sigmaX: key,
      sigmaY: key,
      tileMode: TileMode.clamp,
    );
  }

  late final LyricRenderConfig _config;
  Ticker? _ticker;
  double _currentTimeMs = 0;

  /// seek 后用于过滤旧进度回调的临时目标
  double? _pendingSeekMs;
  DateTime? _pendingSeekAt;
  static const _seekGuardWindowMs = 200;

  late final AnimationController _scaleController;
  late final AnimationController _floatController;

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
    _scaleController = AnimationController.unbounded(vsync: this);
    _scaleController.value = widget.distance == 0
        ? _config.mainLineScale * _config.activeLineScaleMultiplier
        : _config.subLineScale * _config.inactiveLineScaleMultiplier;
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _floatController.value = widget.distance == 0 ? 1.0 : 0.0;
    _initTicker();
  }

  void _animateScale() {
    final target = widget.distance == 0
        ? _config.mainLineScale * _config.activeLineScaleMultiplier
        : _config.subLineScale * _config.inactiveLineScaleMultiplier;
    final simulation = SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 100, damping: 17),
      _scaleController.value,
      target,
      0,
    );
    _scaleController.animateWith(simulation);
  }

  void _animateFloat() {
    final target = widget.distance == 0 ? 1.0 : 0.0;
    if ((_floatController.value - target).abs() < 0.001) return;
    _floatController.animateTo(
      target,
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
    );
  }

  void _initTicker() {
    if (widget.distance == 0 && _ticker == null) {
      final rawMs = PlayService.instance.playbackService.position * 1000.0;
      _currentTimeMs = rawMs;
      _pendingSeekMs = null;
      _pendingSeekAt = null;
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
    final rawMs = PlayService.instance.playbackService.position * 1000.0;
    final delta = rawMs - _currentTimeMs;

    // seek 保护：大幅跳转后的短窗口内，忽略与跳转方向相反的旧进度回调
    if (_pendingSeekMs != null && _pendingSeekAt != null) {
      final age = DateTime.now().difference(_pendingSeekAt!).inMilliseconds;
      if (age > _seekGuardWindowMs || (rawMs - _pendingSeekMs!).abs() <= 50) {
        _pendingSeekMs = null;
        _pendingSeekAt = null;
      } else if ((rawMs > _currentTimeMs) !=
          (_pendingSeekMs! > _currentTimeMs)) {
        // 方向相反，跳过本次回调
        setState(() {});
        return;
      }
    }

    if (delta.abs() >= 100) {
      // Seek 或大幅跳转：记录目标并直接同步
      _pendingSeekMs = rawMs;
      _pendingSeekAt = DateTime.now();
      _currentTimeMs = rawMs;
    } else if (delta > 0) {
      // 播放中：直接同步 raw，避免平滑滞后导致歌词末尾覆盖不全
      _currentTimeMs = rawMs;
    } else if (delta < -32) {
      // 暂停或倒带：回退到 raw
      _currentTimeMs = rawMs;
    }

    setState(() {});
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

      _animateScale();
      _animateFloat();

      if (!isActive) {
        _cachedPainter = null;
      }
    }

    if (widget.line != oldWidget.line) {
      _cachedPainter = null;
      _pendingSeekMs = null;
      _pendingSeekAt = null;
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _scaleController.dispose();
    _floatController.dispose();
    _cachedPainter = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 必需

    final dist = (widget.distance ?? 0).abs();
    final isCurrentLine = widget.distance == 0;

    final renderConfig = context.watch<LyricViewController>().renderConfig;

    final effectiveTextAlign =
        renderConfig.hasMultipleAgents && widget.line is SyncLyricLine
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
        : (isCurrentLine ? 0.0 : renderConfig.blurSigmaForDistance(dist));

    final isTransitionLine = _isTransitionLine(widget.line, isCurrentLine);
    if (isTransitionLine) {
      if (!isCurrentLine) {
        return const SizedBox.shrink();
      }

      final verticalPad = widget.line is SyncLyricLine
          ? renderConfig.syncVerticalPadding(isMainLine: true)
          : renderConfig.lrcVerticalPadding();

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
        padding: const EdgeInsets.symmetric(horizontal: transitionTileMargin),
        child: _LocalHoverMask(
          onTap: widget.onTap,
          color: scheme.onSurface.withValues(alpha: 0.08),
          child: Padding(
            padding: EdgeInsets.only(
                left: transitionTileMargin,
                right: transitionTileMargin,
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
            _cachedPainter!.isMainLine != isCurrentLine ||
            _cachedPainter!.useMaterialYouColor !=
                AppSettings.instance.useMaterialYouForLyrics ||
            _cachedPainter!.fontFamily != fontFamily ||
            _cachedPainter!.agent !=
                (widget.line is SyncLyricLine
                    ? (widget.line as SyncLyricLine).agent
                    : null)) {
          _cachedPainter = LyricsLinePainter(
            line: widget.line,
            currentTimeMs: _currentTimeMs,
            blurSigma: blurSigma,
            config: renderConfig,
            scheme: scheme,
            isMainLine: isCurrentLine,
            useMaterialYouColor: AppSettings.instance.useMaterialYouForLyrics,
            fontFamily: fontFamily,
            agent: widget.line is SyncLyricLine
                ? (widget.line as SyncLyricLine).agent
                : null,
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
                imageFilter: _getBlurFilter(sigma),
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

    inner = AnimatedBuilder(
      animation: _scaleController,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleController.value,
          alignment: scaleAlignment,
          child: child!,
        );
      },
      child: inner,
    );

    inner = AnimatedBuilder(
      animation: _floatController,
      builder: (context, child) {
        final offsetY = _floatController.value * -4.0;
        return Transform.translate(
          offset: Offset(0, offsetY),
          child: child!,
        );
      },
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
