import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/matcher.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lyric.dart';

void main() {
  test('joins multiple artists with spaces in online search queries', () {
    final audio = Audio(
      '夜に駆ける',
      'Ayase/ikura、初音ミク feat. Eve & suis',
      '',
      null,
      1,
      260,
      320,
      44100,
      r'C:\Music\夜に駆ける.flac',
      1,
      1,
      'test',
    );

    expect(
      buildOnlineLyricSearchQueries(audio).first,
      '夜に駆ける Ayase ikura 初音ミク Eve suis',
    );
  });

  test('keeps only usable timed lyrics and reports their actual type',
      () async {
    final results = [
      SongSearchResult(ResultSource.qq, 'plain', 'artist', 'album', 100),
      SongSearchResult(ResultSource.ne, 'line', 'artist', 'album', 90),
      SongSearchResult(ResultSource.kugou, 'word', 'artist', 'album', 80),
    ];
    final lineLyric = Lyric([
      UnsyncLyricLine(const Duration(seconds: 1), 'line'),
    ]);
    final wordLyric = Lyric([
      SyncLyricLine(
        const Duration(seconds: 1),
        const Duration(seconds: 1),
        [
          SyncLyricWord(
            const Duration(seconds: 1),
            const Duration(seconds: 1),
            'word',
          ),
        ],
      ),
    ]);

    final validated = await validateOnlineLyricResults(
      results,
      loadLyric: (result) async => switch (result.title) {
        'line' => lineLyric,
        'word' => wordLyric,
        _ => null,
      },
    );

    expect(validated.map((result) => result.title), ['line', 'word']);
    expect(validated.map((result) => result.lyricType), ['逐行', '逐字']);
  });

  test('selects one best usable exact result from each source', () async {
    final audio = Audio(
      '夜に駆ける',
      'YOASOBI',
      'THE BOOK',
      null,
      1,
      260,
      320,
      44100,
      r'C:\Music\夜に駆ける.flac',
      1,
      1,
      'test',
    );
    final results = [
      SongSearchResult(
        ResultSource.qq,
        '夜に駆ける (Live)',
        'YOASOBI',
        '第71回 NHK 紅白歌合戦',
        120,
        qqSongId: 'live',
      ),
      SongSearchResult(
        ResultSource.qq,
        '夜に駆ける（向夜晚奔去）',
        'YOASOBI',
        '夜に駆ける',
        90,
        qqSongId: 'original',
      ),
      SongSearchResult(
        ResultSource.kugou,
        '夜に駆ける',
        'YOASOBI',
        'THE BOOK',
        110,
        kugouSongHash: 'empty',
      ),
      SongSearchResult(
        ResultSource.kugou,
        '夜に駆ける',
        'YOASOBI',
        'THE BOOK',
        80,
        kugouSongHash: 'usable',
      ),
    ];
    final lineLyric = Lyric([
      UnsyncLyricLine(const Duration(seconds: 1), 'line'),
    ]);

    final selected = await selectBestValidOnlineLyricResults(
      audio,
      results,
      loadLyric: (result) async {
        if (result.kugouSongHash == 'empty') return null;
        return lineLyric;
      },
    );

    expect(selected, hasLength(2));
    expect(
      selected.singleWhere((result) => result.source == ResultSource.qq).title,
      '夜に駆ける（向夜晚奔去）',
    );
    expect(
      selected
          .singleWhere((result) => result.source == ResultSource.kugou)
          .kugouSongHash,
      'usable',
    );
  });
}
