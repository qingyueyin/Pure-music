import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';

/// 进度条拖拽的激活手势类型。
enum _DragGestureType { longPress, drag }

class _MouseThresholdHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  _MouseThresholdHorizontalDragGestureRecognizer({
    required this.mouseDragThreshold,
  });

  final double mouseDragThreshold;

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    if (pointerDeviceKind == PointerDeviceKind.mouse) {
      return globalDistanceMoved.abs() > mouseDragThreshold;
    }
    return super.hasSufficientGlobalDistanceToAccept(
      pointerDeviceKind,
      deviceTouchSlop,
    );
  }
}

/// 进度条拖拽状态机（纯逻辑，便于单元测试）。
///
/// 职责：判断拖拽是否可开始（空播放时不允许）、记录拖拽开始时的歌曲身份、
/// 结束拖拽时校验歌曲是否一致（不一致则不 seek）、切歌时取消拖拽。
class ProgressDragController {
  bool _dragging = false;
  String? _dragAudioIdentity;

  bool get isDragging => _dragging;

  /// 开始拖拽。返回 false 表示不可拖拽（如无正在播放）。
  bool begin({required String? audioIdentity}) {
    if (audioIdentity == null) return false;
    _dragging = true;
    _dragAudioIdentity = audioIdentity;
    return true;
  }

  /// 结束拖拽。返回 true 表示应执行 seek（确实在拖拽且歌曲一致）。
  bool end({required String? currentIdentity, required bool applySeek}) {
    final wasDragging = _dragging;
    final identity = _dragAudioIdentity;
    _dragging = false;
    _dragAudioIdentity = null;
    if (!wasDragging || !applySeek) return false;
    return identity != null && identity == currentIdentity;
  }

  /// 歌曲变化时取消拖拽。
  void cancelOnTrackChange() {
    _dragging = false;
    _dragAudioIdentity = null;
  }
}

class RectangleProgressIndicator extends StatefulWidget {
  const RectangleProgressIndicator({
    super.key,
    required this.size,
    required this.child,
    this.onSeek,
    this.onDragActiveChanged,
  });

  final Size size;
  final Widget child;

  /// 长按拖拽结束后回调（fraction 0-1，相对进度条宽度）。
  /// 为 null 时禁用拖拽交互。
  final ValueChanged<double>? onSeek;

  /// 拖拽激活状态变化回调（长按开始 true，结束/取消 false）。
  /// 外层可用它控制整个控件的缩放反馈。
  final ValueChanged<bool>? onDragActiveChanged;

  @override
  State<RectangleProgressIndicator> createState() =>
      _RectangleProgressIndicatorState();
}

