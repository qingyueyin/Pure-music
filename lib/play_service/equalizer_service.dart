import 'dart:math' as math;

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/native/bass/bass_player.dart';

/// EQ 控制服务，从 PlaybackService 提取
/// 管理均衡器增益、预设、自动增益和输出增益应用
class EqualizerService {
  final BassPlayer _player;
  final PlaybackPreference _pref;

  EqualizerService(this._player, this._pref) {
    final savedGains = _pref.eqGains;
    for (int i = 0; i < 10; i++) {
      if (i < savedGains.length) {
        _player.setEQ(i, savedGains[i]);
      }
    }
    _applyOutputGain();
  }

  double get eqPreampDb => _pref.eqPreampDb;
  bool get eqAutoGainEnabled => _pref.eqAutoGainEnabled;
  double get eqAutoHeadroomDb => _pref.eqAutoHeadroomDb;
  double get eqAutoGainDb => eqAutoGainEnabled ? _computeEqAutoGainDb() : 0.0;
  List<double> get eqGains => _player.eqGains;
  List<EqPreset> get eqPresets => _pref.eqPresets;

  double _dbToLinear(double db) {
    return math.pow(10.0, db / 20.0).toDouble();
  }

  double _computeEqAutoGainDb() {
    final gains = _player.eqGains;
    if (gains.isEmpty) return 0.0;
    if (gains.every((g) => g.abs() < 1e-6)) return 0.0;

    double maxGain = gains.first;
    double sumGain = 0.0;
    for (final g in gains) {
      if (g > maxGain) maxGain = g;
      sumGain += g;
    }
    final meanGain = sumGain / gains.length;

    final desired = -meanGain;
    final safeUpper = math.max(0.0, (-maxGain - eqAutoHeadroomDb).toDouble());
    final clampedDesired = desired.clamp(-24.0, safeUpper).toDouble();
    return clampedDesired;
  }

  void _applyOutputGain() {
    final totalDb = eqPreampDb + (eqAutoGainEnabled ? eqAutoGainDb : 0.0);
    final volume = (_pref.volumeDsp * _dbToLinear(totalDb)).clamp(0.0, 8.0);
    _player.setVolumeDsp(volume.toDouble());
  }

  void refreshEQ() {
    _player.refreshEQ();
    _applyOutputGain();
  }

  void setEQ(int band, double gain) {
    logger.i('[action] setEQ band=$band gain=$gain');
    AudioEchoLogRecorder.instance
        .mark('setEQ', extra: {'band': band, 'gain': gain});
    _player.setEQ(band, gain);
    if (band < _pref.eqGains.length) {
      _pref.eqGains[band] = gain;
    }
    _applyOutputGain();
  }

  void setEqPreampDb(double value) {
    final next = value.clamp(-24.0, 24.0).toDouble();
    if (_pref.eqPreampDb == next) return;
    _pref.eqPreampDb = next;
    _applyOutputGain();
  }

  void setEqAutoGainEnabled(bool enabled) {
    if (_pref.eqAutoGainEnabled == enabled) return;
    _pref.eqAutoGainEnabled = enabled;
    _applyOutputGain();
  }

  void saveEqPreset(String name) {
    final gains = List<double>.from(_player.eqGains);
    final existingIndex = _pref.eqPresets.indexWhere((e) => e.name == name);
    if (existingIndex >= 0) {
      _pref.eqPresets[existingIndex] = EqPreset(name, gains);
    } else {
      _pref.eqPresets.add(EqPreset(name, gains));
    }
    AppPreference.instance.save();
  }

  void removeEqPreset(String name) {
    _pref.eqPresets.removeWhere((e) => e.name == name);
    AppPreference.instance.save();
  }

  void applyEqPreset(EqPreset preset) {
    for (int i = 0; i < 10; i++) {
      if (i < preset.gains.length) {
        setEQ(i, preset.gains[i]);
      }
    }
    AppPreference.instance.save();
  }

  /// 重新应用输出增益（当 volumeDsp 变化时调用）
  void reapplyOutputGain() {
    _applyOutputGain();
  }
}
