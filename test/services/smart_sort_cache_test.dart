import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/services/smart_sort_cache.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('smart_sort_cache_');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'corrupt cache is treated as empty and replaced by valid data',
    () async {
      final file = File(
        '${directory.path}${Platform.pathSeparator}smart_sort_features.json',
      );
      await file.writeAsString('{broken json');
      final cache = SmartSortFeatureCache.forTesting(directory);
      final audio = _audio(modified: 42);

      expect(await cache.lookup(audio), isNull);
      cache.put(audio, '{"bpm":120}');
      await cache.flush();

      final decoded = jsonDecode(await file.readAsString());
      expect(decoded, isA<Map<String, dynamic>>());
      expect(await cache.lookup(audio), '{"bpm":120}');
    },
  );

  test(
    'failed flush remains dirty and succeeds after storage recovers',
    () async {
      final target = Directory(
        '${directory.path}${Platform.pathSeparator}smart_sort_features.json',
      );
      await target.create();
      final cache = SmartSortFeatureCache.forTesting(directory);
      final audio = _audio(modified: 7);
      cache.put(audio, '{"bpm":90}');

      await cache.flush();
      expect(await target.exists(), isTrue);

      await target.delete();
      await cache.flush();

      final restored = SmartSortFeatureCache.forTesting(directory);
      expect(await restored.lookup(audio), '{"bpm":90}');
    },
  );

  test('version and modification mismatches are cache misses', () async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}smart_sort_features.json',
    );
    await file.writeAsString(
      jsonEncode({
        'c:/music/track.mp3': {
          'version': 1,
          'mtime': 42,
          'features': '{"bpm":120}',
        },
      }),
    );
    final oldVersion = SmartSortFeatureCache.forTesting(directory);
    expect(await oldVersion.lookup(_audio(modified: 42)), isNull);

    await file.writeAsString(
      jsonEncode({
        'c:/music/track.mp3': {
          'version': 2,
          'mtime': 41,
          'features': '{"bpm":120}',
        },
      }),
    );
    final staleFile = SmartSortFeatureCache.forTesting(directory);
    expect(await staleFile.lookup(_audio(modified: 42)), isNull);
  });
}

Audio _audio({required int modified}) => Audio(
  'Track',
  'Artist',
  'Album',
  null,
  1,
  60,
  320,
  44100,
  r'C:\Music\track.mp3',
  modified,
  1,
  'test',
);
