import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/services/online_lyric/models/lyric_entry.dart' hide LyricFormat;
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/krc.dart';
import 'package:pure_music/lyric/qrc.dart';
import 'package:pure_music/services/online_lyric/api/net_lyric_api.dart' as net_api;
import 'package:pure_music/core/utils.dart' as utils;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

final logger = utils.logger;
final _pathSeparator = defaultTargetPlatform == TargetPlatform.windows ? r'\' : '/';

enum ResultSource { qq, kugou, ne }

const int _durationFilterThreshold = 10;

final Map<String, Future<Lyric?>> _lyricFetchCache = {};
final Map<String, Lyric> _lyricResultCache = {};

String _cacheKey({String? qqSongId, String? kugouSongHash, int? neSongId}) {
  return qqSongId != null
      ? 'qq:$qqSongId'
      : kugouSongHash != null
          ? 'kg:$kugouSongHash'
          : neSongId != null
              ? 'ne:$neSongId'
              : '';
}

void cacheLyric(
    {String? qqSongId, String? kugouSongHash, int? neSongId, required Lyric lyric}) {
  final key = _cacheKey(qqSongId: qqSongId, kugouSongHash: kugouSongHash, neSongId: neSongId);
  if (key.isNotEmpty) {
    _lyricResultCache[key] = lyric;
  }
}

Lyric? getCachedLyric(
    {String? qqSongId, String? kugouSongHash, int? neSongId}) {
  final key = _cacheKey(qqSongId: qqSongId, kugouSongHash: kugouSongHash, neSongId: neSongId);
  return key.isNotEmpty ? _lyricResultCache[key] : null;
}

Future<Lyric?> getOnlineLyric({
  String? qqSongId,
  String? kugouSongHash,
  int? neSongId,
}) {
  final cached = getCachedLyric(
    qqSongId: qqSongId,
    kugouSongHash: kugouSongHash,
    neSongId: neSongId,
  );
  if (cached != null) {
    logger.d('[getOnlineLyric] cache hit');
    return Future.value(cached);
  }

  final key = _cacheKey(qqSongId: qqSongId, kugouSongHash: kugouSongHash, neSongId: neSongId);
  
  if (key.isNotEmpty && _lyricFetchCache.containsKey(key)) {
    logger.d('[getOnlineLyric] request dedup: $key');
    return _lyricFetchCache[key]!;
  }

  final future = _fetchLyricInternal(
    qqSongId: qqSongId,
    kugouSongHash: kugouSongHash,
    neSongId: neSongId,
  );
  
  if (key.isNotEmpty) {
    _lyricFetchCache[key] = future;
    future.then((lyric) {
      _lyricFetchCache.remove(key);
      if (lyric != null) {
        cacheLyric(
          qqSongId: qqSongId,
          kugouSongHash: kugouSongHash,
          neSongId: neSongId,
          lyric: lyric,
        );
      }
    });
  }
  
  return future;
}

Future<Lyric?> _fetchLyricInternal({
  String? qqSongId,
  String? kugouSongHash,
  int? neSongId,
}) async {
  Lyric? lyric;

  if (qqSongId != null) {
    logger.d('[getOnlineLyric] trying QQ: $qqSongId');
    lyric = await _getQQSyncLyric(qqSongId);
    if (lyric != null && lyric.lines.isNotEmpty) {
      logger.d('[getOnlineLyric] QQ success: ${lyric.lines.length} lines');
      return lyric;
    }
    logger.d('[getOnlineLyric] QQ returned null or empty');
  }

  if (neSongId != null) {
    logger.d('[getOnlineLyric] trying NE: $neSongId');
    lyric = await _getNeSyncLyric(neSongId);
    if (lyric != null && lyric.lines.isNotEmpty) {
      logger.d('[getOnlineLyric] NE success: ${lyric.lines.length} lines');
      return lyric;
    }
    logger.d('[getOnlineLyric] NE returned null or empty');
  }

  if (kugouSongHash != null) {
    logger.d('[getOnlineLyric] trying KG: $kugouSongHash');
    lyric = await _getKugouSyncLyric(kugouSongHash);
    if (lyric != null && lyric.lines.isNotEmpty) {
      logger.d('[getOnlineLyric] KG success: ${lyric.lines.length} lines');
      return lyric;
    }
    logger.d('[getOnlineLyric] KG returned null or empty');
  }

  return lyric;
}

