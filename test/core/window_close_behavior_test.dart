import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/settings.dart';

void main() {
  tearDown(() async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'WindowCloseBehavior': WindowCloseBehavior.exit.name,
    });
  });

  test('old settings keep exiting when the main window closes', () async {
    await AppSettings.readFromSettingsMapForTest({'Version': 'test'});

    expect(AppSettings.instance.windowCloseBehavior, WindowCloseBehavior.exit);
  });

  test('tray close behavior is restored from settings', () async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'WindowCloseBehavior': WindowCloseBehavior.minimizeToTray.name,
    });

    expect(
      AppSettings.instance.windowCloseBehavior,
      WindowCloseBehavior.minimizeToTray,
    );
  });
}
