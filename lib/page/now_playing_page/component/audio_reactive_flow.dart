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
  static const _targetPeak = 0.65;
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

final class AudioReactiveFlowTransientDetector {
  static const _silenceThreshold = .006;

  double _baseline = 0;
  double _previous = 0;
  bool _initialized = false;

  double update(double low) {
    final value = low.isFinite ? low.clamp(0.0, 1.0).toDouble() : 0.0;
    if (value < _silenceThreshold) {
      _baseline *= .86;
      _previous = 0;
      _initialized = false;
      return 0;
    }
    if (!_initialized) {
      _baseline = value;
      _previous = value;
      _initialized = true;
      return 0;
    }

    final reference = math.max(_baseline, .035);
    final rise = math.max(0.0, value - _previous) / reference;
    final excess = math.max(0.0, value - _baseline * 1.12) / reference;
    final transient = math
        .max(rise * .88, math.min(rise * 1.2, excess * .55))
        .clamp(0.0, 1.0)
        .toDouble();
    final baselineResponse = value > _baseline ? .045 : .14;
    _baseline += (value - _baseline) * baselineResponse;
    _previous = value;
    return transient;
  }

  void reset() {
    _baseline = 0;
    _previous = 0;
    _initialized = false;
  }
}

final class AudioReactiveFlowPulseEnvelope {
  static const _attackSeconds = .038;
  static const _releaseSeconds = .22;
  static const _targetDecaySeconds = .10;
  static const _minimumTriggerStrength = .12;
  static const _retriggerDelaySeconds = .045;
  static const _retriggerLift = .30;

  double _value = 0;
  double _target = 0;
  double _retriggerDelayRemaining = 0;

  double get value => _value;

  bool trigger(double strength) {
    final next = strength.isFinite ? strength.clamp(0.0, 1.0).toDouble() : 0.0;
    if (next < _minimumTriggerStrength || _retriggerDelayRemaining > 0) {
      return false;
    }
    final accentedTarget = (_value + next * _retriggerLift).clamp(0.0, 1.0);
    _target = math.max(_target, math.max(next, accentedTarget));
    _retriggerDelayRemaining = _retriggerDelaySeconds;
    return true;
  }

  double advance(double deltaSeconds) {
    if (!deltaSeconds.isFinite || deltaSeconds <= 0) return _value;
    _retriggerDelayRemaining = math.max(
      0.0,
      _retriggerDelayRemaining - deltaSeconds,
    );
    final timeConstant = _target > _value ? _attackSeconds : _releaseSeconds;
    final response = 1 - math.exp(-deltaSeconds / timeConstant);
    _value += (_target - _value) * response;
    _target *= math.exp(-deltaSeconds / _targetDecaySeconds);
    if (_value < .001 && _target < .001) reset();
    return _value;
  }

  void reset() {
    _value = 0;
    _target = 0;
    _retriggerDelayRemaining = 0;
  }
}

final class AudioReactiveFlowVisualSpring {
  static const _attackResponse = 0.16;
  static const _releaseResponse = 0.22;

  double _value = 0;
  double _velocity = 0;

  double get value => _value;

  double follow(double target, double deltaSeconds) {
    final next = target.isFinite ? target.clamp(0.0, 1.0).toDouble() : 0.0;
    if (!deltaSeconds.isFinite || deltaSeconds <= 0) return _value;
    final dt = math.min(deltaSeconds, 0.05);
    final response = next > _value ? _attackResponse : _releaseResponse;
    final omega = 2 * math.pi / response;
    final y0 = _value - next;
    final b = _velocity + omega * y0;
    final decay = math.exp(-omega * dt);
    final y = (y0 + b * dt) * decay;
    _velocity = (b - omega * (y0 + b * dt)) * decay;
    _value = (next + y).clamp(0.0, 1.0).toDouble();
    if (_value <= 0 && _velocity < 0) _velocity = 0;
    if (_value >= 1 && _velocity > 0) _velocity = 0;
    if (_value < .001 && _velocity.abs() < .001 && next < .001) reset();
    return _value;
  }

  void reset() {
    _value = 0;
    _velocity = 0;
  }
}
