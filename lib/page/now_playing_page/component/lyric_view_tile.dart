import 'dart:math';

import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/window_render_gate.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/lyric/lyric_manual_offset.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/lyric_service.dart'
    show lyricWordPreSwitchMs;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

const compactTransitionTileHeight = 24.0;
const compactTransitionTileWidth = 72.0;
const transitionTileHeight = 40.0;
const _baseRadius = 6.0;
const _compactBaseRadius = 4.0;
const _compactSizeFactorMultiplier = 0.5;
const _circleGapMultiplier = 3.0;
const compactTransitionTileMargin = 10.0;
const transitionTileMargin = 12.0;
const _alphaBase = 0.05;
const _activeAlphaBase = 0.22;
const _staggerStep = 1 / 3;
const _breathingStep = 1 / 180;
const _staleInterludeTick = Duration(milliseconds: 200);
// 进出场按固定时长换算成进度比例，动画节奏不随间奏长短变化。
const _transitionEnterDurationMs = 500.0;
const _transitionExitDurationMs = 500.0;
const _transitionFractionCap = 0.25;
// 切行定位测量发生在行尾前 lyricWordPreSwitchMs，退场额外提前一点收完，
// 留出一帧余量，避免测量后行高还在变化导致下一句位置偏高。
const _exitSettleMarginMs = 100.0;

double _transitionFraction(double lengthMs, double windowMs) =>
    (windowMs / lengthMs).clamp(1e-6, _transitionFractionCap);

bool shouldIgnoreStaleInterludeTick(Duration delta) =>
    delta > _staleInterludeTick;

double lyricTransitionEnterOpacity(double progress, double enterFraction) {
  return Curves.easeOutCubic.transform(
    (progress / enterFraction).clamp(0.0, 1.0),
  );
}

double _dotExitProgress(
  double progress,
  int staggerIndex,
  double exitFraction,
  double exitEnd,
) {
  if (progress >= exitEnd) return 1.0;
  final start = exitEnd - exitFraction * (staggerIndex + 1) / 3;
  if (progress <= start) return 0.0;
  return ((progress - start) / (exitFraction / 3)).clamp(0.0, 1.0);
}

/// 出场按点亮的反向逐个熄灭：dot3 先走、dot1 最后走。
double lyricTransitionDotExitOpacity(
  double progress,
  int staggerIndex,
  double exitFraction,
  double exitEnd,
) {
  return 1.0 -
      Curves.easeInCubic.transform(
        _dotExitProgress(progress, staggerIndex, exitFraction, exitEnd),
      );
}

/// 熄灭同步收缩半径，避免最后一个点以原大小残留。
double lyricTransitionDotShrinkFactor(
  double progress,
  int staggerIndex,
  double exitFraction,
  double exitEnd,
) {
  return 1.0 - _dotExitProgress(progress, staggerIndex, exitFraction, exitEnd);
}

/// 进场窗口内行高从 0 展开到满，避免行高一帧弹出、点亮显得凭空开始。
double lyricTransitionEnterFactor(double progress, double enterFraction) {
  return Curves.easeOutCubic.transform(
    (progress / enterFraction).clamp(0.0, 1.0),
  );
}

bool lyricTransitionSkipEnter({
  required int startMs,
  required int lengthMs,
  required double positionMs,
}) {
  if (startMs != 0 || lengthMs <= 0) return false;
  return positionMs >= 0 && positionMs < lengthMs;
}

/// 手动点到间奏窗外时，不要把行高瞬间打成 0，沿退场时长收完。
bool lyricTransitionShouldAnimateSeekCollapse({
  required double previousHeight,
  required int sinceStartMs,
  required int lengthMs,
}) {
  if (previousHeight <= 0.001 || lengthMs <= 0) return false;
  return sinceStartMs > lengthMs || sinceStartMs < 0;
}

/// 间奏占位高度，含上下留白，和行组件实际布局一致。
double lyricTransitionBlockExtent(double heightFactor, double verticalPadding) {
  if (heightFactor <= 0) return 0;
  return (transitionTileHeight + verticalPadding * 2) * heightFactor;
}

double lyricTransitionHeightFactor({
  required double progress,
  required double enterFraction,
  required double exitFraction,
  required double exitEnd,
  bool skipEnter = false,
}) {
  final enter = skipEnter
      ? 1.0
      : lyricTransitionEnterFactor(progress, enterFraction);
  return enter * lyricTransitionCollapseFactor(progress, exitFraction, exitEnd);
}

