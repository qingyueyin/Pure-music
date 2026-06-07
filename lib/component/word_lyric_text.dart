import 'dart:math';

import 'package:desktop_lyric/component/foreground.dart';
import 'package:desktop_lyric/message.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class WordLyricText extends StatefulWidget {
  final LyricLineChangedMessage line;
  final Color color;
  final double fontSize;
  final int fontWeight;
  final TextAlign textAlign;
  final ValueListenable<bool> isPlaying;
  final double alpha;

  const WordLyricText({
    super.key,
    required this.line,
    required this.color,
    required this.fontSize,
    required this.fontWeight,
    required this.textAlign,
    required this.isPlaying,
    this.alpha = 1.0,
  });

  @override
  State<WordLyricText> createState() => _WordLyricTextState();
}

class _WordLyricTextState extends State<WordLyricText>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final Stopwatch _stopwatch = Stopwatch();
  final ValueNotifier<int> _progressMs = ValueNotifier(0);

  List<_WordLayout> _layouts = const [];
  double _textWidth = 0;
  double _textHeight = 0;
  int _baseProgressMs = 0;

  late VoidCallback _playingListener;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _playingListener = _syncPlaying;
    widget.isPlaying.addListener(_playingListener);
    _resetFromLine(widget.line);
    _syncPlaying();
  }

  @override
  void didUpdateWidget(covariant WordLyricText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      oldWidget.isPlaying.removeListener(_playingListener);
      _playingListener = _syncPlaying;
      widget.isPlaying.addListener(_playingListener);
    }

    final contentChanged =
        oldWidget.line.content != widget.line.content ||
        oldWidget.line.translation != widget.line.translation ||
        oldWidget.line.words != widget.line.words;
    final progressChanged = oldWidget.line.progressMs != widget.line.progressMs;
    final propsChanged =
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.fontWeight != widget.fontWeight ||
        oldWidget.color != widget.color;

    if (contentChanged || propsChanged) {
      // Content/props changed → full layout rebuild
      _resetFromLine(widget.line);
      _syncPlaying();
    } else if (progressChanged) {
      // Only progress changed → recalibrate without layout rebuild
      _stopwatch.reset();
      _baseProgressMs = widget.line.progressMs ?? 0;
      _progressMs.value = _baseProgressMs;
      _syncPlaying();
    }
  }

  void _resetFromLine(LyricLineChangedMessage line) {
    _stopwatch.reset();
    _baseProgressMs = line.progressMs ?? 0;
    _progressMs.value = _baseProgressMs;
    final words = line.words ?? const [];

    // Detect if startMs is absolute time (>> progressMs) and convert to relative
    final firstWordStartMs = words.isNotEmpty ? words[0].startMs : 0;
    final isAbsoluteTime = firstWordStartMs > _baseProgressMs * 10;
    final timeOffset = isAbsoluteTime ? firstWordStartMs : 0;

    final fontWeight = lyricFontWeightFromInt(widget.fontWeight);
    final outlineWidth = lyricOutlineWidth(widget.fontSize);

    final layouts = <_WordLayout>[];
    double x = 0;
    double maxH = 0;
    for (final w in words) {
      final baseSpan = TextSpan(
        text: w.content,
        style: TextStyle(
          fontSize: widget.fontSize,
          fontWeight: fontWeight,
          color: widget.color.withValues(alpha: 0.22 * widget.alpha),
        ),
      );
      final activeSpan = TextSpan(
        text: w.content,
        style: TextStyle(
          fontSize: widget.fontSize,
          fontWeight: fontWeight,
          color: widget.color.withValues(alpha: widget.alpha),
        ),
      );

      final basePainter = TextPainter(
        text: baseSpan,
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
        maxLines: 1,
      )..layout();
      final activePainter = TextPainter(
        text: activeSpan,
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
        maxLines: 1,
      )..layout();

      final strokePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = outlineWidth
        ..color = lyricOutlineColor(widget.color);
      final outlinePainter = TextPainter(
        text: TextSpan(
          text: w.content,
          style: TextStyle(
            fontSize: widget.fontSize,
            fontWeight: fontWeight,
            foreground: strokePaint,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
        maxLines: 1,
      )..layout();

      final width = max(
        basePainter.width,
        max(activePainter.width, outlinePainter.width),
      );
      final height = max(
        basePainter.height,
        max(activePainter.height, outlinePainter.height),
      );
      maxH = max(maxH, height);

      layouts.add(
        _WordLayout(
          startMs: w.startMs - timeOffset,
          lengthMs: w.lengthMs,
          x: x,
          width: width,
          height: height,
          outline: outlinePainter,
          inactive: basePainter,
          active: activePainter,
        ),
      );
      x += width;
    }

    _layouts = layouts;
    _textWidth = x;
    _textHeight = maxH;
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
        _progressMs.value = _baseProgressMs;
      }
      if (_ticker.isActive) _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (!_stopwatch.isRunning) return;
    final next = _baseProgressMs + _stopwatch.elapsedMilliseconds;
    if (next == _progressMs.value) return;
    _progressMs.value = next;
  }

  @override
  void dispose() {
    widget.isPlaying.removeListener(_playingListener);
    _ticker.dispose();
    _stopwatch.stop();
    _progressMs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _progressMs,
      builder: (context, progress, _) {
        if (_layouts.isEmpty) {
          return const SizedBox.shrink();
        }

        return SizedBox(
          width: _textWidth,
          height: _textHeight,
          child: CustomPaint(
            painter: _WordLyricPainter(
              layouts: _layouts,
              progressMs: progress,
              textAlign: widget.textAlign,
              textColor: widget.color,
              alpha: widget.alpha,
            ),
          ),
        );
      },
    );
  }
}

