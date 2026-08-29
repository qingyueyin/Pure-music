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
