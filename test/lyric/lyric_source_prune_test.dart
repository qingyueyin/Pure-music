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
}