class _WordLyricPainter extends CustomPainter {
  final List<_WordLayout> layouts;
  final int progressMs;
  final TextAlign textAlign;
  final Color textColor;
  final double alpha;

  _WordLyricPainter({
    required this.layouts,
    required this.progressMs,
    required this.textAlign,
    required this.textColor,
    required this.alpha,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (layouts.isEmpty) return;
    final totalW = layouts.last.x + layouts.last.width;
    final startX = switch (textAlign) {
      TextAlign.left || TextAlign.start => 0.0,
      TextAlign.center => (size.width - totalW) / 2,
      TextAlign.right || TextAlign.end => size.width - totalW,
      _ => 0.0,
    };

    // Calculate current word index and progress
    int currentWordIndex = -1;
    double wordProgress = 0.0;

    for (int i = 0; i < layouts.length; i++) {
      final w = layouts[i];
      final wordStart = w.startMs;
      final wordEnd = w.startMs + w.lengthMs;

      if (progressMs >= wordStart && progressMs < wordEnd) {
        currentWordIndex = i;
        wordProgress = w.lengthMs > 0
            ? (progressMs - wordStart) / w.lengthMs
            : 0.0;
        break;
      } else if (progressMs >= wordEnd) {
        currentWordIndex = i;
        wordProgress = 1.0;
      }
    }

    for (int i = 0; i < layouts.length; i++) {
      final w = layouts[i];
      final dx = startX + w.x;
      final dy = 0.0;
      final offset = Offset(dx, dy);

      if (i == currentWordIndex && wordProgress > 0) {
        // Draw outline
        w.outline.paint(canvas, offset);

        // Draw inactive (dim) text as base
        w.inactive.paint(canvas, offset);

        // Clip to the "sung" portion and draw active text over it.
        // This avoids the expensive saveLayer used by the old ShaderMask approach.
        final clipWidth = (w.width * wordProgress).clamp(0.0, w.width);
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(dx, dy, clipWidth, w.height));
        w.active.paint(canvas, offset);
        canvas.restore();
      } else if (i < currentWordIndex) {
        // Already passed words - fully highlighted
        w.outline.paint(canvas, offset);
        w.active.paint(canvas, offset);
      } else {
        // Not yet reached words - inactive
        w.outline.paint(canvas, offset);
        w.inactive.paint(canvas, offset);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WordLyricPainter oldDelegate) {
    return oldDelegate.progressMs != progressMs ||
        oldDelegate.layouts != layouts ||
        oldDelegate.textAlign != textAlign;
  }
}

class _WordLayout {
  final int startMs;
  final int lengthMs;
  final double x;
  final double width;
  final double height;
  final TextPainter outline;
  final TextPainter inactive;
  final TextPainter active;

  const _WordLayout({
    required this.startMs,
    required this.lengthMs,
    required this.x,
    required this.width,
    required this.height,
    required this.outline,
    required this.inactive,
    required this.active,
  });
}
