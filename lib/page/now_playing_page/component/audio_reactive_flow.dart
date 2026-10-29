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

    final low = math.max(bandAt(0), bandAt(1) * 0.85);
    final mid = (bandAt(1) + bandAt(2)) / 2;
    final high = bandAt(3);
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

/// 把频谱收成更稳的推力量，避免跟着瞬时峰值抽。
double audioReactiveFlowCurve(double value) {
  final x = value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.0;
  return x * x * x * (x * (x * 6 - 15) + 10);
}

/// 低音主导的整体放大，混一点点中频。
double audioReactiveFlowSpectrumScale(double low, double mid) {
  final specMix = _unit(low) * 0.9 + _unit(mid) * 0.1;
  return specMix * specMix * 0.38 + 1.0;
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

double audioReactiveFlowOnsetPulse({
  required double currentEnergy,
  required double previousEnergy,
  required double previousPulse,
}) {
  final current = _unit(currentEnergy);
  final previous = _unit(previousEnergy);
  final decayed = _unit(previousPulse) * 0.82;
  final rise = ((current - previous) * 4.4).clamp(0.0, 1.0).toDouble();
  return math.max(decayed, rise);
}

double audioReactiveFlowMotionSpeedTarget({
  required double energy,
  required double onset,
}) {
  return (1.0 + _unit(energy) * 0.32 + _unit(onset) * 0.55)
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
  required AudioReactiveFlowNormalizer normalizer,
  required AudioReactiveFlowEnvelope envelope,
}) {
  if (!pageSettled) return awaitingPlaybackSpectrum;
  if (audioReactiveFlowShouldHoldEnvelope(
    awaitingPlaybackSpectrum: awaitingPlaybackSpectrum,
    incoming: incoming,
  )) {
    return true;
  }
  envelope.update(normalizer.update(incoming));
  return false;
}

double _unit(double value) {
  return value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.0;
}

final class AudioReactiveFlowEnvelope {
  static const _release = .12;

  final _BandSmoother _low = _BandSmoother(50);
  final _BandSmoother _mid = _BandSmoother(100);
  final _BandSmoother _high = _BandSmoother(1000);
  AudioReactiveFlowResponse _value = AudioReactiveFlowResponse.zero;

  AudioReactiveFlowResponse get value => _value;

  AudioReactiveFlowResponse update(AudioReactiveFlowResponse target) {
    _value = AudioReactiveFlowResponse(
      _low.push(_sanitize(target.low)),
      _mid.push(_sanitize(target.mid)),
      _high.push(_sanitize(target.high)),
    );
    return _value;
  }

  AudioReactiveFlowResponse release() {
    _value = AudioReactiveFlowResponse(
      _low.decay(_release),
      _mid.decay(_release),
      _high.decay(_release),
    );
    return _value;
  }

  void reset() {
    _low.reset();
    _mid.reset();
    _high.reset();
    _value = AudioReactiveFlowResponse.zero;
  }

  static double _sanitize(double value) {
    return value.isFinite && value >= 0
        ? value.clamp(0.0, 1.0).toDouble()
        : 0.0;
  }
}

final class _BandSmoother {
  _BandSmoother(this._peakDivisor);

  final double _peakDivisor;
  final List<double> _hist = List<double>.filled(4, 0);
  double _peak = 0;
  double _smoothed = 0;

  double push(double incoming) {
    _hist[0] = _hist[1];
    _hist[1] = _hist[2];
    _hist[2] = _hist[3];
    _hist[3] = incoming;
    final fir =
        _hist[0] * 0.1 + _hist[1] * 0.2 + _hist[2] * 0.3 + _hist[3] * 0.4;
    if (fir > _peak) {
      _peak = fir;
    } else {
      _peak *= 1.0 - 1.0 / _peakDivisor;
    }
    _smoothed += (_peak - _smoothed) * 0.5;
    return _smoothed.clamp(0.0, 1.0).toDouble();
  }

  double decay(double amount) {
    final keep = (1.0 - amount).clamp(0.0, 1.0).toDouble();
    _hist[0] *= keep;
    _hist[1] *= keep;
    _hist[2] *= keep;
    _hist[3] *= keep;
    _peak *= keep;
    _smoothed *= keep;
    return _smoothed.clamp(0.0, 1.0).toDouble();
  }

  void reset() {
    _hist[0] = 0;
    _hist[1] = 0;
    _hist[2] = 0;
    _hist[3] = 0;
    _peak = 0;
    _smoothed = 0;
  }
}

final class AudioReactiveFlowNormalizer {
  static const _targetPeak = 0.85;
  static const _attack = 0.30;
  static const _release = 0.01;
  static const _maxGain = 30.0;

  double _smoothedPeak = 0;
  bool _hasPeak = false;

  AudioReactiveFlowResponse update(AudioReactiveFlowResponse input) {
    if (input.isNearlySilent) {
      _smoothedPeak += (0 - _smoothedPeak) * _release;
      return AudioReactiveFlowResponse.zero;
    }

    final peak = math.max(input.low, math.max(input.mid, input.high));
    if (!_hasPeak) {
      _smoothedPeak = peak;
      _hasPeak = true;
    } else {
      final coefficient = peak > _smoothedPeak ? _attack : _release;
      _smoothedPeak += (peak - _smoothedPeak) * coefficient;
    }
    final gain = (_targetPeak / math.max(_smoothedPeak, 0.001))
        .clamp(0.1, _maxGain)
        .toDouble();

    double normalize(double value) => (value * gain).clamp(0.0, 1.0).toDouble();

    return AudioReactiveFlowResponse(
      normalize(input.low),
      normalize(input.mid),
      normalize(input.high),
    );
  }

  void reset() {
    _smoothedPeak = 0;
    _hasPeak = false;
  }
}
