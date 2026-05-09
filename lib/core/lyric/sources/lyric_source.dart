import 'package:pure_music/core/lyric/models/lyric_entry.dart';
import 'package:pure_music/core/lyric/models/lyric_source_type.dart';
import 'package:pure_music/core/lyric/models/song_search_result.dart';

/// 歌词数据源接口
/// 参考 Lyrico SearchSource 接口
abstract class LyricSource {
  LyricSourceType get sourceType;

  /// 搜索歌曲
  Future<List<SongSearchResult>> search(
    String keyword, {
    int page = 1,
    int pageSize = 8,
    String separator = '、',
  });

  /// 获取指定歌曲的歌词
  Future<ParsedLyricResult?> getLyrics(SongSearchResult song);

  /// 将搜索结果与音频文件进行匹配计算分数
  Future<List<SongSearchResult>> match(
    String audioTitle,
    String audioArtist, {
    Duration audioDuration = Duration.zero,
    String? fileName,
    String? audioAlbum,
  });

  /// 获取搜索结果中分数最高的结果
  Future<SongSearchResult?> bestResult(
    String audioTitle,
    String audioArtist, {
    Duration audioDuration = Duration.zero,
    String? fileName,
    String? audioAlbum,
  });

  /// 直接下载歌词并返回纯文本
  Future<String?> downloadLyric(SongSearchResult song);
}
