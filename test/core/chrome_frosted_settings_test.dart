import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/settings.dart';

void main() {
  tearDown(() async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'EnableTitleBarFrostedGlass': false,
      'EnableSidebarFrostedGlass': false,
    });
  });

  test('chrome frosted glass defaults to MD3 (off)', () async {
    await AppSettings.readFromSettingsMapForTest({'Version': 'test'});

    expect(AppSettings.instance.enableTitleBarFrostedGlass, isFalse);
    expect(AppSettings.instance.enableSidebarFrostedGlass, isFalse);
  });

  test('chrome frosted glass settings can be enabled independently', () async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'EnableTitleBarFrostedGlass': true,
      'EnableSidebarFrostedGlass': false,
    });

    expect(AppSettings.instance.enableTitleBarFrostedGlass, isTrue);
    expect(AppSettings.instance.enableSidebarFrostedGlass, isFalse);

    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'EnableTitleBarFrostedGlass': false,
      'EnableSidebarFrostedGlass': true,
    });

    expect(AppSettings.instance.enableTitleBarFrostedGlass, isFalse);
    expect(AppSettings.instance.enableSidebarFrostedGlass, isTrue);
  });

  test('missing chrome frosted keys reset to MD3', () async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'EnableTitleBarFrostedGlass': true,
      'EnableSidebarFrostedGlass': true,
    });

    await AppSettings.readFromSettingsMapForTest({'Version': 'test'});

    expect(AppSettings.instance.enableTitleBarFrostedGlass, isFalse);
    expect(AppSettings.instance.enableSidebarFrostedGlass, isFalse);
  });
}
