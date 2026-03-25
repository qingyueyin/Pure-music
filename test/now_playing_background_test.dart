import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/mesh_gradient_background.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background.dart';

void main() {
  const baseInputs = NowPlayingBackgroundInputs(
    dominantColor: Colors.blue,
    enableAnimation: true,
    isVisible: true,
    playerState: PlayerState.playing,
  );

  test('NowPlayingBackgroundInputs only animates while visible and playing', () {
    expect(baseInputs.shouldAnimate, isTrue);

    expect(
      baseInputs.copyWith(isVisible: false).shouldAnimate,
      isFalse,
    );
    expect(
      baseInputs.copyWith(playerState: PlayerState.paused).shouldAnimate,
      isFalse,
    );
    expect(
      baseInputs.copyWith(enableAnimation: false).shouldAnimate,
      isFalse,
    );
  });

  testWidgets('NowPlayingBackground maps legacy shader fallback to mesh mode',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NowPlayingBackground(
            mode: NowPlayingBackgroundMode.meshGradient,
            inputs: baseInputs,
            fallbackColor: Colors.black,
          ),
        ),
      ),
    );

    expect(find.byType(MeshGradientBackground), findsOneWidget);
  });

  testWidgets('NowPlayingBackground routes mesh mode to MeshGradientBackground',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NowPlayingBackground(
            mode: NowPlayingBackgroundMode.meshGradient,
            inputs: baseInputs,
            fallbackColor: Colors.black,
          ),
        ),
      ),
    );

    expect(find.byType(MeshGradientBackground), findsOneWidget);
  });

  testWidgets('NowPlayingBackground routes simple mode to plain fallback',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NowPlayingBackground(
            mode: NowPlayingBackgroundMode.simpleFallback,
            inputs: baseInputs,
            fallbackColor: Colors.black,
          ),
        ),
      ),
    );

    expect(find.byType(ColoredBox), findsWidgets);
    expect(find.byType(MeshGradientBackground), findsNothing);
  });
}
