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

  void ensureBound() {
    if (_bound) return;
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
      return await FlutterVolumeController.getVolume().timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  Future<void> refresh({required Duration timeout}) async {
    final v = await read(timeout: timeout);
    if (v != null && (v - volume.value).abs() > 0.0001) {
      volume.value = v;
    }
  }

  Future<void> set(double v) async {
    await FlutterVolumeController.setVolume(v);
  }

  void _rebindPluginListener() {
    FlutterVolumeController.removeListener();
    FlutterVolumeController.addListener(_pluginListener);
  }

  void _startWindowsPoll() {
    _windowsPollTimer?.cancel();
    _windowsPollTimer =
        Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (_windowsPollBusy) return;
      _windowsPollBusy = true;
      try {
        final v = await read(timeout: const Duration(seconds: 1));
        if (v == null) {
          _windowsReadFailures += 1;
          if (_windowsReadFailures >= 3) {
            _windowsReadFailures = 0;
            _rebindPluginListener();
          }
          return;
        }
        _windowsReadFailures = 0;
        if ((v - volume.value).abs() > 0.005) {
          volume.value = v;
        }
      } finally {
        _windowsPollBusy = false;
      }
    });
  }
}

