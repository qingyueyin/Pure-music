import 'package:pure_player_lyric/component/foreground.dart';
import 'package:pure_player_lyric/message.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

double desktopLyricHighlightTimeMs({
  required double progressMs,
  required double lastWordEndMs,
  required double? deadlineMs,
  double catchUpDurationMs = 260.0,
  double finishLeadMs = 32.0,
}) {
  if (deadlineMs == null || deadlineMs <= 0) return progressMs;
  if (lastWordEndMs <= deadlineMs - finishLeadMs ||
      progressMs < deadlineMs - catchUpDurationMs) {
    return progressMs;
  }
  final catchUpStart = deadlineMs - catchUpDurationMs;
  final catchUpEnd = deadlineMs - finishLeadMs;
  final t = ((progressMs - catchUpStart) / (catchUpEnd - catchUpStart)).clamp(
    0.0,
    1.0,
  );
  final eased = Curves.easeIn.transform(t);
  final targetEnd = lastWordEndMs > deadlineMs ? lastWordEndMs : deadlineMs;
  return progressMs + (targetEnd - progressMs) * eased;
}

Color applyLyricOpacity(Color color, double alpha) {
  return color.withValues(alpha: color.a * alpha);
}

class WordLyricText extends StatefulWidget {
  final LyricLineChangedMessage line;
  final Color color;
  final Color playedColor;
  final double fontSize;
  final int fontWeight;
  final TextAlign textAlign;
  final ValueListenable<bool> isPlaying;
  final ValueListenable<LyricProgressChangedMessage> progress;
  final double alpha;
  final bool enableOutline;
  final Color outlineColor;

  const WordLyricText({
    super.key,
    required this.line,
    required this.color,
    required this.playedColor,
    required this.fontSize,
    required this.fontWeight,
    required this.textAlign,
    required this.isPlaying,
    required this.progress,
    this.alpha = 1.0,
    this.enableOutline = true,
    this.outlineColor = Colors.black,
  });

  @override
  State<WordLyricText> createState() => _WordLyricTextState();
}