final Set<String> _searchDedupCache = {};
int _searchQueryCounter = 0;

void clearSearchDedupCache() {
  _searchDedupCache.clear();
}

bool shouldPerformSearch(String query) {
  _searchQueryCounter++;
  final key = '${_searchQueryCounter}_$query';
  
  for (final k in _searchDedupCache) {
    if (k.endsWith('_$query')) {
      return false;
    }
  }
  
  _searchDedupCache.add(key);
  
  if (_searchDedupCache.length > 100) {
    _searchDedupCache.clear();
  }
  
  return true;
}

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
      'source': source.toString(),
      'title': title,
      'artists': artists,
      'album': album,
      'score': score,
    });
  }

  static SongSearchResult? fromQQSearchItem(
      net_api.QmSearchItem item, Audio audio) {
    return SongSearchResult(
      ResultSource.qq,
      item.title,
      item.artist,
      item.album,
      _computeScore(audio, item.title, item.artist, item.album,
          duration: item.durationMs ~/ 1000),
      qqSongId: item.id,
      duration: item.durationMs ~/ 1000,
    );
  }

  static SongSearchResult? fromKugouSearchItem(
      net_api.KgSearchItem item, Audio audio) {
    return SongSearchResult(
      ResultSource.kugou,
      item.title,
      item.artist,
      item.album,
      _computeScore(audio, item.title, item.artist, item.album,
          duration: item.durationMs ~/ 1000),
      kugouSongHash: item.hash,
      duration: item.durationMs ~/ 1000,
    );
  }

  static SongSearchResult? fromNeSearchItem(
      net_api.NeSearchItem item, Audio audio) {
    return SongSearchResult(
      ResultSource.ne,
      item.title,
      item.artist,
      item.album,
      _computeScore(audio, item.title, item.artist, item.album,
          duration: item.durationMs ~/ 1000),
      neSongId: int.tryParse(item.id),
      duration: item.durationMs ~/ 1000,
    );
  }
}

Future<List<SongSearchResult>> uniSearch(Audio audio) async {
  String searchQuery = audio.title;
  if (audio.artist.isNotEmpty) {
    searchQuery = '${audio.title} ${audio.artist}';
  }

  final List<SongSearchResult> result = [];

  final fileName = audio.path
      .split(_pathSeparator)
      .last
      .replaceAll(RegExp(r'\.[^.]+$'), '');

  List<String> searchQueries = [searchQuery];
  if (fileName.isNotEmpty &&
      fileName != audio.title &&
      fileName != '${audio.title} ${audio.artist}') {
    searchQueries.add(fileName);
  }

  const int perSourceLimit = 1;

  for (final query in searchQueries) {
    logger.d('=== uniSearch query: "$query" ===');

    final kgFuture = _searchKugouWithTimeout(query, audio, 6, perSourceLimit);
    final qqFuture = _searchQQWithTimeout(query, audio, 6, perSourceLimit);
    final neFuture = _searchNEWithTimeout(query, audio, 6, perSourceLimit);

    final results = await Future.wait([kgFuture, qqFuture, neFuture], eagerError: false)
        .timeout(const Duration(seconds: 18), onTimeout: () {
      logger.w('uniSearch timeout for query: $query');
      return <List<SongSearchResult>>[[], [], []];
    });

    final kgResults = results[0];
    final qqResults = results[1];
    final neResults = results[2];

    SongSearchResult? qqBest;
    SongSearchResult? kgBest;
    SongSearchResult? neBest;

    for (final item in qqResults) {
      if (qqBest == null || item.score > qqBest.score) qqBest = item;
    }
    for (final item in kgResults) {
      if (kgBest == null || item.score > kgBest.score) kgBest = item;
    }
    for (final item in neResults) {
      if (neBest == null || item.score > neBest.score) neBest = item;
    }

    final merged = <SongSearchResult>[];
    if (qqBest != null) merged.add(qqBest);
    if (kgBest != null) merged.add(kgBest);
    if (neBest != null) merged.add(neBest);
    merged.sort((a, b) => b.score.compareTo(a.score));

    for (final item in merged) {
      if (!_containsResult(result, item)) {
        result.add(item);
      }
    }

    if (result.isNotEmpty) {
      logger.d('=== uniSearch done: ${result.length} results ===');
      return result.take(3).toList();
    }
  }

  result.sort((a, b) => b.score.compareTo(a.score));
  logger.d('=== uniSearch done: ${result.length} results ===');
  return result.take(3).toList();
}

