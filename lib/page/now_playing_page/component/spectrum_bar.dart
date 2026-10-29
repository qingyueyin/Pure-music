import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/playback_service.dart';
import 'package:pure_music/core/window_render_gate.dart';

@visibleForTesting
void clearSpectrumFrameForTesting(Float32List values) {
  values.fillRange(0, values.length, 0.0);
}

/// 播放页进度条上方的柱状频谱条。
///
/// 数据来自 [PlaybackService.spectrumDisplayStream]（约 15~120Hz），
/// 组件内部按屏幕帧率做帧间插值；绘制单独放在一个重绘岛里，不牵动页面其它部分。
class SpectrumBar extends StatefulWidget {
  const SpectrumBar({super.key, required this.color, this.height = 16.0});

  /// 柱条基准色（跟随播放页底部控件前景色）。
  final Color color;

  final double height;

  @override
  State<SpectrumBar> createState() => _SpectrumBarState();
}

class _SpectrumBarState extends State<SpectrumBar>
    with SingleTickerProviderStateMixin {
  static const _lerpDurationMs = 110.0;
  static const _maxStepSeconds = 0.1;
  static const _settleEpsilon = 0.004;
  // 插值按 30fps 刷新即可，避免 144Hz 屏上白跑 4 倍绘制
  static const _paintInterval = Duration(milliseconds: 33);

  late final PlaybackService _playback;
  StreamSubscription<Float32List>? _subscription;
  final _repaint = _RepaintTick();
  final _frame = _SpectrumFrame();
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  Duration? _lastPaint;

  Float32List _from = Float32List(0);
  Float32List _to = Float32List(0);
  double _t = 1.0;
  bool _reduceMotion = false;
  bool _windowFramesEnabled = true;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackService>();
    _windowFramesEnabled = WindowRenderGate.instance.framesEnabled.value;
    WindowRenderGate.instance.framesEnabled.addListener(_onWindowFramesChanged);
    _syncSpectrumSubscription();
    _playback.playerStateNotifier.addListener(_onPlayerStateChanged);
  }

  void _onWindowFramesChanged() {
    if (!mounted) return;
    _windowFramesEnabled = WindowRenderGate.instance.framesEnabled.value;
    if (!_windowFramesEnabled) {
      _subscription?.cancel();
      _subscription = null;
      _ticker?.stop();
      _lastTick = Duration.zero;
      _lastPaint = null;
      _clearFrameToBaseline();
      return;
    }
    _syncSpectrumSubscription();
  }

  void _syncSpectrumSubscription() {
    final shouldListen = _windowFramesEnabled && !_reduceMotion;
    if (shouldListen) {
      _subscription ??= _playback.spectrumDisplayStream.listen(_onData);
      return;
    }
    _subscription?.cancel();
    _subscription = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      if (reduce) {
        _ticker?.stop();
        _lastTick = Duration.zero;
        _lastPaint = null;
        _clearFrameToBaseline();
      }
      _syncSpectrumSubscription();
    }
  }

  @override
  void dispose() {
    WindowRenderGate.instance.framesEnabled.removeListener(
      _onWindowFramesChanged,
    );
    _playback.playerStateNotifier.removeListener(_onPlayerStateChanged);
    _subscription?.cancel();
    _ticker?.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _onData(Float32List data) {
    if (!mounted || !_windowFramesEnabled || data.isEmpty) return;
    if (_frame.values.length != data.length) {
      _frame.values = Float32List(data.length);
      _from = Float32List(data.length);
      _to = Float32List(data.length);
      _frame.values.setAll(0, data);
      _repaint.bump();
      return;
    }
    if (_reduceMotion) {
      _frame.values.setAll(0, data);
      _repaint.bump();
      return;
    }
    _from.setAll(0, _frame.values);
    _to.setAll(0, data);
    _t = 0.0;
    _ensureTicker();
  }

  void _onPlayerStateChanged() {
    if (!mounted) return;
    if (_playback.playerStateNotifier.value == PlayerState.playing) return;
    // 暂停/停止后把柱条收回到基线
    var alreadyIdle = true;
    for (var i = 0; i < _frame.values.length; i++) {
      if (_frame.values[i] > _settleEpsilon) {
        alreadyIdle = false;
        break;
      }
    }
    if (alreadyIdle) return;
    if (_reduceMotion) {
      _clearFrameToBaseline();
      return;
    }
    _from.setAll(0, _frame.values);
    _to.fillRange(0, _to.length, 0.0);
    _t = 0.0;
    _ensureTicker();
  }

  void _clearFrameToBaseline() {
    if (_frame.values.isEmpty) return;
    clearSpectrumFrameForTesting(_frame.values);
    if (_from.length == _frame.values.length) {
      clearSpectrumFrameForTesting(_from);
    }
    if (_to.length == _frame.values.length) {
      clearSpectrumFrameForTesting(_to);
    }
    _t = 1.0;
    _repaint.bump();
  }

  void _ensureTicker() {
    final ticker = _ticker ??= createTicker(_onTick);
    if (!ticker.isActive) {
      _lastTick = Duration.zero;
      _lastPaint = null;
      ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final lastPaint = _lastPaint;
    if (lastPaint != null && elapsed - lastPaint < _paintInterval) return;
    _lastPaint = elapsed;
    var dtSeconds = _lastTick == Duration.zero
        ? 0.016
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dtSeconds > _maxStepSeconds) dtSeconds = _maxStepSeconds;
    _t = (_t + dtSeconds * 1000.0 / _lerpDurationMs).clamp(0.0, 1.0).toDouble();

    for (var i = 0; i < _frame.values.length; i++) {
      _frame.values[i] = _from[i] + (_to[i] - _from[i]) * _t;
    }
    _repaint.bump();

    if (_t >= 1.0) {
      var settled = true;
      for (var i = 0; i < _frame.values.length; i++) {
        if ((_frame.values[i] - _to[i]).abs() > _settleEpsilon) {
          settled = false;
          break;
        }
      }
      if (settled) {
        _frame.values.setAll(0, _to);
        _repaint.bump();
        _ticker?.stop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          painter: _SpectrumBarsPainter(
            frame: _frame,
            color: widget.color,
            repaint: _repaint,
          ),
        ),
      ),
    );
  }
}

