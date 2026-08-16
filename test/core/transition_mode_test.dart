import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/preference.dart';

void main() {
  test('smart transition mode round-trips through playback preferences', () {
    final preference = PlaybackPreference.fromMap({'transitionMode': 'smart'});

    expect(preference.transitionMode, TransitionMode.smart);
    expect(preference.toMap()['transitionMode'], 'smart');
    expect(
      TransitionMode.fromString('TransitionMode.smart'),
      TransitionMode.smart,
    );
  });

  test('existing transition mode storage names stay stable', () {
    expect(TransitionMode.values.take(3).map((mode) => mode.name), [
      'seamless',
      'fade',
      'crossfade',
    ]);
  });
}
