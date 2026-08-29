import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lyric_source.dart';

void main() {
  setUp(() {
    AudioLibrary.instance.dispose();
    lyricSources = {};
  });

  tearDown(() {
    AudioLibrary.instance.dispose();
    lyricSources = {};
  });

  test('prunes stale lyric sources using the library path index', () {
    const existingPath = r'C:\Music\Song.mp3';
    AudioLibrary.instance.replaceFolders([
      AudioFolder(
        [
          Audio(
            'Song',
            'Artist',
            'Album',
            null,
            1,
            60,
            320,
            44100,
            existingPath,
            1,
            1,
            'test',
          ),
        ],
        r'C:\Music',
        1,
        1,
      ),
    ]);
    lyricSources = {
      'c:/music/song.mp3': LyricSource(LyricSourceType.qq, qqSongId: '1'),
      r'C:\Music\Removed.mp3': LyricSource(
        LyricSourceType.kugou,
        kugouSongHash: 'removed',
      ),
    };

    pruneLyricSourcesWhereMissing(
      (path) => AudioLibrary.instance.audioByPath(path) != null,
    );

    expect(lyricSources.keys, ['c:/music/song.mp3']);
  });

  test(
    'failed lyric source persistence restores a newly added entry',
    () async {
      const path = r'C:\Music\Song.mp3';
      final source = LyricSource(LyricSourceType.qq, qqSongId: '123');

      await expectLater(
        persistLyricSource(
          path,
          source,
          persist: () async => throw StateError('write failed'),
        ),
        throwsA(isA<StateError>()),
      );

      expect(lyricSources, isEmpty);
    },
  );

  test('failed lyric source persistence restores the previous entry', () async {
    const path = r'C:\Music\Song.mp3';
    final previous = LyricSource(LyricSourceType.kugou, kugouSongHash: 'old');
    final replacement = LyricSource(LyricSourceType.qq, qqSongId: 'new');
    lyricSources[path] = previous;

    await expectLater(
      persistLyricSource(
        path,
        replacement,
        persist: () async => throw StateError('write failed'),
      ),
      throwsA(isA<StateError>()),
    );

    expect(lyricSources[path], same(previous));
  });
}