/// 出场窗口内行高整体收起，progress 到 exitEnd 时归零，交接无跳变。
double lyricTransitionCollapseFactor(
  double progress,
  double exitFraction,
  double exitEnd,
) {
  if (progress >= exitEnd) return 0.0;
  final windowStart = exitEnd - exitFraction;
  if (progress <= windowStart) return 1.0;
  final exitProgress = ((progress - windowStart) / exitFraction).clamp(
    0.0,
    1.0,
  );
  return 1.0 - Curves.easeInCubic.transform(exitProgress);
}

bool lyricLineIsTransitionTile(LyricLine line) {
  if (line is SyncLyricLine) {
    return line.words.isEmpty && line.length > const Duration(seconds: 3);
  }
  if (line is LrcLine) {
    return line.isBlank &&
        line.length > const Duration(seconds: 3) &&
        line.start == Duration.zero;
  }
  return false;
}

double lyricTransitionLayoutHeight(LyricLine line, {required bool isMain}) {
  if (!isMain) return 0.0;
  return lyricLineIsTransitionTile(line) ? transitionTileHeight : 0.0;
}

/// 歌词间奏表示
/// lrcLine 和 syncLine 必须有且只有一个不为空
class LyricTransitionTile extends StatefulWidget {
  final LrcLine? lrcLine;
  final SyncLyricLine? syncLine;
  final double? positionMs;
  final LyricTextAlign? alignment;
  final bool enableBreathing;
  final bool compact;
  final bool useMaterialYouColor;
  final bool animateVisibilityWithProgress;

  /// 行内上下留白，随出场一起收起，由外层行组件传入。
  final double verticalPadding;

  /// 手动跳出间奏时行高变化量（负值表示在收）。列表用它把当前行拉回原高度。
  final ValueChanged<double>? onSeekCollapseHeightDelta;
  const LyricTransitionTile({
    super.key,
    this.lrcLine,
    this.syncLine,
    this.positionMs,
    this.alignment,
    this.enableBreathing = true,
    this.compact = false,
    this.useMaterialYouColor = true,
    this.animateVisibilityWithProgress = true,
    this.verticalPadding = 0.0,
    this.onSeekCollapseHeightDelta,
  });

  @override
  State<LyricTransitionTile> createState() => _LyricTransitionTileState();
}