Future<List<SongSearchResult>> _searchKugouWithTimeout(
    String query, Audio audio, int seconds, int limit) async {
  try {
    logger.d('[KG] searching: "$query"');
    final kugouResults = await net_api.kgSearchLyric(
      keyword: query,
      pageSize: limit,
    ).timeout(Duration(seconds: seconds),
        onTimeout: () => throw TimeoutException('KG search timeout'));
    logger.d('[KG] got ${kugouResults.length} raw results');
    final List<SongSearchResult> results = [];
    for (final item in kugouResults.take(limit)) {
      final searchResult = SongSearchResult.fromKugouSearchItem(item, audio);
      if (searchResult != null && searchResult.score >= 0) {
        results.add(searchResult);
      }
    }
    logger.d('[KG] accepted ${results.length}');
    return results;
  } catch (err, trace) {
    logger.w('KuGou search failed: $err', stackTrace: trace);
    return [];
  }
}

Future<List<SongSearchResult>> _searchQQWithTimeout(
    String query, Audio audio, int seconds, int limit) async {
  try {
    logger.d('[QQ] searching: "$query"');
    final qqResults = await net_api.qqSearchLyric(
      keyword: query,
      pageSize: limit,
    ).timeout(Duration(seconds: seconds),
        onTimeout: () => throw TimeoutException('QQ search timeout'));
    logger.d('[QQ] got ${qqResults.length} raw results');
    final List<SongSearchResult> results = [];
    for (final item in qqResults.take(limit)) {
      final searchResult = SongSearchResult.fromQQSearchItem(item, audio);
      if (searchResult != null && searchResult.score >= 0) {
        results.add(searchResult);
      }
    }
    logger.d('[QQ] accepted ${results.length}');
    return results;
  } catch (err, trace) {
    logger.w('QQ search failed: $err', stackTrace: trace);
    return [];
  }
}

Future<List<SongSearchResult>> _searchNEWithTimeout(
    String query, Audio audio, int seconds, int limit) async {
  try {
    logger.d('[NE] searching: "$query"');
    final neResults = await net_api.neSearchLyric(
      keyword: query,
      pageSize: limit,
    ).timeout(Duration(seconds: seconds),
        onTimeout: () => throw TimeoutException('NE search timeout'));
    logger.d('[NE] got ${neResults.length} raw results');
    final List<SongSearchResult> results = [];
    for (final item in neResults) {
      final searchResult = SongSearchResult.fromNeSearchItem(item, audio);
      if (searchResult != null && searchResult.score > 10) {
        results.add(searchResult);
      }
    }
    logger.d('[NE] accepted ${results.length}');
    return results;
  } catch (err, trace) {
    logger.w('NetEase search failed: $err', stackTrace: trace);
    return [];
  }
}

