import 'package:pure_music/core/lyric/models/lyric_entry.dart';
import 'package:pure_music/core/lyric/models/lyric_source_type.dart';
import 'package:pure_music/core/lyric/models/song_search_result.dart';
import 'package:pure_music/core/lyric/sources/lyric_source.dart';
import 'package:pure_music/core/net_lyrics/net_lyric_api.dart' as net_api;
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

  @override
  Future<List<SongSearchResult>> match(
    String audioTitle,
    String audioArtist, {
    Duration audioDuration = Duration.zero,
    String? fileName,
    String? audioAlbum,
  }) async {
    try {
      final parts = <String>[audioTitle];
      if (audioArtist.isNotEmpty) parts.add(audioArtist);
      if (audioAlbum != null && audioAlbum.isNotEmpty) parts.add(audioAlbum);
      final keyword = parts.join(' ');

      final searchResults = await search(keyword);
      if (searchResults.isEmpty) return [];

      for (final result in searchResults) {
        result.score = SongSearchResult.computeScore(
          result,
          audioTitle,
          audioArtist,
          audioDuration: audioDuration,
          fileName: fileName,
        );
      }

      searchResults.sort((a, b) => b.score.compareTo(a.score));
      return searchResults;
    } catch (e, st) {
      logger.w('NetEaseSource.match failed: $e', error: st);
      return [];
    }
  }

  @override
  Future<SongSearchResult?> bestResult(
    String audioTitle,
    String audioArtist, {
    Duration audioDuration = Duration.zero,
    String? fileName,
    String? audioAlbum,
  }) async {
    try {
      final matched = await match(
        audioTitle,
        audioArtist,
        audioDuration: audioDuration,
        fileName: fileName,
        audioAlbum: audioAlbum,
      );
      return matched.isNotEmpty ? matched.first : null;
    } catch (e, st) {
      logger.w('NetEaseSource.bestResult failed: $e', error: st);
      return null;
    }
  }

  @override
  Future<String?> downloadLyric(SongSearchResult song) async {
    try {
      final lyricResult = await getLyrics(song);
      return lyricResult?.rawContent;
    } catch (e, st) {
      logger.w('NetEaseSource.downloadLyric failed: $e', error: st);
      return null;
    }
  }
}
