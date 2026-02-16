import 'package:flutter/foundation.dart';

class ImmersiveModeController with ChangeNotifier {
  ImmersiveModeController._();

  static final ImmersiveModeController instance = ImmersiveModeController._();

  bool _enabled = false;
  bool get enabled => _enabled;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
  }

  Future<void> enter() async {
    _setEnabled(true);
  }

  Future<void> exit() async {
    _setEnabled(false);
  }

  Future<void> toggle() async {
    if (_enabled) {
      await exit();
    } else {
      await enter();
    }
  }

  void _setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
  }
}

