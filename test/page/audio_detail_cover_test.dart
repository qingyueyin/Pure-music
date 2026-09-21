import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/audio_detail_cover.dart';

void main() {
  testWidgets('sidebar layout changes keep the cover load and state', (
    tester,
  ) async {
    final audio = _CoverAudio('song.flac');
    Widget build({required bool expanded, required double progress}) {
      return MaterialApp(
        home: SpringRailScaffold(
          expanded: expanded,
          progress: progress,
          collapsedWidth: 80,
          expandedWidth: 240,
          rail: const SizedBox.expand(),
          body: LayoutBuilder(
            builder: (context, constraints) => Flex(
              direction: constraints.maxWidth < 600
                  ? Axis.vertical
                  : Axis.horizontal,
              children: [
                AudioDetailCover(
                  audio: audio,
                  placeholder: const SizedBox(
                    key: ValueKey('missing-cover'),
                    width: 156,
                    height: 156,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(build(expanded: false, progress: 0));
    expect(audio.loads, 1);
    final state = tester.state(find.byType(AudioDetailCover));
    final future = tester
        .widget<FutureBuilder<ImageProvider?>>(
          find.byType(FutureBuilder<ImageProvider?>),
        )
        .future;
    audio.result.complete(null);
    await tester.pump();
    for (final step in [
      (true, 0.0),
      (true, 0.4),
      (true, 1.0),
      (false, 1.0),
      (false, 0.4),
      (false, 0.0),
    ]) {
      await tester.pumpWidget(build(expanded: step.$1, progress: step.$2));
      expect(audio.loads, 1);
      expect(tester.state(find.byType(AudioDetailCover)), same(state));
      expect(
        tester
            .widget<FutureBuilder<ImageProvider?>>(
              find.byType(FutureBuilder<ImageProvider?>),
            )
            .future,
        same(future),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const ValueKey('missing-cover')), findsOneWidget);
    }
  });

  testWidgets('cover refreshes after writing artwork or changing tracks', (
    tester,
  ) async {
    final first = _CoverAudio('first.flac');
    final second = _CoverAudio('second.flac');
    Widget build(Audio audio, {int revision = 0}) => MaterialApp(
      home: AudioDetailCover(
        audio: audio,
        revision: revision,
        placeholder: const SizedBox(),
      ),
    );

    await tester.pumpWidget(build(first));
    expect(first.loads, 1);
    await tester.pumpWidget(build(first, revision: 1));
    expect(first.loads, 2);
    await tester.pumpWidget(build(first, revision: 1));
    expect(first.loads, 2);
    first.modified++;
    await tester.pumpWidget(build(first, revision: 1));
    expect(first.loads, 3);
    await tester.pumpWidget(build(second, revision: 1));
    expect(second.loads, 1);
    second.result.complete(null);
    first.result.complete(null);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

class _CoverAudio extends Audio {
  _CoverAudio(String path)
    : super(
        'Song',
        'Artist',
        'Album',
        null,
        1,
        240,
        null,
        null,
        path,
        0,
        0,
        null,
      );

  final result = Completer<ImageProvider?>();
  int loads = 0;

  @override
  Future<ImageProvider?> get mediumCover async {
    loads++;
    return result.future;
  }
}
