import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/audio_reactive_flow.dart';
import 'package:pure_music/page/now_playing_page/component/flowing_light_background.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

Future<Uint8List> _createCoverPng() async {
  return base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8A'
    'AQUBAScY42YAAAAASUVORK5CYII=',
  );
}

Future<void> _pumpAsyncWork(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  test('visual normalization strengthens quiet spectrum response', () {
    final normalizer = AudioReactiveFlowNormalizer();
    const input = AudioReactiveFlowResponse(0.16, 0.10, 0.04);
    late AudioReactiveFlowResponse output;

    for (var i = 0; i < 30; i++) {
      output = normalizer.update(input);
    }

    expect(output.low, greaterThan(input.low * 1.5));
    expect(output.mid / output.low, closeTo(input.mid / input.low, 0.001));
  });

  test('visual normalization settles loud spectrum near its target peak', () {
    final normalizer = AudioReactiveFlowNormalizer();
    late AudioReactiveFlowResponse output;

    for (var i = 0; i < 30; i++) {
      output = normalizer.update(
        const AudioReactiveFlowResponse(0.9, 0.5, 0.2),
      );
    }

    expect(output.low, closeTo(0.5, 0.001));
    expect(output.mid / output.low, closeTo(0.5 / 0.9, 0.001));
  });

  test('visual normalization caps gain for near-silent spectrum', () {
    final normalizer = AudioReactiveFlowNormalizer();

    final output = normalizer.update(
      const AudioReactiveFlowResponse(0.0011, 0.0005, 0.0002),
    );

    expect(output.low, closeTo(0.033, 0.001));
  });

  test('visual normalization keeps silence silent and reset clears its peak',
      () {
    final normalizer = AudioReactiveFlowNormalizer();
    normalizer.update(const AudioReactiveFlowResponse(0.4, 0.2, 0.1));
    normalizer.reset();

    final silence = normalizer.update(AudioReactiveFlowResponse.zero);
    final afterReset =
        normalizer.update(const AudioReactiveFlowResponse(0.1, 0.05, 0.02));

    expect(silence.isNearlySilent, isTrue);
    expect(afterReset.low, greaterThan(0.2));
  });

  test('bass transient ignores startup and reacts to a real rising edge', () {
    final detector = AudioReactiveFlowTransientDetector();

    expect(detector.update(0.12), 0);
    expect(detector.update(0.13), lessThan(0.1));
    expect(detector.update(0.62), greaterThan(0.9));
  });

  test('bass impact includes the upper bass band', () {
    expect(audioReactiveFlowBassEnergy([0.12, 0.70]), closeTo(0.595, 0.001));
    expect(audioReactiveFlowBassEnergy([0.68, 0.20]), closeTo(0.68, 0.001));
  });

  test('bass transient gives a medium rising edge visible strength', () {
    final detector = AudioReactiveFlowTransientDetector();
    detector.update(0.30);

    expect(detector.update(0.45), greaterThan(0.5));
  });

  test('bass transient resets across silence without a startup flash', () {
    final detector = AudioReactiveFlowTransientDetector();
    detector.update(0.18);
    detector.update(0.70);

    expect(detector.update(0), 0);
    expect(detector.update(0.40), 0);
  });

  test('bass transient does not retrigger while low energy is falling', () {
    final detector = AudioReactiveFlowTransientDetector();
    detector.update(0.12);
    detector.update(0.62);

    expect(detector.update(0.55), 0);
    expect(detector.update(0.42), 0);
  });

  test('bass pulse rises and falls without jumping to the trigger value', () {
    final pulse = AudioReactiveFlowPulseEnvelope()..trigger(1);

    final firstFrame = pulse.advance(1 / 60);
    var peak = firstFrame;
    for (var frame = 0; frame < 12; frame++) {
      peak = max(peak, pulse.advance(1 / 60));
    }
    for (var frame = 0; frame < 60; frame++) {
      pulse.advance(1 / 60);
    }

    expect(firstFrame, inExclusiveRange(0.5, 0.7));
    expect(peak, greaterThan(firstFrame));
    expect(pulse.value, lessThan(0.05));
  });

  test('smallest artwork layer is cropped beyond the viewport', () {
    const output = Size(320, 180);
    const artwork = Size.square(512);

    final scale = flowingLightArtworkCropScale(output, artwork);
    final renderedSide = artwork.width * scale;

    expect(renderedSide, greaterThanOrEqualTo(output.width * 1.3));
    expect(renderedSide, greaterThan(output.height * 2));
  });

  test('audio breathing stays visible without oversized face movement', () {
    expect(flowingLightBreathingScale(0.5), closeTo(1.025, 0.001));
    expect(flowingLightBreathingScale(1), lessThanOrEqualTo(1.05));
    expect(
      flowingLightBreathingScale(0.5, bassTransient: 1),
      closeTo(1.175, 0.001),
    );
  });

  test('artwork layers carry the cover color over the sampled base color', () {
    expect(flowingLightArtworkOpacityCeiling(), greaterThanOrEqualTo(0.9));
  });

  testWidgets('disabled audio-reactive flow does not subscribe to spectrum', (
    tester,
  ) async {
    final spectrum = StreamController<Float32List>.broadcast();
    addTearDown(spectrum.close);

    await tester.pumpWidget(
      MaterialApp(
        home: FlowingLightBackground(
          fallbackColor: Colors.black,
          inputs: NowPlayingBackgroundInputs(
            spectrumStream: spectrum.stream,
            enableAnimation: true,
            isVisible: true,
            playerState: PlayerState.playing,
            audioReactiveFlow: false,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(spectrum.hasListener, isFalse);
  });

  testWidgets('paused audio-reactive flow releases its spectrum subscription', (
    tester,
  ) async {
    final spectrum = StreamController<Float32List>.broadcast();
    addTearDown(spectrum.close);

    await tester.pumpWidget(
      MaterialApp(
        home: FlowingLightBackground(
          fallbackColor: Colors.black,
          inputs: NowPlayingBackgroundInputs(
            spectrumStream: spectrum.stream,
            enableAnimation: true,
            isVisible: true,
            playerState: PlayerState.paused,
            audioReactiveFlow: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(spectrum.hasListener, isFalse);
  });

  testWidgets('ticker mode controls the spectrum subscription', (tester) async {
    final spectrum = StreamController<Float32List>.broadcast();
    addTearDown(spectrum.close);
    final cover = await _createCoverPng();

    Widget buildSubject({required bool tickerModeEnabled}) {
      return MaterialApp(
        home: TickerMode(
          enabled: tickerModeEnabled,
          child: FlowingLightBackground(
            fallbackColor: Colors.black,
            inputs: NowPlayingBackgroundInputs(
              albumCoverBytes: cover,
              spectrumStream: spectrum.stream,
              enableAnimation: true,
              isVisible: true,
              playerState: PlayerState.playing,
              audioReactiveFlow: true,
            ),
          ),
        ),
      );
    }

    try {
      await tester.pumpWidget(buildSubject(tickerModeEnabled: false));
      await _pumpAsyncWork(tester);
      expect(spectrum.hasListener, isFalse);

      await tester.pumpWidget(buildSubject(tickerModeEnabled: true));
      await tester.pump();
      expect(spectrum.hasListener, isTrue);

      await tester.pumpWidget(buildSubject(tickerModeEnabled: false));
      await tester.pump();
      expect(spectrum.hasListener, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('invalid current cover falls back instead of keeping old artwork',
      (
    tester,
  ) async {
    final cover = await _createCoverPng();

    Widget buildSubject(Uint8List bytes) {
      return MaterialApp(
        home: FlowingLightBackground(
          fallbackColor: Colors.black,
          inputs: NowPlayingBackgroundInputs(
            albumCoverBytes: bytes,
            enableAnimation: false,
            isVisible: true,
            playerState: PlayerState.paused,
          ),
        ),
      );
    }

    final flowingPaint = find.descendant(
      of: find.byType(FlowingLightBackground),
      matching: find.byType(CustomPaint),
    );
    final flowingOpacity = find.descendant(
      of: find.byType(FlowingLightBackground),
      matching: find.byType(AnimatedOpacity),
    );

    try {
      await tester.pumpWidget(buildSubject(cover));
      await _pumpAsyncWork(tester);
      expect(flowingPaint, findsOneWidget);
      expect(tester.widget<AnimatedOpacity>(flowingOpacity).opacity, 1);

      await tester.pumpWidget(buildSubject(Uint8List.fromList([1, 2, 3])));
      await _pumpAsyncWork(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(flowingPaint, findsOneWidget);
      expect(tester.widget<AnimatedOpacity>(flowingOpacity).opacity, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}
