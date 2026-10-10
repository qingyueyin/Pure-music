import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, visibleForTesting;
import 'package:flutter/scheduler.dart';
import 'package:flutter/physics.dart';
import 'package:provider/provider.dart';

import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_tile.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_stagger_motion.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_height_cache_key.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_painter_params.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';
import 'package:pure_music/play_service/play_service.dart';

/// 退场逐字上抬衰减：当前行或当前组为 1，组离开后落到 0。
@visibleForTesting
bool lyricLineFloatTarget({
  required bool mainHighlight,
  required bool isHighlightActive,
  required bool wasLatched,
}) => mainHighlight || (wasLatched && isHighlightActive);

/// 缩放走过目标行程九成后再开上抬。
@visibleForTesting
bool lyricScaleReachedLiftGate({
  required double start,
  required double target,
  required double value,
}) {
  final travel = target - start;
  if (travel.abs() < 1e-6) return true;
  return (value - start) / travel >= 0.9;
}

/// 播放中按帧时间往前走。原生进度只在倒退或偏差达到跳转阈值时接管。
double lyricMonotonicPlaybackMs({
  required double previousMs,
  required double predictedMs,
  required double nativeMs,
  double seekThresholdMs = 100,
}) {
  if ((nativeMs - previousMs).abs() >= seekThresholdMs) return nativeMs;
  if (predictedMs < previousMs) return previousMs;
  return predictedMs;
}

class LyricsLineWidget extends StatefulWidget {
  const LyricsLineWidget({
    super.key,
    required this.line,
    required this.opacity,
    this.distance,
    this.positionMs,
    this.positionListenable,
    this.isHighlightActive = false,
    this.isMainVocalActive,
    this.isBackgroundActive = false,
    this.isBackgroundVisible,
    this.usesAuthoredTiming = false,
    this.accelerateTailHighlight = false,
    this.lineOffsetY = 0.0,
    this.lineOffsetProgressListenable,
    this.staggerDelay = Duration.zero,
    this.jumpTriggerId = 0,
    this.jumpDeltaY = 0.0,
    this.isUserScrolling = false,
    this.freezeHeight = false,
    this.reserveBackgroundVocalHeight = false,
    this.highlightDeadlineMs,
    this.backgroundVocalVisibilityListenable,
    this.onTap,
  });

  final LyricLine line;
  final double opacity;
  final int? distance;
  final double? positionMs;
  final ValueListenable<double>? positionListenable;
  final bool isHighlightActive;
  final bool? isMainVocalActive;
  final bool isBackgroundActive;
  final bool? isBackgroundVisible;
  final bool usesAuthoredTiming;
  final bool accelerateTailHighlight;
  final double lineOffsetY;
  final ValueListenable<double>? lineOffsetProgressListenable;
  final Duration staggerDelay;
  final int jumpTriggerId;
  final double jumpDeltaY;
  final bool isUserScrolling;
  final bool freezeHeight;
  final bool reserveBackgroundVocalHeight;
  final double? highlightDeadlineMs;
  final ValueListenable<double>? backgroundVocalVisibilityListenable;
  final VoidCallback? onTap;

  /// 保留给内存监控调用；歌词模糊已改为 painter 内绘制。
  static void clearBlurFilterCache() {}

  @override
  State<LyricsLineWidget> createState() => _LyricsLineWidgetState();
}