class _WordLyricTextState extends State<WordLyricText>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final Stopwatch _stopwatch = Stopwatch();
  final ValueNotifier<int> _progressMs = ValueNotifier(0);

  List<_CharInfo> _chars = const [];
  double _totalWidth = 0;
  double _totalHeight = 0;
  double _baseProgressMs = 0;
  double _playbackRate = 1.0;

  late VoidCallback _playingListener;
  late VoidCallback _progressListener;

  /// 字符宽度缓存
  static final Map<String, _CharMeasurement> _charWidthCache = {};
  static const int _maxCacheSize = 200;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _playingListener = _syncPlaying;
    _progressListener = _applyProgressSnapshot;
    widget.isPlaying.addListener(_playingListener);
    widget.progress.addListener(_progressListener);
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
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_progressListener);
      _progressListener = _applyProgressSnapshot;
      widget.progress.addListener(_progressListener);
    }

    final contentChanged =
        oldWidget.line.content != widget.line.content ||
        oldWidget.line.translation != widget.line.translation ||
        oldWidget.line.romanLyric != widget.line.romanLyric ||
        oldWidget.line.length != widget.line.length ||
        !_sameWords(oldWidget.line.words, widget.line.words);
    final propsChanged =
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.fontWeight != widget.fontWeight ||
        oldWidget.color != widget.color ||
        oldWidget.playedColor != widget.playedColor;

    if (contentChanged) {
      _resetFromLine(widget.line);
      _syncPlaying();
    } else if (propsChanged) {
      _rebuildLayout();
    } else if (oldWidget.progress != widget.progress) {
      _applyProgressSnapshot();
    }
  }

  bool _sameWords(List<LyricWord>? a, List<LyricWord>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].startMs != b[i].startMs ||
          a[i].lengthMs != b[i].lengthMs ||
          a[i].content != b[i].content) {
        return false;
      }
    }
    return true;
  }

  /// 测量并构建字符布局。桌面歌词收到的 words.startMs 已是相对行开始的时间，
  /// 直接使用，不再做绝对/相对时间猜测。
  void _buildLayout() {
    final words = widget.line.words ?? const [];
    final fontSize = widget.fontSize;

    final chars = <_CharInfo>[];
    final measureTp = _TextPainterPool.obtain();
    double x = 0;
    double maxH = 0;

    for (int wi = 0; wi < words.length; wi++) {
      final w = words[wi];
      final wordStartMs = w.startMs;
      final wordLengthMs = w.lengthMs;

      for (final rune in w.content.runes) {
        final char = String.fromCharCode(rune);
        final cacheKey = '$char|$fontSize|${widget.fontWeight}';
        final cached = _charWidthCache[cacheKey];
        final measurement = cached ?? _measureChar(measureTp, char, cacheKey);
        final charWidth = measurement.width;

        if (maxH < measurement.height) maxH = measurement.height;

        chars.add(
          _CharInfo(
            char: char,
            x: x,
            width: charWidth,
            wordIndex: wi,
            wordStartMs: wordStartMs,
            wordLengthMs: wordLengthMs,
          ),
        );

        x += charWidth;
      }
      x += fontSize * 0.12;
    }

    _chars = chars;
    _totalWidth = x;
    _totalHeight = maxH;
    _TextPainterPool.recycle(measureTp);
  }

  _CharMeasurement _measureChar(TextPainter tp, String char, String cacheKey) {
    tp.text = TextSpan(
      text: char,
      style: TextStyle(
        fontSize: widget.fontSize,
        fontWeight: lyricFontWeightFromInt(widget.fontWeight),
      ),
    );
    tp.layout();
    final measurement = _CharMeasurement(tp.width, tp.height);
    if (_charWidthCache.length >= _maxCacheSize) {
      _charWidthCache.remove(_charWidthCache.keys.first);
    }
    _charWidthCache[cacheKey] = measurement;
    return measurement;
  }

  void _resetFromLine(LyricLineChangedMessage line) {
    _buildLayout();
    _applyProgressSnapshot();
  }

  void _rebuildLayout() {
    _buildLayout();
  }

  double _currentProgressMs() {
    final elapsed = _stopwatch.elapsedMilliseconds * _playbackRate;
    return _baseProgressMs + elapsed;
  }

  bool _matchesLine(LyricProgressChangedMessage snapshot) {
    final lineId = widget.line.lineId;
    return lineId == null ||
        snapshot.lineId == null ||
        snapshot.lineId == lineId;
  }

  int _highlightProgressMs(double progressMs) {
    final words = widget.line.words;
    if (words == null || words.isEmpty) return progressMs.round();
    final lastWord = words.last;
    return desktopLyricHighlightTimeMs(
      progressMs: progressMs,
      lastWordEndMs: (lastWord.startMs + lastWord.lengthMs).toDouble(),
      deadlineMs: widget.line.highlightDeadlineMs?.toDouble(),
      catchUpDurationMs:
          widget.line.highlightCatchUpDurationMs?.toDouble() ?? 260.0,
      finishLeadMs: widget.line.highlightFinishLeadMs?.toDouble() ?? 32.0,
    ).round();
  }

  void _applyProgressSnapshot() {
    final snapshot = widget.progress.value;
    if (!_matchesLine(snapshot)) {
      if (_stopwatch.isRunning) _stopwatch.stop();
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    if (!snapshot.playing && _stopwatch.isRunning) {
      _stopwatch.stop();
      _stopwatch.reset();
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final transitMs = snapshot.playing
        ? (nowMs - snapshot.sampledAtMs).clamp(0, 60000) * snapshot.playbackRate
        : 0.0;
    final maxProgress = widget.line.length.inMilliseconds.toDouble();
    final target = (snapshot.progressMs + transitMs)
        .clamp(-60000.0, maxProgress)
        .toDouble();
    _stopwatch.reset();
    _baseProgressMs = target;
    _playbackRate = snapshot.playbackRate > 0 ? snapshot.playbackRate : 1.0;
    _progressMs.value = _highlightProgressMs(target);
    _syncPlaying();
  }

  void _syncPlaying() {
    final progress = widget.progress.value;
    final playing =
        widget.isPlaying.value && progress.playing && _matchesLine(progress);
    if (playing) {
      if (!_ticker.isActive) _ticker.start();
      if (!_stopwatch.isRunning) _stopwatch.start();
    } else {
      if (_stopwatch.isRunning) {
        _stopwatch.stop();
        _baseProgressMs = _currentProgressMs();
        _stopwatch.reset();
        _progressMs.value = _highlightProgressMs(_baseProgressMs);
      }
      if (_ticker.isActive) _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (!_stopwatch.isRunning) return;
    final rawProgress = _currentProgressMs()
        .clamp(-60000.0, widget.line.length.inMilliseconds.toDouble())
        .toDouble();
    final next = _highlightProgressMs(rawProgress);
    if (next == _progressMs.value) return;
    _progressMs.value = next;
  }

  @override
  void dispose() {
    widget.isPlaying.removeListener(_playingListener);
    widget.progress.removeListener(_progressListener);
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
        if (_chars.isEmpty) {
          return const SizedBox.shrink();
        }

        return SizedBox(
          width: _totalWidth,
          height: _totalHeight,
          child: CustomPaint(
            painter: _WordLyricPainter(
              chars: _chars,
              progressMs: progress,
              textAlign: widget.textAlign,
              textColor: widget.color,
              playedColor: widget.playedColor,
              alpha: widget.alpha,
              enableOutline: widget.enableOutline,
              outlineColor: widget.outlineColor,
              fontSize: widget.fontSize,
              fontWeight: lyricFontWeightFromInt(widget.fontWeight),
              totalWidth: _totalWidth,
            ),
          ),
        );
      },
    );
  }
}

class _CharInfo {
  final String char;
  final double x;
  final double width;
  final int wordIndex;
  final int wordStartMs;
  final int wordLengthMs;

  const _CharInfo({
    required this.char,
    required this.x,
    required this.width,
    required this.wordIndex,
    required this.wordStartMs,
    required this.wordLengthMs,
  });

  int get wordEndMs => wordStartMs + wordLengthMs;
}

