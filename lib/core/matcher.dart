import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/krc.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/qrc.dart';
import 'package:pure_music/lyric/yrc.dart';
import 'package:pure_music/core/utils.dart' as utils;
import 'package:pure_music/native/rust/api/ne.dart';
import 'package:pure_music/native/rust/api/qq.dart';
import 'package:pure_music/native/rust/api/kg.dart' as kg_api;

final logger = utils.logger;

enum ResultSource { qq, kugou, ne }

const int _durationFilterThreshold = 10;

double _computeScore(Audio audio, String title, String artists, String album,
    {int? duration}) {
  double score = 0.0;

  final normalizedAudioTitle = audio.title.toLowerCase();
  final normalizedAudioArtist = audio.artist.toLowerCase();
  final normalizedTitle = title.toLowerCase();
  final normalizedArtists = artists.toLowerCase();

  if (normalizedTitle.isEmpty) return 0.0;
  if (normalizedAudioTitle.isEmpty) return 0.0;

  if (normalizedTitle == normalizedAudioTitle) {
    score += 40;
  } else if (normalizedAudioTitle.contains(normalizedTitle) ||
      normalizedTitle.contains(normalizedAudioTitle)) {
    score += 25;
  } else {
    int matchCount = 0;
    for (int i = 0;
        i < min(normalizedTitle.length, normalizedAudioTitle.length);
        i++) {
      if (normalizedTitle[i] == normalizedAudioTitle[i]) {
        matchCount++;
      }
    }
    score += 30.0 *
        matchCount /
        max(normalizedTitle.length, normalizedAudioTitle.length);
  }

  if (normalizedArtists.isNotEmpty && normalizedAudioArtist.isNotEmpty) {
    if (normalizedArtists == normalizedAudioArtist) {
      score += 40;
    } else if (normalizedAudioArtist.contains(normalizedArtists) ||
        normalizedArtists.contains(normalizedAudioArtist)) {
      score += 25;
    } else {
      int matchCount = 0;
      for (int i = 0;
          i < min(normalizedArtists.length, normalizedAudioArtist.length);
          i++) {
        if (normalizedArtists[i] == normalizedAudioArtist[i]) {
          matchCount++;
        }
      }
      score += 20.0 *
          matchCount /
          max(normalizedArtists.length, normalizedAudioArtist.length);
    }
  }

  final normalizedAlbum = album.toLowerCase();
  final normalizedAudioAlbum = audio.album.toLowerCase();
  if (normalizedAlbum.isNotEmpty && normalizedAudioAlbum.isNotEmpty) {
    if (normalizedAlbum == normalizedAudioAlbum) {
      score += 10;
    } else if (normalizedAudioAlbum.contains(normalizedAlbum) ||
        normalizedAlbum.contains(normalizedAudioAlbum)) {
      score += 5;
    }
  }

  if (duration != null && audio.duration > 0) {
    final audioDuration = audio.duration;
    final diff = (duration - audioDuration).abs();
    if (diff <= _durationFilterThreshold) {
      score += 10;
    }
  }

  return score;
}

class SongSearchResult {
  ResultSource source;
  String title;
  String artists;
  String album;
  double score;
  int? duration;

  String? qqSongId;
  String? kugouSongHash;
  int? neSongId;

  SongSearchResult(
      this.source, this.title, this.artists, this.album, this.score,
      {this.qqSongId, this.kugouSongHash, this.neSongId, this.duration});

  @override
  String toString() {
    return json.encode({
      "source": source.toString(),
      "title": title,
      "artists": artists,
      "album": album,
      "score": score,
    });
  }

  static SongSearchResult? fromQQSearchResult(Map itemSong, Audio audio) {
    final singers = itemSong["artists"];
    String artists = "";
    if (singers is List && singers.isNotEmpty) {
      final buffer = StringBuffer(singers[0] ?? "");
      for (int i = 1; i < singers.length; ++i) {
        buffer.write("、${singers[i]}");
      }
      artists = buffer.toString();
    }

    final title = itemSong["name"] ?? "";
    final album = itemSong["album"] ?? "";
    final duration = itemSong["duration"] as int?;

    return SongSearchResult(
      ResultSource.qq,
      title,
      artists,
      album,
      _computeScore(audio, title, artists, album, duration: duration),
      qqSongId: itemSong["id"],
      duration: duration,
    );
  }

