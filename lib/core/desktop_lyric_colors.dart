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

bool shouldUseLightDesktopLyricOutline(Color playedColor) {
  return ThemeData.estimateBrightnessForColor(playedColor) == Brightness.dark;
}

DesktopLyricColors resolveDesktopLyricColors({
  required bool followThemeColor,
  required DesktopLyricBrightnessMode brightnessMode,
  required ColorScheme scheme,
  int? customPlayedColor,
  int? customUnplayedColor,
}) {
  if (followThemeColor) {
    return DesktopLyricColors(
      played: scheme.primary,
      unplayed: scheme.onSurface,
    );
  }
  final neutralColors = resolveDesktopLyricNeutralColors(
    mode: brightnessMode,
    effectiveBrightness: scheme.brightness,
  );
  return DesktopLyricColors(
    played: customPlayedColor == null
        ? neutralColors.played
        : Color(customPlayedColor),
    unplayed: customUnplayedColor == null
        ? neutralColors.unplayed
        : Color(customUnplayedColor),
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
