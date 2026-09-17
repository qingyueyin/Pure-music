import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/window_render_gate.dart';

void main() {
  test('visible window is foreground even if it would be unfocused', () {
    expect(windowRenderShouldEnableFrames(trayHidden: false), isTrue);
  });

  test('only hiding to tray is background', () {
    expect(windowRenderShouldEnableFrames(trayHidden: true), isFalse);
  });

  testWidgets('hiding to tray disables ticker mode then pauses the scheduler', (
    tester,
  ) async {
    final applied = <bool>[];
    final gate = WindowRenderGate(applyFramesEnabled: applied.add);
    addTearDown(gate.detach);

    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: gate.framesEnabled,
        builder: (context, enabled, _) {
          return TickerMode(enabled: enabled, child: const SizedBox.shrink());
        },
      ),
    );

    expect(gate.framesEnabled.value, isTrue);
    expect(applied, isEmpty);

    gate.setTrayHidden(true);
    expect(gate.framesEnabled.value, isFalse);
    expect(applied, isEmpty);

    await tester.pump();
    expect(applied, [false]);
  });

  testWidgets('showing the window resumes the scheduler before ticker mode', (
    tester,
  ) async {
    final applied = <bool>[];
    final gate = WindowRenderGate(applyFramesEnabled: applied.add);
    addTearDown(gate.detach);

    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: gate.framesEnabled,
        builder: (context, enabled, _) {
          return TickerMode(enabled: enabled, child: const SizedBox.shrink());
        },
      ),
    );

    gate.setTrayHidden(true);
    await tester.pump();
    applied.clear();

    gate.enterForeground();
    expect(applied, [true]);
    expect(gate.framesEnabled.value, isTrue);
  });

  testWidgets('showing before the pause frame leaves the scheduler running', (
    tester,
  ) async {
    final applied = <bool>[];
    final gate = WindowRenderGate(applyFramesEnabled: applied.add);
    addTearDown(gate.detach);

    await tester.pumpWidget(const SizedBox.shrink());
    gate.setTrayHidden(true);
    gate.enterForeground();
    await tester.pump();
    expect(applied, isEmpty);
    expect(gate.framesEnabled.value, isTrue);
  });

  testWidgets('resumed or inactive lifecycle forces foreground', (tester) async {
    final applied = <bool>[];
    final gate = WindowRenderGate(applyFramesEnabled: applied.add);
    addTearDown(gate.detach);

    await tester.pumpWidget(const SizedBox.shrink());
    gate.setTrayHidden(true);
    await tester.pump();
    applied.clear();

    gate.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(gate.framesEnabled.value, isTrue);
    expect(applied, [true]);

    gate.setTrayHidden(true);
    await tester.pump();
    applied.clear();
    gate.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(gate.framesEnabled.value, isTrue);
    expect(applied, [true]);
  });

  testWidgets('hidden lifecycle does not pause a visible window', (
    tester,
  ) async {
    final applied = <bool>[];
    final gate = WindowRenderGate(applyFramesEnabled: applied.add);
    addTearDown(gate.detach);

    await tester.pumpWidget(const SizedBox.shrink());
    gate.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await tester.pump();
    expect(gate.framesEnabled.value, isTrue);
    expect(applied, isEmpty);
  });

  test('lyric UI updates are dropped while frames are off', () {
    expect(shouldAcceptLyricUiUpdate(windowFramesEnabled: false), isFalse);
    expect(shouldAcceptLyricUiUpdate(windowFramesEnabled: true), isTrue);
  });

  testWidgets('warmup completes after a resumed frame', (tester) async {
    final gate = WindowRenderGate(applyFramesEnabled: (_) {});
    addTearDown(gate.detach);
    await tester.pumpWidget(const SizedBox.shrink());
    gate.setTrayHidden(true);
    await tester.pump();
    gate.enterForeground();
    final warmup = gate.waitForWarmup();
    await tester.pump();
    await warmup;
  });
}
