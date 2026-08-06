import 'dart:math';

import 'package:pure_music/core/enums.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';
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
const _enterOpacityFraction = 0.12;
const _exitOpacityFraction = 0.18;
const _alphaBase = 0.05;
const _activeAlphaBase = 0.22;
const _staggerStep = 1 / 3;
const _breathingStep = 1 / 180;

/// 歌词间奏表示
/// lrcLine 和 syncLine 必须有且只有一个不为空
class LyricTransitionTile extends StatefulWidget {
  final LrcLine? lrcLine;
  final SyncLyricLine? syncLine;
  final LyricTextAlign? alignment;
  final bool enableBreathing;
  final bool compact;
  final bool useMaterialYouColor;
  final bool animateVisibilityWithProgress;
  const LyricTransitionTile({
    super.key,
    this.lrcLine,
    this.syncLine,
    this.alignment,
    this.enableBreathing = true,
    this.compact = false,
    this.useMaterialYouColor = true,
    this.animateVisibilityWithProgress = true,
  });

  @override
  State<LyricTransitionTile> createState() => _LyricTransitionTileState();
}

class _LyricTransitionTileState extends State<LyricTransitionTile> {
  late LyricTransitionTileController controller;

  @override
  void initState() {
    super.initState();
    controller = LyricTransitionTileController(
        widget.lrcLine, widget.syncLine, widget.enableBreathing);
  }

  @override
  void didUpdateWidget(LyricTransitionTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lrcLine != widget.lrcLine ||
        oldWidget.syncLine != widget.syncLine) {
      controller.dispose();
      controller = LyricTransitionTileController(
          widget.lrcLine, widget.syncLine, widget.enableBreathing);
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

    // 由播放进度控制可见性时，结束后立即隐藏
    if (widget.animateVisibilityWithProgress && controller.progress >= 1) {
      return const SizedBox.shrink();
    }

    final align = widget.alignment ?? LyricTextAlign.left;
    final alignment = switch (align) {
      LyricTextAlign.left => Alignment.centerLeft,
      LyricTextAlign.center => Alignment.center,
      LyricTextAlign.right => Alignment.centerRight,
    };

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

    return SizedBox(
      width: double.infinity,
      height: transitionTileHeight,
      child: CustomPaint(
        painter: LyricTransitionPainter(
          scheme,
          controller,
          alignment: align,
          useMaterialYouColor: widget.useMaterialYouColor,
          animateVisibilityWithProgress: widget.animateVisibilityWithProgress,
        ),
      ),
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

  LyricTransitionPainter(this.scheme, this.controller,
      {this.compact = false,
      this.useMaterialYouColor = true,
      this.animateVisibilityWithProgress = true,
      this.alignment = LyricTextAlign.left})
      : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) {
    final progress = controller.progress.clamp(0.0, 1.0);
    final enterOpacity = Curves.easeOutCubic
        .transform((progress / _enterOpacityFraction).clamp(0.0, 1.0));
    final exitOpacity = Curves.easeOutCubic
        .transform(((1.0 - progress) / _exitOpacityFraction).clamp(0.0, 1.0));
    final opacityEnvelope =
        animateVisibilityWithProgress ? enterOpacity * exitOpacity : 1.0;
    final alphaBase =
        animateVisibilityWithProgress ? _alphaBase : _activeAlphaBase;
    final alphaRange = 1.0 - alphaBase;

    final a1 = (255 *
            opacityEnvelope *
            (alphaBase + min(controller.progress * 3, 1) * alphaRange))
        .round()
        .clamp(0, 255);
    final a2 = (255 *
            opacityEnvelope *
            (alphaBase +
                min(max(controller.progress - _staggerStep, 0) * 3, 1) *
                    alphaRange))
        .round()
        .clamp(0, 255);
    final a3 = (255 *
            opacityEnvelope *
            (alphaBase +
                min(max(controller.progress - 2 * _staggerStep, 0) * 3, 1) *
                    alphaRange))
        .round()
        .clamp(0, 255);
    final transitionColor =
        useMaterialYouColor ? scheme.onSecondaryContainer : scheme.onSurface;
    circlePaint1.color = transitionColor.withAlpha(a1);
    circlePaint2.color = transitionColor.withAlpha(a2);
    circlePaint3.color = transitionColor.withAlpha(a3);

    final cy = size.height / 2;
    if (compact) {
      final r = _compactBaseRadius +
          controller.sizeFactor * _compactSizeFactorMultiplier;
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
      canvas.drawCircle(Offset(x1, cy), r, circlePaint1);
      canvas.drawCircle(Offset(x2, cy), r, circlePaint2);
      canvas.drawCircle(Offset(x3, cy), r, circlePaint3);
    } else {
      final rWithFactor = radius + controller.sizeFactor;
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
      canvas.drawCircle(Offset(x1, cy), rWithFactor, circlePaint1);
      canvas.drawCircle(Offset(x2, cy), rWithFactor, circlePaint2);
      canvas.drawCircle(Offset(x3, cy), rWithFactor, circlePaint3);
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
  late final VoidCallback _playerStateListener = _syncPlaybackState;

  bool get _isPlaying =>
      PlayService.instance.playbackService.playerState == PlayerState.playing;

  double get _estimatedPosition {
    if (!_isPlaying) return _syncedPosition;
    return _syncedPosition +
        _positionClock.elapsedMicroseconds / Duration.microsecondsPerSecond;
  }

  void register(LyricTransitionTileController controller) {
    if (_controllers.isEmpty) {
      PlayService.instance.playbackService.playerStateNotifier
          .addListener(_playerStateListener);
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
      PlayService.instance.playbackService.playerStateNotifier
          .removeListener(_playerStateListener);
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

  void _syncNativePosition() {
    _syncedPosition = PlayService.instance.playbackService.position;
    _lastNativeSyncMs = DateTime.now().millisecondsSinceEpoch;
    _positionClock
      ..reset()
      ..stop();
    if (_isPlaying) {
      _positionClock.start();
    }
  }

  void _syncProgressTicker() {
    if (_controllers.isEmpty || !_isPlaying) {
      _stopProgressTicker();
      return;
    }
    _progressTicker ??= Ticker(_tickProgress);
    if (_progressTicker!.isActive) return;
    _lastTickElapsed = Duration.zero;
    _progressTicker!.start();
  }

  void _stopProgressTicker() {
    _progressTicker?.stop();
    _lastTickElapsed = Duration.zero;
    _positionClock.stop();
  }

  void _tickProgress(Duration elapsed) {
    if (_controllers.isEmpty || !_isPlaying) {
      _syncProgressTicker();
      return;
    }
    final tickDelta = _lastTickElapsed == Duration.zero
        ? Duration.zero
        : elapsed - _lastTickElapsed;
    _lastTickElapsed = elapsed;
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
      PlayService.instance.playbackService.playerStateNotifier
          .removeListener(_playerStateListener);
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

  double sizeFactor = 0;
  double k = 1;
  late final bool _enableBreathing;
  bool _disposed = false;
  bool _isPlaying = false;

  LyricTransitionTileController(
      [this.lrcLine, this.syncLine, bool enableBreathing = true]) {
    _enableBreathing = enableBreathing;
    _TransitionControllerManager.instance.register(this);
  }

  void _advanceBreathing(double stepScale) {
    if (_disposed || !_enableBreathing || !_isPlaying || stepScale <= 0) {
      return;
    }
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
      notifyListeners();
      dispose();
      return;
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
    if (_disposed) return;
    _disposed = true;

    _TransitionControllerManager.instance.unregister(this);

    super.dispose();
  }
}
