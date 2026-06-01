import 'package:pure_music/services/online_lyric/models/lyric_source_type.dart';

final _artistSplitRegex = RegExp(r'[、,，&\s]+');

/// 统一搜索结果模型
class SongSearchResult {
  final LyricSourceType source;
  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final Map<String, String> extras;
  final String? picUrl;

  double score;

  SongSearchResult({
    required this.source,
    required this.id,
    required this.title,
    required this.artist,
    this.album = '',
    this.duration = Duration.zero,
    this.extras = const {},
    this.picUrl,
    this.score = 0,
  });

  factory SongSearchResult.fromMap(Map<String, String> map, LyricSourceType source) {
    return SongSearchResult(
      source: source,
      id: map['id'] ?? '',
      title: map['title'] ?? '',
      artist: map['artist'] ?? '',
      album: map['album'] ?? '',
      duration: Duration(
        milliseconds: int.tryParse(map['duration'] ?? '0') ?? 0,
      ),
      extras: map,
      picUrl: map['picUrl'],
    );
  }

  /// 计算与目标音频的匹配分数
  static double computeScore(
    SongSearchResult song,
    String audioTitle,
    String audioArtist, {
    Duration audioDuration = Duration.zero,
    String? fileName,
  }) {
    double score = 0;

    if (fileName != null && fileName.isNotEmpty) {
      final score2 = _computeFileNameScore(song, audioTitle, audioArtist, fileName);
      if (score2 >= 80) return score2;
    }

    score += _computeTitleScore(song, audioTitle);
    score += _computeArtistScore(song, audioArtist);

    if (audioDuration > Duration.zero && song.duration > Duration.zero) {
      final diff =
          (song.duration.inMilliseconds - audioDuration.inMilliseconds).abs();
      if (diff <= 3000) {
        score += 10;
      }
    }

    return score;
  }

  static double _computeFileNameScore(
    SongSearchResult song,
    String audioTitle,
    String audioArtist,
    String fileName,
  ) {
    final fileNameWithoutExt = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    final hasArtistInFileName = audioArtist.isNotEmpty;

    double score = 0;

    if (hasArtistInFileName) {
      score += _computeArtistScore(song, audioArtist) * 0.45;
      score += _computeTitleScore(song, audioTitle) * 0.45;
    } else {
      score += _computeTitleScore(song, audioTitle) * 0.9;
    }

    if (song.album.isNotEmpty &&
        fileNameWithoutExt.contains(song.artist) &&
        fileNameWithoutExt.contains(song.title) &&
        fileNameWithoutExt.contains(song.album)) {
      score += 10;
    }

    if (score >= 90) score += 10;

    return score;
  }

  static double _computeTitleScore(SongSearchResult song, String targetTitle) {
    if (targetTitle.isEmpty) return 10;
    if (song.title == targetTitle) return 80;

    if (targetTitle.contains(song.title) || song.title.contains(targetTitle)) {
      double score = 50;
      final lenDiff = (targetTitle.length - song.title.length).abs();
      if (lenDiff == 1) score += 10;
      if (lenDiff == 2) score += 5;
      return score;
    }

    final titleChars = song.title.runes.length;
    final targetChars = targetTitle.runes.length;
    if (titleChars == 0 || targetChars == 0) return 0;

    int matched = 0;
    for (final c in song.title.runes) {
      if (targetTitle.runes.contains(c)) matched++;
    }
    return 50 * (matched / targetChars);
  }

  static double _computeArtistScore(
    SongSearchResult song,
    String targetArtist,
  ) {
    if (targetArtist.isEmpty) return 10;
    if (song.artist == targetArtist) return 30;

    final songArtists = _splitArtist(song.artist);
    final targetArtists = _splitArtist(targetArtist);
    int matchCount = 0;
    for (final ta in targetArtists) {
      for (final sa in songArtists) {
        if (ta == sa || ta.contains(sa) || sa.contains(ta)) {
          matchCount++;
          break;
        }
      }
    }
    return 20 * (matchCount / targetArtists.length);
  }

  static List<String> _splitArtist(String artist) {
    if (artist.isEmpty) return [];
    return artist.split(_artistSplitRegex).where((a) => a.isNotEmpty).toList();
  }
}
