import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/services/online_lyric/models/lyric_entry.dart'
    hide LyricFormat;
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/krc.dart';
import 'package:pure_music/lyric/qrc.dart';
import 'package:pure_music/services/online_lyric/api/net_lyric_api.dart'
    as net_api;
import 'package:pure_music/core/utils.dart' as utils;
import 'package:pure_music/lyric/lyric_stripper.dart';
import 'package:pure_music/lyric/exclude_data.dart';

final logger = utils.logger;

enum ResultSource { qq, kugou, ne }

const int _lyricCacheMaxSize = 64;
final Map<String, Future<Lyric?>> _lyricFetchCache = {};
final Map<String, Lyric> _lyricResultCache = {};
final List<String> _lyricCacheAccessOrder = [];
int _manualSearchSeq = 0;

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
    {String? qqSongId,
    String? kugouSongHash,
    int? neSongId,
    required Lyric lyric}) {
  final key = _cacheKey(
      qqSongId: qqSongId, kugouSongHash: kugouSongHash, neSongId: neSongId);
  if (key.isEmpty) return;

  _lyricResultCache[key] = lyric;

  _lyricCacheAccessOrder.remove(key);
  _lyricCacheAccessOrder.add(key);

  while (_lyricResultCache.length > _lyricCacheMaxSize) {
    final oldestKey = _lyricCacheAccessOrder.removeAt(0);
    _lyricResultCache.remove(oldestKey);
  }
}

Lyric? getCachedLyric(
    {String? qqSongId, String? kugouSongHash, int? neSongId}) {
  final key = _cacheKey(
      qqSongId: qqSongId, kugouSongHash: kugouSongHash, neSongId: neSongId);
  if (key.isEmpty) return null;

  final lyric = _lyricResultCache[key];
  if (lyric != null) {
    _lyricCacheAccessOrder.remove(key);
    _lyricCacheAccessOrder.add(key);
  }
  return lyric;
}

