import 'package:flutter/material.dart';
import 'package:pure_music/core/enums.dart';

@immutable
class DesktopLyricColors {
  final Color played;
  final Color unplayed;

  const DesktopLyricColors({
    required this.played,
    required this.unplayed,
  });
}

DesktopLyricColors resolveDesktopLyricColors({
  required bool followThemeColor,
  required DesktopLyricBrightnessMode brightnessMode,
  required ColorScheme scheme,
}) {
  if (followThemeColor) {
    return DesktopLyricColors(
      played: scheme.primary,
      unplayed: scheme.onSurface,
    );
  }
  return resolveDesktopLyricNeutralColors(
    mode: brightnessMode,
    effectiveBrightness: scheme.brightness,
  );
}

DesktopLyricColors resolveDesktopLyricNeutralColors({
  required DesktopLyricBrightnessMode mode,
  required Brightness effectiveBrightness,
}) {
  final brightness = switch (mode) {
    DesktopLyricBrightnessMode.follow => effectiveBrightness,
    DesktopLyricBrightnessMode.light => Brightness.light,
    DesktopLyricBrightnessMode.dark => Brightness.dark,
  };
  if (brightness == Brightness.dark) {
    return const DesktopLyricColors(
      played: Color(0xffffffff),
      unplayed: Color(0x59ffffff),
    );
  }
  return const DesktopLyricColors(
    played: Color(0xff000000),
    unplayed: Color(0x73000000),
  );
}
