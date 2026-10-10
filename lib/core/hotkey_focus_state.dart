import 'package:flutter/widgets.dart';

bool isTextInputFocusedForHotkeys() {
  final focused = FocusManager.instance.primaryFocus;
  if (focused == null || !focused.hasFocus) return false;

  final context = focused.context;
  if (context == null) return false;
  if (context.widget is! EditableText &&
      context.findAncestorWidgetOfExactType<EditableText>() == null) {
    return false;
  }
  return _isVisibleForInAppHotkeys(context);
}

/// 侧栏换页后旧输入框仍在树里，但已被 Offstage 藏起，不能继续挡住快捷键。
bool _isVisibleForInAppHotkeys(BuildContext context) {
  var hidden = false;
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is Offstage && widget.offstage) {
      hidden = true;
      return false;
    }
    return true;
  });
  if (hidden) return false;
  final renderObject = context.findRenderObject();
  return renderObject is RenderBox && renderObject.attached;
}

bool canHandleInAppPlaybackHotkey({required bool textInputFocused}) =>
    !textInputFocused;
