import 'dart:async';

import 'package:pure_music/core/log/app_log.dart';
import 'package:pure_music/native/bass/bass_player.dart';

/// 播放停滞检测：连续采样位置不动时只记日志，不自动恢复。
class PlaybackWatchdog {
  PlaybackWatchdog({
    required double Function() readPositionMs,
    required PlayerState Function() readState,
  }) : _readPositionMs = readPositionMs,
       _readState = readState;

  static const _sampleInterval = Duration(seconds: 2);
  static const _stallSamples = 3;
  static const _warnCooldown = Duration(seconds: 300);

  final double Function() _readPositionMs;
  final PlayerState Function() _readState;

  Timer? _timer;
  double? _lastPositionMs;
  int _stalledSamples = 0;
  DateTime? _lastWarnAt;

  void start() {
    _timer?.cancel();
    _lastPositionMs = null;
    _stalledSamples = 0;
    _timer = Timer.periodic(_sampleInterval, (_) => _sample());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _lastPositionMs = null;
    _stalledSamples = 0;
  }

  void _sample() {
    final positionMs = _readPositionMs();
    final last = _lastPositionMs;
    _lastPositionMs = positionMs;
    if (_readState() != PlayerState.playing || last == null) {
      _stalledSamples = 0;
      return;
    }
    if ((positionMs - last).abs() >= 1.0) {
      _stalledSamples = 0;
      return;
    }
    _stalledSamples++;
    if (_stalledSamples < _stallSamples) return;
    _stalledSamples = 0;
    _warn(positionMs);
  }

  void _warn(double positionMs) {
    final now = DateTime.now();
    final lastWarnAt = _lastWarnAt;
    if (lastWarnAt != null && now.difference(lastWarnAt) < _warnCooldown) {
      return;
    }
    _lastWarnAt = now;
    log.playback.warn(
      'legacy',
      '[watchdog] playback stalled at ${positionMs.round()}ms',
    );
  }
}