class _LyricTransitionTileState extends State<LyricTransitionTile>
    with SingleTickerProviderStateMixin {
  late LyricTransitionTileController controller;
  AnimationController? _seekCollapse;

  @override
  void initState() {
    super.initState();
    controller = LyricTransitionTileController(
      widget.lrcLine,
      widget.syncLine,
      widget.enableBreathing,
      widget.positionMs,
    );
    _hookCollapsePin();
  }

  void _hookCollapsePin() {
    controller.onLayoutHeightJumped = (previous, next) {
      if (!mounted) return;
      final delta =
          lyricTransitionBlockExtent(next, widget.verticalPadding) -
          lyricTransitionBlockExtent(previous, widget.verticalPadding);
      if (delta.abs() < 0.01) return;
      widget.onSeekCollapseHeightDelta?.call(delta);
    };
  }

  @override
  void didUpdateWidget(LyricTransitionTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lrcLine != widget.lrcLine ||
        oldWidget.syncLine != widget.syncLine) {
      _stopSeekCollapse();
      controller.dispose();
      controller = LyricTransitionTileController(
        widget.lrcLine,
        widget.syncLine,
        widget.enableBreathing,
        widget.positionMs,
      );
      _hookCollapsePin();
    }
    if (widget.positionMs != null &&
        widget.positionMs != oldWidget.positionMs) {
      _handlePositionMs(widget.positionMs!);
    }
  }

  void _handlePositionMs(double positionMs) {
    final startMs =
        widget.lrcLine?.start.inMilliseconds ??
        widget.syncLine!.start.inMilliseconds;
    final lengthMs =
        widget.lrcLine?.length.inMilliseconds ??
        widget.syncLine!.length.inMilliseconds;
    final sinceStartMs = (positionMs - startMs).round();
    if (lyricTransitionShouldAnimateSeekCollapse(
      previousHeight: controller.heightFactor.value,
      sinceStartMs: sinceStartMs,
      lengthMs: lengthMs,
    )) {
      final collapsing = _startSeekCollapse();
      controller.updatePositionMs(positionMs, holdHeight: collapsing);
      return;
    }
    _stopSeekCollapse();
    controller.updatePositionMs(positionMs);
  }

  /// 返回 true 表示正在把间奏行高收掉，进度先别改写高度。
  bool _startSeekCollapse() {
    if (_seekCollapse != null && _seekCollapse!.isAnimating) return true;
    _stopSeekCollapse();
    final from = controller.heightFactor.value;
    if (from <= 0.001) {
      controller.heightFactor.value = 0;
      controller.releaseHeightHold();
      return false;
    }
    final seekCollapse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _seekCollapse = seekCollapse;
    seekCollapse.addListener(() {
      final t = Curves.easeInCubic.transform(seekCollapse.value);
      final next = from * (1.0 - t);
      final previous = controller.heightFactor.value;
      controller.heightFactor.value = next;
      _emitSeekCollapseHeightDelta(previous, next);
    });
    seekCollapse.addStatusListener((status) {
      if (status != AnimationStatus.completed || !mounted) return;
      final previous = controller.heightFactor.value;
      controller.heightFactor.value = 0;
      _emitSeekCollapseHeightDelta(previous, 0);
      controller.releaseHeightHold();
      if (!identical(_seekCollapse, seekCollapse)) return;
      _seekCollapse = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        seekCollapse.dispose();
      });
    });
    seekCollapse.forward();
    return true;
  }

  void _stopSeekCollapse() {
    _seekCollapse?.dispose();
    _seekCollapse = null;
  }

  void _emitSeekCollapseHeightDelta(double previousFactor, double nextFactor) {
    if (!widget.animateVisibilityWithProgress || widget.compact) return;
    final delta =
        lyricTransitionBlockExtent(nextFactor, widget.verticalPadding) -
        lyricTransitionBlockExtent(previousFactor, widget.verticalPadding);
    if (delta.abs() < 0.01) return;
    widget.onSeekCollapseHeightDelta?.call(delta);
  }

  @override
  void dispose() {
    final factor = controller.heightFactor.value;
    final collapsing = _seekCollapse != null;
    final reportRemaining = widget.onSeekCollapseHeightDelta;
    _stopSeekCollapse();
    if (collapsing &&
        factor > 0.001 &&
        reportRemaining != null &&
        widget.animateVisibilityWithProgress &&
        !widget.compact) {
      final delta = -lyricTransitionBlockExtent(factor, widget.verticalPadding);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        reportRemaining(delta);
      });
    }
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final align = widget.alignment ?? LyricTextAlign.left;
    final alignment = switch (align) {
      LyricTextAlign.left => Alignment.centerLeft,
      LyricTextAlign.center => Alignment.center,
      LyricTextAlign.right => Alignment.centerRight,
    };

    // 行高收到 0 后再卸掉，seek 跳出时间窗时还能把退场播完。
    if (widget.animateVisibilityWithProgress &&
        controller.heightFactor.value <= 0.001 &&
        _seekCollapse == null) {
      return const SizedBox.shrink();
    }

    if (widget.compact) {
      return Align(
        alignment: alignment,
        child: SizedBox(
          height: compactTransitionTileHeight,
          width: compactTransitionTileWidth,
          child: CustomPaint(
            painter: LyricTransitionPainter(
              scheme,
              controller,
              compact: true,
              alignment: align,
              useMaterialYouColor: widget.useMaterialYouColor,
              animateVisibilityWithProgress:
                  widget.animateVisibilityWithProgress,
            ),
          ),
        ),
      );
    }

    final painter = LyricTransitionPainter(
      scheme,
      controller,
      alignment: align,
      useMaterialYouColor: widget.useMaterialYouColor,
      animateVisibilityWithProgress: widget.animateVisibilityWithProgress,
    );
    if (!widget.animateVisibilityWithProgress) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: widget.verticalPadding),
        child: SizedBox(
          width: double.infinity,
          height: transitionTileHeight,
          child: CustomPaint(painter: painter),
        ),
      );
    }
    return ValueListenableBuilder<double>(
      valueListenable: controller.heightFactor,
      builder: (context, collapse, _) {
        return Padding(
          padding: EdgeInsets.symmetric(
            vertical: widget.verticalPadding * collapse,
          ),
          child: SizedBox(
            width: double.infinity,
            height: transitionTileHeight * collapse,
            child: CustomPaint(painter: painter),
          ),
        );
      },
    );
  }
}

