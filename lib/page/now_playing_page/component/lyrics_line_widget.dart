import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/physics.dart';
import 'package:provider/provider.dart';

import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/native/bass/bass_player.dart';
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

  /// 保留给内存监控调用；歌词模糊已改为 painter 内绘制。
  static void clearBlurFilterCache() {}

  @override
  State<LyricsLineWidget> createState() => _LyricsLineWidgetState();
}

class _LyricsLineWidgetState extends State<LyricsLineWidget>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late final LyricRenderConfig _config;
  Ticker? _ticker;
  double _currentTimeMs = 0;
  final ValueNotifier<double> _currentTimeNotifier = ValueNotifier(0);
  late final VoidCallback _playerStateListener;
  Duration _lastTickElapsed = Duration.zero;
  Duration _lastNativeSyncElapsed = Duration.zero;

  /// seek 后用于过滤旧进度回调的临时目标
  double? _pendingSeekMs;
  DateTime? _pendingSeekAt;
  static const _seekGuardWindowMs = 200;
  static const _nativePositionSyncInterval = Duration(milliseconds: 250);

  late final AnimationController _scaleController;
  late final AnimationController _floatController;

  // 缓存 Painter，避免每帧重建
  LyricsLinePainter? _cachedPainter;
  double? _cachedLineHeight;
  double _cachedLineWidth = 0.0;
  LyricLine? _heightLine;
  LyricRenderConfig? _heightConfig;
  bool? _heightIsMainLine;
  bool? _heightUseMaterialYouColor;
  String? _heightFontFamily;
  String? _heightAgent;
  final ValueNotifier<double> _heightNotifier = ValueNotifier(0.0);
  double _lastBgHeightUpdateMs = -1e9;

  void _clearHeightCache() {
    _cachedLineHeight = null;
    _cachedLineWidth = 0.0;
    _heightLine = null;
    _heightConfig = null;
    _heightIsMainLine = null;
    _heightUseMaterialYouColor = null;
    _heightFontFamily = null;
    _heightAgent = null;
  }

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
          _clearHeightCache();
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
    _playerStateListener = _syncProgressTicker;
    PlayService.instance.playbackService.playerStateNotifier
        .addListener(_playerStateListener);
    _syncProgressTicker();
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

  bool get _needsProgressTicker =>
      widget.distance == 0 &&
      widget.line is SyncLyricLine &&
      (widget.line as SyncLyricLine).words.isNotEmpty;

  void _syncProgressTicker() {
    if (_needsProgressTicker) {
      _syncToNativePosition();
      _lastTickElapsed = Duration.zero;
      _lastNativeSyncElapsed = Duration.zero;
      _pendingSeekMs = null;
      _pendingSeekAt = null;
      final isPlaying = PlayService.instance.playbackService.playerState ==
          PlayerState.playing;
      if (!isPlaying) {
        _ticker?.stop();
        return;
      }
      final ticker = _ticker ??= createTicker(_onTick);
      if (!ticker.isActive) ticker.start();
    } else {
      _ticker?.stop();
    }
  }

  double _readNativePositionMs() {
    return PlayService.instance.playbackService.position * 1000.0;
  }

  void _syncToNativePosition() {
    _setCurrentTimeMs(_readNativePositionMs());
  }

  void _setCurrentTimeMs(double value) {
    _currentTimeMs = value;
    if (_currentTimeNotifier.value != value) {
      _currentTimeNotifier.value = value;
    }
  }

  double _targetOpacity() {
    final dist = (widget.distance ?? 0).abs();
    if (dist == 0) return 1.0;
    return (widget.opacity).clamp(0.0, 1.0);
  }

  void _onTick(Duration elapsed) {
    final elapsedDelta = _lastTickElapsed == Duration.zero
        ? Duration.zero
        : elapsed - _lastTickElapsed;
    _lastTickElapsed = elapsed;

    final shouldSyncNative = _lastNativeSyncElapsed == Duration.zero ||
        elapsed - _lastNativeSyncElapsed >= _nativePositionSyncInterval;
    final rawMs = shouldSyncNative
        ? _readNativePositionMs()
        : _currentTimeMs + elapsedDelta.inMicroseconds / 1000.0;
    if (shouldSyncNative) {
      _lastNativeSyncElapsed = elapsed;
    }

    final delta = rawMs - _currentTimeMs;
    var shouldRepaint = false;

    // seek 保护：大幅跳转后的短窗口内，忽略与跳转方向相反的旧进度回调
    if (_pendingSeekMs != null && _pendingSeekAt != null) {
      final age = DateTime.now().difference(_pendingSeekAt!).inMilliseconds;
      if (age > _seekGuardWindowMs || (rawMs - _pendingSeekMs!).abs() <= 50) {
        _pendingSeekMs = null;
        _pendingSeekAt = null;
      } else if ((rawMs > _currentTimeMs) !=
          (_pendingSeekMs! > _currentTimeMs)) {
        // 方向相反，跳过本次回调
        if (mounted) _currentTimeNotifier.value = _currentTimeMs;
        return;
      }
    }

    if (delta.abs() >= 100) {
      // Seek 或大幅跳转：记录目标并直接同步
      _pendingSeekMs = rawMs;
      _pendingSeekAt = DateTime.now();
      _setCurrentTimeMs(rawMs);
      shouldRepaint = true;
    } else if (delta > 0.5) {
      // 播放中：直接同步 raw，避免平滑滞后导致歌词末尾覆盖不全
      _setCurrentTimeMs(rawMs);
      shouldRepaint = true;
    } else if (delta < -32) {
      // 暂停或倒带：回退到 raw
      _setCurrentTimeMs(rawMs);
      shouldRepaint = true;
    }

    if (!shouldRepaint || !mounted) return;

    if (widget.line is SyncLyricLine) {
      final syncLine = widget.line as SyncLyricLine;
      if (syncLine.bg != null || (syncLine.bgText?.isNotEmpty == true)) {
        final bgStart = (syncLine.bgStart ?? syncLine.bg?.start ?? syncLine.start)
            .inMilliseconds
            .toDouble();
        final bgEnd = _bgEndMs(syncLine);
        if (_currentTimeMs >= bgStart - 100 && _currentTimeMs < bgEnd + 1500) {
          if ((_currentTimeMs - _lastBgHeightUpdateMs).abs() > 30) {
            _lastBgHeightUpdateMs = _currentTimeMs;
            if (_cachedPainter != null && _cachedLineWidth > 0) {
              _heightNotifier.value =
                  _cachedPainter!.measureHeight(_cachedLineWidth);
            }
          }
        }
      }
    }
  }

  double _bgEndMs(SyncLyricLine syncLine) {
    var end = (syncLine.bgEnd ??
            syncLine.bg?.end ??
            (syncLine.start + syncLine.length))
        .inMilliseconds
        .toDouble();
    if (syncLine.bgWords.isNotEmpty) {
      final last = syncLine.bgWords.last;
      final lastEnd =
          (last.start.inMilliseconds + last.length.inMilliseconds).toDouble();
      if (lastEnd > end) end = lastEnd;
    }
    return end;
  }

  @override
  void didUpdateWidget(covariant LyricsLineWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    final isActive = widget.distance == 0;
    final wasActive = oldWidget.distance == 0;

    if (isActive != wasActive || widget.line != oldWidget.line) {
      _syncProgressTicker();
    }

    if (isActive != wasActive) {
      _animateScale();
      _animateFloat();

      if (!isActive) {
        _cachedPainter = null;
        _clearHeightCache();
      }
    }

    final oldKeepAlive = (oldWidget.distance ?? 999).abs() <= 2;
    final newKeepAlive = (widget.distance ?? 999).abs() <= 2;
    if (oldKeepAlive != newKeepAlive) {
      updateKeepAlive();
    }

    if (widget.line != oldWidget.line) {
      _cachedPainter = null;
      _clearHeightCache();
      _pendingSeekMs = null;
      _pendingSeekAt = null;
    }
  }

  @override
  void dispose() {
    PlayService.instance.playbackService.playerStateNotifier
        .removeListener(_playerStateListener);
    _ticker?.dispose();
    _scaleController.dispose();
    _floatController.dispose();
    _currentTimeNotifier.dispose();
    _heightNotifier.dispose();
    _cachedPainter = null;
    _cachedLineHeight = null;
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

    final effectiveOpacity = widget.isHovered ? 1.0 : _targetOpacity();

    Widget inner = TweenAnimationBuilder<double>(
      tween: Tween<double>(end: effectiveOpacity),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, animatedOpacity, _) {
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: blurSigma),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          builder: (context, animatedBlurSigma, _) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final theme = Theme.of(context);
                final fontFamily = theme.textTheme.bodyMedium?.fontFamily ??
                    theme.textTheme.bodySmall?.fontFamily;

                final lineWidth = constraints.maxWidth;
                final agent = widget.line is SyncLyricLine
                    ? (widget.line as SyncLyricLine).agent
                    : null;
                final useMaterialYouColor =
                    AppSettings.instance.useMaterialYouForLyrics;
                final currentTimeListenable =
                    _needsProgressTicker ? _currentTimeNotifier : null;

                if (_cachedPainter == null ||
                    _cachedPainter!.line != widget.line ||
                    _cachedPainter!.currentTimeListenable !=
                        currentTimeListenable ||
                    (currentTimeListenable == null &&
                        _cachedPainter!.currentTimeMs != _currentTimeMs) ||
                    _cachedPainter!.blurSigma != animatedBlurSigma ||
                    _cachedPainter!.config != renderConfig ||
                    _cachedPainter!.isMainLine != isCurrentLine ||
                    _cachedPainter!.useMaterialYouColor !=
                        useMaterialYouColor ||
                    _cachedPainter!.opacity != animatedOpacity ||
                    _cachedPainter!.fontFamily != fontFamily ||
                    _cachedPainter!.agent != agent) {
                  _cachedPainter = LyricsLinePainter(
                    line: widget.line,
                    currentTimeMs: _currentTimeMs,
                    currentTimeListenable: currentTimeListenable,
                    blurSigma: animatedBlurSigma,
                    config: renderConfig,
                    scheme: scheme,
                    isMainLine: isCurrentLine,
                    useMaterialYouColor: useMaterialYouColor,
                    opacity: animatedOpacity,
                    fontFamily: fontFamily,
                    agent: agent,
                  );
                }

                final heightCacheValid = _cachedLineHeight != null &&
                    _cachedLineWidth == lineWidth &&
                    identical(_heightLine, widget.line) &&
                    _heightConfig == renderConfig &&
                    _heightIsMainLine == isCurrentLine &&
                    _heightUseMaterialYouColor == useMaterialYouColor &&
                    _heightFontFamily == fontFamily &&
                    _heightAgent == agent;
                final lineHeight = heightCacheValid
                    ? _cachedLineHeight!
                    : _cachedPainter!.measureHeight(lineWidth);
                if (!heightCacheValid) {
                  _cachedLineHeight = lineHeight;
                  _cachedLineWidth = lineWidth;
                  _heightLine = widget.line;
                  _heightConfig = renderConfig;
                  _heightIsMainLine = isCurrentLine;
                  _heightUseMaterialYouColor = useMaterialYouColor;
                  _heightFontFamily = fontFamily;
                  _heightAgent = agent;
                }
                _heightNotifier.value = lineHeight;

                return ValueListenableBuilder<double>(
                  valueListenable: _heightNotifier,
                  builder: (context, h, _) => SizedBox(
                    height: h,
                    child: CustomPaint(
                      painter: _cachedPainter,
                      size: Size(lineWidth, h),
                    ),
                  ),
                );
              },
            );
          },
        );
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

    if (widget.isHovered && widget.onTap != null) {
      inner = Container(
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.08),
          borderRadius: AppRadius.mdCircular,
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
            borderRadius: AppRadius.mdCircular,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