class _LyricsLineWidgetState extends State<LyricsLineWidget>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late LyricRenderConfig _config;
  bool _isHovered = false;
  Ticker? _ticker;
  double _currentTimeMs = 0;
  final ValueNotifier<double> _currentTimeNotifier = ValueNotifier(0);
  late final VoidCallback _playerStateListener;
  Duration _lastTickElapsed = Duration.zero;

  /// seek 后用于过滤旧进度回调的临时目标
  double? _pendingSeekMs;
  DateTime? _pendingSeekAt;
  static const _seekGuardWindowMs = 200;

  late final AnimationController _scaleController;
  late final AnimationController _floatController;
  late final AnimationController _blurController;
  bool _blurSyncScheduled = false;
  double _pendingBlurTarget = 0.0;
  double _activeBlurTarget = 0.0;
  bool _pendingBlurImmediate = false;

  // 缓存 Painter，避免每帧重建
  LyricsLinePainter? _cachedPainter;
  final LyricCharLiftCache _liftCache = LyricCharLiftCache();
  double? _cachedLineHeight;
  LyricHeightCacheKey? _heightCacheKey;
  LyricLine? _effectTimingLine;
  Duration _effectLineMedian = Duration.zero;
  final ValueNotifier<double> _heightNotifier = ValueNotifier(0.0);
  double? _frozenHeight;
  double? _departingPaintHeight;
  double _lastBackgroundHeightUpdateMs = -1e9;
  double _lastBackgroundVocalHeightFactor = -1.0;
  bool _floatLatched = false;
  late final AnimationController _liftGateController;
  Timer? _scaleDelayTimer;
  Timer? _floatDelayTimer;
  Timer? _blurDelayTimer;
  Completer<void>? _scaleCompleter;
  int _liftGateGen = 0;
  VoidCallback? _scaleLiftListener;

  void _clearHeightCache() {
    _cachedLineHeight = null;
    _heightCacheKey = null;
  }

  void _applyMeasuredHeight(double measuredHeight) {
    if (widget.freezeHeight) {
      _frozenHeight ??= measuredHeight;
      if ((_frozenHeight! - _heightNotifier.value).abs() > 0.01) {
        _cachedLineHeight = _frozenHeight;
        _heightNotifier.value = _frozenHeight!;
      }
      return;
    }
    if ((measuredHeight - _heightNotifier.value).abs() <= 0.01) return;
    _cachedLineHeight = measuredHeight;
    _heightNotifier.value = measuredHeight;
  }

  double _backgroundVocalHeightFactor() {
    final line = widget.line;
    if (line is! SyncLyricLine) return 0.0;
    final currentTime = widget.positionListenable?.value ?? _currentTimeMs;
    return lyricBackgroundHeightFactor(
      currentTimeMs: currentTime,
      startMs: lyricBackgroundStartMs(line),
      endMs: lyricBackgroundEndMs(line),
      isMainLine: widget.distance == 0,
      isBackgroundActive: widget.isBackgroundActive,
      isBackgroundVisible: widget.isBackgroundVisible,
      exitVisibility: widget.backgroundVocalVisibilityListenable?.value,
    );
  }

  void _updateBackgroundVocalHeight() {
    if (!widget.reserveBackgroundVocalHeight ||
        !mounted ||
        _cachedPainter == null ||
        _heightCacheKey == null ||
        _heightCacheKey!.lineWidth <= 0) {
      return;
    }
    final factor = _backgroundVocalHeightFactor();
    final now = DateTime.now().microsecondsSinceEpoch / 1000.0;
    if ((factor - _lastBackgroundVocalHeightFactor).abs() <= 0.002 ||
        now - _lastBackgroundHeightUpdateMs < 8) {
      return;
    }
    _lastBackgroundHeightUpdateMs = now;
    _lastBackgroundVocalHeightFactor = factor;
    final height = _cachedPainter!.measureHeight(
      _heightCacheKey!.lineWidth,
      reserveBackgroundVocalHeight: true,
    );
    _applyMeasuredHeight(height);
  }

  void _bindBackgroundVocalListeners() {
    widget.positionListenable?.addListener(_updateBackgroundVocalHeight);
    widget.backgroundVocalVisibilityListenable?.addListener(
      _updateBackgroundVocalHeight,
    );
  }

  void _unbindBackgroundVocalListeners(LyricsLineWidget target) {
    target.positionListenable?.removeListener(_updateBackgroundVocalHeight);
    target.backgroundVocalVisibilityListenable?.removeListener(
      _updateBackgroundVocalHeight,
    );
  }

  Duration _lineMedianWordDuration(LyricLine line) {
    if (identical(_effectTimingLine, line)) return _effectLineMedian;
    _effectTimingLine = line;
    _effectLineMedian = line is SyncLyricLine
        ? lyricMedianWordDuration(line.words)
        : Duration.zero;
    return _effectLineMedian;
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
    _currentTimeMs = widget.positionMs ?? _readNativePositionMs();
    _currentTimeNotifier.value = _currentTimeMs;
    _config = context.read<LyricViewController>().renderConfig;
    _scaleController = AnimationController.unbounded(vsync: this);
    _scaleController.value = widget.distance == 0
        ? _config.mainLineScale * _config.activeLineScaleMultiplier
        : _config.subLineScale * _config.inactiveLineScaleMultiplier;
    _blurController = AnimationController.unbounded(vsync: this);
    _blurController.value = _blurSigmaTarget(_config);
    _activeBlurTarget = _blurController.value;
    if (widget.usesAuthoredTiming) {
      _floatLatched = lyricLineFloatTarget(
        mainHighlight: _mainHighlightFor(widget),
        isHighlightActive: widget.isHighlightActive,
        wasLatched: false,
      );
    }
    _floatController = AnimationController.unbounded(vsync: this);
    _floatController.value =
        lyricLineFloatTarget(
          mainHighlight: _mainHighlightFor(widget),
          isHighlightActive: widget.isHighlightActive,
          wasLatched: _floatLatched,
        )
        ? 1.0
        : 0.0;
    _liftGateController = AnimationController.unbounded(vsync: this);
    _liftGateController.value = 1.0;
    _bindBackgroundVocalListeners();
    _playerStateListener = _syncProgressTicker;
    if (widget.positionListenable == null) {
      PlayService.instance.playbackService.playerStateNotifier.addListener(
        _playerStateListener,
      );
    }
    _syncProgressTicker();
  }

  SpringSimulation _lineSpring(double from, double to) {
    return SpringSimulation(
      lyricLineSwitchSpring,
      from,
      to,
      0,
      // 缩放行程只有 0.05，停稳门槛要远小于行程才有过渡
      tolerance: const Tolerance(distance: 0.0005, velocity: 0.005),
    );
  }

  void _detachScaleLiftListener() {
    final listener = _scaleLiftListener;
    if (listener == null) return;
    _scaleController.removeListener(listener);
    _scaleLiftListener = null;
  }

  void _cancelLiftGateWait() {
    _liftGateGen++;
    _detachScaleLiftListener();
  }

  void _runAfterStagger(
    Timer? timer,
    void Function(Timer?) save,
    VoidCallback action, {
    bool ignoreDelay = false,
  }) {
    timer?.cancel();
    final delay =
        !ignoreDelay &&
            context.read<LyricViewController>().renderConfig.staggerStyle ==
                LyricStaggerStyle.spring
        ? widget.staggerDelay
        : Duration.zero;
    if (delay <= Duration.zero) {
      save(null);
      action();
      return;
    }
    save(
      Timer(delay, () {
        save(null);
        if (mounted) action();
      }),
    );
  }

  bool _skipLiftSwitchWait(LyricsLineWidget oldWidget) {
    if (widget.jumpTriggerId != oldWidget.jumpTriggerId &&
        widget.jumpDeltaY.abs() < 0.2) {
      return true;
    }
    final now =
        widget.positionListenable?.value ?? widget.positionMs ?? _currentTimeMs;
    return now - widget.line.start.inMilliseconds > 100;
  }

  Future<void> _animateScale() {
    final previous = _scaleCompleter;
    final completer = Completer<void>();
    _scaleCompleter = completer;
    if (previous != null && !previous.isCompleted) {
      previous.complete();
    }
    _runAfterStagger(_scaleDelayTimer, (timer) => _scaleDelayTimer = timer, () {
      if (!mounted) {
        if (!completer.isCompleted) completer.complete();
        return;
      }
      final target = widget.distance == 0
          ? _config.mainLineScale * _config.activeLineScaleMultiplier
          : _config.subLineScale * _config.inactiveLineScaleMultiplier;
      final style = context
          .read<LyricViewController>()
          .renderConfig
          .staggerStyle;
      final TickerFuture future;
      if (style == LyricStaggerStyle.smooth) {
        future = _scaleController.animateTo(
          target,
          duration: lyricSmoothTransitionDuration,
          curve: lyricSmoothTransitionCurve,
        );
      } else {
        future = _scaleController.animateWith(
          _lineSpring(_scaleController.value, target),
        );
      }
      future.whenComplete(() {
        if (mounted && (_scaleController.value - target).abs() < 0.01) {
          _scaleController.value = target;
        }
        if (!completer.isCompleted) completer.complete();
      });
    });
    return completer.future;
  }

  void _armLiftGateAfterScale(
    Future<void> scaleFuture, {
    required bool alsoFloat,
  }) {
    final gen = ++_liftGateGen;
    _liftGateController.stop();
    _liftGateController.value = 0;
    _detachScaleLiftListener();
    final start = _scaleController.value;
    final target = _config.mainLineScale * _config.activeLineScaleMultiplier;
    var opened = false;

    void open() {
      if (opened) return;
      opened = true;
      _detachScaleLiftListener();
      if (!mounted || gen != _liftGateGen || widget.distance != 0) return;
      _liftGateController.animateTo(
        1,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
      if (alsoFloat) _animateFloat(ignoreStaggerDelay: true);
    }

    void check() {
      if (!mounted || gen != _liftGateGen) {
        _detachScaleLiftListener();
        return;
      }
      if (widget.distance != 0) {
        _detachScaleLiftListener();
        return;
      }
      if (lyricScaleReachedLiftGate(
        start: start,
        target: target,
        value: _scaleController.value,
      )) {
        open();
      }
    }

    if (lyricScaleReachedLiftGate(
      start: start,
      target: target,
      value: _scaleController.value,
    )) {
      open();
      return;
    }
    _scaleLiftListener = check;
    _scaleController.addListener(check);
    scaleFuture.then((_) {
      if (gen != _liftGateGen) return;
      open();
    });
  }

  double _blurSigmaTarget(LyricRenderConfig config) {
    if (widget.isUserScrolling || !config.enableBlur) return 0.0;
    final dist = (widget.distance ?? 0).abs();
    if (dist == 0) return 0.0;
    return config.blurSigmaForDistance(dist);
  }

  void _scheduleBlurSync(double target, {required bool immediate}) {
    if (immediate) {
      _pendingBlurTarget = target;
      _pendingBlurImmediate = true;
    } else if (!_pendingBlurImmediate &&
        _activeBlurTarget == target &&
        (_blurController.isAnimating ||
            (_blurController.value - target).abs() < 0.01)) {
      return;
    } else {
      _pendingBlurTarget = target;
    }
    if (_blurSyncScheduled) return;
    _blurSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _blurSyncScheduled = false;
      if (!mounted) return;
      final next = _pendingBlurTarget;
      final jump = _pendingBlurImmediate;
      _pendingBlurImmediate = false;
      _activeBlurTarget = next;
      _blurDelayTimer?.cancel();
      _blurDelayTimer = null;
      if (jump) {
        _blurController.stop();
        _blurController.value = next;
        return;
      }
      if ((_blurController.value - next).abs() < 0.01) return;
      final style = context
          .read<LyricViewController>()
          .renderConfig
          .staggerStyle;
      void start() {
        if (!mounted) return;
        if (style == LyricStaggerStyle.smooth) {
          _blurController.animateTo(
            next,
            duration: lyricSmoothTransitionDuration,
            curve: lyricSmoothTransitionCurve,
          );
          return;
        }
        _blurController
            .animateWith(_lineSpring(_blurController.value, next))
            .whenComplete(() {
              if (!mounted) return;
              if ((_blurController.value - next).abs() < 0.01) {
                _blurController.value = next;
              }
            });
      }

      _runAfterStagger(
        _blurDelayTimer,
        (timer) => _blurDelayTimer = timer,
        start,
      );
    });
  }

  void _animateFloat({bool ignoreStaggerDelay = false}) {
    final target =
        lyricLineFloatTarget(
          mainHighlight: _mainHighlightFor(widget),
          isHighlightActive: widget.isHighlightActive,
          wasLatched: _floatLatched,
        )
        ? 1.0
        : 0.0;
    _runAfterStagger(
      _floatDelayTimer,
      (timer) => _floatDelayTimer = timer,
      () {
        final style = context
            .read<LyricViewController>()
            .renderConfig
            .staggerStyle;
        if (style == LyricStaggerStyle.smooth) {
          _floatController.animateTo(
            target,
            duration: lyricSmoothTransitionDuration,
            curve: lyricSmoothTransitionCurve,
          );
          return;
        }
        _floatController
            .animateWith(_lineSpring(_floatController.value, target))
            .whenComplete(() {
              if (!mounted) return;
              if ((_floatController.value - target).abs() < 0.01) {
                _floatController.value = target;
              }
            });
      },
      ignoreDelay: ignoreStaggerDelay,
    );
  }

  bool _tickerHoldActive = false;
  DateTime? _tickerHoldUntil;
  Timer? _tickerHoldTimer;

  bool _mainHighlightFor(LyricsLineWidget target) {
    return target.usesAuthoredTiming
        ? target.isMainVocalActive ?? target.isHighlightActive
        : target.distance == 0 || target.isHighlightActive;
  }

  bool _hasBaseProgressTickerFor(LyricsLineWidget target) {
    if (target.line is! SyncLyricLine ||
        _config.displayMode != LyricDisplayMode.wordByWord) {
      return false;
    }
    final line = target.line as SyncLyricLine;
    final hasBg = lyricLineHasBackgroundVocal(line);
    if (line.words.isEmpty && !hasBg) return false;
    if (_mainHighlightFor(target) || target.isBackgroundActive) {
      return true;
    }
    if (!hasBg) return false;
    if (target.distance != 0 && target.isBackgroundVisible != true) {
      return false;
    }
    final now = target.positionListenable?.value ?? _currentTimeMs;
    if (target.backgroundVocalVisibilityListenable != null) {
      return false;
    }
    return lyricLineEffectsNeedFrame(
      words: [...line.words, ...line.bgWords],
      nowMs: now,
      lineMedianDuration: _lineMedianWordDuration(line),
      enableGlow: _config.enableGlow,
      liftActive:
          _mainHighlightFor(target) &&
          _config.liftStyle == LyricLiftStyle.vertical,
      liftPeak: _config.liftPeak,
    );
  }

  bool get _needsProgressTicker {
    if (_hasBaseProgressTickerFor(widget)) return true;
    // 给 ticker 最小持有时间，避免歌词行切换时频繁启停导致动画丢失
    if (_tickerHoldActive &&
        _tickerHoldUntil != null &&
        DateTime.now().isBefore(_tickerHoldUntil!)) {
      return true;
    }
    return false;
  }

  void _holdProgressTickerForLineTransition() {
    _tickerHoldTimer?.cancel();
    _tickerHoldActive = true;
    _tickerHoldUntil = DateTime.now().add(const Duration(milliseconds: 200));
    _tickerHoldTimer = Timer(const Duration(milliseconds: 200), () {
      _tickerHoldTimer = null;
      _tickerHoldActive = false;
      _tickerHoldUntil = null;
      if (mounted) _syncProgressTicker();
    });
  }

  void _syncProgressTicker() {
    if (widget.positionListenable != null) {
      _ticker?.stop();
      return;
    }
    final hasBaseProgressTicker = _hasBaseProgressTickerFor(widget);
    if (hasBaseProgressTicker) {
      _tickerHoldTimer?.cancel();
      _tickerHoldTimer = null;
      _tickerHoldActive = false;
      _tickerHoldUntil = null;
    }
    if (_needsProgressTicker) {
      _syncToNativePosition();
      _lastTickElapsed = Duration.zero;
      _pendingSeekMs = null;
      _pendingSeekAt = null;
      final isPlaying =
          PlayService.instance.playbackService.playerState ==
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

  void _setCurrentTimeMs(double value, {bool notify = true}) {
    _currentTimeMs = value;
    if (notify && _currentTimeNotifier.value != value) {
      _currentTimeNotifier.value = value;
    }
  }

  bool _visualProgressChangedBetween(
    SyncLyricLine line,
    double fromMs,
    double toMs,
  ) {
    if (toMs < fromMs) return true;

    bool overlapsProgress(Iterable<SyncLyricWord> words) {
      for (final word in words) {
        final start = word.start.inMilliseconds.toDouble();
        final end = start + word.length.inMilliseconds;
        if (toMs >= start && fromMs <= end) return true;
      }
      return false;
    }

    if (overlapsProgress(line.words) || overlapsProgress(line.bgWords)) {
      return true;
    }
    if (lyricLineEffectsNeedFrame(
      words: [...line.words, ...line.bgWords],
      nowMs: toMs,
      lineMedianDuration: _lineMedianWordDuration(line),
      enableGlow: _config.enableGlow,
      liftActive:
          _mainHighlightFor(widget) &&
          _config.liftStyle == LyricLiftStyle.vertical,
      liftPeak: _config.liftPeak,
    )) {
      return true;
    }
    if (!lyricLineHasBackgroundVocal(line)) return false;
    final bgStart = lyricBackgroundStartMs(line);
    final bgVisualEnd =
        lyricBackgroundEndMs(line) +
        lyricBackgroundVocalExitDuration.inMilliseconds;
    return toMs >= bgStart && fromMs <= bgVisualEnd;
  }

  double _targetOpacity() {
    final dist = (widget.distance ?? 0).abs();
    if (dist == 0) return 1.0;
    return (widget.opacity).clamp(0.0, 1.0);
  }

  void _onTick(Duration elapsed) {
    final previousTimeMs = _currentTimeMs;
    final elapsedDelta = _lastTickElapsed == Duration.zero
        ? Duration.zero
        : elapsed - _lastTickElapsed;
    _lastTickElapsed = elapsed;

    final rate = widget.usesAuthoredTiming
        ? PlayService.instance.playbackService.rate.value
        : 1.0;
    final predictedMs =
        _currentTimeMs + elapsedDelta.inMicroseconds / 1000.0 * rate;
    final nativeMs = _readNativePositionMs();
    final rawMs = lyricMonotonicPlaybackMs(
      previousMs: _currentTimeMs,
      predictedMs: predictedMs,
      nativeMs: nativeMs,
    );

    final delta = rawMs - _currentTimeMs;
    var shouldRepaint = false;
    var forceRepaint = false;

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
      _setCurrentTimeMs(rawMs, notify: false);
      shouldRepaint = true;
      forceRepaint = true;
    } else if (delta > 0.5) {
      // 播放中：直接同步 raw，避免平滑滞后导致歌词末尾覆盖不全
      _setCurrentTimeMs(rawMs, notify: false);
      shouldRepaint = true;
    } else if (delta < -32) {
      // 暂停或倒带：回退到 raw
      _setCurrentTimeMs(rawMs, notify: false);
      shouldRepaint = true;
      forceRepaint = true;
    }

    if (!shouldRepaint || !mounted) return;
    if (widget.line is SyncLyricLine) {
      final syncLine = widget.line as SyncLyricLine;
      if (!forceRepaint &&
          !_visualProgressChangedBetween(
            syncLine,
            previousTimeMs,
            _currentTimeMs,
          )) {
        return;
      }
      if (_currentTimeNotifier.value != _currentTimeMs) {
        _currentTimeNotifier.value = _currentTimeMs;
      }
    } else if (_currentTimeNotifier.value != _currentTimeMs) {
      _currentTimeNotifier.value = _currentTimeMs;
    }
    _updateBackgroundVocalHeight();
  }

  @override
  void didUpdateWidget(covariant LyricsLineWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.positionMs != oldWidget.positionMs &&
        widget.positionMs != null &&
        (widget.positionMs! - _currentTimeMs).abs() > 0.5) {
      _pendingSeekMs = null;
      _pendingSeekAt = null;
      _setCurrentTimeMs(widget.positionMs!);
    }

    final backgroundVocalListenersChanged =
        widget.positionListenable != oldWidget.positionListenable ||
        widget.backgroundVocalVisibilityListenable !=
            oldWidget.backgroundVocalVisibilityListenable;
    if (backgroundVocalListenersChanged) {
      _unbindBackgroundVocalListeners(oldWidget);
      _bindBackgroundVocalListeners();
    }

    if (widget.positionListenable != oldWidget.positionListenable) {
      if (oldWidget.positionListenable == null) {
        PlayService.instance.playbackService.playerStateNotifier.removeListener(
          _playerStateListener,
        );
      } else if (widget.positionListenable == null) {
        PlayService.instance.playbackService.playerStateNotifier.addListener(
          _playerStateListener,
        );
      }
      _syncProgressTicker();
    }

    if (widget.backgroundVocalVisibilityListenable !=
        oldWidget.backgroundVocalVisibilityListenable) {
      _clearHeightCache();
    }

    if (!widget.usesAuthoredTiming &&
        widget.backgroundVocalVisibilityListenable != null &&
        oldWidget.backgroundVocalVisibilityListenable == null &&
        _heightNotifier.value > 0) {
      _departingPaintHeight = _heightNotifier.value;
    } else if (widget.usesAuthoredTiming ||
        widget.backgroundVocalVisibilityListenable == null) {
      _departingPaintHeight = null;
    }

    if (widget.freezeHeight && !oldWidget.freezeHeight) {
      // 只冻结已经算出的完整高度，不重新测量半成品
      _frozenHeight = widget.distance == 0 || _heightNotifier.value <= 0
          ? null
          : _heightNotifier.value;
    } else if (!widget.freezeHeight) {
      _frozenHeight = null;
    }

    final isActive = widget.distance == 0;
    final wasActive = oldWidget.distance == 0;
    final isHighlightActive = _mainHighlightFor(widget);
    final wasHighlightActive = _mainHighlightFor(oldWidget);
    var authoredFloatAfterScale = false;
    if (widget.usesAuthoredTiming) {
      final wasFloatActive = lyricLineFloatTarget(
        mainHighlight: wasHighlightActive,
        isHighlightActive: oldWidget.isHighlightActive,
        wasLatched: _floatLatched,
      );
      _floatLatched = lyricLineFloatTarget(
        mainHighlight: isHighlightActive,
        isHighlightActive: widget.isHighlightActive,
        wasLatched: _floatLatched,
      );
      if (_floatLatched != wasFloatActive) {
        if (isActive && !wasActive && !_skipLiftSwitchWait(oldWidget)) {
          authoredFloatAfterScale = true;
        } else {
          _animateFloat();
        }
      }
    }

    if (isHighlightActive != wasHighlightActive ||
        widget.isBackgroundActive != oldWidget.isBackgroundActive ||
        widget.line != oldWidget.line) {
      if (widget.isBackgroundActive != oldWidget.isBackgroundActive ||
          widget.isBackgroundVisible != oldWidget.isBackgroundVisible) {
        _clearHeightCache();
      }
      if (_hasBaseProgressTickerFor(oldWidget) &&
          !_hasBaseProgressTickerFor(widget)) {
        _holdProgressTickerForLineTransition();
      }
      _syncProgressTicker();
    }

    if (isActive != wasActive) {
      _cancelLiftGateWait();
      final scaleFuture = _animateScale();
      if (isActive) {
        if (_skipLiftSwitchWait(oldWidget)) {
          _liftGateController.stop();
          _liftGateController.value = 1.0;
          if (!widget.usesAuthoredTiming || authoredFloatAfterScale) {
            _animateFloat();
          }
        } else {
          _armLiftGateAfterScale(
            scaleFuture,
            alsoFloat: !widget.usesAuthoredTiming || authoredFloatAfterScale,
          );
        }
      } else {
        if (!widget.usesAuthoredTiming) _animateFloat();
      }
      _cachedPainter = null;
      _clearHeightCache();
      if (isActive) _frozenHeight = null;
    }

    final oldKeepAlive = (oldWidget.distance ?? 999).abs() <= 2;
    final newKeepAlive = (widget.distance ?? 999).abs() <= 2;
    if (oldKeepAlive != newKeepAlive) {
      updateKeepAlive();
    }

    if (widget.distance != oldWidget.distance ||
        widget.isUserScrolling != oldWidget.isUserScrolling) {
      _scheduleBlurSync(
        _blurSigmaTarget(_config),
        immediate: widget.isUserScrolling,
      );
    }

    if (widget.line != oldWidget.line) {
      _cachedPainter = null;
      _liftCache.values = const [];
      _liftCache.effectProgress = const [];
      _clearHeightCache();
      _frozenHeight = null;
      _pendingSeekMs = null;
      _pendingSeekAt = null;
      _lastBackgroundVocalHeightFactor = -1.0;
    }
  }

  @override
  void dispose() {
    if (widget.positionListenable == null) {
      PlayService.instance.playbackService.playerStateNotifier.removeListener(
        _playerStateListener,
      );
    }
    _ticker?.dispose();
    _tickerHoldTimer?.cancel();
    _scaleDelayTimer?.cancel();
    _floatDelayTimer?.cancel();
    _blurDelayTimer?.cancel();
    _cancelLiftGateWait();
    if (_scaleCompleter != null && !_scaleCompleter!.isCompleted) {
      _scaleCompleter!.complete();
    }
    _unbindBackgroundVocalListeners(widget);
    _scaleController.dispose();
    _floatController.dispose();
    _blurController.dispose();
    _liftGateController.dispose();
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
    final isMainVocalActive = _mainHighlightFor(widget);
    final isHighlightActive = widget.usesAuthoredTiming
        ? widget.isHighlightActive
        : isMainVocalActive;

    final renderConfig = context.watch<LyricViewController>().renderConfig;
    _config = renderConfig;

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
    final layoutScaleAlignment = lyricLineScaleAlignment(effectiveTextAlign);
    final scheme = Theme.of(context).colorScheme;
    final blurSigma = widget.isUserScrolling
        ? 0.0
        : (isCurrentLine ? 0.0 : renderConfig.blurSigmaForDistance(dist));
    _scheduleBlurSync(blurSigma, immediate: widget.isUserScrolling);

    // 间奏行按自身时间窗渲染到底，不随主行切换销毁，退场才能收完。
    final isTransitionLine = _isTransitionLine(widget.line);
    if (isTransitionLine) {
      final verticalPad = widget.line is SyncLyricLine
          ? renderConfig.syncVerticalPadding(isMainLine: true)
          : renderConfig.lrcVerticalPadding();

      final transitionTile = widget.line is SyncLyricLine
          ? LyricTransitionTile(
              key: ValueKey(widget.line),
              syncLine: widget.line as SyncLyricLine,
              positionMs: _currentTimeMs,
              alignment: effectiveTextAlign,
              useMaterialYouColor:
                  AppSettings.instance.useMaterialYouForTransition,
              verticalPadding: verticalPad,
            )
          : LyricTransitionTile(
              key: ValueKey(widget.line),
              lrcLine: widget.line as LrcLine,
              alignment: effectiveTextAlign,
              useMaterialYouColor:
                  AppSettings.instance.useMaterialYouForTransition,
              verticalPadding: verticalPad,
            );

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: transitionTileMargin),
        child: _LocalHoverMask(
          onTap: widget.onTap,
          color: scheme.onSurface.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: transitionTileMargin,
            ),
            child: Align(alignment: scaleAlignment, child: transitionTile),
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

    final effectiveOpacity = _isHovered ? 1.0 : _targetOpacity();
    final isSmoothTransition =
        renderConfig.staggerStyle == LyricStaggerStyle.smooth;
    final visualTransitionDuration = isSmoothTransition
        ? lyricSmoothTransitionDuration
        : const Duration(milliseconds: 600);
    final visualTransitionCurve = isSmoothTransition
        ? lyricSmoothTransitionCurve
        : Curves.easeOutCubic;

    Widget inner = TweenAnimationBuilder<double>(
      tween: Tween<double>(end: effectiveOpacity),
      duration: visualTransitionDuration,
      curve: visualTransitionCurve,
      builder: (context, animatedOpacity, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final fontFamily = context
                .watch<ThemeProvider>()
                .resolvedLyricFontFamily;

            final lineWidth = constraints.maxWidth;
            final agent = widget.line is SyncLyricLine
                ? (widget.line as SyncLyricLine).agent
                : null;
            final useMaterialYouColor =
                AppSettings.instance.useMaterialYouForLyrics;
            final currentTimeListenable =
                widget.positionListenable ??
                (_needsProgressTicker ? _currentTimeNotifier : null);
            final backgroundVocalVisibilityListenable =
                widget.backgroundVocalVisibilityListenable;
            final lineMedianWordDuration = _lineMedianWordDuration(widget.line);

            final newParams = LyricPainterParams(
              line: widget.line,
              currentTimeMs: _currentTimeMs,
              currentTimeListenable: currentTimeListenable,
              backgroundVocalVisibilityListenable:
                  backgroundVocalVisibilityListenable,
              blurSigma: blurSigma,
              blurSigmaListenable: _blurController,
              config: renderConfig,
              isMainLine: isCurrentLine,
              isHighlightActive: isHighlightActive,
              isMainVocalActive: widget.usesAuthoredTiming
                  ? isMainVocalActive
                  : null,
              isBackgroundActive: widget.isBackgroundActive,
              isBackgroundVisible: widget.isBackgroundVisible,
              usesAuthoredTiming: widget.usesAuthoredTiming,
              accelerateTailHighlight: widget.accelerateTailHighlight,
              useMaterialYouColor: useMaterialYouColor,
              opacity: animatedOpacity,
              fontFamily: fontFamily,
              agent: agent,
              highlightDeadlineMs: widget.highlightDeadlineMs,
              lineMedianWordDuration: lineMedianWordDuration,
              liftDecayListenable: isMainVocalActive ? null : _floatController,
              liftGateListenable: _liftGateController,
            );

            if (_cachedPainter == null || _cachedPainter!.params != newParams) {
              _cachedPainter = LyricsLinePainter(
                params: newParams,
                scheme: scheme,
                liftCache: _liftCache,
              );
            }

            final heightCacheKey = LyricHeightCacheKey(
              line: widget.line,
              lineWidth: lineWidth,
              config: renderConfig,
              isMainLine: isCurrentLine,
              useMaterialYouColor: useMaterialYouColor,
              reserveBackgroundVocalHeight: widget.reserveBackgroundVocalHeight,
              fontFamily: fontFamily,
              agent: agent,
            );
            final heightCacheValid =
                _cachedLineHeight != null && _heightCacheKey == heightCacheKey;
            final lineHeight = heightCacheValid
                ? _cachedLineHeight!
                : _cachedPainter!.measureHeight(
                    lineWidth,
                    reserveBackgroundVocalHeight:
                        widget.reserveBackgroundVocalHeight,
                  );
            if (!heightCacheValid) {
              if (widget.freezeHeight) _frozenHeight = null;
              _cachedLineHeight = lineHeight;
              _heightCacheKey = heightCacheKey;
            }
            final resolvedHeight = widget.freezeHeight
                ? _frozenHeight ??= lineHeight
                : lineHeight;
            _heightNotifier.value = resolvedHeight;

            return ValueListenableBuilder<double>(
              valueListenable: _heightNotifier,
              builder: (context, h, _) {
                final paintHeight = max(h, _departingPaintHeight ?? h);
                return SizedBox(
                  height: h,
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    minHeight: paintHeight,
                    maxHeight: paintHeight,
                    child: SizedBox(
                      width: lineWidth,
                      height: paintHeight,
                      child: CustomPaint(
                        painter: _cachedPainter,
                        size: Size(lineWidth, paintHeight),
                      ),
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
        final transform = Matrix4.identity()
          ..scaleByDouble(
            _scaleController.value,
            _scaleController.value,
            _scaleController.value,
            1.0,
          );
        return Transform(
          transform: transform,
          alignment: layoutScaleAlignment,
          child: child!,
        );
      },
      child: inner,
    );

    final lineOffsetProgress = widget.lineOffsetProgressListenable;
    if (lineOffsetProgress != null && widget.lineOffsetY != 0.0) {
      inner = AnimatedBuilder(
        animation: lineOffsetProgress,
        builder: (context, child) => Transform.translate(
          offset: Offset(0.0, widget.lineOffsetY * lineOffsetProgress.value),
          child: child,
        ),
        child: inner,
      );
    }

    if (_isHovered && widget.onTap != null) {
      inner = Container(
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.08),
          borderRadius: AppRadius.mdCircular,
        ),
        child: inner,
      );
    }

    inner = LyricStaggerTransition(
      enabled:
          renderConfig.enableStaggeredAnimation &&
          renderConfig.staggerStyle == LyricStaggerStyle.spring,
      generation: widget.jumpTriggerId,
      shiftY: widget.jumpDeltaY,
      delay: widget.staggerDelay,
      child: inner,
    );

    inner = GestureDetector(onTap: widget.onTap, child: inner);

    if (widget.onTap != null) {
      inner = MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
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

  bool _isTransitionLine(LyricLine line) => lyricLineIsTransitionTile(line);
}

class _LocalHoverMask extends StatefulWidget {
  const _LocalHoverMask({required this.child, required this.color, this.onTap});

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
