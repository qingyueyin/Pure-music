import 'package:flutter_test/flutter_test.dart';

import 'package:pure_music/core/preference.dart';

void main() {
  test('PlaybackPreference: missing output keys keeps current backend behavior',
      () {
    // Provide required legacy keys; we're specifically asserting the behavior
    // when the *new* keys are missing.
    final pref = PlaybackPreference.fromMap({
      'playMode': 'forward',
    });
    final map = pref.toMap();

    // Existing users should stay on the current (system/default) backend unless
    // they explicitly opt into ASIO later.
    expect(map['outputBackend'], 'system');
    expect(map['asioDeviceIndex'], 0);
  });

  test('PlaybackPreference: output backend and ASIO device index round-trip',
      () {
    final input = <String, dynamic>{
      'playMode': 'forward',
      'volumeDsp': 1.0,
      'eqGains': List<double>.filled(10, 0.0),
      'eqPresets': const <dynamic>[],
      'outputBackend': 'asio',
      'asioDeviceIndex': 2,
    };

    final pref = PlaybackPreference.fromMap(input);
    final out = pref.toMap();

    expect(out['outputBackend'], 'asio');
    expect(out['asioDeviceIndex'], 2);
  });

  test('PlaybackPreference: invalid stored backend falls back safely', () {
    final input = <String, dynamic>{
      'playMode': 'forward',
      'volumeDsp': 1.0,
      'eqGains': List<double>.filled(10, 0.0),
      'eqPresets': const <dynamic>[],
      'outputBackend': 'not_a_real_backend',
      'asioDeviceIndex': 4,
    };

    final pref = PlaybackPreference.fromMap(input);
    final out = pref.toMap();

    expect(out['outputBackend'], 'system');
    // Device index should still be persisted; it is only meaningful when ASIO
    // is selected.
    expect(out['asioDeviceIndex'], 4);
  });

  test('PlaybackPreference: non-string stored backend falls back safely', () {
    final input = <String, dynamic>{
      'playMode': 'forward',
      'volumeDsp': 1.0,
      'eqGains': List<double>.filled(10, 0.0),
      'eqPresets': const <dynamic>[],
      'outputBackend': 123,
      'asioDeviceIndex': 1,
    };

    final pref = PlaybackPreference.fromMap(input);
    final out = pref.toMap();

    expect(out['outputBackend'], 'system');
    expect(out['asioDeviceIndex'], 1);
  });
}
