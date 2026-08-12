import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/scroll_aware_future_builder.dart';

void main() {
  testWidgets('sustained fast scrolling cannot starve visible loads', (
    tester,
  ) async {
    var loadCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ListView.builder(
          physics: const _AlwaysDeferPhysics(),
          itemExtent: 48,
          itemCount: 20,
          itemBuilder: (context, index) => ScrollAwareFutureBuilder<int>(
            identity: '$index',
            future: () async => ++loadCount,
            builder: (context, snapshot) => Text('${snapshot.data ?? 0}'),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 256));

    expect(loadCount, greaterThan(0));
    expect(loadCount, lessThanOrEqualTo(2));
  });
}

class _AlwaysDeferPhysics extends ScrollPhysics {
  const _AlwaysDeferPhysics({super.parent});

  @override
  _AlwaysDeferPhysics applyTo(ScrollPhysics? ancestor) =>
      _AlwaysDeferPhysics(parent: buildParent(ancestor));

  @override
  bool recommendDeferredLoading(
    double velocity,
    ScrollMetrics metrics,
    BuildContext context,
  ) => true;
}
