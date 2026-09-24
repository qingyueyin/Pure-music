import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';

class SystemVolumeService {
  SystemVolumeService._();

  static SystemVolumeService? _instance;
  static SystemVolumeService get instance {
    _instance ??= SystemVolumeService._();
    return _instance!;
  }

  final volume = ValueNotifier<double>(0.5);

  bool _bound = false;
  late final ValueChanged<double> _pluginListener;

  Timer? _windowsPollTimer;
  bool _windowsPollBusy = false;
  int _windowsReadFailures = 0;
  bool _disposed = false;

  void ensureBound() {
    if (_bound || _disposed) return;
    _pluginListener = (v) {
      if ((v - volume.value).abs() > 0.0001) {
        volume.value = v;
      }
    };
    FlutterVolumeController.addListener(_pluginListener);
    _bound = true;
    refresh(timeout: const Duration(milliseconds: 600));
    if (Platform.isWindows) {
      _startWindowsPoll();
    }
  }

  Future<double?> read({required Duration timeout}) async {
    try {
      final value = await FlutterVolumeController.getVolume().timeout(timeout);
      return _normalizeVolume(value);
    } catch (_) {
      return null;
    }
  }

  Future<void> refresh({required Duration timeout}) async {
    final v = await read(timeout: timeout);
    _publishVolume(v);
  }

  Future<void> set(double v) async {
    final normalized = _normalizeVolume(v);
    if (normalized == null || _disposed) return;
    await FlutterVolumeController.setVolume(normalized);
  }

  double? _normalizeVolume(double? value) {
    if (value == null || !value.isFinite) return null;
    return value.clamp(0.0, 1.0).toDouble();
  }

  void _publishVolume(double? value) {
    if (_disposed || value == null) return;
    if ((value - volume.value).abs() > 0.0001) {
      volume.value = value;
    }
  }

  void _rebindPluginListener() {
    FlutterVolumeController.removeListener();
    FlutterVolumeController.addListener(_pluginListener);
  }

  void _startWindowsPoll() {
    _windowsPollTimer?.cancel();
    _windowsPollTimer = Timer.periodic(const Duration(milliseconds: 250), (
      _,
    ) async {
      if (_disposed || _windowsPollBusy) return;
      _windowsPollBusy = true;
      try {
        final v = await read(timeout: const Duration(seconds: 1));
        if (_disposed) return;
        if (v == null) {
          _windowsReadFailures += 1;
          if (_windowsReadFailures >= 3) {
            _windowsReadFailures = 0;
            _rebindPluginListener();
          }
          return;
        }
        _windowsReadFailures = 0;
        _publishVolume(v);
      } finally {
        _windowsPollBusy = false;
      }
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _windowsPollTimer?.cancel();
    if (_bound) {
      FlutterVolumeController.removeListener();
      _bound = false;
    }
    volume.dispose();
    _instance = null;
  }
}