  static SongSearchResult? fromKugouSearchResult(Map info, Audio audio) {
    final title = info["songname"];
    final album = info["album_name"];
    final artists = info["singername"];
    final duration =
        info["duration"] != null ? (info["duration"] as int) ~/ 1000 : null;

    return SongSearchResult(
      ResultSource.kugou,
      title,
      artists,
      album,
      _computeScore(audio, title, artists, album, duration: duration),
      kugouSongHash: info["hash"],
      duration: duration,
    );
  }

  static SongSearchResult? fromNeSearchResult(Map song, Audio audio) {
    final title = song["name"] ?? "";
    final artists = (song["artists"] as List?)
            ?.map((a) => a["name"]?.toString() ?? "")
            .join("、") ??
        "";
    final album = song["album"]?["name"] ?? "";
    final duration =
        song["duration"] != null ? (song["duration"] as int) ~/ 1000 : null;

    return SongSearchResult(
      ResultSource.ne,
      title,
      artists,
      album,
      _computeScore(audio, title, artists, album, duration: duration),
      neSongId: song["id"],
      duration: duration,
    );
  }
}

Future<List<SongSearchResult>> uniSearch(Audio audio) async {
  String searchQuery = audio.title;
  if (audio.artist.isNotEmpty) {
    searchQuery = "${audio.title} ${audio.artist}";
  }

  final List<SongSearchResult> result = [];

  final fileName = audio.path
      .split(Platform.pathSeparator)
      .last
      .replaceAll(RegExp(r'\.[^.]+$'), '');

  List<String> searchQueries = [searchQuery];
  if (fileName.isNotEmpty &&
      fileName != audio.title &&
      fileName != "${audio.title} ${audio.artist}") {
    searchQueries.insert(0, fileName);
  }

  for (final query in searchQueries) {
    logger.d('=== uniSearch query: "$query" ===');
    final futures = <Future<List<SongSearchResult>>>[];

    futures.add(_searchKugouWithTimeout(query, audio, 5));
    futures.add(_searchQQWithTimeout(query, audio, 5));
    futures.add(_searchNeWithTimeout(query, audio, 5));

    final allResults = await Future.wait(futures, eagerError: false);

    for (final r in allResults) {
      if (r.isNotEmpty) {
        result.addAll(r);
        result.sort((a, b) => b.score.compareTo(a.score));
        if (result.length >= 5) {
          logger.d('=== uniSearch done: ${result.length} results ===');
          for (int i = 0; i < result.length; i++) {
            logger.d('  [$i] ${result[i].source.name}: ${result[i].title} - ${result[i].artists}');
          }
          return result.take(5).toList();
        }
      }
    }
  }

  result.sort((a, b) => b.score.compareTo(a.score));

  if (result.isEmpty && audio.artist.isNotEmpty) {
    try {
      final kugouResult = await kg_api.kgSearch(audio.artist, limit: 5);
      for (int j = 0; j < min(5, kugouResult.length); j++) {
        final searchResult = SongSearchResult.fromKugouSearchResult(
          kugouResult[j],
          audio,
        );
        if (searchResult != null && searchResult.score > 20) {
          result.add(searchResult);
        }
      }
    } catch (err) {
      logger.w("Fallback KuGou search failed: $err");
    }

    result.sort((a, b) => b.score.compareTo(a.score));
  }

  logger.d('=== uniSearch done: ${result.length} results ===');
  for (int i = 0; i < result.length; i++) {
    logger.d('  [$i] ${result[i].source.name}: ${result[i].title} - ${result[i].artists}');
  }

  return result;
}

Future<List<SongSearchResult>> _searchKugouWithTimeout(
    String query, Audio audio, int seconds) async {
  try {
    logger.d('[KG] searching: "$query"');
    final kugouResult = await kg_api.kgSearch(query, limit: 8);
    logger.d('[KG] got ${kugouResult.length} raw results');
    for (int i = 0; i < kugouResult.length; i++) {
      logger.d('[KG] item[$i]: ${kugouResult[i]['songname']} - ${kugouResult[i]['singername']}');
    }
    final List<SongSearchResult> results = [];
    for (int j = 0; j < min(8, kugouResult.length); j++) {
      final searchResult = SongSearchResult.fromKugouSearchResult(
        kugouResult[j],
        audio,
      );
      if (searchResult != null && searchResult.score > 10) {
        results.add(searchResult);
      }
    }
    logger.d('[KG] accepted ${results.length}');
    return results;
  } catch (err, trace) {
    logger.w("KuGou search failed: $err", stackTrace: trace);
    return [];
  }
}

