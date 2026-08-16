import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/smart_transition_coordinator.dart';

void main() {
  test('committed transition suppresses ordinary auto-next', () {
    var fallbackCalled = false;

    final handled = SmartTransitionCoordinator.resolvePlayerCompleted(
      committed: true,
      targetIsValid: true,
      prepareFallback: () {
        fallbackCalled = true;
        return true;
      },
    );

    expect(handled, isTrue);
    expect(fallbackCalled, isFalse);
  });

  test('failed fallback allows ordinary auto-next', () {
    final handled = SmartTransitionCoordinator.resolvePlayerCompleted(
      committed: false,
      targetIsValid: true,
      prepareFallback: () => false,
    );

    expect(handled, isFalse);
  });

  test('prepared fallback suppresses duplicate auto-next', () {
    final handled = SmartTransitionCoordinator.resolvePlayerCompleted(
      committed: false,
      targetIsValid: true,
      prepareFallback: () => true,
    );

    expect(handled, isTrue);
  });
}
