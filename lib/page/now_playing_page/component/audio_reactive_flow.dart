import 'dart:math' as math;

import 'package:flutter/foundation.dart';

@immutable
final class AudioReactiveFlowResponse {
  const AudioReactiveFlowResponse(this.low, this.mid, this.high);

  static const zero = AudioReactiveFlowResponse(0, 0, 0);
  static const _nearlySilentThreshold = .001;

  factory AudioReactiveFlowResponse.fromBands(List<num> bands) {
    double bandAt(int index) {
      if (index >= bands.length) return 0;
      final value = bands[index].toDouble();
      return value.isFinite && value >= 0 ? value : 0;
    }

    final low = bandAt(0);
    final mid = bandAt(1);
    final high = bandAt(2);
    return AudioReactiveFlowResponse(
      low.clamp(0.0, 1.0).toDouble(),
      mid.clamp(0.0, 1.0).toDouble(),
      high.clamp(0.0, 1.0).toDouble(),
    );
  }

  final double low;
  final double mid;
  final double high;

  bool get isNearlySilent =>
      low < _nearlySilentThreshold &&
      mid < _nearlySilentThreshold &&
      high < _nearlySilentThreshold;
}

/// 把绝对频段值映射到 0–1，不依赖自动增益。
/// 0.06 以下视为静音，0.36 以上视为满幅，中间用 smoothstep。
double audioReactiveFlowLevel(double value) {
  final x = value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.0;
  final t = ((x - .06) / .30).clamp(0.0, 1.0).toDouble();
  return t * t * (3 - 2 * t);
}

/// 低音主导的整体放大，带一点中频，避免只有鼓点的歌才有反应。
/// 幅度只给到 0.30：再大就会变成每拍一次的整体缩放闪烁。
double audioReactiveFlowSpectrumScale(double low, double mid) {
  final specMix = _unit(low) * 0.75 + _unit(mid) * 0.25;
  return specMix * specMix * 0.30 + 1.0;
}

/// 整屏鼓点增幅：保留旧版缩放的那一下，但走平滑脉冲而不是硬起音。
const double audioReactiveFlowZoomBeatGain = 0.16;

/// 三个层的最大缩放增幅。主封面只给很小的一下，保住视觉焦点的张力。
const double audioReactiveFlowPrimaryLayerMaxIncrease = 0.015;
const double audioReactiveFlowSecondaryLayerMaxIncrease = 0.05;
const double audioReactiveFlowLightLayerMaxIncrease = 0.06;

/// 鼓点同时推柔性层的位移，避免只有缩放在动时像机械抽一下。
const double audioReactiveFlowSecondaryLayerBeatOffset = 0.008;
const double audioReactiveFlowLightLayerBeatOffset = 0.010;

double audioReactiveFlowBeatOffset({
  required double beat,
  required double maximumOffset,
}) {
  final amount = maximumOffset.isFinite
      ? maximumOffset.clamp(0.0, 0.012).toDouble()
      : 0.0;
  return _unit(beat) * amount;
}

/// 首次订阅后需要重建音频状态。
bool audioReactiveFlowShouldResetAfterPause({required Duration? pausedFor}) {
  return pausedFor == null;
}

/// 恢复时让绘制脉冲平滑追上已按暂停时长推进的节拍脉冲。
double audioReactiveFlowFollowBeat({
  required double current,
  required double target,
  required double dtSeconds,
}) {
  final from = _unit(current);
  final to = _unit(target);
  if (!dtSeconds.isFinite || dtSeconds <= 0) return from;
  final tau = to > from ? 0.07 : 0.20;
  final response = 1 - math.exp(-math.min(dtSeconds, 0.25) / tau);
  return (from + (to - from) * response).clamp(0.0, 1.0).toDouble();
}

/// 鼓点对局部柔光层的缩放，限制最大增幅，避免超出实机对照范围。
double audioReactiveFlowLayerScale({
  required double beat,
  required double maximumIncrease,
}) {
  final increase = maximumIncrease.isFinite
      ? maximumIncrease.clamp(0.0, 0.16).toDouble()
      : 0.0;
  return 1.0 + _unit(beat) * increase;
}

/// 整屏缩放：慢电平做基准，鼓点再加一条平滑脉冲。
double audioReactiveFlowZoom({
  required double slowLow,
  required double slowMid,
  required double beat,
  double wholeBackgroundBeatGain = audioReactiveFlowZoomBeatGain,
}) {
  final gain = wholeBackgroundBeatGain.isFinite
      ? wholeBackgroundBeatGain.clamp(0.0, 0.20).toDouble()
      : 0.0;
  final value =
      audioReactiveFlowSpectrumScale(slowLow, slowMid) + _unit(beat) * gain;
  return value.clamp(1.0, 1.48).toDouble();
}

/// 低音把封面对比略微拉开。
double audioReactiveFlowContrast(double low) {
  return _unit(low) * 0.08 + 1.0;
}

/// 高频把颜色拉鲜一点。
double audioReactiveFlowSaturationBoost(double high) {
  return _unit(high) * 0.08;
}

