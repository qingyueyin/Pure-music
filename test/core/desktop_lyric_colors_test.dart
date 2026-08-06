import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/desktop_lyric_colors.dart';
import 'package:pure_music/core/enums.dart';

void main() {
  group('DesktopLyricBrightnessMode', () {
    test('parses stored names and falls back for invalid values', () {
      expect(
        DesktopLyricBrightnessMode.fromString('light'),
        DesktopLyricBrightnessMode.light,
      );
      expect(
        DesktopLyricBrightnessMode.fromString(
          'DesktopLyricBrightnessMode.dark',
        ),
        DesktopLyricBrightnessMode.dark,
      );
      expect(DesktopLyricBrightnessMode.fromString('invalid'), isNull);
      expect(DesktopLyricBrightnessMode.fromString(null), isNull);
    });
  });

  group('resolveDesktopLyricNeutralColors', () {
    test('follow uses effective light brightness', () {
      final colors = resolveDesktopLyricNeutralColors(
        mode: DesktopLyricBrightnessMode.follow,
        effectiveBrightness: Brightness.light,
      );

      expect(colors.played, const Color(0xff000000));
      expect(colors.unplayed, const Color(0x73000000));
    });

    test('theme color mode keeps theme colors', () {
      final scheme = ColorScheme.fromSeed(
        seedColor: Colors.orange,
        brightness: Brightness.dark,
      );
      final colors = resolveDesktopLyricColors(
        followThemeColor: true,
        brightnessMode: DesktopLyricBrightnessMode.light,
        scheme: scheme,
      );

      expect(colors.played, scheme.primary);
      expect(colors.unplayed, scheme.onSurface);
    });

    test('follow uses effective dark brightness', () {
      final colors = resolveDesktopLyricNeutralColors(
        mode: DesktopLyricBrightnessMode.follow,
        effectiveBrightness: Brightness.dark,
      );

      expect(colors.played, const Color(0xffffffff));
      expect(colors.unplayed, const Color(0x59ffffff));
    });

    test('forced modes ignore effective brightness', () {
      final light = resolveDesktopLyricNeutralColors(
        mode: DesktopLyricBrightnessMode.light,
        effectiveBrightness: Brightness.dark,
      );
      final dark = resolveDesktopLyricNeutralColors(
        mode: DesktopLyricBrightnessMode.dark,
        effectiveBrightness: Brightness.light,
      );

      expect(light.played, const Color(0xff000000));
      expect(light.unplayed, const Color(0x73000000));
      expect(dark.played, const Color(0xffffffff));
      expect(dark.unplayed, const Color(0x59ffffff));
    });
  });
}
