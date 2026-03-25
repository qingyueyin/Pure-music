import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/widget/breathing_dots.dart';

void main() {
  testWidgets('BreathingDots can reuse external controller across rebuilds',
      (tester) async {
    late final AnimationController controller;

    await tester.pumpWidget(
      MaterialApp(
        home: _BreathingDotsHarness(
          onControllerReady: (value) => controller = value,
        ),
      ),
    );

    controller.value = 0.37;
    await tester.pump();

    final firstOpacity = tester.widget<Opacity>(find.byType(Opacity)).opacity;

    await tester.pumpWidget(
      MaterialApp(
        home: _BreathingDotsHarness(
          onControllerReady: (value) => controller = value,
          controller: controller,
        ),
      ),
    );
    await tester.pump();

    final secondOpacity = tester.widget<Opacity>(find.byType(Opacity)).opacity;
    expect(secondOpacity, closeTo(firstOpacity, 1e-9));
  });
}

class _BreathingDotsHarness extends StatefulWidget {
  const _BreathingDotsHarness({
    required this.onControllerReady,
    this.controller,
  });

  final void Function(AnimationController controller) onControllerReady;
  final AnimationController? controller;

  @override
  State<_BreathingDotsHarness> createState() => _BreathingDotsHarnessState();
}

class _BreathingDotsHarnessState extends State<_BreathingDotsHarness>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = widget.controller ??
      AnimationController(
        vsync: this,
        duration: const Duration(seconds: 2),
      );

  @override
  void initState() {
    super.initState();
    widget.onControllerReady(_controller);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: BreathingDots(
          controller: _controller,
        ),
      ),
    );
  }
}
