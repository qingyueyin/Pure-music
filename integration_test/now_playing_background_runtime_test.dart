import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/mesh_gradient_background.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background.dart';

final Uint8List _kBluePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEUAAACnej3aAAAAAXRSTlMAQObYZgAAAApJREFUCNdjYAAAAAIAAeIhvDMAAAAASUVORK5CYII=',
);

final Uint8List _kRedPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXY/jPwPAfAAUAAf+mXJtdAAAAAElFTkSuQmCC',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows runtime: background modes, pause/resume and cover switch stay stable',
      (tester) async {
    final spectrumController = StreamController<Float32List>.broadcast();
    addTearDown(spectrumController.close);

    NowPlayingBackgroundMode mode = NowPlayingBackgroundMode.meshGradient;
    Uint8List? coverBytes = _kBluePng;
    PlayerState playerState = PlayerState.playing;
    bool isVisible = true;

    Future<void> pumpHost() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 960,
                height: 540,
                child: NowPlayingBackground(
                  mode: mode,
                  fallbackColor: Colors.black,
                  inputs: NowPlayingBackgroundInputs(
                    albumCoverBytes: coverBytes,
                    dominantColor: Colors.blue,
                    spectrumStream: spectrumController.stream,
                    enableAnimation: true,
                    isVisible: isVisible,
                    playerState: playerState,
                    flowSpeed: 1.0,
                    intensity: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    await pumpHost();
    expect(find.byType(MeshGradientBackground), findsOneWidget);

    spectrumController.add(Float32List.fromList(
      [0.9, 0.7, 0.5, 0.3, 0.1, 0.05, 0.02, 0.01],
    ));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);

    playerState = PlayerState.paused;
    await pumpHost();
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);

    playerState = PlayerState.playing;
    coverBytes = _kRedPng;
    await pumpHost();
    await tester.pump(const Duration(milliseconds: 900));
    expect(tester.takeException(), isNull);

    mode = NowPlayingBackgroundMode.meshGradient;
    await pumpHost();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(MeshGradientBackground), findsOneWidget);
    expect(tester.takeException(), isNull);

    spectrumController.add(Float32List.fromList(
      [0.15, 0.25, 0.35, 0.45, 0.2, 0.1, 0.05, 0.02],
    ));
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.takeException(), isNull);

    isVisible = false;
    await pumpHost();
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.takeException(), isNull);

    isVisible = true;
    mode = NowPlayingBackgroundMode.blurCover;
    await pumpHost();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(NowPlayingBackground), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