/// 每帧一次的重绘通知（内容本身无意义）。
class _RepaintTick extends ChangeNotifier {
  void bump() => notifyListeners();
}

/// 画笔一直拿着这个对象，里面的数组可以换，不会画到旧的空数据上。
class _SpectrumFrame {
  Float32List values = Float32List(0);
}

class _SpectrumBarsPainter extends CustomPainter {
  _SpectrumBarsPainter({
    required this.frame,
    required this.color,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final _SpectrumFrame frame;
  final Color color;

  static const _maxBarWidth = 8.0;
  static const _widthRatio = 0.58;
  static const _minBar = 3.5;
  static const _visualGain = 1.25;
  static const _visualCurve = 0.9;
  static const _minAlpha = 0.3;
  static const _maxAlpha = 0.68;

  final Paint _barPaint = Paint()..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    final values = frame.values;
    if (values.isEmpty || size.width <= 0 || size.height <= 0) return;
    final count = values.length;
    final slot = size.width / count;
    final stretched = slot * _widthRatio;
    final barWidth = stretched > _maxBarWidth ? _maxBarWidth : stretched;
    if (barWidth <= 0.4) return;
    final maxHeight = size.height;
    if (maxHeight <= _minBar) return;
    final radius = Radius.circular(barWidth > 4.0 ? 2.0 : barWidth / 2);
    final inset = (slot - barWidth) / 2;
    for (var i = 0; i < count; i++) {
      final rawValue = values[i].clamp(0.0, 1.0).toDouble();
      final value = (math.pow(rawValue, _visualCurve).toDouble() * _visualGain)
          .clamp(0.0, 1.0)
          .toDouble();
      final barHeight = _minBar + (maxHeight - _minBar) * value;
      _barPaint.color = color.withValues(
        alpha: _minAlpha + (_maxAlpha - _minAlpha) * value,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            i * slot + inset,
            size.height - barHeight,
            barWidth,
            barHeight,
          ),
          radius,
        ),
        _barPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumBarsPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.frame.values.length != frame.values.length;
}
