import 'package:flutter/material.dart';

ButtonStyle subtleIconButtonStyle({
  required Color tint,
  double hoverAlpha = 0.02,
  double pressedAlpha = 0.04,
  Color background = Colors.transparent,
  OutlinedBorder? shape,
}) {
  return ButtonStyle(
    backgroundColor: WidgetStatePropertyAll(background),
    shape: shape == null ? null : WidgetStatePropertyAll(shape),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return Colors.transparent;
      }
      if (states.contains(WidgetState.pressed)) {
        return tint.withValues(alpha: pressedAlpha);
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return tint.withValues(alpha: hoverAlpha);
      }
      return Colors.transparent;
    }),
  );
}

IconButtonThemeData subtleIconButtonTheme({
  required Color tint,
  double hoverAlpha = 0.04,
  double pressedAlpha = 0.06,
  Color background = Colors.transparent,
  OutlinedBorder? shape,
}) {
  return IconButtonThemeData(
    style: subtleIconButtonStyle(
      tint: tint,
      hoverAlpha: hoverAlpha,
      pressedAlpha: pressedAlpha,
      background: background,
      shape: shape,
    ),
  );
}