double audioReactiveFlowBeatEnergy(AudioReactiveFlowResponse response) {
  final weighted =
      response.low * 0.52 + response.mid * 0.40 + response.high * 0.08;
  return math.pow(_unit(weighted), 0.62).toDouble();
}

double audioReactiveFlowMotionSpeedTarget({
  required double energy,
  required double beat,
  required double energyGain,
  required double beatGain,
}) {
  return (1.0 + _unit(energy) * energyGain + _unit(beat) * beatGain)
      .clamp(1.0, 1.70)
      .toDouble();
}

/// 重新接上频谱时，空窗帧先丢掉，避免把上一帧的色场瞬间拉黑。
bool audioReactiveFlowShouldHoldEnvelope({
  required bool awaitingPlaybackSpectrum,
  required AudioReactiveFlowResponse incoming,
}) {
  return awaitingPlaybackSpectrum && incoming.isNearlySilent;
}

/// 页面稳定停留时才把频谱写进包络；离开或过渡中直接丢弃，包络保持原值。
/// 返回值是下一次仍需「等待非静音帧」的标记。
bool audioReactiveFlowWriteSpectrum({
  required bool pageSettled,
  required bool awaitingPlaybackSpectrum,
  required AudioReactiveFlowResponse incoming,
  required AudioReactiveFlowEngine engine,
  double? dtSeconds,
}) {
  if (!pageSettled) return awaitingPlaybackSpectrum;
  if (audioReactiveFlowShouldHoldEnvelope(
    awaitingPlaybackSpectrum: awaitingPlaybackSpectrum,
    incoming: incoming,
  )) {
    return true;
  }
  engine.update(incoming, dtSeconds: dtSeconds);
  return false;
}

double _unit(double value) {
  return value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.0;
}

/// 律动统一入口：慢电平做基准，鼓点走事件检测 + 平滑脉冲。
final class AudioReactiveFlowEngine {
  AudioReactiveFlowEngine({
    double pulseAttackSeconds = .09,
    double pulseReleaseTauSeconds = .30,
  }) : _beat = _BeatTracker(
         pulseAttackSeconds: pulseAttackSeconds,
         pulseReleaseTauSeconds: pulseReleaseTauSeconds,
       );

  /// 频谱固定 23Hz（2048 点窗约 43ms）；首帧或异常间隔时用它兜底。
  static const double nominalDtSeconds = 1 / 23;
  static const double _maxDtSeconds = .25;

  final _BeatTracker _beat;
  AudioReactiveFlowResponse _value = AudioReactiveFlowResponse.zero;

  AudioReactiveFlowResponse get value => _value;

  /// 慢电平：2.5s 绝对响度平均。
  double get levelLow => _beat.levelLow;
  double get levelMid => _beat.levelMid;
  double get levelHigh => _beat.levelHigh;

  double get beatPulse => _beat.pulse;

  void update(AudioReactiveFlowResponse incoming, {double? dtSeconds}) {
    final dt = dtSeconds == null || !dtSeconds.isFinite || dtSeconds <= 0
        ? nominalDtSeconds
        : math.min(dtSeconds, _maxDtSeconds);
    _beat.update(incoming, dt);
    _value = incoming;
  }

  /// 恢复时推进脉冲年龄，同时保留暂停前的慢电平与基准线。
  void resumeFromPause({double elapsedSeconds = 0}) {
    _beat.resumeFromPause(elapsedSeconds: elapsedSeconds);
  }

  /// 切歌时只重建鼓点检测，保留慢电平和连续量程，避免画面跳一下。
  void resetForTrackChange() {
    _beat.resetForTrackChange();
  }

  void reset() {
    _beat.reset();
    _value = AudioReactiveFlowResponse.zero;
  }
}

/// 律动：慢电平决定底色，鼓点用「能量上升沿 + 最短间隔」检测，
/// 每次触发只记一个事件，由时间算出平滑脉冲，避免每帧硬开关。
final class _BeatTracker {
  static const double _levelTauSeconds = 1.6;
  // 基准线跟的是歌曲平均响度：升得慢，避免把鼓点本身吞掉；降得快，
  // 安静段结束后能马上回到真实电平。
  static const double _baselineRiseTauSeconds = 3.0;
  static const double _baselineFallTauSeconds = .35;
  static const double _risePeakTauSeconds = 2.5;
  static const double _minRise = .04;
  static const double _minScale = .12;
  static const double _riseRatio = .20;
  static const double _riseEpsilon = .004;
  static const double _refractorySeconds = .16;
  static const double _absoluteGate = .025;
  static const double _minStrength = .08;
  // 强度走平方曲线：强拍保住满幅，弱拍压到很小，节奏对比更清楚。
  static const double _strengthCurve = 2.0;
  static const double _pulseLifeSeconds = 1.2;

  _BeatTracker({
    double pulseAttackSeconds = .09,
    double pulseReleaseTauSeconds = .30,
  }) : _pulseAttackSeconds = pulseAttackSeconds,
       _pulseReleaseTauSeconds = pulseReleaseTauSeconds;

  final double _pulseAttackSeconds;
  final double _pulseReleaseTauSeconds;

