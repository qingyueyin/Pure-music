import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/services/online_lyric/models/lyric_entry.dart'
    hide LyricFormat;
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/lyric/krc.dart';
import 'package:pure_music/lyric/qrc.dart';
import 'package:pure_music/lyric/ttml.dart';
import 'package:pure_music/services/online_lyric/api/net_lyric_api.dart'
    as net_api;
import 'package:pure_music/core/utils.dart' as utils;
import 'package:pure_music/lyric/lyric_stripper.dart';
import 'package:pure_music/lyric/exclude_data.dart';

final logger = utils.logger;

enum ResultSource { qq, kugou, ne, amll }

const int _lyricCacheMaxSize = 64;
const int _amllSearchLimit = 30;
final Map<String, Future<Lyric?>> _lyricFetchCache = {};
final Map<String, Lyric> _lyricResultCache = {};
final List<String> _lyricCacheAccessOrder = [];

String _cacheKey(
    {String? qqSongId,
    String? kugouSongHash,
    int? neSongId,
    String? amllTtmlFile}) {
  return qqSongId != null
      ? 'qq:$qqSongId'
      : kugouSongHash != null
          ? 'kg:$kugouSongHash'
          : neSongId != null
              ? 'ne:$neSongId'
              : amllTtmlFile != null
                  ? 'amll:$amllTtmlFile'
                  : '';
}

void cacheLyric({
  String? qqSongId,
  String? kugouSongHash,
  int? neSongId,
  String? amllTtmlFile,
  required Lyric lyric,
}) {
  final key = _cacheKey(
    qqSongId: qqSongId,
    kugouSongHash: kugouSongHash,
    neSongId: neSongId,
    amllTtmlFile: amllTtmlFile,
  );
  if (key.isEmpty) return;

  _lyricResultCache[key] = lyric;

  _lyricCacheAccessOrder.remove(key);
  _lyricCacheAccessOrder.add(key);

  while (_lyricResultCache.length > _lyricCacheMaxSize) {
    final oldestKey = _lyricCacheAccessOrder.removeAt(0);
    _lyricResultCache.remove(oldestKey);
  }
}

Lyric? getCachedLyric({
  String? qqSongId,
  String? kugouSongHash,
  int? neSongId,
  String? amllTtmlFile,
}) {
  final key = _cacheKey(
    qqSongId: qqSongId,
    kugouSongHash: kugouSongHash,
    neSongId: neSongId,
    amllTtmlFile: amllTtmlFile,
  );
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
  final searchQueries = buildOnlineLyricSearchQueries(audio);
  if (searchQueries.isEmpty) {
    logger.w('[preferred] no valid search queries');
    return null;
  }

  final query = searchQueries.first;
  logger.i('[preferred] searching from $source');

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
      case ResultSource.amll:
        final raw = await net_api
            .amllSearchSingle(keyword: query, pageSize: _amllSearchLimit)
            .timeout(const Duration(seconds: 8));
        results = raw
            .map((item) => SongSearchResult.fromAmllSearchItem(item, audio))
            .where((r) => r != null && r.score >= 0)
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
    logger.i('[preferred] best from $source: score=${best.score}');

    return getOnlineLyric(
      qqSongId: best.qqSongId,
      kugouSongHash: best.kugouSongHash,
      neSongId: best.neSongId,
      amllTtmlFile: best.amllTtmlFile,
    );
  } catch (e) {
    logger.e('[preferred] $source search failed: ${e.runtimeType}');
    return null;
  }
}