class LyricTransitionPainter extends CustomPainter {
  final ColorScheme scheme;
  final LyricTransitionTileController controller;
  final bool compact;
  final bool useMaterialYouColor;
  final bool animateVisibilityWithProgress;
  final LyricTextAlign alignment;

  final Paint circlePaint1 = Paint();
  final Paint circlePaint2 = Paint();
  final Paint circlePaint3 = Paint();

  final double radius = _baseRadius;

  LyricTransitionPainter(
    this.scheme,
    this.controller, {
    this.compact = false,
    this.useMaterialYouColor = true,
    this.animateVisibilityWithProgress = true,
    this.alignment = LyricTextAlign.left,
  }) : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) {
    final progress = controller.progress.clamp(0.0, 1.0);
    final enterFraction = controller.enterFraction;
    final exitFraction = controller.exitFraction;
    final exitEnd = controller.exitEndFraction;
    final enterOpacity = animateVisibilityWithProgress
        ? (controller.skipEnter
              ? 1.0
              : lyricTransitionEnterOpacity(progress, enterFraction))
        : 1.0;
    final collapse = animateVisibilityWithProgress
        ? lyricTransitionHeightFactor(
            progress: progress,
            enterFraction: enterFraction,
            exitFraction: exitFraction,
            exitEnd: exitEnd,
            skipEnter: controller.skipEnter,
          )
        : 1.0;
    final alphaBase = animateVisibilityWithProgress
        ? _alphaBase
        : _activeAlphaBase;
    final alphaRange = 1.0 - alphaBase;
    final exit1 = animateVisibilityWithProgress
        ? lyricTransitionDotExitOpacity(progress, 0, exitFraction, exitEnd)
        : 1.0;
    final exit2 = animateVisibilityWithProgress
        ? lyricTransitionDotExitOpacity(progress, 1, exitFraction, exitEnd)
        : 1.0;
    final exit3 = animateVisibilityWithProgress
        ? lyricTransitionDotExitOpacity(progress, 2, exitFraction, exitEnd)
        : 1.0;
    final shrink1 = animateVisibilityWithProgress
        ? lyricTransitionDotShrinkFactor(progress, 0, exitFraction, exitEnd)
        : 1.0;
    final shrink2 = animateVisibilityWithProgress
        ? lyricTransitionDotShrinkFactor(progress, 1, exitFraction, exitEnd)
        : 1.0;
    final shrink3 = animateVisibilityWithProgress
        ? lyricTransitionDotShrinkFactor(progress, 2, exitFraction, exitEnd)
        : 1.0;

    // 三个点按整段间奏进度依次点亮（各占三分之一），节奏与上游一致；
    // 进场只做整体淡入和行高展开，不接管点亮进度。
    final a1 =
        (255 *
                enterOpacity *
                exit1 *
                (alphaBase + min(progress * 3, 1) * alphaRange))
            .round()
            .clamp(0, 255);
    final a2 =
        (255 *
                enterOpacity *
                exit2 *
                (alphaBase +
                    min(max(progress - _staggerStep, 0) * 3, 1) * alphaRange))
            .round()
            .clamp(0, 255);
    final a3 =
        (255 *
                enterOpacity *
                exit3 *
                (alphaBase +
                    min(max(progress - 2 * _staggerStep, 0) * 3, 1) *
                        alphaRange))
            .round()
            .clamp(0, 255);
    final transitionColor = useMaterialYouColor
        ? scheme.onSecondaryContainer
        : playerThemeForeground(scheme, enabled: false);
    circlePaint1.color = transitionColor.withAlpha(a1);
    circlePaint2.color = transitionColor.withAlpha(a2);
    circlePaint3.color = transitionColor.withAlpha(a3);

    final cy = size.height / 2;
    if (compact) {
      final r =
          (_compactBaseRadius +
              controller.sizeFactor * _compactSizeFactorMultiplier) *
          collapse;
      final gap = _circleGapMultiplier * r;
      final double x1, x2, x3;
      switch (alignment) {
        case LyricTextAlign.left:
          x1 = compactTransitionTileMargin;
          x2 = x1 + gap;
          x3 = x2 + gap;
        case LyricTextAlign.center:
          x2 = size.width / 2;
          x1 = x2 - gap;
          x3 = x2 + gap;
        case LyricTextAlign.right:
          x3 = size.width - compactTransitionTileMargin;
          x2 = x3 - gap;
          x1 = x2 - gap;
      }
      canvas.drawCircle(Offset(x1, cy), r * shrink1, circlePaint1);
      canvas.drawCircle(Offset(x2, cy), r * shrink2, circlePaint2);
      canvas.drawCircle(Offset(x3, cy), r * shrink3, circlePaint3);
    } else {
      final rWithFactor = (radius + controller.sizeFactor) * collapse;
      final gap = _circleGapMultiplier * rWithFactor;
      final double x1, x2, x3;
      switch (alignment) {
        case LyricTextAlign.left:
          x1 = transitionTileMargin;
          x2 = x1 + gap;
          x3 = x2 + gap;
        case LyricTextAlign.center:
          x2 = size.width / 2;
          x1 = x2 - gap;
          x3 = x2 + gap;
        case LyricTextAlign.right:
          x3 = size.width - transitionTileMargin;
          x2 = x3 - gap;
          x1 = x2 - gap;
      }
      canvas.drawCircle(Offset(x1, cy), rWithFactor * shrink1, circlePaint1);
      canvas.drawCircle(Offset(x2, cy), rWithFactor * shrink2, circlePaint2);
      canvas.drawCircle(Offset(x3, cy), rWithFactor * shrink3, circlePaint3);
    }
  }

  @override
  bool shouldRepaint(LyricTransitionPainter oldDelegate) => false;

  @override
  bool shouldRebuildSemantics(LyricTransitionPainter oldDelegate) => false;
}

