import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/settings.dart';

void main() {
  test('portable builds keep data next to the executable', () {
    final result = resolveAppDataPath(
      usePortableData: true,
      executablePath: r'D:\Apps\Pure Music\pure_music.exe',
      environment: const {
        'LOCALAPPDATA': r'C:\Users\listener\AppData\Local',
      },
    );

    expect(result, r'D:\Apps\Pure Music\data');
  });

  test('installed builds use the local user profile', () {
    final result = resolveAppDataPath(
      usePortableData: false,
      executablePath: r'C:\Program Files\Pure Music\pure_music.exe',
      environment: const {
        'LOCALAPPDATA': r'C:\Users\listener\AppData\Local',
        'APPDATA': r'C:\Users\listener\AppData\Roaming',
      },
    );

    expect(result, r'C:\Users\listener\AppData\Local\pure_music');
  });

  test('development processes do not write into the SDK directory', () {
    final result = resolveAppDataPath(
      usePortableData: true,
      executablePath: r'C:\flutter\bin\cache\dart.exe',
      environment: const {
        'LOCALAPPDATA': r'C:\Users\listener\AppData\Local',
      },
    );

    expect(result, r'C:\Users\listener\AppData\Local\pure_music');
  });
}