Future<Lyric?> getOnlineLyric({
  String? qqSongId,
  String? kugouSongHash,
  int? neSongId,
  String? amllTtmlFile,
}) {
  final cached = getCachedLyric(
    qqSongId: qqSongId,
    kugouSongHash: kugouSongHash,
    neSongId: neSongId,
    amllTtmlFile: amllTtmlFile,
  );
  if (cached != null) {
    logger.d('[getOnlineLyric] cache hit');
    return Future.value(cached);
  }

  final key = _cacheKey(
    qqSongId: qqSongId,
    kugouSongHash: kugouSongHash,
    neSongId: neSongId,
    amllTtmlFile: amllTtmlFile,
  );

  if (key.isNotEmpty && _lyricFetchCache.containsKey(key)) {
    logger.d('[getOnlineLyric] request dedup');
    return _lyricFetchCache[key]!;
  }

  final future = _fetchLyricInternal(
    qqSongId: qqSongId,
    kugouSongHash: kugouSongHash,
    neSongId: neSongId,
    amllTtmlFile: amllTtmlFile,
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
          amllTtmlFile: amllTtmlFile,
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
  String? amllTtmlFile,
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

  if (amllTtmlFile != null) {
    futures.add(_getAmllTtmlLyric(amllTtmlFile));
  }

  if (futures.isEmpty) return null;

  // Run all sources in parallel, each with error isolation
  final wrapped = futures.map((f) => f.catchError((e) {
        logger.e('Source failed: ${e.runtimeType}');
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

String _stripTrailingFeaturedArtists(String title) {
  return title
      .replaceAll(
        RegExp(
          r'\s*[\(\[（【]\s*(?:feat(?:uring)?|ft)\.?\s+[^)\]）】]*[\)\]）】]\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(
        RegExp(
          r'\s+(?:feat(?:uring)?|ft)\.?\s*.*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
}

bool _containsVersionQualifier(String value) {
  return RegExp(
    r'\b(?:acoustic|live|remix|explicit|deluxe|edit|version|mix|radio|single|demo|bonus|track|album|studio|remaster(?:ed|ing)?|instrumental|karaoke|cover|ver\.?)\b|现场|現場|现场版|現場版|演唱会|演唱會|音乐节|音樂節|混音|重混|伴奏|纯音乐|純音樂|翻唱|ライブ|リミックス|アコースティック|インスト(?:ゥルメンタル)?|弾き語り|라이브|리믹스|버전',
    caseSensitive: false,
  ).hasMatch(value);
}

String? _titleLanguageGroup(String value) {
  if (RegExp(r'[\u3040-\u30ff]').hasMatch(value)) return 'ja';
  if (RegExp(r'[\uac00-\ud7af]').hasMatch(value)) return 'ko';

  final hasHan = RegExp(r'[\u3400-\u9fff]').hasMatch(value);
  final hasLatin = RegExp(r'[A-Za-z]').hasMatch(value);
  if (hasHan && !hasLatin) return 'han';
  if (hasLatin && !hasHan) return 'latin';
  return null;
}

String _stripTrailingLocalizedTranslation(String title) {
  final match = RegExp(
    r'^(.*?)\s*[\(\[（【]([^)\]）】]+)[\)\]）】]\s*$',
  ).firstMatch(title);
  if (match == null) return title.trim();

  final base = match.group(1)!.trim();
  final suffix = match.group(2)!.trim();
  if (base.isEmpty || suffix.isEmpty || _containsVersionQualifier(suffix)) {
    return title.trim();
  }

  final baseLanguage = _titleLanguageGroup(base);
  final suffixLanguage = _titleLanguageGroup(suffix);
  if (baseLanguage != null &&
      suffixLanguage != null &&
      baseLanguage != suffixLanguage) {
    return base;
  }
  return title.trim();
}

String _stripNonVersionTitleSuffixes(String title) {
  return _stripTrailingFeaturedArtists(
    _stripTrailingLocalizedTranslation(title),
  );
}

String _normalizeExactMatchText(String value) {
  return _stripNonVersionTitleSuffixes(value.toLowerCase()).replaceAll(
    RegExp(
        r'''[-‐‑‒–—―\s_/\\|,，、.&＆+＋·・:：;；!！?？'"“”‘’`~～^()（）\[\]【】{}《》〈〉「」『』]+'''),
    '',
  );
}

Set<String> _normalizedArtistParts(String value) {
  final separated = value
      .replaceAll(
        RegExp(
          r'\s+(?:feat(?:uring)?|ft|with)\.?\s*',
          caseSensitive: false,
        ),
        ';',
      )
      .replaceAll(RegExp(r'\s+[x×]\s+', caseSensitive: false), ';');
  return separated
      .split(RegExp(r'[、,，/&＆;；|()（）\[\]【】]+'))
      .map(_normalizeExactMatchText)
      .where((part) => part.isNotEmpty && part != 'unknown')
      .toSet();
}

bool _isExactAggregateMatch(Audio audio, SongSearchResult result) {
  final audioTitle = _normalizeExactMatchText(audio.title);
  final resultTitle = _normalizeExactMatchText(result.title);
  if (audioTitle.isEmpty || resultTitle != audioTitle) return false;

  final audioArtists = _normalizedArtistParts(audio.artist);
  if (audioArtists.isEmpty) return true;

  final resultArtists = _normalizedArtistParts(result.artists);
  return resultArtists.any(audioArtists.contains);
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

  final strippedAudio = _stripNonVersionTitleSuffixes(normalizedAudioTitle);
  final strippedResult = _stripNonVersionTitleSuffixes(normalizedTitle);

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
  String? amllTtmlFile;

  SongSearchResult(
      this.source, this.title, this.artists, this.album, this.score,
      {this.qqSongId,
      this.kugouSongHash,
      this.neSongId,
      this.amllTtmlFile,
      this.duration,
      this.lyricType});

  LyricSource toLyricSource() {
    final sourceType = switch (source) {
      ResultSource.qq => LyricSourceType.qq,
      ResultSource.kugou => LyricSourceType.kugou,
      ResultSource.ne => LyricSourceType.ne,
      ResultSource.amll => LyricSourceType.amll,
    };
    return LyricSource(
      sourceType,
      qqSongId: qqSongId,
      kugouSongHash: kugouSongHash,
      neSongId: neSongId,
      amllTtmlFile: amllTtmlFile,
    );
  }

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

  static SongSearchResult? fromAmllSearchItem(
      net_api.AmllSearchItem item, Audio audio) {
    final apiScore = (item.score / 1000).clamp(0.0, 1.0).toDouble();
    final computeScore =
        _computeScore(audio, item.title, item.artist, item.album);
    final blended = apiScore * 60 + computeScore * 0.4;
    return SongSearchResult(
      ResultSource.amll,
      item.title,
      item.artist,
      item.album,
      blended,
      amllTtmlFile: item.id,
    );
  }
}

Future<List<SongSearchResult>> validateOnlineLyricResults(
  Iterable<SongSearchResult> candidates, {
  Future<Lyric?> Function(SongSearchResult result)? loadLyric,
  int maxConcurrency = 6,
}) async {
  final items = candidates.toList(growable: false);
  if (items.isEmpty) return const [];

  final loader = loadLyric ?? _loadOnlineLyricResult;
  final validated = List<SongSearchResult?>.filled(items.length, null);
  var nextIndex = 0;

  Future<void> worker() async {
    while (nextIndex < items.length) {
      final index = nextIndex++;
      final item = items[index];
      try {
        final lyric = await loader(item);
        if (lyric == null || lyric.lines.isEmpty) continue;
        item.lyricType = lyric.isWordByWord ? '逐字' : '逐行';
        validated[index] = item;
      } catch (error, trace) {
        logger.w(
          'Lyric result validation failed: ${error.runtimeType}',
          stackTrace: trace,
        );
      }
    }
  }

  final workerCount = min(max(1, maxConcurrency), items.length);
  await Future.wait(List.generate(workerCount, (_) => worker()));
  return validated.whereType<SongSearchResult>().toList(growable: false);
}

Future<List<SongSearchResult>> selectBestValidOnlineLyricResults(
  Audio audio,
  Iterable<SongSearchResult> candidates, {
  Future<Lyric?> Function(SongSearchResult result)? loadLyric,
  int maxConcurrency = 6,
}) async {
  final exactCandidates = candidates
      .where((item) => _isExactAggregateMatch(audio, item))
      .toList(growable: false);
  final validated = (await validateOnlineLyricResults(
    exactCandidates,
    loadLyric: loadLyric,
    maxConcurrency: maxConcurrency,
  ))
      .toList()
    ..sort((a, b) => b.score.compareTo(a.score));

  final bestBySource = <ResultSource, SongSearchResult>{};
  for (final item in validated) {
    bestBySource.putIfAbsent(item.source, () => item);
  }
  return bestBySource.values.toList(growable: false);
}

Future<Lyric?> _loadOnlineLyricResult(SongSearchResult result) {
  return getOnlineLyric(
    qqSongId: result.qqSongId,
    kugouSongHash: result.kugouSongHash,
    neSongId: result.neSongId,
    amllTtmlFile: result.amllTtmlFile,
  );
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

String _cleanArtistsForSearch(Audio audio) {
  final artistParts = audio.splitedArtists
      .map((artist) => artist.trim())
      .where((artist) => artist.isNotEmpty)
      .toList(growable: false);
  final joinedArtists =
      artistParts.isEmpty ? audio.artist.trim() : artistParts.join(' ');
  return _cleanForSearch(joinedArtists)
      .replaceAll(
        RegExp(
          r'\s+(?:feat(?:uring)?|ft|with|vs)\.?\s+',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// 构建多个搜索查询
/// 例如："呼吸决定 - Fine乐团" → ["呼吸决定 Fine乐团", "呼吸决定", "Fine乐团 呼吸决定"]
List<String> buildOnlineLyricSearchQueries(Audio audio) {
  final queries = <String>[];

  final rawTitle = audio.title.trim();

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
  final cleanArtist = _cleanArtistsForSearch(audio);
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
  final searchQueries = buildOnlineLyricSearchQueries(audio);
  if (searchQueries.isEmpty) {
    logger.w('uniSearch: no valid search queries');
    return [];
  }

  final bestBySource = <ResultSource, SongSearchResult>{};
  const int perSourceSearchLimit = 6;

  // 尝试每个查询，直到找到高置信结果
  for (int i = 0; i < searchQueries.length; i++) {
    final searchQuery = searchQueries[i];
    logger.d('=== uniSearch query #${i + 1} ===');

    final kgFuture =
        _searchKugouWithTimeout(searchQuery, audio, 6, perSourceSearchLimit);
    final qqFuture =
        _searchQQWithTimeout(searchQuery, audio, 6, perSourceSearchLimit);
    final neFuture =
        _searchNEWithTimeout(searchQuery, audio, 6, perSourceSearchLimit);
    final amllFuture =
        _searchAMLLWithTimeout(searchQuery, audio, 6, _amllSearchLimit);

    final results = await Future.wait(
            [kgFuture, qqFuture, neFuture, amllFuture],
            eagerError: false)
        .timeout(const Duration(seconds: 18), onTimeout: () {
      logger.w('uniSearch query #${i + 1} timed out');
      return <List<SongSearchResult>>[[], [], [], []];
    });

    final unresolvedCandidates = results
        .expand((sourceResults) => sourceResults)
        .where((item) => !bestBySource.containsKey(item.source));
    final selectedResults = await selectBestValidOnlineLyricResults(
      audio,
      unresolvedCandidates,
      maxConcurrency: 4,
    );

    for (final item in selectedResults) {
      bestBySource[item.source] = item;
    }

    if (bestBySource.length == ResultSource.values.length) {
      logger.d('=== uniSearch resolved every source on query #${i + 1} ===');
      break;
    }
  }

  final result = bestBySource.values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  logger.d(
      '=== uniSearch done: ${result.length} results, best=${result.isNotEmpty ? result.first.score : 0} ===');
  return result.take(4).toList();
}

Future<List<SongSearchResult>> _searchKugouWithTimeout(
    String query, Audio audio, int seconds, int limit) async {
  try {
    logger.d('[KG] searching');
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
  } catch (err) {
    logger.w('[KG] search failed: ${err.runtimeType}');
    return [];
  }
}

Future<List<SongSearchResult>> _searchQQWithTimeout(
    String query, Audio audio, int seconds, int limit) async {
  try {
    logger.d('[QQ] searching');
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
  } catch (err) {
    logger.w('[QQ] search failed: ${err.runtimeType}');
    return [];
  }
}

Future<List<SongSearchResult>> _searchNEWithTimeout(
    String query, Audio audio, int seconds, int limit) async {
  try {
    logger.d('[NE] searching');
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
  } catch (err) {
    logger.w('[NE] search failed: ${err.runtimeType}');
    return [];
  }
}

Future<List<SongSearchResult>> _searchAMLLWithTimeout(
    String query, Audio audio, int seconds, int limit) async {
  try {
    logger.d('[AMLL] searching');
    final amllResults = await net_api
        .amllSearchSingle(keyword: query, pageSize: limit)
        .timeout(Duration(seconds: seconds),
            onTimeout: () => throw TimeoutException('AMLL search timeout'));
    logger.d('[AMLL] got ${amllResults.length} raw results');
    final List<SongSearchResult> results = [];
    for (final item in amllResults) {
      final searchResult = SongSearchResult.fromAmllSearchItem(item, audio);
      if (searchResult != null && searchResult.score >= 0) {
        results.add(searchResult);
      }
    }
    logger.d('[AMLL] accepted ${results.length}');
    return results;
  } catch (err) {
    logger.w('[AMLL] search failed: ${err.runtimeType}');
    return [];
  }
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
        if (lineContent.isNotEmpty &&
            LrcLine.isLyricMetadataLine(lineContent)) {
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

Future<Lyric?> _getAmllTtmlLyric(String amllTtmlFile) async {
  try {
    final raw = await net_api.amllGetTtml(amllTtmlFile);
    if (raw == null || raw.isEmpty) return null;

    final ttml = Ttml.fromTtmlText(raw);
    if (ttml == null || ttml.lines.isEmpty) return null;

    logger.i('[AMLL lyric] parsed ${ttml.lines.length} lines');
    return ttml;
  } catch (err, trace) {
    logger.e('Failed to get AMLL lyric: $err', stackTrace: trace);
  }
  return null;
}

Future<Lyric?> getAmllLyric(String id) async {
  final cached = getCachedLyric(amllTtmlFile: id);
  if (cached != null) return cached;
  return getOnlineLyric(amllTtmlFile: id);
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
    if (entry.content.isNotEmpty &&
        LrcLine.isLyricMetadataLine(entry.content)) {
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