Future<List<SongSearchResult>> manualSearch(Audio audio, String query,
    {int limit = 10}) async {
  logger.d('=== manualSearch START: query="$query", limit=$limit ===');
  final List<SongSearchResult> result = [];

  const int perSourceLimit = 10;
  const int pageSize = perSourceLimit;

  try {
    logger.d('[MS][NE] searching: "$query"');
    final neResults = await net_api.neSearchLyric(
            keyword: query, pageSize: pageSize)
        .timeout(const Duration(seconds: 8));
    logger.d('[MS][NE] got ${neResults.length} raw results');
    for (final item in neResults.take(perSourceLimit)) {
      final searchResult = SongSearchResult.fromNeSearchItem(item, audio);
      if (searchResult != null && searchResult.score >= 0) {
        result.add(searchResult);
      }
    }
    logger.d('[MS][NE] accepted ${result.where((r) => r.source == ResultSource.ne).length}');
  } catch (err, trace) {
    logger.e('[MS] NE ERROR: $err', stackTrace: trace);
  }

  try {
    logger.d('[MS][KG] searching: "$query"');
    final kugouResults = await net_api.kgSearchLyric(
            keyword: query, pageSize: pageSize)
        .timeout(const Duration(seconds: 8));
    logger.d('[MS][KG] got ${kugouResults.length} raw results');
    for (final item in kugouResults.take(perSourceLimit)) {
      final searchResult = SongSearchResult.fromKugouSearchItem(item, audio);
      if (searchResult != null && searchResult.score >= 0) {
        result.add(searchResult);
      }
    }
    logger.d('[MS][KG] accepted ${result.where((r) => r.source == ResultSource.kugou).length}');
  } catch (err, trace) {
    logger.e('[MS] KG ERROR: $err', stackTrace: trace);
  }

  try {
    logger.d('[MS][QQ] searching: "$query"');
    final qqResults = await net_api.qqSearchLyric(
            keyword: query, pageSize: pageSize)
        .timeout(const Duration(seconds: 8));
    logger.d('[MS][QQ] got ${qqResults.length} raw results');
    for (final item in qqResults.take(perSourceLimit)) {
      final searchResult = SongSearchResult.fromQQSearchItem(item, audio);
      if (searchResult != null && searchResult.score >= 0) {
        result.add(searchResult);
      }
    }
    logger.d('[MS][QQ] accepted ${result.where((r) => r.source == ResultSource.qq).length}');
  } catch (err, trace) {
    logger.e('[MS] QQ ERROR: $err', stackTrace: trace);
  }

  result.sort((a, b) => b.score.compareTo(a.score));
  logger.d('=== manualSearch done: ${result.length} results ===');
  return result.sublist(0, min(limit, result.length));
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

Future<Lyric?> _getQQSyncLyric(String qqSongId) async {
  try {
    final songId = int.tryParse(qqSongId);
    if (songId == null || songId == 0) return null;

    final lyricResult = await net_api
        .qqGetLyricById(id: songId)
        .timeout(const Duration(seconds: 10));
    if (lyricResult == null || !lyricResult.hasContent) return null;

    final parsed = lyricResult.toParsedLyric();
    if (parsed != null && parsed.isNotEmpty) {
      return _parsedToLyric(parsed);
    }
    logger.d('[QQ lyric] toParsedLyric returned null or empty');
  } catch (err, trace) {
    logger.e('Failed to get QQ lyric: $err', stackTrace: trace);
  }
  return null;
}

Future<Krc?> _getKugouSyncLyric(String kugouSongHash) async {
  try {
    final lyricResult = await net_api
        .kgGetLyric(hash: kugouSongHash)
        .timeout(const Duration(seconds: 10));
    if (lyricResult == null || !lyricResult.hasContent) return null;

    final parsed = lyricResult.toParsedLyric();
    if (parsed != null && parsed.isNotEmpty) {
      final syncLines = <SyncLyricLine>[];
      for (final entry in parsed.lines) {
        if (entry.words != null && entry.words!.isNotEmpty) {
          final words = entry.words!.map((w) {
            return SyncLyricWord(w.start, w.length, w.content);
          }).toList();
          final length = entry.nextTime - entry.start;
          syncLines.add(SyncLyricLine(
            entry.start,
            length,
            words,
            entry.translation,
          )..romanLyric = entry.romanization);
        } else {
          final length = entry.nextTime - entry.start;
          syncLines.add(SyncLyricLine(
            entry.start,
            length,
            [SyncLyricWord(entry.start, length, entry.content)],
            entry.translation,
          )..romanLyric = entry.romanization);
        }
      }
      return Krc(syncLines);
    }
    logger.d('[KG lyric] toParsedLyric returned null or empty');
  } catch (err, trace) {
    logger.e('Failed to get Kugou lyric: $err', stackTrace: trace);
  }
  return null;
}

Future<Lyric?> _getNeSyncLyric(int neSongId) async {
  try {
    final lyricResult = await net_api
        .neGetLyric(id: neSongId)
        .timeout(const Duration(seconds: 10));
    if (lyricResult == null || !lyricResult.hasContent) return null;

    final parsed = lyricResult.toParsedLyric();
    if (parsed != null && parsed.isNotEmpty) {
      return _parsedToLyric(parsed);
    }
    logger.d('[NE lyric] toParsedLyric returned null or empty');
  } catch (err, trace) {
    logger.e('Failed to get NetEase lyric: $err', stackTrace: trace);
  }
  return null;
}

Lyric? _parsedToLyric(ParsedLyricResult parsed) {
  if (parsed.hasWordByWord) {
    final syncLines = <SyncLyricLine>[];
    for (final entry in parsed.lines) {
      if (entry.words != null && entry.words!.isNotEmpty) {
        final words = entry.words!.map((w) {
          return SyncLyricWord(
            w.start,
            w.length,
            w.content,
          );
        }).toList();
        final length = entry.nextTime - entry.start;
        syncLines.add(SyncLyricLine(
          entry.start,
          length,
          words,
          entry.translation,
        )..romanLyric = entry.romanization);
      } else {
        final length = entry.nextTime - entry.start;
        syncLines.add(SyncLyricLine(
          entry.start,
          length,
          [SyncLyricWord(entry.start, length, entry.content)],
          entry.translation,
        )..romanLyric = entry.romanization);
      }
    }
    return Qrc(syncLines);
  }

  final unsyncLines = <LrcLine>[];
  for (final entry in parsed.lines) {
    unsyncLines.add(LrcLine(
      entry.start,
      entry.content,
      requiredIsBlank: entry.content.isEmpty,
      translation: entry.translation,
    ));
  }
  return Lrc(unsyncLines, LyricFormat.web);
}

Future<Lyric?> getMostMatchedLyric(Audio audio) async {
  final unisearchResult = await uniSearch(audio)
      .timeout(const Duration(seconds: 22), onTimeout: () {
    logger.w('getMostMatchedLyric uniSearch timeout');
    return [];
  });

  if (unisearchResult.isEmpty) {
    logger.w("No search result for '${audio.title}' by ${audio.artist}");
    return null;
  }

  final bestMatch = unisearchResult.first;
  final lyric = await getOnlineLyric(
    qqSongId: bestMatch.qqSongId,
    kugouSongHash: bestMatch.kugouSongHash,
    neSongId: bestMatch.neSongId,
  ).timeout(const Duration(seconds: 15), onTimeout: () {
    logger.w('getMostMatchedLyric getOnlineLyric timeout');
    return null;
  });

  if (lyric != null && lyric.lines.isNotEmpty) {
    logger.i(
        "Found lyric from ${bestMatch.source} for '${audio.title}' by ${audio.artist} (score: ${bestMatch.score})");
    return lyric;
  }

  logger.w("No lyric found for '${audio.title}' by ${audio.artist}");
  return null;
}