class _RectangleProgressIndicatorState
    extends State<RectangleProgressIndicator> {
  final playbackService = PlayService.instance.playbackService;
  Timer? _progressTimer;
  final Stopwatch _clock = Stopwatch()..start();
  int _lastNativeSyncMs = 0;
  double _syncedPosition = 0.0;
  double _syncedLength = 1.0;
  static const _nativeSyncInterval = Duration(seconds: 1);

  /// position / length, [0, 1]
  final progress = ValueNotifier<double>(0);

  /// 长按拖拽中的预览进度（0-1），null 表示未拖拽。
  double? _dragFraction;

  /// 当前激活拖拽的手势类型（长按 or 拖动），避免竞技场失败方误结束拖拽。
  _DragGestureType? _activeDragGesture;

  final ProgressDragController _dragController = ProgressDragController();

  static const _longPressDuration = Duration(milliseconds: 250);
  static const _mouseDragThreshold = 12.0;

  @override
  void initState() {
    super.initState();
    playbackService.playerStateNotifier.addListener(_syncTimer);
    playbackService.nowPlayingNotifier.addListener(_onNowPlayingChanged);
    _syncNativeProgress();
    _syncTimer();
  }

  void _syncNativeProgress() {
    // 拖拽中冻结本地同步值，避免结束后进度跳回 seek 前的位置。
    if (_dragFraction != null) return;
    _syncedLength = playbackService.length;
    _syncedPosition = playbackService.position;
    _lastNativeSyncMs = _clock.elapsedMilliseconds;
    _emitProgressFromLocal();
  }

  void _emitProgressFromLocal() {
    if (_dragFraction != null) return;
    final elapsedMs = _clock.elapsedMilliseconds - _lastNativeSyncMs;
    final isPlaying =
        playbackService.playerStateNotifier.value == PlayerState.playing;
    final position =
        isPlaying ? _syncedPosition + elapsedMs / 1000.0 : _syncedPosition;
    progress.value =
        _syncedLength > 0 ? (position / _syncedLength).clamp(0.0, 1.0) : 0;
  }

  void _syncTimer() {
    _syncNativeProgress();
    final isPlaying =
        playbackService.playerStateNotifier.value == PlayerState.playing;
    if (!isPlaying) {
      _progressTimer?.cancel();
      _progressTimer = null;
      return;
    }
    _progressTimer ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      final elapsedSinceNative = _clock.elapsedMilliseconds - _lastNativeSyncMs;
      if (elapsedSinceNative >= _nativeSyncInterval.inMilliseconds) {
        _syncNativeProgress();
      } else {
        _emitProgressFromLocal();
      }
    });
  }

  /// 歌曲变化：拖拽中切歌则取消拖拽，随后同步新歌的真实进度。
  void _onNowPlayingChanged() {
    if (_dragFraction != null) {
      _dragFraction = null;
      _activeDragGesture = null;
      _dragController.cancelOnTrackChange();
      widget.onDragActiveChanged?.call(false);
    }
    _syncNativeProgress();
  }

  /// 开始拖拽：空播放时不允许，记录歌曲身份。
  void _beginDrag(double fraction) {
    if (_dragFraction != null) return;
    if (!_dragController.begin(
      audioIdentity: playbackService.nowPlaying?.path,
    )) {
      return;
    }
    _dragFraction = fraction.clamp(0.0, 1.0);
    progress.value = _dragFraction!;
    widget.onDragActiveChanged?.call(true);
  }

  void _handleLongPressStart(LongPressStartDetails d) {
    if (_activeDragGesture != null) return;
    _activeDragGesture = _DragGestureType.longPress;
    final width = widget.size.width;
    if (width <= 0) return;
    _beginDrag(d.localPosition.dx / width);
  }

  void _handleLongPressMove(LongPressMoveUpdateDetails d) {
    final width = widget.size.width;
    if (width <= 0 || _dragFraction == null) return;
    _dragFraction = (d.localPosition.dx / width).clamp(0.0, 1.0);
    progress.value = _dragFraction!;
  }

  void _handleLongPressEnd(LongPressEndDetails d) {
    if (_activeDragGesture != _DragGestureType.longPress) return;
    _endDrag(applySeek: true);
  }

  void _handleLongPressCancel() {
    if (_activeDragGesture != _DragGestureType.longPress) return;
    _endDrag(applySeek: false);
  }

  void _handleDragStart(DragStartDetails d) {
    if (_activeDragGesture != null) return;
    _activeDragGesture = _DragGestureType.drag;
    final width = widget.size.width;
    if (width <= 0) return;
    _beginDrag(d.localPosition.dx / width);
  }

  void _handleDragUpdate(DragUpdateDetails d) {
    if (_activeDragGesture != _DragGestureType.drag) return;
    final width = widget.size.width;
    if (width <= 0 || _dragFraction == null) return;
    _dragFraction = (d.localPosition.dx / width).clamp(0.0, 1.0);
    progress.value = _dragFraction!;
  }

  void _handleDragEnd(DragEndDetails d) {
    if (_activeDragGesture != _DragGestureType.drag) return;
    _endDrag(applySeek: true);
  }

  void _handleDragCancel() {
    if (_activeDragGesture != _DragGestureType.drag) return;
    _endDrag(applySeek: false);
  }

  void _endDrag({required bool applySeek}) {
    final fraction = _dragFraction;
    _dragFraction = null;
    _activeDragGesture = null;
    widget.onDragActiveChanged?.call(false);
    final shouldSeek = _dragController.end(
      currentIdentity: playbackService.nowPlaying?.path,
      applySeek: applySeek,
    );
    if (fraction == null || !shouldSeek) {
      // 取消拖拽或歌曲已变化：重新同步真实进度。
      _syncNativeProgress();
      return;
    }
    // 乐观更新本地同步值到目标位置，避免 seek 异步生效期间进度跳回旧值。
    _syncedPosition = fraction * _syncedLength;
    _lastNativeSyncMs = _clock.elapsedMilliseconds;
    progress.value = _syncedLength > 0 ? fraction.clamp(0.0, 1.0) : 0;
    widget.onSeek?.call(fraction);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasSeek = widget.onSeek != null;
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                duration: _longPressDuration,
              ),
              (instance) {
                instance
                  ..onLongPressStart = hasSeek ? _handleLongPressStart : null
                  ..onLongPressMoveUpdate =
                      hasSeek ? _handleLongPressMove : null
                  ..onLongPressEnd = hasSeek ? _handleLongPressEnd : null
                  ..onLongPressCancel =
                      hasSeek ? _handleLongPressCancel : null;
              },
            ),
        _MouseThresholdHorizontalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              _MouseThresholdHorizontalDragGestureRecognizer
            >(
              () => _MouseThresholdHorizontalDragGestureRecognizer(
                mouseDragThreshold: _mouseDragThreshold,
              ),
              (instance) {
                instance
                  ..onStart = hasSeek ? _handleDragStart : null
                  ..onUpdate = hasSeek ? _handleDragUpdate : null
                  ..onEnd = hasSeek ? _handleDragEnd : null
                  ..onCancel = hasSeek ? _handleDragCancel : null;
              },
            ),
      },
      child: CustomPaint(
        size: widget.size,
        painter: RectangleProgressPainter(progress: progress, scheme: scheme),
        child: widget.child,
      ),
    );
  }

  @override
  void dispose() {
    playbackService.playerStateNotifier.removeListener(_syncTimer);
    playbackService.nowPlayingNotifier.removeListener(_onNowPlayingChanged);
    _progressTimer?.cancel();
    progress.dispose();
    super.dispose();
  }
}

class RectangleProgressPainter extends CustomPainter {
  /// position / length, [0, 1]
  final ValueNotifier<double> progress;

  final ColorScheme scheme;
  final Paint _progressPainter = Paint();
  final Paint _trackPainter = Paint();

  RectangleProgressPainter({required this.progress, required this.scheme})
      : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    _progressPainter.color = scheme.secondaryContainer;
    _trackPainter.color = scheme.surfaceContainer;

    /// 进度条背景
    canvas.drawRect(
      Rect.fromLTWH(0.0, 0.0, size.width, size.height),
      _trackPainter,
    );

    /// 进度
    if (!progress.value.isNaN && !progress.value.isInfinite) {
      canvas.drawRect(
        Rect.fromLTWH(0.0, 0.0, size.width * progress.value, size.height),
        _progressPainter,
      );
    }
  }

  @override
  bool shouldRepaint(RectangleProgressPainter oldDelegate) => false;

  @override
  bool shouldRebuildSemantics(RectangleProgressPainter oldDelegate) => false;
}
