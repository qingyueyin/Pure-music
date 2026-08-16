import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/matcher.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lyric.dart';

Audio _audio({
  String title = 'Song',
  String artist = 'Artist',
  int duration = 260,
}) {
  return Audio(
    title,
    artist,
    '',
    null,
    1,
    duration,
    320,
    44100,
    r'C:\Music\song.flac',
    1,
    1,
    'test',
  );
}

Lyric _lineLyric([String content = 'line']) {
  return Lyric([UnsyncLyricLine(const Duration(seconds: 1), content)]);
}

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

  test(
    'keeps only usable timed lyrics and reports their actual type',
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
        SyncLyricLine(const Duration(seconds: 1), const Duration(seconds: 1), [
          SyncLyricWord(
            const Duration(seconds: 1),
            const Duration(seconds: 1),
            'word',
          ),
        ]),
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
    },
  );

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

  test(
    'uses a version-qualified result when no exact lyric is usable',
    () async {
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
          '夜に駆ける',
          'YOASOBI',
          'THE BOOK',
          100,
          qqSongId: 'empty',
        ),
        SongSearchResult(
          ResultSource.qq,
          '夜に駆ける（Live）',
          'YOASOBI',
          'Live Album',
          80,
          qqSongId: 'live',
        ),
      ];
      final lineLyric = Lyric([
        UnsyncLyricLine(const Duration(seconds: 1), 'line'),
      ]);

      final selected = await selectBestValidOnlineLyricResults(
        audio,
        results,
        loadLyric: (result) async =>
            result.qqSongId == 'live' ? lineLyric : null,
      );

      expect(selected, hasLength(1));
      expect(selected.single.qqSongId, 'live');
    },
  );

  test(
    'puts title-only and compatible base-title queries in the first batch',
    () {
      final queries = buildOnlineLyricSearchQueries(
        _audio(title: 'Song (Live)'),
      );

      expect(queries.take(4), [
        'Song Live Artist',
        'Song Artist',
        'Song Live',
        'Song',
      ]);
    },
  );

  test('rejects risky versions and incompatible live results', () async {
    final audio = _audio();
    final loadedIds = <String>[];
    final candidates = [
      SongSearchResult(
        ResultSource.qq,
        'Song (Remix)',
        'Artist',
        '',
        120,
        qqSongId: 'remix',
        duration: 260,
      ),
      SongSearchResult(
        ResultSource.qq,
        'Song (Live)',
        'Artist',
        '',
        110,
        qqSongId: 'long-live',
        duration: 400,
      ),
      SongSearchResult(
        ResultSource.qq,
        'Song (Live)',
        'Other Artist',
        '',
        100,
        qqSongId: 'wrong-artist',
        duration: 262,
      ),
      SongSearchResult(
        ResultSource.qq,
        'Song (Live)',
        'Artist',
        '',
        90,
        qqSongId: 'usable-live',
        duration: 262,
      ),
    ];

    final selected = await selectBestValidOnlineLyricResults(
      audio,
      candidates,
      loadLyric: (result) async {
        loadedIds.add(result.qqSongId!);
        return _lineLyric();
      },
    );

    expect(selected.single.qqSongId, 'usable-live');
    expect(loadedIds, ['usable-live']);
  });

  test('accepts a meaningful partial artist match', () async {
    final selected =
        await selectBestValidOnlineLyricResults(_audio(artist: 'Artist'), [
          SongSearchResult(
            ResultSource.qq,
            'Song',
            'The Artist',
            '',
            80,
            qqSongId: 'alias',
            duration: 260,
          ),
        ], loadLyric: (_) async => _lineLyric());

    expect(selected.single.qqSongId, 'alias');
  });

  test(
    'uses exact title and close duration when artist metadata differs',
    () async {
      final selected = await selectBestValidOnlineLyricResults(_audio(), [
        SongSearchResult(
          ResultSource.qq,
          'Song',
          'Different Artist Field',
          '',
          80,
          qqSongId: 'duration-confirmed',
          duration: 262,
        ),
      ], loadLyric: (_) async => _lineLyric());

      expect(selected.single.qqSongId, 'duration-confirmed');
    },
  );

  test(
    'aggregate manual-first sources keep their top usable search result',
    () async {
      final selected = await selectBestValidOnlineLyricResults(
        _audio(),
        [
          SongSearchResult(
            ResultSource.qq,
            'Different QQ title',
            'Different artist',
            '',
            90,
            qqSongId: 'qq-first',
          ),
          SongSearchResult(
            ResultSource.ne,
            'Different NE title',
            'Different artist',
            '',
            80,
            neSongId: 1,
          ),
          SongSearchResult(
            ResultSource.kugou,
            'Different KG title',
            'Different artist',
            '',
            70,
            kugouSongHash: 'kg-first',
          ),
          SongSearchResult(
            ResultSource.amll,
            'Different AMLL title',
            'Different artist',
            '',
            100,
            amllTtmlFile: 'amll-rejected',
          ),
        ],
        manualFirstSources: const {
          ResultSource.qq,
          ResultSource.ne,
          ResultSource.kugou,
        },
        loadLyric: (_) async => _lineLyric(),
      );

      expect(selected.map((result) => result.source).toSet(), {
        ResultSource.qq,
        ResultSource.ne,
        ResultSource.kugou,
      });
    },
  );

  test(
    'preferred search uses title-only results and stops after a valid batch',
    () async {
      final searchedQueries = <String>[];
      final loadedIds = <String>[];
      final lyric = await getLyricFromPreferredSource(
        _audio(),
        ResultSource.qq,
        search: (query, audio, source) async {
          searchedQueries.add(query);
          if (query == 'Song Artist') throw StateError('primary query failed');
          if (query != 'Song') return [];
          return [
            SongSearchResult(
              source,
              'Song',
              'Artist',
              '',
              100,
              qqSongId: 'empty',
              duration: 260,
            ),
            SongSearchResult(
              source,
              'Song',
              'Artist',
              '',
              90,
              qqSongId: 'usable',
              duration: 260,
            ),
            SongSearchResult(
              source,
              'Song',
              'Artist',
              '',
              80,
              qqSongId: 'unused',
              duration: 260,
            ),
          ];
        },
        loadLyric: (result) async {
          loadedIds.add(result.qqSongId!);
          return result.qqSongId == 'usable' ? _lineLyric('usable') : null;
        },
      );

      expect(lyric, isNotNull);
      expect(searchedQueries.take(2), ['Song Artist', 'Song']);
      expect(loadedIds, ['empty', 'usable']);
    },
  );

  test('preferred search respects its total time limit', () async {
    final stopwatch = Stopwatch()..start();
    final lyric = await getLyricFromPreferredSource(
      _audio(),
      ResultSource.qq,
      search: (_, _, _) => Completer<List<SongSearchResult>>().future,
      loadLyric: (_) async => _lineLyric(),
      timeLimit: const Duration(milliseconds: 30),
    );
    stopwatch.stop();

    expect(lyric, isNull);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('preferred search passes its remaining budget to the source', () async {
    Duration? receivedTimeout;
    final lyric = await getLyricFromPreferredSource(
      _audio(),
      ResultSource.qq,
      searchWithTimeout: (_, _, _, timeout) async {
        receivedTimeout = timeout;
        return [];
      },
      timeLimit: const Duration(milliseconds: 80),
    );

    expect(lyric, isNull);
    expect(receivedTimeout, isNotNull);
    expect(
      receivedTimeout!,
      lessThanOrEqualTo(const Duration(milliseconds: 80)),
    );
  });

  test('preferred lyric load receives the remaining source budget', () async {
    Duration? receivedTimeout;
    final lyric = await getLyricFromPreferredSource(
      _audio(),
      ResultSource.qq,
      search: (query, audio, source) async => [
        SongSearchResult(
          source,
          'Song',
          'Artist',
          '',
          100,
          qqSongId: 'timed',
          duration: 260,
        ),
      ],
      loadLyricWithTimeout: (result, timeout) async {
        receivedTimeout = timeout;
        return _lineLyric();
      },
      timeLimit: const Duration(milliseconds: 100),
    );

    expect(lyric, isNotNull);
    expect(receivedTimeout, isNotNull);
    expect(
      receivedTimeout!,
      lessThanOrEqualTo(const Duration(milliseconds: 100)),
    );
  });

  test(
    'preferred search loads the first source result as a last resort',
    () async {
      final loadedIds = <String>[];
      final lyric = await getLyricFromPreferredSource(
        _audio(),
        ResultSource.qq,
        search: (query, audio, source) async {
          if (query != 'Song Artist') return [];
          return [
            SongSearchResult(
              source,
              'Different title',
              'Different artist',
              '',
              1,
              qqSongId: 'manual-first',
              duration: 260,
            ),
          ];
        },
        loadLyric: (result) async {
          loadedIds.add(result.qqSongId!);
          return _lineLyric('fallback');
        },
      );

      expect(lyric, isNotNull);
      expect(loadedIds, ['manual-first']);
    },
  );

  test('source fallback stops after the preferred source succeeds', () async {
    final attempted = <ResultSource>[];

    final result = await getLyricWithSourceFallback(
      _audio(),
      ResultSource.ne,
      loadSource: (source, _) async {
        attempted.add(source);
        return _lineLyric();
      },
    );

    expect(result?.source, ResultSource.ne);
    expect(attempted, [ResultSource.ne]);
  });

  test('source fallback tries remaining sources in a fixed order', () async {
    final attempted = <ResultSource>[];

    final result = await getLyricWithSourceFallback(
      _audio(),
      ResultSource.ne,
      loadSource: (source, _) async {
        attempted.add(source);
        return source == ResultSource.kugou ? _lineLyric() : null;
      },
    );

    expect(result?.source, ResultSource.kugou);
    expect(attempted, [ResultSource.ne, ResultSource.qq, ResultSource.kugou]);
  });

  test('source fallback continues after errors and empty lyrics', () async {
    final attempted = <ResultSource>[];

    final result = await getLyricWithSourceFallback(
      _audio(),
      ResultSource.qq,
      loadSource: (source, _) async {
        attempted.add(source);
        return switch (source) {
          ResultSource.qq => throw StateError('failed'),
          ResultSource.kugou => Lyric.empty,
          ResultSource.ne => _lineLyric(),
          ResultSource.amll => null,
        };
      },
    );

    expect(result?.source, ResultSource.ne);
    expect(attempted, [ResultSource.qq, ResultSource.kugou, ResultSource.ne]);
  });

  test('source fallback respects its total time limit', () async {
    final attempted = <ResultSource>[];
    final stopwatch = Stopwatch()..start();

    final result = await getLyricWithSourceFallback(
      _audio(),
      ResultSource.qq,
      timeLimit: const Duration(milliseconds: 40),
      loadSource: (source, _) {
        attempted.add(source);
        return Completer<Lyric?>().future;
      },
    );
    stopwatch.stop();

    expect(result, isNull);
    expect(attempted, isNotEmpty);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('strict preferred search ignores an unrelated first result', () async {
    final loadedIds = <String>[];

    final lyric = await getLyricFromPreferredSource(
      _audio(),
      ResultSource.qq,
      allowUnmatchedFirstResult: false,
      search: (query, audio, source) async => [
        SongSearchResult(
          source,
          'Different title',
          'Different artist',
          '',
          1,
          qqSongId: 'unrelated',
          duration: 260,
        ),
      ],
      loadLyric: (result) async {
        loadedIds.add(result.qqSongId!);
        return _lineLyric();
      },
    );

    expect(lyric, isNull);
    expect(loadedIds, isEmpty);
  });
}