/// 搜索指定源并返回最佳匹配的歌词
Future<Lyric?> getLyricFromPreferredSource(
    Audio audio, ResultSource source) async {
  final searchQueries = _buildSearchQueries(audio);
  if (searchQueries.isEmpty) {
    logger.w('[preferred] no valid search queries');
    return null;
  }

  final query = searchQueries.first;
  logger.i('[preferred] searching "$query" from $source');

  try {
    final List<SongSearchResult> results;
    switch (source) {
      case ResultSource.qq:
        final raw = await net_api
            .qqSearchLyric(keyword: query, pageSize: 3)
            .timeout(const Duration(seconds: 8));
        results = raw
            .map((item) => SongSearchResult.fromQQSearchItem(item, audio))
            .where((r) => r != null && r.score >= 0)
            .cast<SongSearchResult>()
            .toList();
        break;
      case ResultSource.kugou:
        final raw = await net_api
            .kgSearchLyric(keyword: query, pageSize: 3)
            .timeout(const Duration(seconds: 8));
        results = raw
            .map((item) => SongSearchResult.fromKugouSearchItem(item, audio))
            .where((r) => r != null && r.score >= 0)
            .cast<SongSearchResult>()
            .toList();
        break;
      case ResultSource.ne:
        final raw = await net_api
            .neSearchLyric(keyword: query, pageSize: 3)
            .timeout(const Duration(seconds: 8));
        results = raw
            .map((item) => SongSearchResult.fromNeSearchItem(item, audio))
            .where((r) => r != null && r.score > 0)
            .cast<SongSearchResult>()
            .toList();
        break;
    }

    if (results.isEmpty) {
      logger.i('[preferred] no results from $source');
      return null;
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    final best = results.first;
    logger.i(
        '[preferred] best from $source: score=${best.score} id=${best.qqSongId ?? best.kugouSongHash ?? best.neSongId}');

    return getOnlineLyric(
      qqSongId: best.qqSongId,
      kugouSongHash: best.kugouSongHash,
      neSongId: best.neSongId,
    );
  } catch (e) {
    logger.e('[preferred] $source search failed: $e');
    return null;
  }
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

  final key = _cacheKey(
      qqSongId: qqSongId, kugouSongHash: kugouSongHash, neSongId: neSongId);

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
    future.whenComplete(() {
      _lyricFetchCache.remove(key);
    }).then((lyric) {
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
  final futures = <Future<Lyric?>>[];

  if (qqSongId != null) {
    futures.add(_getQQSyncLyric(qqSongId));
  }

  if (neSongId != null) {
    futures.add(_getNeSyncLyric(neSongId));
  }

  if (kugouSongHash != null) {
    futures.add(_getKugouSyncLyric(kugouSongHash));
  }

  if (futures.isEmpty) return null;

  // Run all sources in parallel, each with error isolation
  final wrapped = futures.map((f) => f.catchError((e) {
        logger.e('Source failed: $e');
        return null;
      }));

  final results = await Future.wait(wrapped);

  // First non-empty lyric wins
  for (final lyric in results) {
    if (lyric != null && lyric.lines.isNotEmpty) {
      logger.i(
          '[getOnlineLyric] winner: lines=${lyric.lines.length} type=${lyric.lines.first.runtimeType}');
      logger.d('[getOnlineLyric] success: ${lyric.lines.length} lines');
      return lyric;
    }
  }

  logger.d('[getOnlineLyric] all sources returned null or empty');
  return null;
}

void clearLyricCaches() {
  _lyricResultCache.clear();
  _lyricFetchCache.clear();
  _lyricCacheAccessOrder.clear();
}

double _computeScore(Audio audio, String title, String artists, String album,
    {int? duration}) {
  double score = 0.0;

  // 时长差异过大 → 不奖励时长分（但仍保留标题/歌手匹配的可能，Acoustic/Remix 版本时长常不同）
  if (duration != null && audio.duration > 0) {
    final diff = (duration - audio.duration).abs();
    if (diff <= 3) {
      score += 30; // 3 秒内高度匹配
    } else if (diff <= 10) {
      score += 15; // 10 秒内基本匹配
    } else if (diff <= 30) {
      score += 5;
    }
    // diff > 30：不加分也不排除（可能是不同版本/remix/acoustic）
  }

  final normalizedAudioTitle = audio.title.toLowerCase();
  final normalizedAudioArtist = audio.artist.toLowerCase();
  final normalizedTitle = title.toLowerCase();
  final normalizedArtists = artists.toLowerCase();

  if (normalizedTitle.isEmpty) return -1.0;
  if (normalizedAudioTitle.isEmpty) return -1.0;

  // 剥离常见后缀（(Acoustic)/(Live)/(Remix)/(Explicit)/Feat. 等）提高匹配准确度
  String stripTrailingVariants(String t) {
    return t
        .replaceAll(
            RegExp(
                r'\s*\([^)]*(?:acoustic|live|remix|explicit|deluxe|edit|version|mix|radio|single|demo|bonus|track|album|studio)[^)]*\)',
                caseSensitive: false),
            '')
        .replaceAll(RegExp(r'\s*\(feat\..*\)', caseSensitive: false), '')
        .replaceAll(
            RegExp(r'\s*-\s*(?:acoustic|live|remix).*$', caseSensitive: false),
            '')
        .trim();
  }

  final strippedAudio = stripTrailingVariants(normalizedAudioTitle);
  final strippedResult = stripTrailingVariants(normalizedTitle);

  // 用剥离后的标题做精确匹配
  if (strippedResult == strippedAudio) {
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
      score += 30;
    } else if (normalizedAudioArtist.contains(normalizedArtists) ||
        normalizedArtists.contains(normalizedAudioArtist)) {
      score += 15;
    } else {
      int matchCount = 0;
      for (int i = 0;
          i < min(normalizedArtists.length, normalizedAudioArtist.length);
          i++) {
        if (normalizedArtists[i] == normalizedAudioArtist[i]) {
          matchCount++;
        }
      }
      score += 10.0 *
          matchCount /
          max(normalizedArtists.length, normalizedAudioArtist.length);
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
  String? lyricType;

  String? qqSongId;
  String? kugouSongHash;
  int? neSongId;

  SongSearchResult(
      this.source, this.title, this.artists, this.album, this.score,
      {this.qqSongId,
      this.kugouSongHash,
      this.neSongId,
      this.duration,
      this.lyricType});

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
      lyricType: '逐字',
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
      lyricType: '逐字',
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
      lyricType: null,
    );
  }
}

/// 清理搜索关键词，移除分隔符和噪音
String _cleanForSearch(String text) {
  return text
      .replaceAll(RegExp(r'\s*[-–—－/、,，&＆+×|｜]\s*'), ' ') // 分隔符 → 空格
      .replaceAll(
          RegExp(r'[【】\[\]（）()《》<>「」『』"\x27~\u00B7\u30FB]'), ' ') // 标点符号 → 空格
      .replaceAll(RegExp(r'\s+'), ' ') // 多个空格 → 单个
      .trim();
}

/// 构建多个搜索查询
/// 例如："呼吸决定 - Fine乐团" → ["呼吸决定 Fine乐团", "呼吸决定", "Fine乐团 呼吸决定"]
List<String> _buildSearchQueries(Audio audio) {
  final queries = <String>[];

  final rawTitle = audio.title.trim();
  final rawArtist = audio.artist.trim();

  if (rawTitle.isEmpty || rawTitle == 'UNKNOWN') {
    // 从文件路径提取文件名作为后备
    final fileName = audio.path
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'\.[^.]+$'), '');
    if (fileName.isNotEmpty) {
      queries.add(_cleanForSearch(fileName));
    }
    return queries;
  }

  final cleanTitle = _cleanForSearch(rawTitle);
  final cleanArtist = _cleanForSearch(rawArtist);
  final hasArtist = cleanArtist.isNotEmpty && cleanArtist != 'UNKNOWN';

  // 1. 主要查询：标题 + 艺术家（空格连接，替代原来的 "title - artist"）
  if (hasArtist) {
    queries.add('$cleanTitle $cleanArtist');
  } else {
    queries.add(cleanTitle);
  }

  // 2. 分段查询：当有多片段时，单独搜标题和艺术家
  if (hasArtist) {
    queries.add(cleanTitle);
    queries.add('$cleanArtist $cleanTitle'); // 反向顺序
  }

  // 去重，最多5个查询
  return queries.toSet().take(5).toList();
}

