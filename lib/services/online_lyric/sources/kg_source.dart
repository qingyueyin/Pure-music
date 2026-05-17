import 'package:pure_music/services/online_lyric/models/lyric_entry.dart';
import 'package:pure_music/services/online_lyric/models/lyric_source_type.dart';
import 'package:pure_music/services/online_lyric/models/song_search_result.dart';
import 'package:pure_music/services/online_lyric/sources/lyric_source.dart';
import 'package:pure_music/services/online_lyric/api/net_lyric_api.dart' as net_api;
import 'package:pure_music/core/utils.dart';

class KugouSource implements LyricSource {
  @override
  LyricSourceType get sourceType => LyricSourceType.kugou;

  @override
  Future<List<SongSearchResult>> search(
    String keyword, {
    int page = 1,
    int pageSize = 8,
    String separator = '、',
  }) async {
    try {
      final results = await net_api.kgSearchLyric(
        keyword: keyword,
        page: page,
        pageSize: pageSize,
      );
      return results.map((item) {
        return SongSearchResult(
          source: LyricSourceType.kugou,
          id: item.hash,
          title: item.title,
          artist: item.artist,
          album: item.album,
          duration: Duration(milliseconds: item.durationMs),
          extras: {
            'hash': item.hash,
            'id': item.id,
          },
        );
      }).toList();
    } catch (e, st) {
      logger.w('KugouSource.search failed: $e', error: st);
      return [];
    }
  }

  @override
  Future<ParsedLyricResult?> getLyrics(SongSearchResult song) async {
    try {
      final hash = song.extras['hash'] ?? song.id;
      if (hash.isEmpty) return null;

      final lyricResult = await net_api.kgGetLyric(hash: hash);
      if (lyricResult == null || !lyricResult.hasContent) return null;

      return lyricResult.toParsedLyric();
    } catch (e, st) {
      logger.w('KugouSource.getLyrics failed: $e', error: st);
      return null;
    }
  }
}
