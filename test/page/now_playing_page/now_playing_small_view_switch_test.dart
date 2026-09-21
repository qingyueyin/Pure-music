import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_small_view_switch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('view switch stays hidden with the cursor unless controls are pinned', () {
    expect(
      nowPlayingSmallViewSwitchRevealed(
        alwaysShowControls: false,
        cursorHidden: true,
      ),
      isFalse,
    );
    expect(
      nowPlayingSmallViewSwitchRevealed(
        alwaysShowControls: false,
        cursorHidden: false,
      ),
      isTrue,
    );
    expect(
      nowPlayingSmallViewSwitchRevealed(
        alwaysShowControls: true,
        cursorHidden: true,
      ),
      isTrue,
    );
  });

  setUp(() async {
    await AppSettings.readFromSettingsMapForTest({'Version': 'test'});
  });

  testWidgets('portrait view switch fills the content row height', (
    tester,
  ) async {
    const rowHeight = 600.0;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: rowHeight,
            child: Row(
              children: [
                NowPlayingSmallViewSwitch(
                  onTap: _noop,
                  icon: Icons.queue_music,
                ),
                Expanded(child: SizedBox.expand()),
                NowPlayingSmallViewSwitch(onTap: _noop, icon: Icons.lyrics),
              ],
            ),
          ),
        ),
      ),
    );

    final switches = find.byType(NowPlayingSmallViewSwitch);
    expect(switches, findsNWidgets(2));
    expect(tester.getSize(switches.first).height, rowHeight);
    expect(tester.getSize(switches.last).height, rowHeight);
    expect(tester.getSize(switches.first).height, isNot(48));
  });

  testWidgets('portrait view switch tooltip anchors to the icon, not the bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: NowPlayingSmallViewSwitch(
              onTap: _noop,
              icon: Icons.queue_music,
              tooltip: '播放列表',
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('播放列表'), findsOneWidget);
    final tooltipSize = tester.getSize(find.byTooltip('播放列表'));
    expect(tooltipSize.height, lessThan(80));
  });

  testWidgets('view switch stays readable at rest and strengthens on hover', (
    tester,
  ) async {
    const rowHeight = 600.0;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: rowHeight,
            child: NowPlayingSmallViewSwitch(
              onTap: _noop,
              icon: Icons.queue_music,
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(NowPlayingSmallViewSwitch)).height,
      rowHeight,
    );
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      nowPlayingSmallViewSwitchRestOpacity,
    );
    expect(nowPlayingSmallViewSwitchRestOpacity, greaterThan(0));
    expect(nowPlayingSmallViewSwitchRestOpacity, lessThan(1));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(
      location: tester.getCenter(find.byType(NowPlayingSmallViewSwitch)),
    );
    addTearDown(gesture.removePointer);
    await tester.pump();

    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
  });

  testWidgets('hidden view switch does not paint by default', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: NowPlayingSmallViewSwitch(
              onTap: _noop,
              icon: Icons.queue_music,
              revealed: false,
            ),
          ),
        ),
      ),
    );

    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
  });
}

void _noop() {}