Future<List<SongSearchResult>> uniSearch(Audio audio) async {
  final searchQueries = _buildSearchQueries(audio);
  if (searchQueries.isEmpty) {
    logger.w('uniSearch: no valid search queries');
    return [];
  }

  final List<SongSearchResult> result = [];
  const int perSourceLimit = 1; // 聚合：每源只取一条，严格筛选

  // 尝试每个查询，直到找到高置信结果
  for (int i = 0; i < searchQueries.length; i++) {
    final searchQuery = searchQueries[i];
    logger.d('=== uniSearch query #${i + 1}: "$searchQuery" ===');

    final kgFuture =
        _searchKugouWithTimeout(searchQuery, audio, 6, perSourceLimit);
    final qqFuture =
        _searchQQWithTimeout(searchQuery, audio, 6, perSourceLimit);
    final neFuture =
        _searchNEWithTimeout(searchQuery, audio, 6, perSourceLimit);

    final results =
        await Future.wait([kgFuture, qqFuture, neFuture], eagerError: false)
            .timeout(const Duration(seconds: 18), onTimeout: () {
      logger.w('uniSearch timeout for query: $searchQuery');
      return <List<SongSearchResult>>[[], [], []];
    });

    // 取各来源分数最高的结果
    final bestResults = <SongSearchResult>[];
    for (final sourceResults in results) {
      if (sourceResults.isNotEmpty) {
        sourceResults.sort((a, b) => b.score.compareTo(a.score));
        bestResults.add(sourceResults.first);
      }
    }

    bestResults.sort((a, b) => b.score.compareTo(a.score));

    // 只保留分数 >= 60 的结果（充分匹配）
    for (final item in bestResults) {
      if (item.score >= 60 && !_containsResult(result, item)) {
        result.add(item);
      }
    }

    // 如果已经找到高置信结果，不再尝试后续查询
    if (result.isNotEmpty) {
      logger.d('=== uniSearch found results on query #${i + 1}, stopping ===');
      break;
    }
  }

  logger.d(
      '=== uniSearch done: ${result.length} results, best=${result.isNotEmpty ? result.first.score : 0} ===');
  return result.take(3).toList();
}

