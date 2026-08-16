import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/page/settings_page/other_settings.dart';

void main() {
  final preference = AppPreference.instance.playbackPref;
  late TransitionMode previousMode;

  setUp(() {
    previousMode = preference.transitionMode;
  });

  tearDown(() {
    preference.transitionMode = previousMode;
  });

  testWidgets('smart transition hides manual duration controls', (
    tester,
  ) async {
    preference.transitionMode = TransitionMode.smart;

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox(width: 1000, child: TransitionControl())),
      ),
    );

    expect(find.text('智能衔接'), findsOneWidget);
    expect(find.text('根据歌曲内容自动选择衔接方式'), findsOneWidget);
    expect(find.text('淡出时长'), findsNothing);
    expect(find.text('淡入时长'), findsNothing);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('manual transition modes retain duration controls', (
    tester,
  ) async {
    preference.transitionMode = TransitionMode.crossfade;

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox(width: 1000, child: TransitionControl())),
      ),
    );

    expect(find.text('淡出时长'), findsOneWidget);
    expect(find.text('淡入时长'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(2));
  });
}