class _CharMeasurement {
  final double width;
  final double height;

  const _CharMeasurement(this.width, this.height);
}

/// 轻量 TextPainter 对象池，避免 paint 时频繁创建/销毁。
class _TextPainterPool {
  static final List<TextPainter> _pool = [];
  static const int _maxSize = 8;

  static TextPainter obtain() {
    if (_pool.isNotEmpty) {
      final tp = _pool.removeLast();
      tp.text = null;
      return tp;
    }
    return TextPainter(textDirection: TextDirection.ltr);
  }

  static void recycle(TextPainter tp) {
    if (_pool.length < _maxSize) {
      tp.text = null;
      _pool.add(tp);
    } else {
      tp.dispose();
    }
  }
}

class _WordLyricPainter extends CustomPainter {
  final List<_CharInfo> chars;
  final int progressMs;
  final TextAlign textAlign;
  final Color textColor;
  final Color playedColor;
  final double alpha;
  final bool enableOutline;
  final Color outlineColor;
  final double fontSize;
  final FontWeight fontWeight;
  final double totalWidth;

  const _WordLyricPainter({
    required this.chars,
    required this.progressMs,
    required this.textAlign,
    required this.textColor,
    required this.playedColor,
    required this.alpha,
    required this.enableOutline,
    required this.outlineColor,
    required this.fontSize,
    required this.fontWeight,
    required this.totalWidth,
  });

  double _wordProgress(int startMs, int lengthMs) {
    if (progressMs < startMs) return 0.0;
    final endMs = startMs + lengthMs;
    if (progressMs >= endMs) return 1.0;
    if (lengthMs <= 0) return 1.0;
    return (progressMs - startMs) / lengthMs;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (chars.isEmpty) return;

    final startX = switch (textAlign) {
      TextAlign.left || TextAlign.start => 0.0,
      TextAlign.center => (size.width - totalWidth) / 2,
      TextAlign.right || TextAlign.end => size.width - totalWidth,
      _ => 0.0,
    };

    // 计算扫光右边界：逐个字符累加，做到逐字高亮
    double sweepX = startX;
    for (var i = 0; i < chars.length;) {
      final c = chars[i];
      final wp = _wordProgress(c.wordStartMs, c.wordLengthMs);
      var wordEndIndex = i;
      while (wordEndIndex + 1 < chars.length &&
          chars[wordEndIndex + 1].wordIndex == c.wordIndex) {
        wordEndIndex++;
      }
      final wordEnd = chars[wordEndIndex];
      if (wp >= 1.0) {
        sweepX = startX + wordEnd.x + wordEnd.width;
        i = wordEndIndex + 1;
      } else if (wp > 0) {
        final wordWidth = wordEnd.x + wordEnd.width - c.x;
        sweepX = startX + c.x + wordWidth * wp;
        break;
      } else {
        break;
      }
    }

    final dimColor = applyLyricOpacity(textColor, alpha);
    final brightColor = playedColor.withValues(alpha: alpha);
    final dimOutline = applyLyricOpacity(outlineColor, alpha);
    final brightOutline = applyLyricOpacity(outlineColor, alpha);
    final outlineW = lyricOutlineWidth(fontSize);

    final dimFillStyle = TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: dimColor,
    );
    final dimStrokeStyle = TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = outlineW
        ..color = dimOutline,
    );
    final brightFillStyle = TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: brightColor,
    );
    final brightStrokeStyle = TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = outlineW
        ..color = brightOutline,
    );

    final tp = _TextPainterPool.obtain();

    // Pass 1: 暗淡层
    _paintLayer(canvas, tp, chars, startX, dimFillStyle, dimStrokeStyle);

    // Pass 2: 已播放亮色层，clip 到扫光区域
    if (sweepX > startX) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(startX, -1, sweepX + 1, size.height + 1));
      _paintLayer(
        canvas,
        tp,
        chars,
        startX,
        brightFillStyle,
        brightStrokeStyle,
      );
      canvas.restore();
    }

    _TextPainterPool.recycle(tp);
  }

  void _paintLayer(
    Canvas canvas,
    TextPainter tp,
    List<_CharInfo> chars,
    double startX,
    TextStyle fillStyle,
    TextStyle strokeStyle,
  ) {
    if (enableOutline) {
      for (final c in chars) {
        tp.text = TextSpan(text: c.char, style: strokeStyle);
        tp.layout();
        tp.paint(canvas, Offset(startX + c.x, 0));
      }
    }
    for (final c in chars) {
      tp.text = TextSpan(text: c.char, style: fillStyle);
      tp.layout();
      tp.paint(canvas, Offset(startX + c.x, 0));
    }
  }

  @override
  bool shouldRepaint(covariant _WordLyricPainter oldDelegate) {
    return oldDelegate.progressMs != progressMs ||
        oldDelegate.chars.length != chars.length ||
        oldDelegate.textAlign != textAlign ||
        oldDelegate.textColor != textColor ||
        oldDelegate.playedColor != playedColor ||
        oldDelegate.enableOutline != enableOutline ||
        oldDelegate.outlineColor != outlineColor ||
        oldDelegate.alpha != alpha;
  }
}
