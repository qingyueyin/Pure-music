import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/setting_action_state.dart';

void main() {
  test('minimized window dimensions restore the default size', () {
    expect(normalizedWindowSizeSetting('158.0,26.0'), defaultWindowSizeSetting);
  });

  test('valid window dimensions are preserved', () {
    expect(normalizedWindowSizeSetting('1280.0,756.0'), (
      width: 1280.0,
      height: 756.0,
    ));
  });
}
