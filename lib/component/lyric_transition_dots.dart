import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class LyricTransitionDots extends StatefulWidget {
  final Duration length;
  final int? progressMs;
  final Color color;
  final ValueListenable<bool> isPlaying;

  const LyricTransitionDots({
    super.key,
    required this.length,
    required this.progressMs,
    required this.color,
    required this.isPlaying,
  });

  @override
  State<LyricTransitionDots> createState() => _LyricTransitionDotsState();
}

class _LyricTransitionDotsState extends State<LyricTransitionDots>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final Stopwatch _stopwatch = Stopwatch();
  final ValueNotifier<double> _progress = ValueNotifier(0);
  double _sizeFactor = 0;
  int _baseProgressMs = 0;
  late VoidCallback _playingListener;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _baseProgressMs = widget.progressMs ?? 0;
    _playingListener = _syncPlaying;
    widget.isPlaying.addListener(_playingListener);
    _syncPlaying();
  }

  @override
  void didUpdateWidget(covariant LyricTransitionDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      oldWidget.isPlaying.removeListener(_playingListener);
      _playingListener = _syncPlaying;
      widget.isPlaying.addListener(_playingListener);
    }
    if (oldWidget.progressMs != widget.progressMs ||
        oldWidget.length != widget.length) {
      _stopwatch.reset();
      _baseProgressMs = widget.progressMs ?? 0;
      _syncPlaying();
    }
  }

  void _syncPlaying() {
    final playing = widget.isPlaying.value;
    if (playing) {
      if (!_ticker.isActive) _ticker.start();
      if (!_stopwatch.isRunning) _stopwatch.start();
    } else {
      if (_stopwatch.isRunning) {
        _stopwatch.stop();
        _baseProgressMs += _stopwatch.elapsedMilliseconds;
        _stopwatch.reset();
      }
      if (_ticker.isActive) _ticker.stop();
      _progress.value = 0;
    }
  }

  void _onTick(Duration elapsed) {
    // Smooth sinusoidal breathing (~6s per cycle, matching main player behavior)
    final t = (_baseProgressMs + _stopwatch.elapsedMilliseconds) / 1000.0;
    _sizeFactor = (sin(t * pi / 3) + 1) / 2;

    final lenMs = widget.length.inMilliseconds;
    final posMs = _baseProgressMs + _stopwatch.elapsedMilliseconds;
    final p = lenMs <= 0 ? 0.0 : ((posMs % lenMs) / lenMs);
    _progress.value = p;
  }

  @override
  void dispose() {
    widget.isPlaying.removeListener(_playingListener);
    _ticker.dispose();
    _stopwatch.stop();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: _progress,
        builder: (context, p, _) => SizedBox(
          height: 40.0,
          width: 80.0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 18, 12, 6),
            child: CustomPaint(
              painter: _LyricTransitionPainter(
                progress: p,
                sizeFactor: _sizeFactor,
                color: widget.color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LyricTransitionPainter extends CustomPainter {
  final double progress;
  final double sizeFactor;
  final Color color;

  final Paint circlePaint1 = Paint();
  final Paint circlePaint2 = Paint();
  final Paint circlePaint3 = Paint();

  final double radius = 6;

  _LyricTransitionPainter({
    required this.progress,
    required this.sizeFactor,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    circlePaint1.color = color.withValues(alpha: 0.05 + min(progress * 3, 1) * 0.95);
    circlePaint2.color =
        color.withValues(alpha: 0.05 + min(max(progress - 1 / 3, 0) * 3, 1) * 0.95);
    circlePaint3.color =
        color.withValues(alpha: 0.05 + min(max(progress - 2 / 3, 0) * 3, 1) * 0.95);

    final rWithFactor = radius + sizeFactor;
    final c1 = Offset(rWithFactor, 8);
    final c2 = Offset(4 * rWithFactor, 8);
    final c3 = Offset(7 * rWithFactor, 8);

    canvas.drawCircle(c1, rWithFactor, circlePaint1);
    canvas.drawCircle(c2, rWithFactor, circlePaint2);
    canvas.drawCircle(c3, rWithFactor, circlePaint3);
  }

  @override
  bool shouldRepaint(covariant _LyricTransitionPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.sizeFactor != sizeFactor ||
        oldDelegate.color != color;
  }
}

