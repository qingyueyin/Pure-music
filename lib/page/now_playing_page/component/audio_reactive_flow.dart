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

  AudioReactiveFlowResponse _value = AudioReactiveFlowResponse.zero;

  AudioReactiveFlowResponse get value => _value;

  AudioReactiveFlowResponse update(AudioReactiveFlowResponse target) {
    _value = AudioReactiveFlowResponse(
      _sanitize(target.low),
      _sanitize(target.mid),
      _sanitize(target.high),
    );
    return _value;
  }

  AudioReactiveFlowResponse release() {
    _value = AudioReactiveFlowResponse(
      _value.low * (1.0 - _release),
      _value.mid * (1.0 - _release),
      _value.high * (1.0 - _release),
    );
    return _value;
  }

  void reset() {
    _value = AudioReactiveFlowResponse.zero;
  }

  static double _sanitize(double value) {
    return value.isFinite && value >= 0
        ? value.clamp(0.0, 1.0).toDouble()
        : 0.0;
  }
}

final class AudioReactiveFlowNormalizer {
  static const _targetPeak = 0.65;
  static const _attack = 0.30;
  static const _release = 0.01;
  static const _maxGain = 30.0;

  double _smoothedPeak = 0;

  AudioReactiveFlowResponse update(AudioReactiveFlowResponse input) {
    if (input.isNearlySilent) {
      _smoothedPeak += (0 - _smoothedPeak) * _release;
      return AudioReactiveFlowResponse.zero;
    }

    final peak = math.max(input.low, math.max(input.mid, input.high));
    final coefficient = peak > _smoothedPeak ? _attack : _release;
    _smoothedPeak += (peak - _smoothedPeak) * coefficient;
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

  void reset() => _smoothedPeak = 0;
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
        .max(rise * .72, math.min(rise * 1.15, excess * .42))
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
  static const _attackSeconds = .025;
  static const _releaseSeconds = .10;
  static const _targetDecaySeconds = .06;
  static const _minimumTriggerStrength = .16;
  static const _retriggerDelaySeconds = .045;
  static const _retriggerLift = .35;

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
    _retriggerDelayRemaining =
        math.max(0.0, _retriggerDelayRemaining - deltaSeconds);
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
