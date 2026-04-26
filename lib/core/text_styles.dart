import 'package:pure_music/core/theme.dart';
import 'package:flutter/material.dart';

final Map<String, double> _fontSizeMap = {
  'xs': 10.0,
  'sm': 12.0,
  'md': 14.0,
  'lg': 16.0,
  'xl': 18.0,
  '2xl': 22.0,
  '3xl': 28.0,
  'title': 32.0,
};

TextStyle appTextStyle({
  required BuildContext context,
  required String size,
  double opacity = 1.0,
  double lineHeight = 1.2,
  FontWeight weight = FontWeight.w400,
}) {
  final scheme = ThemeProvider.instance.currScheme;
  return TextStyle(
    color: scheme.onSurface.withValues(alpha: opacity),
    fontSize: _fontSizeMap[size] ?? _fontSizeMap['md'],
    fontWeight: weight,
    height: lineHeight,
    fontFamily: ThemeProvider.instance.fontFamily,
  );
}
