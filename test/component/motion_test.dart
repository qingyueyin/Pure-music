import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/entry.dart';

void main() {
  tearDown(() async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'EnableContentTransitionMotion': true,
    });
  });

  testWidgets('content transition keeps a short fade when disabled', (
    tester,
  ) async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'EnableContentTransitionMotion': false,
    });

    const animation = AlwaysStoppedAnimation<double>(0.5);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              const page = SlideTransitionPage<void>(
                child: SizedBox(key: ValueKey('transition-child')),
              );
              return page.transitionsBuilder(
                context,
                animation,
                const AlwaysStoppedAnimation<double>(0),
                page.child,
              );
            },
          ),
        ),
      ),
    );

    expect(find.byType(FadeTransition), findsOneWidget);
    expect(find.byType(SlideTransition), findsOneWidget);
    expect(find.byKey(const ValueKey('transition-child')), findsOneWidget);
  });

  testWidgets('system reduced motion bypasses content transition', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              const page = SlideTransitionPage<void>(
                child: SizedBox(key: ValueKey('reduced-motion-child')),
              );
              return page.transitionsBuilder(
                context,
                const AlwaysStoppedAnimation<double>(0.5),
                const AlwaysStoppedAnimation<double>(0),
                page.child,
              );
            },
          ),
        ),
      ),
    );

    expect(find.byType(FadeTransition), findsNothing);
    expect(find.byType(SlideTransition), findsNothing);
    expect(find.byKey(const ValueKey('reduced-motion-child')), findsOneWidget);
  });

  testWidgets('list entrance identity history stays bounded', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 200,
          child: TickerMode(
            enabled: false,
            child: ListView.builder(
              controller: controller,
              itemExtent: 20,
              itemCount: 220,
              itemBuilder: (context, index) => DirectionalListItemEntrance(
                identity: index,
                child: Text('$index'),
              ),
            ),
          ),
        ),
      ),
    );

    for (
      var offset = 0.0;
      offset <= controller.position.maxScrollExtent;
      offset += 100
    ) {
      controller.jumpTo(offset);
      await tester.pump();
    }
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();

    expect(listItemEntranceIdentityCount(controller.position), 96);
  });

  testWidgets('the active page keeps the original list entrance', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: DirectionalTabView(
            index: 0,
            children: const [
              Align(
                alignment: Alignment.topLeft,
                child: DirectionalListItemEntrance(
                  child: SizedBox(
                    key: ValueKey('active-item'),
                    width: 40,
                    height: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final item = find.byKey(const ValueKey('active-item'));

    expect(tester.getTopLeft(item).dy, greaterThan(0));
    expect(
      find.ancestor(of: item, matching: find.byType(Opacity)),
      findsOneWidget,
    );

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(item), Offset.zero);
    expect(
      find.ancestor(of: item, matching: find.byType(Opacity)),
      findsNothing,
    );
  });

  testWidgets('tab travel keeps incoming list at its final vertical position', (
    tester,
  ) async {
    final harnessKey = GlobalKey<_TabHarnessState>();
    await tester.pumpWidget(MaterialApp(home: _TabHarness(key: harnessKey)));
    await tester.pumpAndSettle();

    final incoming = find.byKey(const ValueKey('item-1'), skipOffstage: false);
    final verticalPosition = tester.getTopLeft(incoming).dy;
    harnessKey.currentState!.select(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final movingPosition = tester.getTopLeft(incoming);

    expect(movingPosition.dx.abs(), greaterThan(0.01));
    expect(movingPosition.dy, closeTo(verticalPosition, 0.01));
    expect(
      find.ancestor(of: incoming, matching: find.byType(Opacity)),
      findsOneWidget,
    );

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(incoming), Offset(0, verticalPosition));
  });

  testWidgets('rapid tab changes do not release a stale incoming entrance', (
    tester,
  ) async {
    final harnessKey = GlobalKey<_TabHarnessState>();
    await tester.pumpWidget(MaterialApp(home: _TabHarness(key: harnessKey)));
    await tester.pumpAndSettle();
    final incoming = find.byKey(const ValueKey('item-1'), skipOffstage: false);

    harnessKey.currentState!.select(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    harnessKey.currentState!.select(0);
    await tester.pump();
    await tester.pumpAndSettle();

    final verticalPosition = tester.getTopLeft(incoming).dy;
    harnessKey.currentState!.select(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final movingPosition = tester.getTopLeft(incoming);

    expect(movingPosition.dx.abs(), greaterThan(0.01));
    expect(movingPosition.dy, closeTo(verticalPosition, 0.01));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(incoming), Offset(0, verticalPosition));
  });

  testWidgets('SpringProgress starts at the target without an intro', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: _SpringProgressReadout(target: 1)),
    );
    expect(_springReadout(tester), closeTo(1, 0.0001));
  });

  testWidgets('SpringProgress retargets from the live value', (tester) async {
    final harnessKey = GlobalKey<_SpringProgressReadoutState>();
    await tester.pumpWidget(
      MaterialApp(home: _SpringProgressReadout(key: harnessKey, target: 0)),
    );
    harnessKey.currentState!.setTarget(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));
    final midFlight = _springReadout(tester);
    expect(midFlight, greaterThan(0.02));
    expect(midFlight, lessThan(0.98));

    harnessKey.currentState!.setTarget(0);
    await tester.pump();
    final afterRetarget = _springReadout(tester);
    expect(afterRetarget, closeTo(midFlight, 0.08));
    expect(afterRetarget, isNot(closeTo(0, 0.01)));
    expect(afterRetarget, isNot(closeTo(1, 0.01)));
  });

  testWidgets('SpringProgress jumps when animations are disabled', (
    tester,
  ) async {
    final harnessKey = GlobalKey<_SpringProgressReadoutState>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: _SpringProgressReadout(key: harnessKey, target: 0),
        ),
      ),
    );
    harnessKey.currentState!.setTarget(1);
    await tester.pump();
    expect(_springReadout(tester), closeTo(1, 0.0001));
  });

  testWidgets('sidebar spring clips a wide body instead of stretching it', (
    tester,
  ) async {
    final harnessKey = GlobalKey<_LayoutSpringHarnessState>();
    await tester.pumpWidget(
      MaterialApp(home: _LayoutSpringHarness(key: harnessKey)),
    );
    expect(tester.getSize(find.byKey(const ValueKey('rail'))).width, 80);
    expect(tester.getSize(find.byKey(const ValueKey('body'))).width, 320);

    harnessKey.currentState!.setExpanded(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));
    final railWidth = tester.getSize(find.byKey(const ValueKey('rail'))).width;
    expect(railWidth, greaterThan(80));
    expect(railWidth, lessThan(240));
    // Album grids stay on the wide column count while the rail moves.
    expect(tester.getSize(find.byKey(const ValueKey('body'))).width, 320);
    expect(find.byType(OverflowBox), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('body'))).dx,
      closeTo(tester.getTopRight(find.byKey(const ValueKey('rail'))).dx, 0.5),
    );

    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('rail'))).width,
      closeTo(240, 0.05),
    );
    expect(tester.getSize(find.byKey(const ValueKey('body'))).width, 160);
    expect(find.byType(OverflowBox), findsOneWidget);

    harnessKey.currentState!.setExpanded(false);
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey('body'))).width, 320);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('body'))).width, 320);
  });

  testWidgets('sidebar animation preserves body state across layout changes', (
    tester,
  ) async {
    Widget build({required bool expanded, required double progress}) {
      return MaterialApp(
        home: Material(
          child: SizedBox(
            width: 400,
            height: 80,
            child: SpringRailScaffold(
              expanded: expanded,
              progress: progress,
              collapsedWidth: 80,
              expandedWidth: 240,
              rail: const SizedBox.expand(),
              body: const TextField(),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(build(expanded: false, progress: 0));
    await tester.enterText(find.byType(TextField), 'keep cover state');
    final state = tester.state(find.byType(TextField));
    for (final step in [
      (true, 0.0),
      (true, 0.4),
      (true, 1.0),
      (false, 1.0),
      (false, 0.5),
      (false, 0.0),
    ]) {
      await tester.pumpWidget(build(expanded: step.$1, progress: step.$2));
      expect(tester.state(find.byType(TextField)), same(state));
      expect(find.text('keep cover state'), findsOneWidget);
    }
  });

  test('scroll-scrubbed layout progress stays linear', () {
    expect(MotionCurve.scrub(0.25), 0.25);
    expect(MotionCurve.scrub(0.5), 0.5);
    expect(MotionCurve.scrub(1.2), 1.0);
    expect(Curves.easeOutCubic.transform(0.5), closeTo(0.875, 0.01));
  });
}

double _springReadout(WidgetTester tester) {
  return double.parse(
    tester.widget<Text>(find.byKey(const ValueKey('t'))).data!,
  );
}

class _SpringProgressReadout extends StatefulWidget {
  const _SpringProgressReadout({super.key, required this.target});

  final double target;

  @override
  State<_SpringProgressReadout> createState() => _SpringProgressReadoutState();
}

class _SpringProgressReadoutState extends State<_SpringProgressReadout> {
  late double target = widget.target;

  void setTarget(double value) => setState(() => target = value);

  @override
  Widget build(BuildContext context) {
    return SpringProgress(
      target: target,
      builder: (context, t, _) =>
          Text(t.toStringAsFixed(6), key: const ValueKey('t')),
    );
  }
}

class _LayoutSpringHarness extends StatefulWidget {
  const _LayoutSpringHarness({super.key});

  @override
  State<_LayoutSpringHarness> createState() => _LayoutSpringHarnessState();
}

class _LayoutSpringHarnessState extends State<_LayoutSpringHarness> {
  bool expanded = false;

  void setExpanded(bool value) => setState(() => expanded = value);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 400,
        height: 80,
        child: SpringProgress(
          target: expanded ? 1.0 : 0.0,
          builder: (context, t, _) {
            return SpringRailScaffold(
              progress: t,
              expanded: expanded,
              collapsedWidth: 80,
              expandedWidth: 240,
              rail: const ColoredBox(
                key: ValueKey('rail'),
                color: Color(0xFF000000),
              ),
              body: const ColoredBox(
                key: ValueKey('body'),
                color: Color(0xFFFFFFFF),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _TabHarness extends StatefulWidget {
  const _TabHarness({super.key});

  @override
  State<_TabHarness> createState() => _TabHarnessState();
}

class _TabHarnessState extends State<_TabHarness> {
  int index = 0;

  void select(int value) => setState(() => index = value);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 200,
      child: DirectionalTabView(
        index: index,
        children: List.generate(
          2,
          (tab) => Align(
            alignment: Alignment.topLeft,
            child: DirectionalListItemEntrance(
              child: SizedBox(
                key: ValueKey('item-$tab'),
                width: 40,
                height: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
