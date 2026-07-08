import 'package:flutter/widgets.dart';

bool isTextInputFocusedForHotkeys() {
  final focused = FocusManager.instance.primaryFocus;
  if (focused == null) return false;

  final context = focused.context;
  if (context == null) return false;
  if (context.widget is EditableText) return true;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}

bool canHandleInAppPlaybackHotkey({required bool textInputFocused}) =>
    !textInputFocused;
