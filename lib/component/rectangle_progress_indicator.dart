import 'dart:async';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';

class RectangleProgressIndicator extends StatefulWidget {
  const RectangleProgressIndicator({
    super.key,
    required this.size,
    required this.child,
  });

  final Size size;
  final Widget child;

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

  @override
  void initState() {
    super.initState();
    playbackService.playerStateNotifier.addListener(_syncTimer);
    playbackService.nowPlayingNotifier.addListener(_syncNativeProgress);
    _syncNativeProgress();
    _syncTimer();
  }

  void _syncNativeProgress() {
    _syncedLength = playbackService.length;
    _syncedPosition = playbackService.position;
    _lastNativeSyncMs = _clock.elapsedMilliseconds;
    _emitProgressFromLocal();
  }

  void _emitProgressFromLocal() {
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      size: widget.size,
      painter: RectangleProgressPainter(progress: progress, scheme: scheme),
      child: widget.child,
    );
  }

  @override
  void dispose() {
    playbackService.playerStateNotifier.removeListener(_syncTimer);
    playbackService.nowPlayingNotifier.removeListener(_syncNativeProgress);
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
