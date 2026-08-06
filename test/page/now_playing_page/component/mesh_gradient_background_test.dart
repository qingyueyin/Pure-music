import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/mesh_gradient_background.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

Future<Uint8List> _capturePixels(
  WidgetTester tester,
  GlobalKey boundaryKey,
) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = (await tester.runAsync(boundary.toImage))!;
  final data = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  image.dispose();
  return Uint8List.fromList(data!.buffer.asUint8List());
}

double _averageRgbDifference(Uint8List before, Uint8List after) {
  var totalDifference = 0;
  for (var offset = 0; offset < before.length; offset += 4) {
    totalDifference += (before[offset] - after[offset]).abs();
    totalDifference += (before[offset + 1] - after[offset + 1]).abs();
    totalDifference += (before[offset + 2] - after[offset + 2]).abs();
  }
  return totalDifference / (before.length / 4 * 3);
}

Widget _animatedMeshFixture(GlobalKey boundaryKey, List<Color> colors) {
  return MaterialApp(
    theme: ThemeData.dark(),
    home: Center(
      child: RepaintBoundary(
        key: boundaryKey,
        child: SizedBox(
          width: 240,
          height: 140,
          child: MeshGradientBackgroundInternal(
            fallbackColor: const Color(0xFF171717),
            inputs: NowPlayingBackgroundInputs(
              preExtractedColors: colors,
              enableAnimation: true,
              isVisible: true,
              playerState: PlayerState.playing,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('mesh gradient ignores spectrum streams', (tester) async {
    var listens = 0;
    final stream = StreamController<Float32List>.broadcast(
      onListen: () => listens++,
    );
    addTearDown(stream.close);

    await tester.pumpWidget(
      MaterialApp(
        home: MeshGradientBackgroundInternal(
          fallbackColor: Colors.black,
          inputs: NowPlayingBackgroundInputs(
            preExtractedColors: const <Color>[
              Colors.blue,
              Colors.lightBlue,
              Colors.blueGrey,
              Colors.red,
            ],
            spectrumStream: stream.stream,
            enableAnimation: true,
            isVisible: true,
            playerState: PlayerState.playing,
          ),
        ),
      ),
    );

    expect(listens, 0);
  });

  testWidgets('extreme palette stays readable on a dark player page', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: const SizedBox.square(
              dimension: 96,
              child: MeshGradientBackgroundInternal(
                fallbackColor: Color(0xFF171717),
                inputs: NowPlayingBackgroundInputs(
                  preExtractedColors: <Color>[
                    Colors.black,
                    Colors.white,
                    Colors.white,
                    Colors.black,
                  ],
                  enableAnimation: false,
                  isVisible: true,
                  playerState: PlayerState.paused,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    final pixels = await _capturePixels(tester, boundaryKey);
    var minLuminance = 1.0;
    var maxLuminance = 0.0;
    var maxChannelSpread = 0;
    for (var offset = 0; offset < pixels.length; offset += 4) {
      final red = pixels[offset];
      final green = pixels[offset + 1];
      final blue = pixels[offset + 2];
      final color = Color.fromARGB(
        255,
        red,
        green,
        blue,
      );
      final luminance = color.computeLuminance();
      if (luminance < minLuminance) minLuminance = luminance;
      if (luminance > maxLuminance) maxLuminance = luminance;
      final spread = [red, green, blue].reduce((a, b) => a > b ? a : b) -
          [red, green, blue].reduce((a, b) => a < b ? a : b);
      if (spread > maxChannelSpread) maxChannelSpread = spread;
    }

    expect(maxLuminance, lessThanOrEqualTo(0.20));
    expect(maxLuminance - minLuminance, greaterThan(0.10));
    expect(maxChannelSpread, lessThanOrEqualTo(2));
  });

  testWidgets('bright saturated cover colors remain readable in dark mode', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      _animatedMeshFixture(boundaryKey, const <Color>[
        Color(0xFFF5F06A),
        Color(0xFFFFFFFF),
        Color(0xFFFF4D78),
        Color(0xFF3EE6C2),
      ]),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    final pixels = await _capturePixels(tester, boundaryKey);
    var maxLuminance = 0.0;
    for (var offset = 0; offset < pixels.length; offset += 4) {
      final luminance = Color.fromARGB(
        255,
        pixels[offset],
        pixels[offset + 1],
        pixels[offset + 2],
      ).computeLuminance();
      if (luminance > maxLuminance) maxLuminance = luminance;
    }

    expect(maxLuminance, lessThanOrEqualTo(0.20));
  });

  testWidgets('all-black palette keeps restrained tonal depth', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      _animatedMeshFixture(
        boundaryKey,
        const <Color>[
          Colors.black,
          Colors.black,
          Colors.black,
          Colors.black,
        ],
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    final pixels = await _capturePixels(tester, boundaryKey);
    var minLuminance = 1.0;
    var maxLuminance = 0.0;
    var maxChannelSpread = 0;
    for (var offset = 0; offset < pixels.length; offset += 4) {
      final red = pixels[offset];
      final green = pixels[offset + 1];
      final blue = pixels[offset + 2];
      final luminance = Color.fromARGB(
        255,
        red,
        green,
        blue,
      ).computeLuminance();
      if (luminance < minLuminance) minLuminance = luminance;
      if (luminance > maxLuminance) maxLuminance = luminance;
      final spread = [red, green, blue].reduce((a, b) => a > b ? a : b) -
          [red, green, blue].reduce((a, b) => a < b ? a : b);
      if (spread > maxChannelSpread) maxChannelSpread = spread;
    }

    expect(maxLuminance, lessThanOrEqualTo(0.05));
    expect(maxLuminance - minLuminance, greaterThan(0.008));
    expect(maxChannelSpread, lessThanOrEqualTo(2));
  });

  testWidgets('small cover accents remain visible across the dark mesh', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: const SizedBox(
              width: 320,
              height: 180,
              child: MeshGradientBackgroundInternal(
                fallbackColor: Color(0xFF171717),
                inputs: NowPlayingBackgroundInputs(
                  preExtractedColors: <Color>[
                    Color(0xFF869DA9),
                    Color(0xFF91ADB7),
                    Color(0xFF221E1B),
                    Color(0xFFD28D6B),
                  ],
                  enableAnimation: false,
                  isVisible: true,
                  playerState: PlayerState.paused,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    final pixels = await _capturePixels(tester, boundaryKey);
    var hasCoolRegion = false;
    var hasWarmRegion = false;
    var coolPixels = 0;
    var warmPixels = 0;
    for (var offset = 0; offset < pixels.length; offset += 4) {
      final red = pixels[offset];
      final green = pixels[offset + 1];
      final blue = pixels[offset + 2];
      final isCool = blue > red + 12 && blue > green;
      final isWarm = red > blue + 28 && green > blue + 8;
      hasCoolRegion |= isCool;
      hasWarmRegion |= isWarm;
      if (isCool) coolPixels++;
      if (isWarm) warmPixels++;
    }

    expect(hasCoolRegion, isTrue);
    expect(hasWarmRegion, isTrue);
    final pixelCount = pixels.length ~/ 4;
    expect(coolPixels, greaterThan(pixelCount ~/ 20));
    expect(warmPixels, greaterThan(pixelCount ~/ 20));
  });

  testWidgets('near monochrome palette keeps smooth tonal depth', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: const SizedBox(
              width: 240,
              height: 140,
              child: MeshGradientBackgroundInternal(
                fallbackColor: Color(0xFF171717),
                inputs: NowPlayingBackgroundInputs(
                  preExtractedColors: <Color>[
                    Color(0xFFF2F2F0),
                    Color(0xFFF2F2F0),
                    Color(0xFFF2F2F0),
                    Color(0xFFF2F2F0),
                  ],
                  enableAnimation: false,
                  isVisible: true,
                  playerState: PlayerState.paused,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    final pixels = await _capturePixels(tester, boundaryKey);

    const width = 240;
    var minLuminance = 1.0;
    var maxLuminance = 0.0;
    var maxNeighborDifference = 0.0;
    var previousLuminance = 0.0;
    for (var offset = 0; offset < pixels.length; offset += 4) {
      final pixelIndex = offset ~/ 4;
      final luminance = Color.fromARGB(
        255,
        pixels[offset],
        pixels[offset + 1],
        pixels[offset + 2],
      ).computeLuminance();
      if (luminance < minLuminance) minLuminance = luminance;
      if (luminance > maxLuminance) maxLuminance = luminance;
      if (pixelIndex % width != 0) {
        final difference = (luminance - previousLuminance).abs();
        if (difference > maxNeighborDifference) {
          maxNeighborDifference = difference;
        }
      }
      previousLuminance = luminance;
    }

    expect(maxLuminance - minLuminance, inInclusiveRange(0.02, 0.18));
    expect(maxNeighborDifference, lessThan(0.015));
  });

  testWidgets('near-white cover keeps its small chromatic subject color', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      _animatedMeshFixture(boundaryKey, const <Color>[
        Color(0xFFF0F0F0),
        Color(0xFFEAEAEA),
        Color(0xFF3F3F3F),
        Color(0xFFF1A6C2),
      ]),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    final pixels = await _capturePixels(tester, boundaryKey);
    var neutralPixels = 0;
    var pinkPixels = 0;
    for (var offset = 0; offset < pixels.length; offset += 4) {
      final red = pixels[offset];
      final green = pixels[offset + 1];
      final blue = pixels[offset + 2];
      if ((red - green).abs() <= 5 && (blue - green).abs() <= 5) {
        neutralPixels++;
      }
      if (red > green + 12 && blue > green + 4) pinkPixels++;
    }

    expect(pinkPixels, greaterThan(pixels.length ~/ 160));
    expect(neutralPixels, greaterThan(pinkPixels));
  });

  testWidgets('mesh field visibly changes within one second', (tester) async {
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      _animatedMeshFixture(boundaryKey, const <Color>[
        Color(0xFF467AA3),
        Color(0xFF315E7D),
        Color(0xFFB44E62),
        Color(0xFFB79C48),
      ]),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    final before = await _capturePixels(tester, boundaryKey);

    await tester.pump(const Duration(milliseconds: 100));
    final shortlyAfter = await _capturePixels(tester, boundaryKey);
    expect(_averageRgbDifference(before, shortlyAfter), lessThan(8.0));

    await tester.pump(const Duration(milliseconds: 900));
    final after = await _capturePixels(tester, boundaryKey);
    expect(_averageRgbDifference(before, after), greaterThan(2.0));
  });

  testWidgets('related cover colors still show visible mesh motion', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      _animatedMeshFixture(boundaryKey, const <Color>[
        Color(0xFF869DA9),
        Color(0xFF91ADB7),
        Color(0xFF221E1B),
        Color(0xFFD28D6B),
      ]),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    final before = await _capturePixels(tester, boundaryKey);

    await tester.pump(const Duration(seconds: 1));
    final after = await _capturePixels(tester, boundaryKey);
    expect(_averageRgbDifference(before, after), greaterThan(1.2));
  });
}