/// 全局共享的间奏动画控制器管理器
/// 避免间奏动画订阅 positionStream，把底层位置更新拉到高频
class _TransitionControllerManager {
  static final _TransitionControllerManager _instance =
      _TransitionControllerManager._();
  static _TransitionControllerManager get instance => _instance;

  _TransitionControllerManager._();

  Ticker? _progressTicker;
  final Stopwatch _positionClock = Stopwatch();
  final Set<LyricTransitionTileController> _controllers = {};
  double _syncedPosition = 0.0;
  int _lastNativeSyncMs = 0;
  static const int _nativeSyncMs = 1000;
  Duration _lastTickElapsed = Duration.zero;
  Duration? _lastPaintElapsed;
  // 间奏倒计时和呼吸动画 30fps 足够，不必跟着屏幕刷新率跑
  static const _paintInterval = Duration(milliseconds: 33);
  late final VoidCallback _playerStateListener = _syncPlaybackState;
  late final VoidCallback _positionSyncListener = _syncPosition;

  bool get _isPlaying =>
      PlayService.instance.playbackService.playerState == PlayerState.playing;

  double get _estimatedPosition {
    if (!_isPlaying) return _syncedPosition;
    return _syncedPosition +
        _positionClock.elapsedMicroseconds / Duration.microsecondsPerSecond;
  }

  void register(LyricTransitionTileController controller) {
    if (_controllers.isEmpty) {
      PlayService.instance.playbackService.playerStateNotifier.addListener(
        _playerStateListener,
      );
      PlayService.instance.playbackService.positionSyncNotifier.addListener(
        _positionSyncListener,
      );
      LyricManualOffset.instance.addListener(_onManualOffset);
      WindowRenderGate.instance.framesEnabled.addListener(_onWindowFramesChanged);
    }
    _controllers.add(controller);
    controller._isPlaying = _isPlaying;
    _syncNativePosition();
    controller._updateProgress(_syncedPosition);
    _syncProgressTicker();
  }

  void unregister(LyricTransitionTileController controller) {
    _controllers.remove(controller);
    if (_controllers.isEmpty) {
      _stopProgressTicker();
      PlayService.instance.playbackService.playerStateNotifier.removeListener(
        _playerStateListener,
      );
      PlayService.instance.playbackService.positionSyncNotifier.removeListener(
        _positionSyncListener,
      );
      LyricManualOffset.instance.removeListener(_onManualOffset);
      WindowRenderGate.instance.framesEnabled.removeListener(
        _onWindowFramesChanged,
      );
    } else {
      _syncProgressTicker();
    }
  }

  void _syncPlaybackState() {
    final isPlaying = _isPlaying;
    _syncNativePosition();
    _updateControllers(_syncedPosition, isPlaying: isPlaying);
    _syncProgressTicker();
  }