Future<List<SongSearchResult>> _searchQQWithTimeout(
    String query, Audio audio, int seconds) async {
  try {
    logger.d('[QQ] searching: "$query"');
    final qqResult = await qqSearch(query, limit: 8).timeout(
      Duration(seconds: seconds),
      onTimeout: () => throw TimeoutException("QQ search timeout"),
    );
    logger.d('[QQ] got ${qqResult.length} raw results');
    for (int i = 0; i < qqResult.length; i++) {
      logger.d('[QQ] item[$i]: ${qqResult[i]['name']} - ${qqResult[i]['artists']}');
    }
    final List<SongSearchResult> results = [];
    for (int i = 0; i < qqResult.length; i++) {
      final searchResult = SongSearchResult.fromQQSearchResult(
        qqResult[i],
        audio,
      );
      if (searchResult != null && searchResult.score > 10) {
        results.add(searchResult);
      }
    }
    logger.d('[QQ] accepted ${results.length}');
    return results;
  } catch (err, trace) {
    logger.w("QQ search failed: $err", stackTrace: trace);
    return [];
  }
}

Future<List<SongSearchResult>> _searchNeWithTimeout(
    String query, Audio audio, int seconds) async {
  try {
    logger.d('[NE] searching: "$query"');
    final neResult = await neSearch(query, limit: 8).timeout(
      Duration(seconds: seconds),
      onTimeout: () => throw TimeoutException("NetEase search timeout"),
    );
    logger.d('[NE] got ${neResult.length} raw results');
    for (final song in neResult) {
      logger.d('[NE] item: ${song['name']} - ${song['artists']}');
    }
    final List<SongSearchResult> results = [];
    for (final song in neResult) {
      final searchResult = SongSearchResult.fromNeSearchResult(song, audio);
      if (searchResult != null && searchResult.score > 10) {
        results.add(searchResult);
      }
    }
    logger.d('[NE] accepted ${results.length}');
    return results;
  } catch (err, trace) {
    logger.w("NetEase search failed: $err", stackTrace: trace);
    return [];
  }
}

Future<List<SongSearchResult>> manualSearch(Audio audio, String query,
    {int limit = 5}) async {
  logger.d('=== manualSearch: "$query", limit=$limit ===');
  final List<SongSearchResult> result = [];
  final int pageSize = limit * 3;

  // Always search all three sources (for tabbed UI)
  // KuGou
  try {
    logger.d('[MS] querying KuGou...');
    final kugouResult = await kg_api.kgSearch(query, limit: pageSize);
    logger.d('[MS] KG got ${kugouResult.length} raw');
    for (int j = 0; j < min(pageSize, kugouResult.length); j++) {
      final searchResult = SongSearchResult.fromKugouSearchResult(
        kugouResult[j],
        audio,
      );
      if (searchResult != null && !_containsResult(result, searchResult)) {
        result.add(searchResult);
      }
    }
    logger.d('[MS] KG accepted, total now: ${result.length}');
  } catch (err, trace) {
    logger.w("Manual search KuGou failed: $err", stackTrace: trace);
  }

  // QQ
  try {
    logger.d('[MS] querying QQ...');
    final qqResult = await qqSearch(query, limit: pageSize);
    logger.d('[MS] QQ got ${qqResult.length} raw');
    for (int i = 0; i < qqResult.length; i++) {
      final searchResult = SongSearchResult.fromQQSearchResult(
        qqResult[i],
        audio,
      );
      if (searchResult != null && !_containsResult(result, searchResult)) {
        result.add(searchResult);
      }
    }
    logger.d('[MS] QQ accepted, total now: ${result.length}');
  } catch (err, trace) {
    logger.w("Manual search QQ failed: $err", stackTrace: trace);
  }

  // NetEase
  try {
    logger.d('[MS] querying NetEase...');
    final neResult = await neSearch(query, limit: pageSize);
    logger.d('[MS] NE got ${neResult.length} raw');
    for (final song in neResult) {
      final searchResult = SongSearchResult.fromNeSearchResult(song, audio);
      if (searchResult != null && !_containsResult(result, searchResult)) {
        result.add(searchResult);
      }
    }
    logger.d('[MS] NE accepted, total now: ${result.length}');
  } catch (err, trace) {
    logger.w("Manual search NetEase failed: $err", stackTrace: trace);
  }

  result.sort((a, b) => b.score.compareTo(a.score));
  return result.sublist(0, min(limit * 3, result.length));
}

