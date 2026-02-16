import 'package:flutter/foundation.dart';

enum HotkeyUiAction {
  prev,
  next,
  volumeStep,
}

class HotkeyUiEvent {
  final HotkeyUiAction action;
  final int serial;
  const HotkeyUiEvent(this.action, this.serial);
}

class HotkeyUiFeedback extends ChangeNotifier {
  HotkeyUiEvent? _lastEvent;
  int _serial = 0;

  HotkeyUiEvent? get lastEvent => _lastEvent;

  void emit(HotkeyUiAction action) {
    _lastEvent = HotkeyUiEvent(action, ++_serial);
    notifyListeners();
  }
}

final HOTKEY_UI_FEEDBACK = HotkeyUiFeedback();