  final _SlowBand _low = _SlowBand();
  final _SlowBand _mid = _SlowBand();
  final _SlowBand _high = _SlowBand();
  final List<_Beat> _beats = <_Beat>[];

  double _time = 0;
  double _baseline = 0;
  double _risePeak = 0;
  double _previousRise = 0;
  double _lastEnergy = 0;
  double _lastBeatAt = double.negativeInfinity;
  bool _started = false;
  bool _skipNextBeat = false;

  double get levelLow => _low.value;
  double get levelMid => _mid.value;
  double get levelHigh => _high.value;

  double get pulse {
    var value = 0.0;
    for (final beat in _beats) {
      final shaped = beat.strength * _shape(_time - beat.time);
      if (shaped > value) value = shaped;
    }
    return value.clamp(0.0, 1.0).toDouble();
  }

  void update(AudioReactiveFlowResponse incoming, double dtSeconds) {
    _time += dtSeconds;
    final low = _unit(incoming.low);
    final mid = _unit(incoming.mid);
    final high = _unit(incoming.high);
    final energy = low * .65 + mid * .30 + high * .05;
    _lastEnergy = energy;
    if (!_started) {
      // 首帧只记录当前电平，不产生鼓点：进页面不抽。
      _started = true;
      _low.seed(low);
      _mid.seed(mid);
      _high.seed(high);
      _baseline = energy;
      _previousRise = 0;
      _skipNextBeat = false;
      return;
    }
    _low.update(low, dtSeconds);
    _mid.update(mid, dtSeconds);
    _high.update(high, dtSeconds);

    final rise = math.max(0.0, energy - _baseline);
    final scale = math.max(_risePeak, _minScale);
    final threshold = math.max(_minRise, scale * _riseRatio);
    final rising = rise > _previousRise + _riseEpsilon;
    if (!_skipNextBeat &&
        rising &&
        rise >= threshold &&
        energy >= _absoluteGate &&
        _time - _lastBeatAt >= _refractorySeconds) {
      final normalized = (rise / scale).clamp(0.0, 1.0).toDouble();
      final strength = math
          .pow(normalized, _strengthCurve)
          .clamp(_minStrength, 1.0)
          .toDouble();
      // 用上一帧时间，脉冲在触发这一帧就能被看到，不用等下一帧。
      _beats.add(_Beat(_time - dtSeconds, strength));
      _lastBeatAt = _time;
    }
    _skipNextBeat = false;
    _previousRise = rise;
    _risePeak = rise > _risePeak
        ? rise
        : _risePeak * math.exp(-dtSeconds / _risePeakTauSeconds);
    final baselineTau = energy > _baseline
        ? _baselineRiseTauSeconds
        : _baselineFallTauSeconds;
    _baseline +=
        (energy - _baseline) * (1 - math.exp(-dtSeconds / baselineTau));
    _beats.removeWhere((beat) => _time - beat.time > _pulseLifeSeconds);
  }

  /// 恢复时推进节拍脉冲的年龄，但不推进暂停期间的音频电平与基准线。
  void resumeFromPause({required double elapsedSeconds}) {
    if (elapsedSeconds.isFinite && elapsedSeconds > 0) {
      _time += elapsedSeconds;
      _risePeak *= math.exp(-elapsedSeconds / _risePeakTauSeconds);
      _beats.removeWhere((beat) => _time - beat.time > _pulseLifeSeconds);
    }
    _lastBeatAt = double.negativeInfinity;
    _previousRise = 0;
    _skipNextBeat = true;
  }

  /// 切歌时只重建鼓点检测，保留慢电平和连续量程，避免画面跳一下。
  void resetForTrackChange() {
    _beats.clear();
    _baseline = _lastEnergy;
    _risePeak = 0;
    _previousRise = 0;
    _lastBeatAt = double.negativeInfinity;
    _skipNextBeat = true;
  }

  void reset() {
    _time = 0;
    _baseline = 0;
    _risePeak = 0;
    _previousRise = 0;
    _lastBeatAt = double.negativeInfinity;
    _beats.clear();
    _low.reset();
    _mid.reset();
    _high.reset();
    _started = false;
    _skipNextBeat = false;
  }

  double _shape(double age) {
    if (age <= 0) return 0;
    if (age < _pulseAttackSeconds) {
      final t = age / _pulseAttackSeconds;
      return t * t * (3 - 2 * t);
    }
    return math.exp(-(age - _pulseAttackSeconds) / _pulseReleaseTauSeconds);
  }
}

final class _Beat {
  const _Beat(this.time, this.strength);

  final double time;
  final double strength;
}

final class _SlowBand {
  double _value = 0;
  bool _seeded = false;

  double get value => _value;

  void seed(double value) {
    _value = _unit(value);
    _seeded = true;
  }

  void update(double target, double dtSeconds) {
    if (!_seeded) {
      seed(target);
      return;
    }
    final step = 1 - math.exp(-dtSeconds / _BeatTracker._levelTauSeconds);
    _value += (_unit(target) - _value) * step;
  }

  void reset() {
    _value = 0;
    _seeded = false;
  }
}