  void _syncPosition() {
    if (_controllers.isEmpty) return;
    _syncNativePosition();
    _updateControllers(_syncedPosition);
    _syncProgressTicker();
  }

  void _onManualOffset() {
    _syncNativePosition();
    _updateControllers(_estimatedPosition);
  }

  void _syncNativePosition() {
    _syncedPosition =
        lyricTimelineMsDouble(PlayService.instance.playbackService.position) /
        1000.0;
    _lastNativeSyncMs = DateTime.now().millisecondsSinceEpoch;
    _positionClock
      ..reset()
      ..stop();
    if (_isPlaying) {
      _positionClock.start();
    }
  }

  void _onWindowFramesChanged() {
    _syncProgressTicker();
  }

  void _syncProgressTicker() {
    // 这个 Ticker 不吃 TickerMode，窗口隐藏时要自己停，否则托盘里还在按刷新率画。
    if (!WindowRenderGate.instance.framesEnabled.value ||
        _controllers.isEmpty ||
        !_isPlaying) {
      _stopProgressTicker();
      return;
    }
    _progressTicker ??= Ticker(_tickProgress);
    if (_progressTicker!.isActive) return;
    _lastTickElapsed = Duration.zero;
    _lastPaintElapsed = null;
    _progressTicker!.start();
  }

  void _stopProgressTicker() {
    _progressTicker?.stop();
    _lastTickElapsed = Duration.zero;
    _lastPaintElapsed = null;
    _positionClock.stop();
  }

  void _tickProgress(Duration elapsed) {
    if (_controllers.isEmpty || !_isPlaying) {
      _syncProgressTicker();
      return;
    }
    final lastPaint = _lastPaintElapsed;
    if (lastPaint != null && elapsed - lastPaint < _paintInterval) return;
    _lastPaintElapsed = elapsed;
    final tickDelta = _lastTickElapsed == Duration.zero
        ? Duration.zero
        : elapsed - _lastTickElapsed;
    _lastTickElapsed = elapsed;
    if (shouldIgnoreStaleInterludeTick(tickDelta)) {
      _syncNativePosition();
      _updateControllers(_estimatedPosition);
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastNativeSyncMs >= _nativeSyncMs) {
      _syncNativePosition();
    }
    _updateControllers(
      _estimatedPosition,
      breathingStepScale:
          tickDelta.inMicroseconds / (Duration.microsecondsPerSecond / 60.0),
    );
  }

  void _updateControllers(
    double position, {
    bool? isPlaying,
    double breathingStepScale = 0.0,
  }) {
    final controllers = List<LyricTransitionTileController>.from(_controllers);
    for (final c in controllers) {
      if (c._disposed) {
        _controllers.remove(c);
        continue;
      }
      c._updateProgress(position);
      if (c._disposed) {
        _controllers.remove(c);
        continue;
      }
      c._advanceBreathing(breathingStepScale);
      if (isPlaying != null) {
        c._isPlaying = isPlaying;
      }
    }
    if (_controllers.isEmpty) {
      _stopProgressTicker();
      PlayService.instance.playbackService.playerStateNotifier.removeListener(
        _playerStateListener,
      );
      PlayService.instance.playbackService.positionSyncNotifier.removeListener(
        _positionSyncListener,
      );
      LyricManualOffset.instance.removeListener(_onManualOffset);
    }
  }
}

class LyricTransitionTileController extends ChangeNotifier {
  final LrcLine? lrcLine;
  final SyncLyricLine? syncLine;

  @override
  void addListener(VoidCallback listener) {
    if (_disposed) return;
    super.addListener(listener);
  }

  final playbackService = PlayService.instance.playbackService;

  double progress = 0;
  void Function(double previous, double next)? onLayoutHeightJumped;

  /// 进出场固定时长换算出的进度比例，构造时按行时长算好。
  double enterFraction = 1e-6;
  double exitFraction = 1e-6;

  /// 退场结束点：行尾前 lyricWordPreSwitchMs + 余量，保证切行定位测量时行高已收完。
  double exitEndFraction = 1.0;
  bool skipEnter = false;
  final ValueNotifier<double> heightFactor = ValueNotifier(0);

  double sizeFactor = 0;
  double k = 1;
  late final bool _enableBreathing;
  bool _disposed = false;
  bool _isPlaying = false;
  bool _registered = false;
  bool _holdHeight = false;

