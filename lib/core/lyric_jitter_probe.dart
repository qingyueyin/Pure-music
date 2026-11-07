import 'package:pure_music/core/perf_probe.dart';

/// 记录主歌词行每帧位置步长，用来区分时钟抖动和渲染抖动。
///
/// 只在 PerfProbe 开启时统计（debug/profile 默认开启），每 10 秒写一条
/// `lyric.jitter` 事件，不参与绘制逻辑。
class LyricJitterProbe {
  LyricJitterProbe._();

  static bool get enabled => PerfProbe.enabled;

  static double? _lastMs;
  static int _frames = 0;
  static int _backward = 0;
  static int _zero = 0;
  static double _maxStep = 0;
  static final List<double> _steps = <double>[];
  static int _windowStartMs = 0;

  static void sample(double nowMs) {
    if (!enabled) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_windowStartMs == 0) _windowStartMs = now;
    final last = _lastMs;
    _lastMs = nowMs;
    if (last == null) return;
    final step = nowMs - last;
    if (step < 0) {
      _backward++;
    } else if (step < 0.01) {
      _zero++;
    } else {
      _steps.add(step);
      if (step > _maxStep) _maxStep = step;
    }
    _frames++;
    if (now - _windowStartMs >= 10000) {
      _flush(now);
    }
  }

  static void _flush(int now) {
    if (_steps.isNotEmpty) {
      _steps.sort();
      PerfProbe.event('lyric.jitter', {
        'frames': _frames,
        'backward': _backward,
        'zero': _zero,
        'p50StepMs': _percentile(50),
        'p95StepMs': _percentile(95),
        'maxStepMs': _maxStep,
      });
    }
    _lastMs = null;
    _frames = 0;
    _backward = 0;
    _zero = 0;
    _maxStep = 0;
    _steps.clear();
    _windowStartMs = now;
  }

  static double _percentile(int percent) {
    final index = ((_steps.length - 1) * percent / 100).round();
    return _steps[index.clamp(0, _steps.length - 1)];
  }
}
