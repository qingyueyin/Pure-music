import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/services/smart_sort_service.dart';

void main() {
  test('rejects an empty playlist before touching analysis services', () async {
    await expectLater(
      SmartSortService.run(tracks: const []),
      throwsA(isA<StateError>()),
    );
  });

  test('cancellation before the first track stops the batch', () async {
    final track = Audio(
      'Track',
      'Artist',
      'Album',
      null,
      1,
      60,
      320,
      44100,
      r'C:\Music\track.mp3',
      1,
      1,
      'test',
    );

    await expectLater(
      SmartSortService.run(tracks: [track], isCancelled: () => true),
      throwsA(isA<SmartSortCancelledException>()),
    );
  });
}