  LyricTransitionTileController([
    this.lrcLine,
    this.syncLine,
    bool enableBreathing = true,
    double? initialPositionMs,
  ]) {
    _enableBreathing = enableBreathing;
    final startMs =
        lrcLine?.start.inMilliseconds ?? syncLine!.start.inMilliseconds;
    final lengthMs =
        (lrcLine?.length.inMilliseconds ?? syncLine!.length.inMilliseconds)
            .toDouble();
    enterFraction = _transitionFraction(lengthMs, _transitionEnterDurationMs);
    exitFraction = _transitionFraction(lengthMs, _transitionExitDurationMs);
    exitEndFraction =
        ((lengthMs - lyricWordPreSwitchMs - _exitSettleMarginMs) / lengthMs)
            .clamp(0.0, 1.0);
    final positionMs =
        initialPositionMs ??
        lyricTimelineMsDouble(PlayService.instance.playbackService.position);
    skipEnter = lyricTransitionSkipEnter(
      startMs: startMs,
      lengthMs: lengthMs.toInt(),
      positionMs: positionMs,
    );
    final initialProgress = lengthMs <= 0
        ? 1.0
        : ((positionMs - startMs).clamp(0.0, lengthMs) / lengthMs);
    heightFactor.value = lyricTransitionHeightFactor(
      progress: initialProgress,
      enterFraction: enterFraction,
      exitFraction: exitFraction,
      exitEnd: exitEndFraction,
      skipEnter: skipEnter,
    );
    _register();
  }

  void _register() {
    if (_disposed || _registered) return;
    _registered = true;
    _TransitionControllerManager.instance.register(this);
  }

  void _unregister() {
    if (!_registered) return;
    _registered = false;
    _TransitionControllerManager.instance.unregister(this);
  }

  void _advanceBreathing(double stepScale) {
    if (_disposed || !_enableBreathing || !_isPlaying || stepScale <= 0) {
      return;
    }
    // 退场窗口冻结呼吸，残留的最后一个点不再脉动。
    if (progress >= exitEndFraction - exitFraction) return;
    sizeFactor += k * _breathingStep * stepScale;
    if (sizeFactor > 1) {
      k = -1;
      sizeFactor = 1;
    } else if (sizeFactor < 0) {
      k = 1;
      sizeFactor = 0;
    }
  }

  void _updateProgress(double position) {
    if (_disposed) return;

    late int startInMs;
    late int lengthInMs;
    if (lrcLine != null) {
      startInMs = lrcLine!.start.inMilliseconds;
      lengthInMs = lrcLine!.length.inMilliseconds;
    } else {
      startInMs = syncLine!.start.inMilliseconds;
      lengthInMs = syncLine!.length.inMilliseconds;
    }
    // 防止除零：lengthInMs 可能因数据异常为 0
    if (lengthInMs <= 0) {
      progress = 1.0;
      if (heightFactor.value != 0) heightFactor.value = 0;
      notifyListeners();
      _unregister();
      return;
    }
    final sinceStart = position * 1000 - startInMs;
    if (progress >= 1.0 && sinceStart < lengthInMs) {
      _register();
    }
    progress = max(sinceStart, 0) / lengthInMs;
    if (!_holdHeight) {
      final previous = heightFactor.value;
      final nextHeight = lyricTransitionHeightFactor(
        progress: progress.clamp(0.0, 1.0),
        enterFraction: enterFraction,
        exitFraction: exitFraction,
        exitEnd: exitEndFraction,
        skipEnter: skipEnter,
      );
      final jumped = previous - nextHeight > 0.2;
      if ((nextHeight - previous).abs() > 0.001) {
        heightFactor.value = nextHeight;
      }
      if (jumped) onLayoutHeightJumped?.call(previous, nextHeight);
    }
    notifyListeners();

    if (progress >= 1 && !_holdHeight && heightFactor.value <= 0.001) {
      _unregister();
    }
  }

  void updatePositionMs(double positionMs, {bool holdHeight = false}) {
    _holdHeight = holdHeight;
    _updateProgress(positionMs / 1000.0);
  }

  void releaseHeightHold() {
    _holdHeight = false;
    if (progress >= 1 && heightFactor.value <= 0.001) {
      _unregister();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    _unregister();
    heightFactor.dispose();

    super.dispose();
  }
}

@visibleForTesting
int debugLyricTransitionControllerCount() =>
    _TransitionControllerManager.instance._controllers.length;
