import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';

import 'window_render_gate.dart';

class SystemVolumeService {
  SystemVolumeService._();

  static SystemVolumeService? _instance;
  static SystemVolumeService get instance {
    _instance ??= SystemVolumeService._();
    return _instance!;
  }

  final volume = ValueNotifier<double>(0.5);

  bool _bound = false;
  bool _eventListenerBound = false;
  late final ValueChanged<double> _pluginListener;

  Timer? _windowsPollTimer;
  bool _windowsPollBusy = false;
  bool _windowsVolumeReread = false;
  int _windowsPollEpoch = 0;
  void Function()? _windowFramesListener;
  bool _disposed = false;
  final Set<Future<void>> _inFlightOperations = <Future<void>>{};

  void ensureBound() {
    if (_bound || _disposed) return;
    _pluginListener = (v) {
      if ((v - volume.value).abs() > 0.0001) {
        volume.value = v;
      }
    };
    if (!Platform.isWindows) {
      FlutterVolumeController.addListener(_pluginListener);
      _eventListenerBound = true;
    }
    _bound = true;
    unawaited(refresh(timeout: const Duration(milliseconds: 600)));
    if (Platform.isWindows) {
      final listener = _windowFramesListener ??= _syncWindowsVolumePoll;
      WindowRenderGate.instance.framesEnabled.addListener(listener);
      if (WindowRenderGate.instance.framesEnabled.value) {
        _startWindowsPoll();
      }
    }
  }

  // 窗口缩到任务栏或藏进托盘时停掉轮询，重新可见后先读一次当前音量再按原间隔继续。
  void _syncWindowsVolumePoll() {
    if (_disposed) return;
    _windowsPollEpoch++;
    if (!WindowRenderGate.instance.framesEnabled.value) {
      _windowsPollTimer?.cancel();
      _windowsPollTimer = null;
      return;
    }
    final epoch = _windowsPollEpoch;
    _windowsVolumeReread = _windowsPollBusy;
    if (!_windowsPollBusy) {
      unawaited(_readWindowsVolumeNow(epoch));
    }
    _startWindowsPoll();
  }

  Future<void> _readWindowsVolumeNow(int epoch) async {
    if (_disposed ||
        epoch != _windowsPollEpoch ||
        _windowsPollBusy ||
        !WindowRenderGate.instance.framesEnabled.value) {
      return;
    }
    _windowsPollBusy = true;
    var reread = false;
    try {
      final v = await read(timeout: const Duration(seconds: 1));
      if (_disposed ||
          epoch != _windowsPollEpoch ||
          !WindowRenderGate.instance.framesEnabled.value) {
        return;
      }
      _publishVolume(v);
    } finally {
      _windowsPollBusy = false;
      reread = _windowsVolumeReread && !_disposed;
      _windowsVolumeReread = false;
    }
    if (reread && WindowRenderGate.instance.framesEnabled.value) {
      unawaited(_readWindowsVolumeNow(_windowsPollEpoch));
    }
  }

  Future<double?> read({required Duration timeout}) async {
    if (_disposed) return null;
    final operation = FlutterVolumeController.getVolume();
    _trackOperation(operation);
    try {
      final value = await operation.timeout(timeout);
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
    final operation = FlutterVolumeController.setVolume(normalized);
    _trackOperation(operation);
    try {
      await operation.timeout(const Duration(seconds: 1));
    } catch (_) {}
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

  void _startWindowsPoll() {
    _windowsPollTimer?.cancel();
    _windowsPollTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      unawaited(_readWindowsVolumeNow(_windowsPollEpoch));
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final windowFramesListener = _windowFramesListener;
    if (windowFramesListener != null) {
      WindowRenderGate.instance.framesEnabled.removeListener(
        windowFramesListener,
      );
    }
    _windowsPollTimer?.cancel();
    _windowsPollTimer = null;
    if (_eventListenerBound) {
      FlutterVolumeController.removeListener();
      _eventListenerBound = false;
    }
    final operations = List<Future<void>>.of(_inFlightOperations);
    if (operations.isNotEmpty) {
      await Future.wait(
        operations,
      ).timeout(const Duration(seconds: 2), onTimeout: () => <void>[]);
    }
    _bound = false;
    volume.dispose();
    _instance = null;
  }

  void _trackOperation<T>(Future<T> operation) {
    final tracked = operation.then<void>((_) {}).catchError((_) {});
    _inFlightOperations.add(tracked);
    unawaited(tracked.whenComplete(() => _inFlightOperations.remove(tracked)));
  }
}
