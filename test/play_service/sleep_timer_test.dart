import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/sleep_timer.dart';

void main() {
  final timer = SleepTimerService.instance;
  late int resumed;
  late int expired;

  setUp(() {
    timer.setOnCancelExtending(() {});
    timer.cancel();
    resumed = 0;
    expired = 0;
    timer.autoExtendNotifier.value = true;
    timer.setOnEnterExtending(() {});
    timer.setOnCancelExtending(() {
      expect(timer.isExtending, isFalse);
      resumed++;
    });
    timer.setOnExpired(() => expired++);
  });

  tearDown(() {
    timer.setOnCancelExtending(() {});
    timer.setOnExpired(() {});
    timer.setOnEnterExtending(() {});
    timer.cancel();
    timer.autoExtendNotifier.value = true;
  });

  Future<void> enterExtending(WidgetTester tester) async {
    timer.start(Duration.zero);
    await tester.pump(const Duration(seconds: 1));
    expect(timer.isExtending, isTrue);
  }

  testWidgets(
    'cancelling the end-of-song wait resumes transition preparation',
    (tester) async {
      await enterExtending(tester);
      timer.cancel();
      expect(timer.state, SleepTimerState.idle);
      expect(resumed, 1);
      expect(expired, 0);
      timer.cancel();
      expect(resumed, 1);
    },
  );

  testWidgets('replacing the end-of-song wait resumes transition preparation', (
    tester,
  ) async {
    await enterExtending(tester);
    timer.start(const Duration(minutes: 10));
    expect(timer.state, SleepTimerState.counting);
    expect(resumed, 1);
    expect(expired, 0);
    timer.cancel();
    expect(resumed, 1);
  });

  testWidgets('cancelling a countdown does not rebuild transitions', (
    tester,
  ) async {
    timer.start(const Duration(minutes: 10));
    timer.cancel();
    expect(resumed, 0);
    expect(expired, 0);
  });

  for (final action in ['complete', 'pause', 'change']) {
    testWidgets('$action does not requeue transitions during timer cleanup', (
      tester,
    ) async {
      await enterExtending(tester);
      switch (action) {
        case 'complete':
          timer.onSongCompleted();
          break;
        case 'pause':
          timer.onManualPause();
          break;
        case 'change':
          timer.onSongChanged('next.flac');
          break;
      }
      expect(timer.state, SleepTimerState.idle);
      expect(resumed, 0);
      expect(expired, action == 'complete' ? 1 : 0);
    });
  }
}