bool _containsResult(List<SongSearchResult> list, SongSearchResult item) {
  for (final r in list) {
    if (r.qqSongId != null && r.qqSongId == item.qqSongId) return true;
    if (r.kugouSongHash != null && r.kugouSongHash == item.kugouSongHash) {
      return true;
    }
    if (r.neSongId != null && r.neSongId == item.neSongId) return true;
  }
  return false;
}

Future<Lyric?> _getQQSyncLyric(String qqSongMid) async {
  try {
    final result = await qqLyric(qqSongMid);
    if (result != null) {
      final lyricText = result['lyric'];
      if (lyricText is String && lyricText.isNotEmpty) {
        final transText = result['trans'] as String?;
        final format = result['format'] as String?;

        if (format == 'yrc') {
          return Yrc.fromYrcText(lyricText, transText);
        } else if (format == 'qrc') {
          return Qrc.fromQrcText(lyricText, transText);
        }
        return Lrc.fromLrcTextAuto(lyricText, LrcSource.web, separator: "┃");
      }
    }
  } catch (err, trace) {
    logger.e("Failed to get QQ lyric: $err", stackTrace: trace);
  }

  return null;
}

Future<Krc?> _getKugouSyncLyric(String kugouSongHash) async {
  try {
    final answer = await kg_api.kgLyric(kugouSongHash);
    final krcText = answer?['lyric'];
    if (krcText is String && krcText.isNotEmpty) {
      return Krc.fromKrcText(krcText);
    }
  } catch (err, trace) {
    logger.e("Failed to get Kugou lyric: $err", stackTrace: trace);
  }

  return null;
}

Future<Lyric?> _getNeSyncLyric(int neSongId) async {
  try {
    final result = await neLyric(neSongId.toString());
    if (result == null) return null;

    final yrcText = result["yrc"]?["lyric"];
    if (yrcText is String && yrcText.isNotEmpty) {
      final transStr = result["tlyric"]?["lyric"] as String?;
      return Yrc.fromYrcText(yrcText, transStr);
    }

    final lrcText = result["lrc"]?["lyric"];
    if (lrcText is String && lrcText.isNotEmpty) {
      final transStr = result["tlyric"]?["lyric"] as String?;
      if (transStr is String && transStr.isNotEmpty) {
        return Lrc.fromLrcText(lrcText + transStr, LrcSource.web,
            separator: "┃");
      }
      return Lrc.fromLrcText(lrcText, LrcSource.web);
    }

    return null;
  } catch (err, trace) {
    logger.e("Failed to get NetEase lyric: $err", stackTrace: trace);
  }

  return null;
}

Future<Lyric?> getOnlineLyric({
  String? qqSongId,
  String? kugouSongHash,
  int? neSongId,
}) async {
  Lyric? lyric;

  if (qqSongId != null) {
    lyric = await _getQQSyncLyric(qqSongId);
    if (lyric != null && lyric.lines.isNotEmpty) return lyric;
  }

  if (neSongId != null) {
    lyric = await _getNeSyncLyric(neSongId);
    if (lyric != null && lyric.lines.isNotEmpty) return lyric;
  }

  if (kugouSongHash != null) {
    lyric = await _getKugouSyncLyric(kugouSongHash);
    if (lyric != null && lyric.lines.isNotEmpty) return lyric;
  }

  return lyric;
}

Future<Lyric?> getMostMatchedLyric(Audio audio) async {
  final unisearchResult = await uniSearch(audio);

  if (unisearchResult.isEmpty) {
    logger.w("No search result for '${audio.title}' by ${audio.artist}");
    return null;
  }

  final bestMatch = unisearchResult.first;
  final lyric = await getOnlineLyric(
    qqSongId: bestMatch.qqSongId,
    kugouSongHash: bestMatch.kugouSongHash,
    neSongId: bestMatch.neSongId,
  );

  if (lyric != null && lyric.lines.isNotEmpty) {
    logger.i(
        "Found lyric from ${bestMatch.source} for '${audio.title}' by ${audio.artist} (score: ${bestMatch.score})");
    return lyric;
  }

  logger.w("No lyric found for '${audio.title}' by ${audio.artist}");
  return null;
}
