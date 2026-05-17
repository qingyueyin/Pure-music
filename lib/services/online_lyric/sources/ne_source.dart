import 'package:pure_music/services/online_lyric/models/lyric_entry.dart';
import 'package:pure_music/services/online_lyric/models/lyric_source_type.dart';
import 'package:pure_music/services/online_lyric/models/song_search_result.dart';
import 'package:pure_music/services/online_lyric/sources/lyric_source.dart';
import 'package:pure_music/services/online_lyric/api/net_lyric_api.dart' as net_api;
import 'package:pure_music/core/utils.dart';

class NetEaseSource implements LyricSource {
  @override
  LyricSourceType get sourceType => LyricSourceType.ne;

  @override
  Future<List<SongSearchResult>> search(
    String keyword, {
    int page = 1,
    int pageSize = 8,
    String separator = '、',
  }) async {
    try {
      final results = await net_api.neSearchLyric(
        keyword: keyword,
        page: page,
        pageSize: pageSize,
      );
      return results.map((item) {
        return SongSearchResult(
          source: LyricSourceType.ne,
          id: item.id,
          title: item.title,
          artist: item.artist,
          album: item.album,
          duration: Duration(milliseconds: item.durationMs),
          extras: {
            'id': item.id,
          },
        );
      }).toList();
    } catch (e, st) {
      logger.w('NetEaseSource.search failed: $e', error: st);
      return [];
    }
  }

  @override
  Future<ParsedLyricResult?> getLyrics(SongSearchResult song) async {
    try {
      final songId = int.tryParse(song.id);
      if (songId == null) return null;

      final lyricResult = await net_api.neGetLyric(id: songId);
      if (lyricResult == null || !lyricResult.hasContent) return null;

      return lyricResult.toParsedLyric();
    } catch (e, st) {
      logger.w('NetEaseSource.getLyrics failed: $e', error: st);
      return null;
    }
  }
}
