import 'package:pure_music/services/online_lyric/models/lyric_entry.dart';
import 'package:pure_music/services/online_lyric/models/lyric_source_type.dart';
import 'package:pure_music/services/online_lyric/models/song_search_result.dart';
import 'package:pure_music/services/online_lyric/sources/lyric_source.dart';
import 'package:pure_music/services/online_lyric/api/net_lyric_api.dart' as net_api;
import 'package:pure_music/core/utils.dart';

class QQSource implements LyricSource {
  @override
  LyricSourceType get sourceType => LyricSourceType.qq;

  @override
  Future<List<SongSearchResult>> search(
    String keyword, {
    int page = 1,
    int pageSize = 8,
    String separator = '、',
  }) async {
    try {
      final results = await net_api.qqSearchLyric(
        keyword: keyword,
        page: page,
        pageSize: pageSize,
      );
      return results.map((item) {
        return SongSearchResult(
          source: LyricSourceType.qq,
          id: item.mid,
          title: item.title,
          artist: item.artist,
          album: item.album,
          duration: Duration(milliseconds: item.durationMs),
          extras: {
            'id': item.id,
            'mid': item.mid,
          },
        );
      }).toList();
    } catch (e, st) {
      logger.w('QQSource.search failed: $e', error: st);
      return [];
    }
  }

  @override
  Future<ParsedLyricResult?> getLyrics(SongSearchResult song) async {
    try {
      final songId = int.tryParse(song.extras['id'] ?? '');
      if (songId == null || songId == 0) return null;

      final lyricResult = await net_api.qqGetLyric(
        id: songId,
        title: song.title,
        album: song.album,
        artist: song.artist,
        durationSec: song.duration.inSeconds,
      );
      if (lyricResult == null || !lyricResult.hasContent) return null;

      return lyricResult.toParsedLyric();
    } catch (e, st) {
      logger.w('QQSource.getLyrics failed: $e', error: st);
      return null;
    }
  }
}
