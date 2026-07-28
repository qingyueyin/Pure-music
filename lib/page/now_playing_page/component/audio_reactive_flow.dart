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