Future<List<SongSearchResult>> _searchKugouWithTimeout(
    String query, Audio audio, int seconds, int limit) async {
  try {
    logger.d('[KG] searching: "$query"');
    final kugouResults = await net_api
        .kgSearchLyric(
          keyword: query,
          pageSize: limit,
        )
        .timeout(Duration(seconds: seconds),
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
    final qqResults = await net_api
        .qqSearchLyric(
          keyword: query,
          pageSize: limit,
        )
        .timeout(Duration(seconds: seconds),
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
    final neResults = await net_api
        .neSearchLyric(
          keyword: query,
          pageSize: limit,
        )
        .timeout(Duration(seconds: seconds),
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

  final currentSeq = ++_manualSearchSeq;

  const int perSourceLimit = 10;
  const int pageSize = perSourceLimit;

  final neFuture = _neSearchSafe(keyword: query, pageSize: pageSize);
  final kgFuture = _kgSearchSafe(keyword: query, pageSize: pageSize);
  final qqFuture = _qqSearchSafe(keyword: query, pageSize: pageSize);

  final results = await Future.wait([neFuture, kgFuture, qqFuture]);

  if (currentSeq != _manualSearchSeq) {
    logger.d(
        '[MS] cancelled: new request started (seq=$currentSeq, current=$_manualSearchSeq)');
    return [];
  }

  final neResults = results[0];
  final kugouResults = results[1];
  final qqResults = results[2];

  final List<SongSearchResult> result = [];

  for (final item in neResults.take(perSourceLimit)) {
    final searchResult = SongSearchResult.fromNeSearchItem(item, audio);
    if (searchResult != null &&
        searchResult.score > 0 &&
        !_containsResult(result, searchResult)) {
      result.add(searchResult);
    }
  }

  for (final item in kugouResults.take(perSourceLimit)) {
    final searchResult = SongSearchResult.fromKugouSearchItem(item, audio);
    if (searchResult != null &&
        searchResult.score > 0 &&
        !_containsResult(result, searchResult)) {
      result.add(searchResult);
    }
  }

  for (final item in qqResults.take(perSourceLimit)) {
    final searchResult = SongSearchResult.fromQQSearchItem(item, audio);
    if (searchResult != null &&
        searchResult.score > 0 &&
        !_containsResult(result, searchResult)) {
      result.add(searchResult);
    }
  }

  result.sort((a, b) => b.score.compareTo(a.score));
  logger.d('=== manualSearch done: ${result.length} results ===');
  return result.sublist(0, min(limit, result.length));
}

Future<List<dynamic>> _neSearchSafe(
    {required String keyword, required int pageSize}) async {
  try {
    return await net_api
        .neSearchLyric(keyword: keyword, pageSize: pageSize)
        .timeout(const Duration(seconds: 8));
  } catch (err, trace) {
    logger.e('[MS] NE ERROR: $err', stackTrace: trace);
    return [];
  }
}

Future<List<dynamic>> _kgSearchSafe(
    {required String keyword, required int pageSize}) async {
  try {
    return await net_api
        .kgSearchLyric(keyword: keyword, pageSize: pageSize)
        .timeout(const Duration(seconds: 8));
  } catch (err, trace) {
    logger.e('[MS] KG ERROR: $err', stackTrace: trace);
    return [];
  }
}

Future<List<dynamic>> _qqSearchSafe(
    {required String keyword, required int pageSize}) async {
  try {
    return await net_api
        .qqSearchLyric(keyword: keyword, pageSize: pageSize)
        .timeout(const Duration(seconds: 8));
  } catch (err, trace) {
    logger.e('[MS] QQ ERROR: $err', stackTrace: trace);
    return [];
  }
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

    final parsed = await lyricResult.toParsedLyric();
    if (parsed != null && parsed.isNotEmpty) {
      return _parsedToLyric(parsed, rawText: lyricResult.mainLyric);
    }
    logger.d('[QQ lyric] toParsedLyric returned null or empty');
  } catch (err, trace) {
    logger.e('Failed to get QQ lyric: $err', stackTrace: trace);
  }
  return null;
}

Future<Lyric?> _getKugouSyncLyric(String kugouSongHash) async {
  try {
    final lyricResult = await net_api
        .kgGetLyric(hash: kugouSongHash)
        .timeout(const Duration(seconds: 10));
    if (lyricResult == null || !lyricResult.hasContent) return null;

    final parsed = await lyricResult.toParsedLyric();
    if (parsed != null && parsed.isNotEmpty) {
      final syncLines = <SyncLyricLine>[];
      for (final entry in parsed.lines) {
        // 过滤元数据行
        final lineContent = entry.content;
        if (lineContent.isNotEmpty && LrcLine.isLyricMetadataLine(lineContent)) {
          continue;
        }

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
          if (entry.content.isEmpty) {
            syncLines.add(SyncLyricLine(entry.start, length, []));
          } else {
            syncLines.add(SyncLyricLine(
              entry.start,
              length,
              [SyncLyricWord(entry.start, length, entry.content)],
              entry.translation,
            )..romanLyric = entry.romanization);
          }
        }
      }
      final result = Krc(syncLines, LyricFormat.local, lyricResult.mainLyric);
      return _postStripMetadata(result);
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

    final parsed = await lyricResult.toParsedLyric();
    if (parsed != null && parsed.isNotEmpty) {
      return _parsedToLyric(parsed, rawText: lyricResult.mainLyric);
    }
    logger.d('[NE lyric] toParsedLyric returned null or empty');
  } catch (err, trace) {
    logger.e('Failed to get NetEase lyric: $err', stackTrace: trace);
  }
  return null;
}

Lyric? _parsedToLyric(ParsedLyricResult parsed, {String? rawText}) {
  logger.i(
      '[parsedToLyric] hasWordByWord=${parsed.hasWordByWord} format=${parsed.format.name} lines=${parsed.lines.length}');
  if (parsed.hasWordByWord) {
    final syncLines = <SyncLyricLine>[];
    for (final entry in parsed.lines) {
      // 过滤同步歌词中的元数据行
      final lineContent = entry.content;
      if (lineContent.isNotEmpty && LrcLine.isLyricMetadataLine(lineContent)) {
        continue;
      }

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
        if (entry.content.isEmpty) {
          // 间奏空白行：保持 words 为空，让 UI 识别为 LyricTransitionTile
          syncLines.add(SyncLyricLine(entry.start, length, []));
        } else {
          syncLines.add(SyncLyricLine(
            entry.start,
            length,
            [SyncLyricWord(entry.start, length, entry.content)],
            entry.translation,
          )..romanLyric = entry.romanization);
        }
      }
    }
    final result = Qrc(syncLines, LyricFormat.local, rawText);
    return _postStripMetadata(result);
  }

  final unsyncLines = <LrcLine>[];
  for (int i = 0; i < parsed.lines.length; i++) {
    final entry = parsed.lines[i];
    // 过滤非同步歌词中的元数据行
    if (entry.content.isNotEmpty && LrcLine.isLyricMetadataLine(entry.content)) {
      continue;
    }

    final line = LrcLine(
      entry.start,
      entry.content,
      requiredIsBlank: entry.content.isEmpty,
      translation: entry.translation,
    )..romanLyric = entry.romanization;
    // 设置歌词行时长：前奏/间奏空白行需要正确的 length 才能被 UI 显示
    if (entry.content.isEmpty) {
      line.length = entry.nextTime - entry.start;
    } else if (i < parsed.lines.length - 1) {
      line.length = parsed.lines[i + 1].start - entry.start;
    } else {
      line.length = entry.nextTime - entry.start;
    }
    unsyncLines.add(line);
  }
  final result = Lrc(unsyncLines, LyricFormat.web, rawText);
  return _postStripMetadata(result);
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

/// 在线歌词的后处理：用 stripLyricMetadata 做全方位元数据剥离
/// 对齐本地歌词的 loadLyricFromAudio → _stripMetadata 行为
Lyric? _postStripMetadata(Lyric lyric) {
  if (lyric.lines.isEmpty) return lyric;
  final regList = defaultExcludeRegexes
      .map((p) => RegExp(p, caseSensitive: false))
      .toList();
  final softRegList = defaultExcludeSoftRegexes
      .map((p) => RegExp(p, caseSensitive: false))
      .toList();
  final options = StripOptions(
    keywords: defaultExcludeKeywords,
    regexes: regList,
    softRegexes: softRegList,
  );
  final filtered = stripLyricMetadata(lyric.lines, options);
  if (!identical(lyric.lines, filtered)) {
    lyric.lines
      ..clear()
      ..addAll(filtered);
  }
  return lyric;
}
