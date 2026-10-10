import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/workload_policy.dart';
import 'package:pure_music/core/page_sort.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as library_db;
import 'package:pure_music/library/audio_sort.dart';
import 'package:pure_music/library/library_page_order_cache.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/search_action_state.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:pure_music/library/library_page_snapshot_coordinator.dart';

String _audioPathLookupKey(String value) {
  var normalized = value.trim().replaceAll('\\', '/');
  while (normalized.endsWith('/') && normalized.length > 1) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized.toLowerCase();
}

Set<String> _folderPathKeySet(Iterable<String> paths) {
  final result = <String>{};
  for (final path in paths) {
    final key = pendingFolderKey(path);
    if (key.isNotEmpty) result.add(key);
  }
  return result;
}

int? _optionalInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString().trim() ?? '');
}

typedef _AudioSlotMerge = ({
  List<Audio>? mergedAudios,
  bool collectionsChanged,
  bool pageOrderChanged,
  bool canReuseExistingAudios,
});

class _AudioLoadPool {
  _AudioLoadPool();

  static const int _maxTexts = 65536;
  static const int _maxArtistLists = 32768;
  final Map<String, String> _texts = <String, String>{};
  final Map<String, List<String>> _artistLists = <String, List<String>>{};

  int get textCount => _texts.length;
  int get artistListCount => _artistLists.length;

  String text(String value) {
    if (value.isEmpty) return '';
    final existing = _texts[value];
    if (existing != null) return existing;
    if (_texts.length >= _maxTexts) return value;
    _texts[value] = value;
    return value;
  }

  String? optionalText(String? value) => value == null ? null : text(value);

  List<String> artistList(String value) {
    if (value.isEmpty) return const <String>[];
    final canonicalValue = text(value);
    final existing = _artistLists[canonicalValue];
    if (existing != null) return existing;
    final parts = Audio._splitArtistNames(canonicalValue);
    for (var index = 0; index < parts.length; index++) {
      parts[index] = text(parts[index]);
    }
    if (_artistLists.length >= _maxArtistLists) return parts;
    final result = List<String>.unmodifiable(parts);
    _artistLists[canonicalValue] = result;
    return result;
  }

  void release() {
    _artistLists.clear();
    _texts.clear();
  }
}

Audio _audioFromIndex(library_db.IndexAudio audio, _AudioLoadPool pool) =>
    Audio._fromLoaded(
      audio.title,
      audio.artist,
      audio.album,
      audio.albumArtist,
      audio.track,
      audio.duration.toInt(),
      audio.bitrate,
      audio.sampleRate,
      audio.path,
      audio.modified.toInt(),
      audio.created.toInt(),
      audio.by,
      pool,
      disc: audio.disc,
      playCount: audio.playCount,
    );

Audio _audioFromMap(Map map, _AudioLoadPool pool) => Audio._fromLoaded(
  map['title'] ?? '',
  map['artist'] ?? '',
  map['album'] ?? '',
  map['album_artist'],
  map['track'] ?? 0,
  map['duration'] ?? 0,
  map['bitrate'],
  map['sample_rate'],
  map['path'] ?? '',
  map['modified'] ?? 0,
  map['created'] ?? 0,
  map['by'],
  pool,
  disc: _optionalInt(map['disc']),
  playCount: map['play_count'] ?? 0,
);

String _rssMegabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

Uint32List _sortLibraryPageIndexes({
  required int length,
  required bool descending,
  List<String>? naturalValues,
  List<int>? integerValues,
  List<String>? integerTieBreaks,
  bool reuseEqualKeys = false,
}) {
  final indexes = List<int>.generate(length, (index) => index);
  if (naturalValues != null) {
    sortNaturallyBy(
      indexes,
      (index) => naturalValues[index],
      descending: descending,
      reuseEqualKeys: reuseEqualKeys,
    );
    return Uint32List.fromList(indexes);
  }
  sortByIntegerThenNatural(
    indexes,
    valueOf: (index) => integerValues![index],
    tieBreakOf: (index) => integerTieBreaks?[index] ?? '',
    descending: descending,
  );
  return Uint32List.fromList(indexes);
}

typedef _SecondaryPrepareInputs = ({
  bool prepareArtists,
  bool prepareAlbums,
  List<Artist> artists,
  List<Album> albums,
  int artistSortMethod,
  int albumSortMethod,
  SortOrder artistSortOrder,
  SortOrder albumSortOrder,
  bool artistDescending,
  bool albumDescending,
  List<String>? artistNaturalValues,
  List<int>? artistIntegerValues,
  List<String>? artistIntegerTieBreaks,
  List<String>? albumNaturalValues,
  List<int>? albumIntegerValues,
  List<String>? albumIntegerTieBreaks,
});

typedef _SecondaryPageSortRequest = ({
  SendPort sendPort,
  int artistCount,
  List<String>? artistNaturalValues,
  List<int>? artistIntegerValues,
  List<String>? artistIntegerTieBreaks,
  bool artistDescending,
  int albumCount,
  List<String>? albumNaturalValues,
  List<int>? albumIntegerValues,
  List<String>? albumIntegerTieBreaks,
  bool albumDescending,
});

TransferableTypedData _transferPageOrder(Uint32List order) {
  return TransferableTypedData.fromList([
    order.buffer.asUint8List(order.offsetInBytes, order.lengthInBytes),
  ]);
}

Uint32List _materializeTransferredPageOrder(TransferableTypedData data) {
  final bytes = data.materialize().asUint8List();
  return bytes.buffer.asUint32List(
    bytes.offsetInBytes,
    bytes.lengthInBytes ~/ Uint32List.bytesPerElement,
  );
}

void _sortSecondaryPageIndexes(_SecondaryPageSortRequest request) {
  try {
    final artistOrder = _sortLibraryPageIndexes(
      length: request.artistCount,
      naturalValues: request.artistNaturalValues,
      integerValues: request.artistIntegerValues,
      integerTieBreaks: request.artistIntegerTieBreaks,
      descending: request.artistDescending,
    );
    request.sendPort.send(<Object?>[0, _transferPageOrder(artistOrder)]);
    final albumOrder = _sortLibraryPageIndexes(
      length: request.albumCount,
      naturalValues: request.albumNaturalValues,
      integerValues: request.albumIntegerValues,
      integerTieBreaks: request.albumIntegerTieBreaks,
      descending: request.albumDescending,
    );
    request.sendPort.send(<Object?>[1, _transferPageOrder(albumOrder)]);
    request.sendPort.send(const <Object?>[2]);
  } catch (error, trace) {
    request.sendPort.send(<Object?>[3, error.toString(), trace.toString()]);
  }
}

Future<List<T>> _materializeSortedItems<T>(
  List<T> source,
  List<int> indexes,
) async {
  if (indexes.isEmpty) return <T>[];
  final stopwatch = Stopwatch()..start();
  try {
    final result = List<T>.filled(
      indexes.length,
      source[indexes.first],
      growable: false,
    );
    for (var index = 1; index < indexes.length; index++) {
      result[index] = source[indexes[index]];
      if ((index + 1) % AudioLibrary._pageSnapshotMaterializeBatchSize == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return result;
  } finally {
    stopwatch.stop();
    pageSortPhaseObserver?.call('LibraryMaterialize', stopwatch.elapsed);
  }
}

class _CollectionBuildState {
  _CollectionBuildState(this.generation);

  final int generation;
  final Set<Album> albumsUsingAlbumArtists = <Album>{};
}

class PreparedLibraryPage<T> {
  const PreparedLibraryPage({
    required this.items,
    required this.sortMethod,
    required this.sortOrder,
  });

  final List<T> items;
  final int sortMethod;
  final SortOrder sortOrder;
}

class _LibraryInstallMetrics {
  const _LibraryInstallMetrics({
    required this.collectionsMilliseconds,
    required this.pagePreparationMilliseconds,
  });

  final int collectionsMilliseconds;
  final int pagePreparationMilliseconds;
}

class _FolderConversionResult {
  const _FolderConversionResult({
    required this.folders,
    required this.pooledTextCount,
    required this.pooledArtistListCount,
    required this.convertMilliseconds,
    required this.rssAfterConversion,
  });

  final List<AudioFolder> folders;
  final int pooledTextCount;
  final int pooledArtistListCount;
  final int convertMilliseconds;
  final int rssAfterConversion;
}

Future<(List<Audio>, int)> _fillConvertedAudios<T>(
  List<T> sourceAudios,
  Audio Function(T source, _AudioLoadPool pool) convert,
  _AudioLoadPool loadPool, {
  required int convertedAudioCount,
  required int objectBatchSize,
}) async {
  final audioCount = sourceAudios.length;
  if (audioCount == 0) {
    return (<Audio>[], convertedAudioCount);
  }
  final lastIndex = audioCount - 1;
  final lastAudio = convert(sourceAudios.removeLast(), loadPool);
  final audios = List<Audio>.filled(audioCount, lastAudio, growable: false);
  convertedAudioCount++;
  if (convertedAudioCount % objectBatchSize == 0) {
    await Future<void>.delayed(Duration.zero);
  }
  for (var index = lastIndex - 1; index >= 0; index--) {
    audios[index] = convert(sourceAudios.removeLast(), loadPool);
    convertedAudioCount++;
    if (convertedAudioCount % objectBatchSize == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  return (audios, convertedAudioCount);
}

Future<_FolderConversionResult> _convertSqliteFolders(
  List<library_db.IndexFolder> dbFolders, {
  required int objectBatchSize,
}) async {
  final conversionStopwatch = Stopwatch()..start();
  final folders = <AudioFolder>[];
  final loadPool = _AudioLoadPool();
  var convertedAudioCount = 0;
  for (final folder in dbFolders) {
    final converted = await _fillConvertedAudios(
      folder.audios,
      _audioFromIndex,
      loadPool,
      convertedAudioCount: convertedAudioCount,
      objectBatchSize: objectBatchSize,
    );
    convertedAudioCount = converted.$2;
    folders.add(
      AudioFolder(
        converted.$1,
        folder.path,
        folder.modified.toInt(),
        folder.latest.toInt(),
      ),
    );
  }
  final pooledTextCount = loadPool.textCount;
  final pooledArtistListCount = loadPool.artistListCount;
  loadPool.release();
  dbFolders.clear();
  conversionStopwatch.stop();
  return _FolderConversionResult(
    folders: folders,
    pooledTextCount: pooledTextCount,
    pooledArtistListCount: pooledArtistListCount,
    convertMilliseconds: conversionStopwatch.elapsedMilliseconds,
    rssAfterConversion: ProcessInfo.currentRss,
  );
}

Future<_FolderConversionResult> _convertJsonFolders(
  List foldersJson, {
  required int objectBatchSize,
}) async {
  final conversionStopwatch = Stopwatch()..start();
  final folders = <AudioFolder>[];
  final loadPool = _AudioLoadPool();
  var convertedAudioCount = 0;
  for (final folderMap in foldersJson) {
    final map = folderMap as Map;
    final List audiosJson = map['audios'];
    final converted = await _fillConvertedAudios<dynamic>(
      audiosJson,
      (source, pool) => _audioFromMap(source as Map, pool),
      loadPool,
      convertedAudioCount: convertedAudioCount,
      objectBatchSize: objectBatchSize,
    );
    convertedAudioCount = converted.$2;
    folders.add(AudioFolder.fromMap(map, converted.$1));
    map.clear();
  }
  final pooledTextCount = loadPool.textCount;
  final pooledArtistListCount = loadPool.artistListCount;
  loadPool.release();
  foldersJson.clear();
  conversionStopwatch.stop();
  return _FolderConversionResult(
    folders: folders,
    pooledTextCount: pooledTextCount,
    pooledArtistListCount: pooledArtistListCount,
    convertMilliseconds: conversionStopwatch.elapsedMilliseconds,
    rssAfterConversion: ProcessInfo.currentRss,
  );
}

/// from index.json
class AudioLibrary {
  static const int _pageSnapshotMaterializeBatchSize = 8192;
  List<AudioFolder> folders;

  AudioLibrary._(this.folders);

  /// 所有音乐
  List<Audio> audioCollection = [];
  final Map<String, Audio> _audioByPath = {};

  Map<String, Artist> artistCollection = {};

  Map<String, Album> albumCollection = {};

  /// 小封面字节缓存数量硬上限。
  /// 超出时按 LRU 逐出最旧的，避免大曲库快速浏览时 Uint8List 堆积。
  /// 200 × ~5KB ≈ 1MB 封顶。
  static const int _maxCachedSmallCovers = 200;

  /// 访问顺序追踪队列：最近访问的 path 在末尾，最旧的在开头。
  /// 仅用于 _smallCoverBytes 的 LRU 逐出，不涵盖 ImageProvider 缓存。
  final LinkedHashSet<String> _smallCoverOrder = LinkedHashSet<String>();
  final LinkedHashSet<String> _coverCachePaths = LinkedHashSet<String>();
  static const int _maxRetainedCollectionThumbnails = 160;
  final LinkedHashMap<(Object, int), void Function()>
  _collectionThumbnailRetention =
      LinkedHashMap<(Object, int), void Function()>();

  /// must call [initFromIndex]
  static AudioLibrary get instance {
    _instance ??= AudioLibrary._([]);
    return _instance!;
  }

  static AudioLibrary? _instance;

  /// Incremented when the core library objects are installed.
  static final libraryVersion = ValueNotifier<int>(0);

  /// Incremented after artist and album page data is ready for display.
  static final artistAlbumVersion = ValueNotifier<int>(0);
  static final artistPageVersion = ValueNotifier<int>(0);
  static final albumPageVersion = ValueNotifier<int>(0);
  static Future<void>? _collectionInstallInProgress;
  int _collectionGeneration = 0;
  int _publishedArtistAlbumGeneration = -1;
  int _publishedArtistPageGeneration = -1;
  int _publishedAlbumPageGeneration = -1;
  PreparedLibraryPage<Audio>? _preparedAudiosPage;
  PreparedLibraryPage<Artist>? _preparedArtistsPage;
  PreparedLibraryPage<Album>? _preparedAlbumsPage;
  Future<void>? _secondaryPagePreparation;
  int? _secondaryPagePreparationGeneration;
  Future<void>? _audioPagePreparation;
  int? _audioPagePreparationGeneration;
  late final LibraryPageSnapshotCoordinator _pageSnapshotCoordinator =
      LibraryPageSnapshotCoordinator(contextProvider: _pageOrderCacheContext);
  List<AudioFolder>? _aggregatedRootFoldersCache;
  List<AudioFolder>? _aggregatedRootFoldersSource;
  int _aggregatedRootFoldersSourceLength = -1;
  List<String> _aggregatedRootFoldersUserPaths = const <String>[];

  static Future<void> _awaitPendingCollectionInstall() async {
    while (true) {
      final pending = _collectionInstallInProgress;
      if (pending == null) break;
      await pending;
    }
  }

  static Future<_LibraryInstallMetrics> _installLoadedFolders(
    List<AudioFolder> loadedFolders, {
    required String pageCacheSourcePath,
    required String pageCachePath,
    required int objectBatchSize,
  }) async {
    await _awaitPendingCollectionInstall();
    final completer = Completer<void>();
    _collectionInstallInProgress = completer.future;
    try {
      return await _runLoadedFolderInstall(
        loadedFolders,
        pageCacheSourcePath: pageCacheSourcePath,
        pageCachePath: pageCachePath,
        objectBatchSize: objectBatchSize,
      );
    } finally {
      _collectionInstallInProgress = null;
      completer.complete();
    }
  }

  static Future<_LibraryInstallMetrics> _runLoadedFolderInstall(
    List<AudioFolder> loadedFolders, {
    required String pageCacheSourcePath,
    required String pageCachePath,
    required int objectBatchSize,
  }) async {
    _instance ??= AudioLibrary._([]);
    final initialLoad = instance.folders.isEmpty;
    final collectionStopwatch = Stopwatch()..start();
    if (initialLoad) {
      await instance._replaceFoldersForInitialLoad(
        loadedFolders,
        objectBatchSize,
      );
    } else {
      instance.replaceFolders(loadedFolders);
    }
    collectionStopwatch.stop();
    final pagePreparationStopwatch = Stopwatch()..start();
    final cacheSpec = await instance._resolvePageOrderCacheSpec(
      sourcePath: pageCacheSourcePath,
      cachePath: pageCachePath,
    );
    final restored = cacheSpec == null
        ? (audios: false, artists: false, albums: false)
        : await instance._restorePreferredPageSnapshots(cacheSpec);
    final restoredAll = restored.audios && restored.artists && restored.albums;
    await instance._preparePagesForLoad(
      initialLoad: initialLoad,
      cacheSpec: cacheSpec,
      restoredAll: restoredAll,
    );
    CoverImageCache.instance.preloadPersistent(
      List<Audio>.of(instance.audioCollection),
    );
    pagePreparationStopwatch.stop();
    return _LibraryInstallMetrics(
      collectionsMilliseconds: collectionStopwatch.elapsedMilliseconds,
      pagePreparationMilliseconds: pagePreparationStopwatch.elapsedMilliseconds,
    );
  }

  /// 目前 index 结构：
  /// ```json
  /// {
  ///     "folders": [
  ///         {
  ///             "audios": [
  ///                 {...},
  ///                 ...
  ///             ],
  ///             ...
  ///         },
  ///         ...
  ///     ],
  ///     "version": 110
  /// }
  /// ```
  static Future<void> initFromIndex() async {
    final stopwatch = Stopwatch()..start();
    try {
      final supportPath = (await getAppDataDir()).path;
      final indexPath = p.join(supportPath, 'index.json');
      final sqlitePath = p.join(supportPath, 'library.sqlite');
      final pageCachePath = p.join(
        supportPath,
        'cache',
        'library_page_orders.bin',
      );
      final objectBatchSize = libraryObjectBatchSizeFor(
        processorBudget: applicationProcessorBudget,
        hasPlaybackSession: PlayService.hasInitializedPlaybackSession,
      );

      if (!File(sqlitePath).existsSync() && File(indexPath).existsSync()) {
        try {
          await library_db.migrateIndexJsonToSqlite(indexPath: supportPath);
        } catch (err, trace) {
          log.library.error('legacy', err.toString(), stackTrace: trace);
        }
      }

      final loadedFromSqlite = await _tryInitFromSqlite(
        supportPath: supportPath,
        indexPath: indexPath,
        pageCachePath: pageCachePath,
        objectBatchSize: objectBatchSize,
        totalStopwatch: stopwatch,
      );
      if (loadedFromSqlite) return;

      await _initFromJsonIndex(
        indexPath: indexPath,
        pageCachePath: pageCachePath,
        objectBatchSize: objectBatchSize,
        totalStopwatch: stopwatch,
      );
    } catch (err, trace) {
      log.library.error('legacy', err.toString(), stackTrace: trace);
      rethrow;
    }
  }

  static Future<bool> _tryInitFromSqlite({
    required String supportPath,
    required String indexPath,
    required String pageCachePath,
    required int objectBatchSize,
    required Stopwatch totalStopwatch,
  }) async {
    try {
      final sqliteReadStopwatch = Stopwatch()..start();
      final dbFolders = await library_db.readIndexFromSqlite(
        indexPath: supportPath,
      );
      sqliteReadStopwatch.stop();
      final rssAfterRead = ProcessInfo.currentRss;
      final converted = await _convertSqliteFolders(
        dbFolders,
        objectBatchSize: objectBatchSize,
      );
      final installMetrics = await _installLoadedFolders(
        converted.folders,
        pageCacheSourcePath: indexPath,
        pageCachePath: pageCachePath,
        objectBatchSize: objectBatchSize,
      );
      _logSqliteLoad(
        totalStopwatch: totalStopwatch,
        sqliteReadStopwatch: sqliteReadStopwatch,
        converted: converted,
        installMetrics: installMetrics,
        objectBatchSize: objectBatchSize,
        rssAfterRead: rssAfterRead,
      );
      _publishLoadedLibrary();
      return true;
    } catch (err, trace) {
      log.library.warn(
        'legacy',
        'SQLite 曲库读取失败，回退到 JSON 索引',
        error: err,
        stackTrace: trace,
      );
      return false;
    }
  }

  static Future<void> _initFromJsonIndex({
    required String indexPath,
    required String pageCachePath,
    required int objectBatchSize,
    required Stopwatch totalStopwatch,
  }) async {
    final jsonReadStopwatch = Stopwatch()..start();
    var indexStr = await File(indexPath).readAsString();
    jsonReadStopwatch.stop();
    final jsonDecodeStopwatch = Stopwatch()..start();
    final Map indexJson = json.decode(indexStr);
    indexStr = '';
    jsonDecodeStopwatch.stop();
    final rssAfterDecode = ProcessInfo.currentRss;
    final List foldersJson = indexJson['folders'];
    final converted = await _convertJsonFolders(
      foldersJson,
      objectBatchSize: objectBatchSize,
    );
    indexJson.clear();
    final installMetrics = await _installLoadedFolders(
      converted.folders,
      pageCacheSourcePath: indexPath,
      pageCachePath: pageCachePath,
      objectBatchSize: objectBatchSize,
    );
    _logJsonLoad(
      totalStopwatch: totalStopwatch,
      jsonReadStopwatch: jsonReadStopwatch,
      jsonDecodeStopwatch: jsonDecodeStopwatch,
      converted: converted,
      installMetrics: installMetrics,
      objectBatchSize: objectBatchSize,
      rssAfterDecode: rssAfterDecode,
    );
    _publishLoadedLibrary();
  }

  static void _publishLoadedLibrary() {
    libraryVersion.value++;
    instance._publishArtistAlbumVersionIfReady(instance._collectionGeneration);
  }

  static void _logSqliteLoad({
    required Stopwatch totalStopwatch,
    required Stopwatch sqliteReadStopwatch,
    required _FolderConversionResult converted,
    required _LibraryInstallMetrics installMetrics,
    required int objectBatchSize,
    required int rssAfterRead,
  }) {
    log.library.debug(
      'legacy',
      '[perf] library sqlite total=${totalStopwatch.elapsedMilliseconds}ms '
          'read=${sqliteReadStopwatch.elapsedMilliseconds}ms '
          'convert=${converted.convertMilliseconds}ms '
          'collections=${installMetrics.collectionsMilliseconds}ms '
          'pages=${installMetrics.pagePreparationMilliseconds}ms '
          'batch=$objectBatchSize '
          'audios=${instance.audioCollection.length} '
          'pooledTexts=${converted.pooledTextCount} '
          'pooledArtistLists=${converted.pooledArtistListCount} '
          'rssRead=${_rssMegabytes(rssAfterRead)}MB '
          'rssConvert=${_rssMegabytes(converted.rssAfterConversion)}MB',
    );
  }

  static void _logJsonLoad({
    required Stopwatch totalStopwatch,
    required Stopwatch jsonReadStopwatch,
    required Stopwatch jsonDecodeStopwatch,
    required _FolderConversionResult converted,
    required _LibraryInstallMetrics installMetrics,
    required int objectBatchSize,
    required int rssAfterDecode,
  }) {
    log.library.debug(
      'legacy',
      '[perf] library json total=${totalStopwatch.elapsedMilliseconds}ms '
          'read=${jsonReadStopwatch.elapsedMilliseconds}ms '
          'decode=${jsonDecodeStopwatch.elapsedMilliseconds}ms '
          'convert=${converted.convertMilliseconds}ms '
          'collections=${installMetrics.collectionsMilliseconds}ms '
          'pages=${installMetrics.pagePreparationMilliseconds}ms '
          'batch=$objectBatchSize '
          'audios=${instance.audioCollection.length} '
          'pooledTexts=${converted.pooledTextCount} '
          'pooledArtistLists=${converted.pooledArtistListCount} '
          'rssDecode=${_rssMegabytes(rssAfterDecode)}MB '
          'rssConvert=${_rssMegabytes(converted.rssAfterConversion)}MB',
    );
  }

  void _filterExcludedFolders() {
    final excluded = AppPreference.instance.excludedFolderPaths;
    if (excluded.isEmpty) return;
    final excludedKeys = _folderPathKeySet(excluded);
    if (excludedKeys.isEmpty) return;
    folders.removeWhere((folder) {
      final key = folder._pathLookupKey;
      return key.isNotEmpty && excludedKeys.contains(key);
    });
  }

  _CollectionBuildState _beginCollectionBuild() {
    _collectionGeneration++;
    _publishedArtistAlbumGeneration = -1;
    _publishedArtistPageGeneration = -1;
    _publishedAlbumPageGeneration = -1;
    _preparedAudiosPage = null;
    _preparedArtistsPage = null;
    _preparedAlbumsPage = null;
    _pageSnapshotCoordinator.reset();
    final generation = _collectionGeneration;
    for (final artist in artistCollection.values) {
      artist.works.clear();
      artist.albumsMap.clear();
    }
    for (final album in albumCollection.values) {
      album.works.clear();
      album.artistsMap.clear();
    }
    audioCollection.clear();
    _audioByPath.clear();
    return _CollectionBuildState(generation);
  }

  Artist _resolveArtist(String name, int generation) {
    var artist = artistCollection[name];
    if (artist == null) {
      artist = Artist(name: name);
      artistCollection[name] = artist;
    }
    artist._collectionGeneration = generation;
    return artist;
  }

  void _addAudioToCollections(Audio audio, _CollectionBuildState state) {
    audio._libraryIndex = audioCollection.length;
    audioCollection.add(audio);
    final pathKey = audio._pathLookupKey;
    if (pathKey.isNotEmpty && _audioByPath[pathKey] == null) {
      _audioByPath[pathKey] = audio;
    }
    final album = _albumForAudio(audio, state.generation);
    album.works.add(audio);
    _linkArtistsToAudio(audio, album, state.generation);
    _linkAlbumArtists(audio, album, state);
  }

  Album _albumForAudio(Audio audio, int generation) {
    var album = albumCollection[audio.album];
    if (album == null) {
      album = Album(name: audio.album);
      albumCollection[audio.album] = album;
    }
    album._collectionGeneration = generation;
    return album;
  }

  void _linkArtistsToAudio(Audio audio, Album album, int generation) {
    for (final artistName in audio.splitedArtists) {
      final artist = _resolveArtist(artistName, generation);
      artist.works.add(audio);
      artist.albumsMap.putIfAbsent(audio.album, () => album);
    }
    for (final artistName in audio.splitedAlbumArtists) {
      if (audio.splitedArtists.contains(artistName)) continue;
      final artist = _resolveArtist(artistName, generation);
      artist.works.add(audio);
      artist.albumsMap.putIfAbsent(audio.album, () => album);
    }
  }

  void _linkAlbumArtists(
    Audio audio,
    Album album,
    _CollectionBuildState state,
  ) {
    final albumArtistNames = audio.splitedAlbumArtists;
    if (albumArtistNames.isNotEmpty) {
      if (state.albumsUsingAlbumArtists.add(album)) {
        album.artistsMap.clear();
      }
      _putAlbumArtists(album, albumArtistNames);
      return;
    }
    if (state.albumsUsingAlbumArtists.contains(album)) return;
    _putAlbumArtists(album, audio.splitedArtists);
  }

  void _putAlbumArtists(Album album, Iterable<String> artistNames) {
    for (final artistName in artistNames) {
      final artist = artistCollection[artistName];
      if (artist != null) {
        album.artistsMap.putIfAbsent(artistName, () => artist);
      }
    }
  }

  void _finishCollectionBuild(_CollectionBuildState state) {
    artistCollection.removeWhere(
      (_, artist) => artist._collectionGeneration != state.generation,
    );
    albumCollection.removeWhere(
      (_, album) => album._collectionGeneration != state.generation,
    );
    var index = 0;
    for (final artist in artistCollection.values) {
      artist._libraryIndex = index++;
    }
    index = 0;
    for (final album in albumCollection.values) {
      album._libraryIndex = index++;
    }
  }

  void _buildCollections() {
    final state = _beginCollectionBuild();
    for (final folder in folders) {
      for (final audio in folder.audios) {
        _addAudioToCollections(audio, state);
      }
    }
    _finishCollectionBuild(state);
  }

  Future<void> _buildCollectionsForInitialLoad(int objectBatchSize) async {
    final state = _beginCollectionBuild();
    var processed = 0;
    for (final folder in folders) {
      for (final audio in folder.audios) {
        _addAudioToCollections(audio, state);
        processed++;
        if (processed % objectBatchSize == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
    _finishCollectionBuild(state);
  }

  Future<void> _replaceFoldersForInitialLoad(
    List<AudioFolder> refreshedFolders,
    int objectBatchSize,
  ) async {
    _invalidateAggregatedRootFolders();
    folders = refreshedFolders;
    _filterExcludedFolders();
    await _buildCollectionsForInitialLoad(objectBatchSize);
  }

  PreparedLibraryPage<Audio>? get preparedAudiosPage {
    final prepared = _preparedAudiosPage;
    final preference = AppPreference.instance.audiosPagePref;
    if (prepared == null ||
        prepared.sortMethod != preference.sortMethod.clamp(0, audiosPageSortMethodMax).toInt() ||
        prepared.sortOrder != preference.sortOrder) {
      return null;
    }
    return prepared;
  }

  PreparedLibraryPage<Artist>? get preparedArtistsPage {
    final prepared = _preparedArtistsPage;
    final preference = AppPreference.instance.artistsPagePref;
    if (prepared == null ||
        prepared.sortMethod != preference.sortMethod.clamp(0, 1).toInt() ||
        prepared.sortOrder != preference.sortOrder) {
      return null;
    }
    return prepared;
  }

  PreparedLibraryPage<Album>? get preparedAlbumsPage {
    final prepared = _preparedAlbumsPage;
    final preference = AppPreference.instance.albumsPagePref;
    if (prepared == null ||
        prepared.sortMethod != preference.sortMethod.clamp(0, 1).toInt() ||
        prepared.sortOrder != preference.sortOrder) {
      return null;
    }
    return prepared;
  }

  String _pageOrderCacheContext() {
    final excluded =
        AppPreference.instance.excludedFolderPaths
            .map(_audioPathLookupKey)
            .toList(growable: false)
          ..sort();
    return json.encode({
      'appVersion': AppSettings.version,
      'artistSplitPattern': AppSettings.instance.artistSplitPattern,
      'artistSplitRules': AppSettings.instance.artistSplitSignature,
      'excludedFolders': excluded,
    });
  }

  Future<LibraryPageOrderCacheSpec?> _resolvePageOrderCacheSpec({
    required String sourcePath,
    required String cachePath,
  }) {
    return _pageSnapshotCoordinator.resolve(
      sourcePath: sourcePath,
      cachePath: cachePath,
    );
  }

  bool _cachedPageMatches(
    PageOrderSnapshot cached,
    PagePreference preference,
    int maxSortMethod,
  ) {
    final sortMethod = preference.sortMethod.clamp(0, maxSortMethod).toInt();
    return cached.sortMethod == sortMethod &&
        cached.sortOrderIndex == preference.sortOrder.index;
  }

  Future<bool> _installPreparedAudioOrder({
    required List<Audio> source,
    required List<int> indexes,
    required int sortMethod,
    required SortOrder sortOrder,
    required int generation,
  }) async {
    final preparedAudios = await _materializeSortedItems(source, indexes);
    final preference = AppPreference.instance.audiosPagePref;
    if (generation != _collectionGeneration ||
        preference.sortMethod.clamp(0, audiosPageSortMethodMax).toInt() != sortMethod ||
        preference.sortOrder != sortOrder) {
      return false;
    }
    for (var position = 0; position < preparedAudios.length; position++) {
      preparedAudios[position]._audiosPageIndex = position;
    }
    _preparedAudiosPage = PreparedLibraryPage(
      items: preparedAudios,
      sortMethod: sortMethod,
      sortOrder: sortOrder,
    );
    return true;
  }

  Future<({bool audios, bool artists, bool albums})>
  _restorePreferredPageSnapshots(LibraryPageOrderCacheSpec spec) async {
    final stopwatch = Stopwatch()..start();
    final generation = _collectionGeneration;
    final cached = await _pageSnapshotCoordinator.read(
      spec: spec,
      audioCount: audioCollection.length,
      artistCount: artistCollection.length,
      albumCount: albumCollection.length,
    );
    if (cached == null ||
        generation != _collectionGeneration ||
        spec.context != _pageOrderCacheContext()) {
      log.library.debug(
        'legacy',
        '[perf] page order cache miss elapsed=${stopwatch.elapsedMilliseconds}ms',
      );
      return (audios: false, artists: false, albums: false);
    }
    final restoredAudios = await _restoreAudiosSnapshot(
      cached.audios,
      generation,
    );
    final restoredArtists = await _restoreCollectionSnapshot(
      cached: cached.artists,
      preferenceOf: () => AppPreference.instance.artistsPagePref,
      generation: generation,
      sourceOf: () => artistCollection.values.toList(growable: false),
      install: (page) => _preparedArtistsPage = page,
    );
    final restoredAlbums = await _restoreCollectionSnapshot(
      cached: cached.albums,
      preferenceOf: () => AppPreference.instance.albumsPagePref,
      generation: generation,
      sourceOf: () => albumCollection.values.toList(growable: false),
      install: (page) => _preparedAlbumsPage = page,
    );
    stopwatch.stop();
    log.library.debug(
      'legacy',
      '[perf] page order cache hit audios=$restoredAudios '
          'artists=$restoredArtists albums=$restoredAlbums '
          'elapsed=${stopwatch.elapsedMilliseconds}ms',
    );
    return (
      audios: restoredAudios,
      artists: restoredArtists,
      albums: restoredAlbums,
    );
  }

  Future<bool> _restoreAudiosSnapshot(
    PageOrderSnapshot cached,
    int generation,
  ) async {
    final audioPreference = AppPreference.instance.audiosPagePref;
    if (!_cachedPageMatches(cached, audioPreference, audiosPageSortMethodMax)) return false;
    return _installPreparedAudioOrder(
      source: audioCollection,
      indexes: cached.indexes,
      sortMethod: cached.sortMethod,
      sortOrder: SortOrder.values[cached.sortOrderIndex],
      generation: generation,
    );
  }

  Future<bool> _restoreCollectionSnapshot<T>({
    required PageOrderSnapshot cached,
    required PagePreference Function() preferenceOf,
    required int generation,
    required List<T> Function() sourceOf,
    required void Function(PreparedLibraryPage<T> page) install,
  }) async {
    if (generation != _collectionGeneration ||
        !_cachedPageMatches(cached, preferenceOf(), 1)) {
      return false;
    }
    final items = await _materializeSortedItems(sourceOf(), cached.indexes);
    if (generation != _collectionGeneration) return false;
    final currentPreference = preferenceOf();
    if (currentPreference.sortMethod.clamp(0, 1).toInt() != cached.sortMethod ||
        currentPreference.sortOrder.index != cached.sortOrderIndex) {
      return false;
    }
    install(
      PreparedLibraryPage(
        items: items,
        sortMethod: cached.sortMethod,
        sortOrder: SortOrder.values[cached.sortOrderIndex],
      ),
    );
    return true;
  }

  Future<bool> preparePreferredPageSnapshotsUsingCache({
    required String sourcePath,
    required String cachePath,
    bool initialLoad = true,
  }) async {
    final spec = await _resolvePageOrderCacheSpec(
      sourcePath: sourcePath,
      cachePath: cachePath,
    );
    final restored = spec == null
        ? (audios: false, artists: false, albums: false)
        : await _restorePreferredPageSnapshots(spec);
    final restoredAll = restored.audios && restored.artists && restored.albums;
    await _preparePagesForLoad(
      initialLoad: initialLoad,
      cacheSpec: spec,
      restoredAll: restoredAll,
    );
    return restoredAll;
  }

  Future<void> _preparePagesForLoad({
    required bool initialLoad,
    required LibraryPageOrderCacheSpec? cacheSpec,
    required bool restoredAll,
  }) async {
    final protectPlayback = PlayService.hasInitializedPlaybackSession;
    if (shouldDeferSecondaryPagePreparation(
      processorBudget: applicationProcessorBudget,
      initialLoad: initialLoad,
      hasPlaybackSession: protectPlayback,
    )) {
      await preparePreferredAudioPageSnapshot();
      if (preparedArtistsPage == null || preparedAlbumsPage == null) {
        unawaited(_prepareSecondaryPagesAndCache(cacheSpec));
      } else if (!restoredAll && cacheSpec != null) {
        _schedulePageOrderCacheWrite(cacheSpec);
      }
      return;
    }
    await preparePreferredPageSnapshots();
    if (!restoredAll && cacheSpec != null) {
      _schedulePageOrderCacheWrite(cacheSpec);
    }
  }

  Future<void> waitForPreferredPageOrderCacheWrite() async {
    await _pageSnapshotCoordinator.waitForWrite();
  }

  Future<void> _prepareSecondaryPagesAndCache(
    LibraryPageOrderCacheSpec? spec,
  ) async {
    final generation = _collectionGeneration;
    try {
      final delay = deferredSecondaryPagePreparationDelayFor(
        processorBudget: applicationProcessorBudget,
        hasPlaybackSession: PlayService.hasInitializedPlaybackSession,
      );
      if (delay > Duration.zero) {
        log.library.debug(
          'legacy',
          '[perf] secondary page preparation deferred=${delay.inMilliseconds}ms '
              'playback=${PlayService.hasInitializedPlaybackSession}',
        );
        await Future<void>.delayed(delay);
      }
      if (generation != _collectionGeneration) return;
      await preparePreferredSecondaryPageSnapshots();
      _publishArtistAlbumVersion(generation);
      if (generation == _collectionGeneration && spec != null) {
        _schedulePageOrderCacheWrite(spec);
      }
    } catch (error, trace) {
      log.library.warn('legacy', '后台页面顺序准备失败', error: error, stackTrace: trace);
    }
  }

  void _schedulePageOrderCacheWrite(LibraryPageOrderCacheSpec spec) {
    _pageSnapshotCoordinator.scheduleWrite(
      spec: spec,
      generation: _collectionGeneration,
      isGenerationCurrent: (generation) => generation == _collectionGeneration,
      buildOrders: (isCurrent) => _buildPageOrderCacheOrders(spec, isCurrent),
    );
  }

  Future<LibraryPageOrders?> _buildPageOrderCacheOrders(
    LibraryPageOrderCacheSpec spec,
    bool Function() isCurrent,
  ) async {
    final audios = preparedAudiosPage;
    final artists = preparedArtistsPage;
    final albums = preparedAlbumsPage;
    if (audios == null || artists == null || albums == null) return null;
    final audioIndexes = await _pageIndexes(
      audios.items,
      (audio) => audio._libraryIndex,
      isCurrent,
    );
    if (audioIndexes == null) return null;
    final artistIndexes = await _pageIndexes(
      artists.items,
      (artist) => artist._libraryIndex,
      isCurrent,
    );
    if (artistIndexes == null) return null;
    final albumIndexes = await _pageIndexes(
      albums.items,
      (album) => album._libraryIndex,
      isCurrent,
    );
    if (albumIndexes == null) return null;
    return LibraryPageOrders(
      sourceSignature: spec.sourceSignature,
      context: spec.context,
      audios: PageOrderSnapshot(
        sortMethod: audios.sortMethod,
        sortOrderIndex: audios.sortOrder.index,
        indexes: audioIndexes,
      ),
      artists: PageOrderSnapshot(
        sortMethod: artists.sortMethod,
        sortOrderIndex: artists.sortOrder.index,
        indexes: artistIndexes,
      ),
      albums: PageOrderSnapshot(
        sortMethod: albums.sortMethod,
        sortOrderIndex: albums.sortOrder.index,
        indexes: albumIndexes,
      ),
    );
  }

  Future<Uint32List?> _pageIndexes<T>(
    List<T> items,
    int Function(T item) indexOf,
    bool Function() isCurrent,
  ) async {
    if (!isCurrent()) return null;
    final result = Uint32List(items.length);
    var batchRemaining = libraryObjectBatchSizeFor(
      processorBudget: applicationProcessorBudget,
      hasPlaybackSession: PlayService.hasInitializedPlaybackSession,
    );
    for (var position = 0; position < items.length; position++) {
      final index = indexOf(items[position]);
      if (index < 0 || index >= items.length) {
        throw const FormatException('Invalid library page source index');
      }
      result[position] = index;
      batchRemaining--;
      if (batchRemaining == 0) {
        await Future<void>.delayed(Duration.zero);
        if (!isCurrent()) return null;
        batchRemaining = libraryObjectBatchSizeFor(
          processorBudget: applicationProcessorBudget,
          hasPlaybackSession: PlayService.hasInitializedPlaybackSession,
        );
      }
    }
    return isCurrent() ? result : null;
  }

  Future<void> preparePreferredPageSnapshots() async {
    final concurrency = libraryPagePreparationConcurrencyFor(
      processorBudget: applicationProcessorBudget,
      hasPlaybackSession: PlayService.hasInitializedPlaybackSession,
    );
    final prepareAudio = preparedAudiosPage == null;
    if (prepareAudio && concurrency >= 2) {
      await Future.wait([
        preparePreferredAudioPageSnapshot(),
        preparePreferredSecondaryPageSnapshots(
          concurrencyLimit: concurrency - 1,
        ),
      ]);
    } else {
      await preparePreferredAudioPageSnapshot();
      await preparePreferredSecondaryPageSnapshots(
        concurrencyLimit: concurrency,
      );
    }
  }

  Future<void> preparePreferredAudioPageSnapshot() {
    if (preparedAudiosPage != null) return Future<void>.value();
    final generation = _collectionGeneration;
    final pending = _audioPagePreparation;
    if (pending != null && _audioPagePreparationGeneration == generation) {
      return pending;
    }

    late final Future<void> future;
    future = () async {
      try {
        await _preparePreferredAudioPageSnapshot(generation);
      } finally {
        if (identical(_audioPagePreparation, future)) {
          _audioPagePreparation = null;
          _audioPagePreparationGeneration = null;
        }
      }
    }();
    _audioPagePreparation = future;
    _audioPagePreparationGeneration = generation;
    return future;
  }

  Future<void> _preparePreferredAudioPageSnapshot(int generation) async {
    final audios = List<Audio>.from(audioCollection);
    final preference = AppPreference.instance.audiosPagePref;
    final sortMethod = preference.sortMethod.clamp(0, audiosPageSortMethodMax).toInt();
    final sortOrder = preference.sortOrder;
    final descending = sortOrder == SortOrder.decending;
    final naturalValues = switch (sortMethod) {
      0 => audios.map(audioTitleSortValue).toList(growable: false),
      1 => audios.map(audioArtistSortValue).toList(growable: false),
      2 => audios.map(audioAlbumSortValue).toList(growable: false),
      _ => null,
    };
    final integerValues = switch (sortMethod) {
      3 => audios.map((audio) => audio.created).toList(growable: false),
      4 => audios.map((audio) => audio.modified).toList(growable: false),
      5 => audios.map((audio) => audio.duration).toList(growable: false),
      6 => audios.map((audio) => audio.playCount).toList(growable: false),
      _ => null,
    };
    final integerTieBreaks = integerValues == null
        ? null
        : audios.map(audioTitleSortValue).toList(growable: false);
    final audioCount = audios.length;
    final order = await Isolate.run(
      () => _sortLibraryPageIndexes(
        length: audioCount,
        naturalValues: naturalValues,
        integerValues: integerValues,
        integerTieBreaks: integerTieBreaks,
        descending: descending,
        reuseEqualKeys: false,
      ),
    );
    if (generation != _collectionGeneration) return;
    await _installPreparedAudioOrder(
      source: audios,
      indexes: order,
      sortMethod: sortMethod,
      sortOrder: sortOrder,
      generation: generation,
    );
  }

  void rememberPreparedPageOrder<T>(
    List<T> items, {
    required int sortMethod,
    required SortOrder sortOrder,
  }) {
    if (items is List<Audio> && items.length == audioCollection.length) {
      final audios = items.cast<Audio>();
      updateAudiosPageIndexes(audios);
      _preparedAudiosPage = PreparedLibraryPage(
        items: audios,
        sortMethod: sortMethod.clamp(0, audiosPageSortMethodMax).toInt(),
        sortOrder: sortOrder,
      );
    } else if (items is List<Artist> &&
        items.length == artistCollection.length) {
      final artists = items.cast<Artist>();
      _preparedArtistsPage = PreparedLibraryPage(
        items: artists,
        sortMethod: sortMethod.clamp(0, 1).toInt(),
        sortOrder: sortOrder,
      );
    } else if (items is List<Album> && items.length == albumCollection.length) {
      final albums = items.cast<Album>();
      _preparedAlbumsPage = PreparedLibraryPage(
        items: albums,
        sortMethod: sortMethod.clamp(0, 1).toInt(),
        sortOrder: sortOrder,
      );
    } else {
      return;
    }
    final cacheSpec = _pageSnapshotCoordinator.activeSpec;
    if (cacheSpec != null) {
      _schedulePageOrderCacheWrite(cacheSpec);
    }
  }

  Future<void> preparePreferredSecondaryPageSnapshots({int? concurrencyLimit}) {
    if (preparedArtistsPage != null && preparedAlbumsPage != null) {
      return Future<void>.value();
    }
    final generation = _collectionGeneration;
    final concurrency =
        (concurrencyLimit ??
                libraryPagePreparationConcurrencyFor(
                  processorBudget: applicationProcessorBudget,
                  hasPlaybackSession: PlayService.hasInitializedPlaybackSession,
                ))
            .clamp(1, 2)
            .toInt();
    final pending = _secondaryPagePreparation;
    if (pending != null && _secondaryPagePreparationGeneration == generation) {
      return pending;
    }

    late final Future<void> future;
    future = () async {
      try {
        await _preparePreferredSecondaryPageSnapshots(generation, concurrency);
      } finally {
        if (identical(_secondaryPagePreparation, future)) {
          _secondaryPagePreparation = null;
          _secondaryPagePreparationGeneration = null;
        }
      }
    }();
    _secondaryPagePreparation = future;
    _secondaryPagePreparationGeneration = generation;
    return future;
  }

  Future<void> _preparePreferredSecondaryPageSnapshots(
    int generation,
    int concurrency,
  ) async {
    final inputs = _secondaryPrepareInputs();
    if (inputs == null) return;
    final orders = await _sortSecondaryPageOrders(
      inputs,
      generation: generation,
      concurrency: concurrency,
    );
    if (orders.serialDone) return;
    await _installPreparedSecondaryPages(
      inputs,
      artistOrder: orders.artistOrder,
      albumOrder: orders.albumOrder,
      generation: generation,
    );
  }

  _SecondaryPrepareInputs? _secondaryPrepareInputs() {
    final prepareArtists = preparedArtistsPage == null;
    final prepareAlbums = preparedAlbumsPage == null;
    if (!prepareArtists && !prepareAlbums) return null;
    final artists = prepareArtists
        ? artistCollection.values.toList(growable: false)
        : const <Artist>[];
    final albums = prepareAlbums
        ? albumCollection.values.toList(growable: false)
        : const <Album>[];
    final artistPreference = AppPreference.instance.artistsPagePref;
    final albumPreference = AppPreference.instance.albumsPagePref;
    final artistSortMethod = artistPreference.sortMethod.clamp(0, 1).toInt();
    final albumSortMethod = albumPreference.sortMethod.clamp(0, 1).toInt();
    final artistSortOrder = artistPreference.sortOrder;
    final albumSortOrder = albumPreference.sortOrder;
    return (
      prepareArtists: prepareArtists,
      prepareAlbums: prepareAlbums,
      artists: artists,
      albums: albums,
      artistSortMethod: artistSortMethod,
      albumSortMethod: albumSortMethod,
      artistSortOrder: artistSortOrder,
      albumSortOrder: albumSortOrder,
      artistDescending: artistSortOrder == SortOrder.decending,
      albumDescending: albumSortOrder == SortOrder.decending,
      artistNaturalValues: prepareArtists && artistSortMethod == 0
          ? artists.map((artist) => artist.name).toList(growable: false)
          : null,
      artistIntegerValues: prepareArtists && artistSortMethod == 1
          ? artists.map((artist) => artist.works.length).toList(growable: false)
          : null,
      artistIntegerTieBreaks: prepareArtists && artistSortMethod == 1
          ? artists.map((artist) => artist.name).toList(growable: false)
          : null,
      albumNaturalValues: prepareAlbums && albumSortMethod == 0
          ? albums.map((album) => album.name).toList(growable: false)
          : null,
      albumIntegerValues: prepareAlbums && albumSortMethod == 1
          ? albums.map((album) => album.works.length).toList(growable: false)
          : null,
      albumIntegerTieBreaks: prepareAlbums && albumSortMethod == 1
          ? albums.map((album) => album.name).toList(growable: false)
          : null,
    );
  }

  Future<Uint32List> _sortPageIndexesInIsolate({
    required int length,
    required List<String>? naturalValues,
    required List<int>? integerValues,
    List<String>? integerTieBreaks,
    required bool descending,
  }) {
    return Isolate.run(
      () => _sortLibraryPageIndexes(
        length: length,
        naturalValues: naturalValues,
        integerValues: integerValues,
        integerTieBreaks: integerTieBreaks,
        descending: descending,
      ),
    );
  }

  Future<({Uint32List? artistOrder, Uint32List? albumOrder, bool serialDone})>
  _sortSecondaryPageOrders(
    _SecondaryPrepareInputs inputs, {
    required int generation,
    required int concurrency,
  }) async {
    if (inputs.prepareArtists && inputs.prepareAlbums && concurrency >= 2) {
      final orders = await Future.wait<Uint32List>([
        _sortPageIndexesInIsolate(
          length: inputs.artists.length,
          naturalValues: inputs.artistNaturalValues,
          integerValues: inputs.artistIntegerValues,
          integerTieBreaks: inputs.artistIntegerTieBreaks,
          descending: inputs.artistDescending,
        ),
        _sortPageIndexesInIsolate(
          length: inputs.albums.length,
          naturalValues: inputs.albumNaturalValues,
          integerValues: inputs.albumIntegerValues,
          integerTieBreaks: inputs.albumIntegerTieBreaks,
          descending: inputs.albumDescending,
        ),
      ]);
      return (artistOrder: orders[0], albumOrder: orders[1], serialDone: false);
    }
    if (inputs.prepareArtists && inputs.prepareAlbums) {
      await _prepareSecondaryPageSnapshotsSerially(
        generation: generation,
        inputs: inputs,
      );
      return (artistOrder: null, albumOrder: null, serialDone: true);
    }
    if (inputs.prepareArtists) {
      final artistOrder = await _sortPageIndexesInIsolate(
        length: inputs.artists.length,
        naturalValues: inputs.artistNaturalValues,
        integerValues: inputs.artistIntegerValues,
        integerTieBreaks: inputs.artistIntegerTieBreaks,
        descending: inputs.artistDescending,
      );
      return (artistOrder: artistOrder, albumOrder: null, serialDone: false);
    }
    final albumOrder = await _sortPageIndexesInIsolate(
      length: inputs.albums.length,
      naturalValues: inputs.albumNaturalValues,
      integerValues: inputs.albumIntegerValues,
      integerTieBreaks: inputs.albumIntegerTieBreaks,
      descending: inputs.albumDescending,
    );
    return (artistOrder: null, albumOrder: albumOrder, serialDone: false);
  }

  Future<void> _installPreparedSecondaryPages(
    _SecondaryPrepareInputs inputs, {
    required Uint32List? artistOrder,
    required Uint32List? albumOrder,
    required int generation,
  }) async {
    final preparedArtists = artistOrder == null
        ? null
        : await _materializeSortedItems(inputs.artists, artistOrder);
    final preparedAlbums = albumOrder == null
        ? null
        : await _materializeSortedItems(inputs.albums, albumOrder);
    if (generation != _collectionGeneration) return;
    _maybeInstallArtistsPage(
      preparedArtists,
      inputs.artistSortMethod,
      inputs.artistSortOrder,
      generation,
    );
    _maybeInstallAlbumsPage(
      preparedAlbums,
      inputs.albumSortMethod,
      inputs.albumSortOrder,
      generation,
    );
  }

  void _maybeInstallArtistsPage(
    List<Artist>? preparedArtists,
    int artistSortMethod,
    SortOrder artistSortOrder,
    int generation,
  ) {
    final currentArtistPreference = AppPreference.instance.artistsPagePref;
    if (preparedArtists == null ||
        currentArtistPreference.sortMethod.clamp(0, 1).toInt() !=
            artistSortMethod ||
        currentArtistPreference.sortOrder != artistSortOrder) {
      return;
    }
    _preparedArtistsPage = PreparedLibraryPage(
      items: preparedArtists,
      sortMethod: artistSortMethod,
      sortOrder: artistSortOrder,
    );
    _publishArtistPageVersion(generation);
  }

  void _maybeInstallAlbumsPage(
    List<Album>? preparedAlbums,
    int albumSortMethod,
    SortOrder albumSortOrder,
    int generation,
  ) {
    final currentAlbumPreference = AppPreference.instance.albumsPagePref;
    if (preparedAlbums == null ||
        currentAlbumPreference.sortMethod.clamp(0, 1).toInt() !=
            albumSortMethod ||
        currentAlbumPreference.sortOrder != albumSortOrder) {
      return;
    }
    _preparedAlbumsPage = PreparedLibraryPage(
      items: preparedAlbums,
      sortMethod: albumSortMethod,
      sortOrder: albumSortOrder,
    );
    _publishAlbumPageVersion(generation);
  }

  Future<void> _prepareSecondaryPageSnapshotsSerially({
    required int generation,
    required _SecondaryPrepareInputs inputs,
  }) async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(_sortSecondaryPageIndexes, (
      sendPort: receivePort.sendPort,
      artistCount: inputs.artists.length,
      artistNaturalValues: inputs.artistNaturalValues,
      artistIntegerValues: inputs.artistIntegerValues,
      artistIntegerTieBreaks: inputs.artistIntegerTieBreaks,
      artistDescending: inputs.artistDescending,
      albumCount: inputs.albums.length,
      albumNaturalValues: inputs.albumNaturalValues,
      albumIntegerValues: inputs.albumIntegerValues,
      albumIntegerTieBreaks: inputs.albumIntegerTieBreaks,
      albumDescending: inputs.albumDescending,
    ));
    try {
      await _consumeSecondarySortMessages(
        receivePort,
        inputs: inputs,
        generation: generation,
      );
    } finally {
      receivePort.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  Future<void> _consumeSecondarySortMessages(
    ReceivePort receivePort, {
    required _SecondaryPrepareInputs inputs,
    required int generation,
  }) async {
    messageLoop:
    await for (final rawMessage in receivePort) {
      if (generation != _collectionGeneration) break messageLoop;
      final message = rawMessage as List<Object?>;
      switch (message.first as int) {
        case 0:
          await _installArtistOrderMessage(
            message,
            inputs: inputs,
            generation: generation,
          );
        case 1:
          await _installAlbumOrderMessage(
            message,
            inputs: inputs,
            generation: generation,
          );
        case 2:
          break messageLoop;
        case 3:
          throw StateError(
            'Secondary page sort failed: ${message[1]}\n${message[2]}',
          );
      }
    }
  }

  Future<void> _installArtistOrderMessage(
    List<Object?> message, {
    required _SecondaryPrepareInputs inputs,
    required int generation,
  }) async {
    if (preparedArtistsPage != null) return;
    final order = _materializeTransferredPageOrder(
      message[1]! as TransferableTypedData,
    );
    final items = await _materializeSortedItems(inputs.artists, order);
    if (generation != _collectionGeneration || preparedArtistsPage != null) {
      return;
    }
    _maybeInstallArtistsPage(
      items,
      inputs.artistSortMethod,
      inputs.artistSortOrder,
      generation,
    );
  }

  Future<void> _installAlbumOrderMessage(
    List<Object?> message, {
    required _SecondaryPrepareInputs inputs,
    required int generation,
  }) async {
    if (preparedAlbumsPage != null) return;
    final order = _materializeTransferredPageOrder(
      message[1]! as TransferableTypedData,
    );
    final items = await _materializeSortedItems(inputs.albums, order);
    if (generation != _collectionGeneration || preparedAlbumsPage != null) {
      return;
    }
    _maybeInstallAlbumsPage(
      items,
      inputs.albumSortMethod,
      inputs.albumSortOrder,
      generation,
    );
  }

  void updateAudioTags(
    Audio audio, {
    required String title,
    required String artist,
    required String album,
    required int track,
    int? disc,
  }) {
    audio.title = title.trim();
    audio.artist = artist.trim();
    audio.album = album.trim();
    audio.track = track;
    audio.disc = disc;
    audio.splitedArtists = Audio._splitArtistNames(audio.artist);
    audio.splitedAlbumArtists = Audio._splitArtistNames(audio.albumArtist ?? '');
    audio._invalidateSearchCache();
    _buildCollections();
    libraryVersion.value++;
    artistPageVersion.value++;
    albumPageVersion.value++;
    _publishArtistAlbumVersion(_collectionGeneration);
  }

  void _publishArtistAlbumVersionIfReady(int generation) {
    _publishArtistPageVersion(generation);
    _publishAlbumPageVersion(generation);
    if (preparedArtistsPage == null || preparedAlbumsPage == null) return;
    _publishArtistAlbumVersion(generation);
  }

  void _publishArtistPageVersion(int generation) {
    if (generation != _collectionGeneration ||
        preparedArtistsPage == null ||
        _publishedArtistPageGeneration == generation) {
      return;
    }
    _publishedArtistPageGeneration = generation;
    artistPageVersion.value++;
  }

  void _publishAlbumPageVersion(int generation) {
    if (generation != _collectionGeneration ||
        preparedAlbumsPage == null ||
        _publishedAlbumPageGeneration == generation) {
      return;
    }
    _publishedAlbumPageGeneration = generation;
    albumPageVersion.value++;
  }

  void _publishArtistAlbumVersion(int generation) {
    if (generation != _collectionGeneration ||
        _publishedArtistAlbumGeneration == generation) {
      return;
    }
    _publishedArtistAlbumGeneration = generation;
    artistAlbumVersion.value++;
  }

  void replaceFolders(List<AudioFolder> refreshedFolders) {
    _invalidateAggregatedRootFolders();
    final included = _includedRefreshedFolders(refreshedFolders);
    if (folders.isEmpty) {
      folders = included;
      _buildCollections();
      return;
    }
    final merged = _mergeRefreshedFolders(included);
    folders = merged.folders;
    if (merged.collectionsChanged || merged.pageOrderChanged) {
      _buildCollections();
    } else {
      log.library.debug(
        'legacy',
        '[perf] library collections rebuild=skipped '
            'collectionMetadataOnly=true',
      );
    }
  }

  List<AudioFolder> _includedRefreshedFolders(
    List<AudioFolder> refreshedFolders,
  ) {
    final excluded = AppPreference.instance.excludedFolderPaths;
    final excludedKeys = _folderPathKeySet(excluded);
    if (excludedKeys.isEmpty) return refreshedFolders;
    return refreshedFolders
        .where((folder) {
          final key = folder._pathLookupKey;
          return key.isEmpty || !excludedKeys.contains(key);
        })
        .toList(growable: false);
  }

  Map<String, AudioFolder> _folderIndexByPath(List<AudioFolder> source) {
    final existingFolders = <String, AudioFolder>{};
    for (final folder in source) {
      existingFolders[folder._pathLookupKey] = folder;
    }
    return existingFolders;
  }

  Map<String, Audio> _fallbackAudioMap() {
    final fallbackAudios = <String, Audio>{};
    for (final folder in folders) {
      for (final audio in folder.audios) {
        fallbackAudios[_audioPathLookupKey(audio.path)] = audio;
      }
    }
    return fallbackAudios;
  }

  ({List<AudioFolder> folders, bool collectionsChanged, bool pageOrderChanged})
  _mergeRefreshedFolders(List<AudioFolder> includedRefreshedFolders) {
    final existingFolders = _folderIndexByPath(folders);
    var collectionsChanged = includedRefreshedFolders.length != folders.length;
    var pageOrderChanged = false;
    final mergedFolders = <AudioFolder>[];
    Map<String, Audio>? fallbackAudios;
    var fallbackAudiosBuilt = false;
    Audio? resolveExistingAudio(String key) {
      final indexed = _audioByPath[key];
      if (indexed != null || _audioByPath.isNotEmpty) return indexed;
      if (!fallbackAudiosBuilt) {
        fallbackAudiosBuilt = true;
        fallbackAudios = _fallbackAudioMap();
      }
      return fallbackAudios![key];
    }

    for (
      var folderIndex = 0;
      folderIndex < includedRefreshedFolders.length;
      folderIndex++
    ) {
      final refreshedFolder = includedRefreshedFolders[folderIndex];
      final merged = _mergeOneRefreshedFolder(
        refreshedFolder: refreshedFolder,
        existingFolder: existingFolders[refreshedFolder._pathLookupKey],
        folderIndex: folderIndex,
        resolveExistingAudio: resolveExistingAudio,
      );
      if (merged.collectionsChanged) collectionsChanged = true;
      if (merged.pageOrderChanged) pageOrderChanged = true;
      mergedFolders.add(merged.folder);
    }
    if (_audioByPath.isEmpty && fallbackAudiosBuilt) {
      _audioByPath.addAll(fallbackAudios!);
    }
    return (
      folders: mergedFolders,
      collectionsChanged: collectionsChanged,
      pageOrderChanged: pageOrderChanged,
    );
  }

  ({AudioFolder folder, bool collectionsChanged, bool pageOrderChanged})
  _mergeOneRefreshedFolder({
    required AudioFolder refreshedFolder,
    required AudioFolder? existingFolder,
    required int folderIndex,
    required Audio? Function(String key) resolveExistingAudio,
  }) {
    var collectionsChanged =
        existingFolder == null ||
        folderIndex >= folders.length ||
        folders[folderIndex]._pathLookupKey != refreshedFolder._pathLookupKey;
    final existingAudios = existingFolder?.audios;
    if (existingAudios == null ||
        existingAudios.length != refreshedFolder.audios.length) {
      collectionsChanged = true;
    }
    final mergedAudios = _mergeRefreshedAudioList(
      refreshedAudios: refreshedFolder.audios,
      existingAudios: existingAudios,
      resolveExistingAudio: resolveExistingAudio,
    );
    if (mergedAudios.collectionsChanged) collectionsChanged = true;
    final folder = existingFolder ?? refreshedFolder;
    folder
      ..audios = mergedAudios.audios
      ..path = refreshedFolder.path
      ..modified = refreshedFolder.modified
      ..latest = refreshedFolder.latest;
    return (
      folder: folder,
      collectionsChanged: collectionsChanged,
      pageOrderChanged: mergedAudios.pageOrderChanged,
    );
  }

  List<Audio> _copyMergedAudios({
    required List<Audio>? mergedAudios,
    required List<Audio> refreshedAudios,
    required List<Audio>? existingAudios,
  }) {
    if (mergedAudios != null) return mergedAudios;
    if (refreshedAudios.isEmpty) return <Audio>[];
    final result = List<Audio>.filled(
      refreshedAudios.length,
      refreshedAudios.first,
      growable: false,
    );
    if (existingAudios == null) return result;
    final copyCount = existingAudios.length < result.length
        ? existingAudios.length
        : result.length;
    for (var index = 0; index < copyCount; index++) {
      result[index] = existingAudios[index];
    }
    return result;
  }

  ({
    bool collectionsChanged,
    bool pageOrderChanged,
    bool canReuseExistingAudios,
  })
  _applyExistingAudioToMerge({
    required Audio existing,
    required Audio refreshedAudio,
    required String refreshedPathKey,
    required int audioIndex,
    required List<Audio>? existingAudios,
    required bool canReuseExistingAudios,
  }) {
    final metadataMatches = existing._metadataMatches(refreshedAudio);
    final sameAudioSlot =
        existingAudios != null &&
        audioIndex < existingAudios.length &&
        existingAudios[audioIndex]._pathLookupKey == refreshedPathKey;
    final collectionMetadataMatches = existing._collectionMetadataMatches(
      refreshedAudio,
    );
    final pageOrderFieldsMatch =
        existing.title == refreshedAudio.title &&
        existing.artist == refreshedAudio.artist &&
        existing.album == refreshedAudio.album &&
        existing.created == refreshedAudio.created &&
        existing.modified == refreshedAudio.modified;
    if (!metadataMatches) {
      if (existing.path != refreshedAudio.path) {
        refreshedAudio._pathLookupKeyCache = refreshedPathKey;
      }
      existing._replaceMetadataFrom(refreshedAudio);
    }
    return (
      collectionsChanged: !sameAudioSlot || !collectionMetadataMatches,
      pageOrderChanged: !pageOrderFieldsMatch,
      canReuseExistingAudios: canReuseExistingAudios && sameAudioSlot,
    );
  }

  _AudioSlotMerge _mergeOneRefreshedAudioSlot({
    required Audio refreshedAudio,
    required int audioIndex,
    required List<Audio> refreshedAudios,
    required List<Audio>? existingAudios,
    required List<Audio>? mergedAudios,
    required bool canReuseExistingAudios,
    required Audio? Function(String key) resolveExistingAudio,
  }) {
    final refreshedPathKey = _audioPathLookupKey(refreshedAudio.path);
    final existing = resolveExistingAudio(refreshedPathKey);
    if (existing == null) {
      mergedAudios = _copyMergedAudios(
        mergedAudios: mergedAudios,
        refreshedAudios: refreshedAudios,
        existingAudios: existingAudios,
      );
      refreshedAudio._pathLookupKeyCache = refreshedPathKey;
      mergedAudios[audioIndex] = refreshedAudio;
      return (
        mergedAudios: mergedAudios,
        collectionsChanged: true,
        pageOrderChanged: false,
        canReuseExistingAudios: false,
      );
    }
    final applied = _applyExistingAudioToMerge(
      existing: existing,
      refreshedAudio: refreshedAudio,
      refreshedPathKey: refreshedPathKey,
      audioIndex: audioIndex,
      existingAudios: existingAudios,
      canReuseExistingAudios: canReuseExistingAudios,
    );
    if (!applied.canReuseExistingAudios) {
      mergedAudios = _copyMergedAudios(
        mergedAudios: mergedAudios,
        refreshedAudios: refreshedAudios,
        existingAudios: existingAudios,
      );
      mergedAudios[audioIndex] = existing;
    }
    return (
      mergedAudios: mergedAudios,
      collectionsChanged: applied.collectionsChanged,
      pageOrderChanged: applied.pageOrderChanged,
      canReuseExistingAudios: applied.canReuseExistingAudios,
    );
  }

  ({List<Audio> audios, bool collectionsChanged, bool pageOrderChanged})
  _mergeRefreshedAudioList({
    required List<Audio> refreshedAudios,
    required List<Audio>? existingAudios,
    required Audio? Function(String key) resolveExistingAudio,
  }) {
    var collectionsChanged = false;
    var pageOrderChanged = false;
    var canReuseExistingAudios =
        existingAudios != null &&
        existingAudios.length == refreshedAudios.length;
    List<Audio>? mergedAudios;
    for (
      var audioIndex = 0;
      audioIndex < refreshedAudios.length;
      audioIndex++
    ) {
      final slot = _mergeOneRefreshedAudioSlot(
        refreshedAudio: refreshedAudios[audioIndex],
        audioIndex: audioIndex,
        refreshedAudios: refreshedAudios,
        existingAudios: existingAudios,
        mergedAudios: mergedAudios,
        canReuseExistingAudios: canReuseExistingAudios,
        resolveExistingAudio: resolveExistingAudio,
      );
      mergedAudios = slot.mergedAudios;
      canReuseExistingAudios = slot.canReuseExistingAudios;
      if (slot.collectionsChanged) collectionsChanged = true;
      if (slot.pageOrderChanged) pageOrderChanged = true;
    }
    if (!canReuseExistingAudios) {
      mergedAudios = _copyMergedAudios(
        mergedAudios: mergedAudios,
        refreshedAudios: refreshedAudios,
        existingAudios: existingAudios,
      );
    }
    return (
      audios: canReuseExistingAudios ? existingAudios! : mergedAudios!,
      collectionsChanged: collectionsChanged,
      pageOrderChanged: pageOrderChanged,
    );
  }

  Audio? audioByPath(String path) {
    final key = _audioPathLookupKey(path);
    if (key.isEmpty) return null;
    return _audioByPath[key];
  }

  void updateAudiosPageIndexes(List<Audio> audios) {
    for (var index = 0; index < audios.length; index++) {
      audios[index]._audiosPageIndex = index;
    }
  }

  int? audiosPageIndexForPath(String path) {
    final index = audioByPath(path)?._audiosPageIndex ?? -1;
    return index >= 0 ? index : null;
  }

  @override
  String toString() {
    return folders.toString();
  }

  /// 注册一个小封面字节缓存到追踪队列，超出上限时逐出最旧的。
  void _registerSmallCoverBytes(Audio audio) {
    _coverCachePaths.add(audio.path);
    _smallCoverOrder.remove(audio.path);
    _smallCoverOrder.add(audio.path);
    while (_smallCoverOrder.length > _maxCachedSmallCovers) {
      final oldest = _smallCoverOrder.first;
      _smallCoverOrder.remove(oldest);
      // 在 audioCollection 中找到对应 Audio 并逐出
      final evictedAudio = audioByPath(oldest);
      evictedAudio?._smallCoverBytes = null;
      evictedAudio?._unregisterCoverCacheIfEmpty();
    }
  }

  void _registerCoverCache(Audio audio) {
    _coverCachePaths.add(audio.path);
  }

  void _retainCollectionThumbnail(
    Object owner,
    int size,
    void Function() release,
  ) {
    final key = (owner, size);
    _collectionThumbnailRetention.remove(key);
    _collectionThumbnailRetention[key] = release;
    trimCollectionThumbnailRetention(_maxRetainedCollectionThumbnails);
  }

  void _touchCollectionThumbnail(Object owner, int size) {
    final key = (owner, size);
    final release = _collectionThumbnailRetention.remove(key);
    if (release != null) _collectionThumbnailRetention[key] = release;
  }

  void _forgetCollectionThumbnails(Object owner) {
    final keys = _collectionThumbnailRetention.keys
        .where((key) => identical(key.$1, owner))
        .toList(growable: false);
    for (final key in keys) {
      _collectionThumbnailRetention.remove(key);
    }
  }

  void trimCollectionThumbnailRetention(int keepEntries) {
    while (_collectionThumbnailRetention.length > keepEntries) {
      final oldest = _collectionThumbnailRetention.keys.first;
      final release = _collectionThumbnailRetention.remove(oldest);
      release?.call();
    }
  }

  /// 只清理一段时间内未被访问过的"冷"封面，保护当前播放歌曲
  void evictStaleCoverBytes() {
    final now = DateTime.now().millisecondsSinceEpoch;
    const coldMs = 2 * 60 * 1000;
    final playingPath = PlayService.existingPlaybackService?.nowPlaying?.path;
    int evicted = 0;
    final activePaths = List<String>.from(_coverCachePaths);
    for (final path in activePaths) {
      final audio = audioByPath(path);
      if (audio == null) {
        _coverCachePaths.remove(path);
        continue;
      }
      if (audio._coverImage?.target == null &&
          audio._mediumCoverImage?.target == null &&
          audio._largeCoverImage?.target == null &&
          audio._smallCoverBytes == null) {
        _coverCachePaths.remove(path);
        continue;
      }
      if (audio.path == playingPath) continue;
      if (now - audio._coverLastAccessMs < coldMs) continue;
      if (audio._releaseRetainedCoverCache()) evicted++;
    }
    if (evicted > 0) {
      log.memory.debug('legacy', '[mem] evicted $evicted cold cover caches');
    }
  }

  /// Evict retained Audio cover providers except the currently playing track.
  void evictAllCoversExcept(
    String? playingPath, {
    bool includeCollectionCovers = false,
  }) {
    int evicted = 0;
    final activePaths = List<String>.from(_coverCachePaths);
    for (final path in activePaths) {
      if (path == playingPath) continue;
      final audio = audioByPath(path);
      if (audio == null) {
        _coverCachePaths.remove(path);
        continue;
      }
      if (audio.evictCoverCacheIfPresent()) evicted++;
    }
    if (includeCollectionCovers) {
      for (final artist in artistCollection.values) {
        if (artist.primaryPath == playingPath) continue;
        if (artist.evictPictureCache()) evicted++;
      }
      for (final album in albumCollection.values) {
        if (album.primaryPath == playingPath) continue;
        if (album.evictCoverCache()) evicted++;
      }
    }
    if (evicted > 0) {
      log.memory.debug(
        'legacy',
        '[mem] evicted $evicted covers on song change',
      );
    }
  }

  /// 完全释放数据库资源
  void dispose() {
    _collectionGeneration++;
    _preparedAudiosPage = null;
    _preparedArtistsPage = null;
    _preparedAlbumsPage = null;
    _pageSnapshotCoordinator.reset();
    trimCollectionThumbnailRetention(0);
    _smallCoverOrder.clear();
    _coverCachePaths.clear();
    _invalidateAggregatedRootFolders();
    _audioByPath.clear();
    audioCollection.clear();
    artistCollection.clear();
    albumCollection.clear();
    folders.clear();
  }

  void _invalidateAggregatedRootFolders() {
    _aggregatedRootFoldersCache = null;
    _aggregatedRootFoldersSource = null;
    _aggregatedRootFoldersSourceLength = -1;
    _aggregatedRootFoldersUserPaths = const <String>[];
  }

  bool _canReuseAggregatedRootFolders(
    List<String> userFolders,
    Map<String, String> folderAliases,
  ) {
    final cached = _aggregatedRootFoldersCache;
    if (cached == null ||
        !identical(_aggregatedRootFoldersSource, folders) ||
        _aggregatedRootFoldersSourceLength != folders.length ||
        !listEquals(_aggregatedRootFoldersUserPaths, userFolders)) {
      return false;
    }
    for (final folder in cached) {
      if (folder.alias != folderAliases[folder._pathLookupKey]) return false;
    }
    return true;
  }

  List<AudioFolder> _cacheAggregatedRootFolders(
    List<AudioFolder> result,
    List<String> userFolders,
  ) {
    final cached = List<AudioFolder>.unmodifiable(result);
    _aggregatedRootFoldersCache = cached;
    _aggregatedRootFoldersSource = folders;
    _aggregatedRootFoldersSourceLength = folders.length;
    _aggregatedRootFoldersUserPaths = List<String>.unmodifiable(userFolders);
    return List<AudioFolder>.of(cached);
  }

  /// 只返回用户手动添加的根文件夹，每项聚合该根下所有子文件夹的音频。
  static List<AudioFolder> aggregatedRootFolders() {
    final library = instance;
    final userFolders = AppPreference.instance.userFolders;
    final folderAliases = AppPreference.instance.folderAliases;
    if (library._canReuseAggregatedRootFolders(userFolders, folderAliases)) {
      return List<AudioFolder>.of(library._aggregatedRootFoldersCache!);
    }
    if (library.folders.isEmpty) {
      final result = userFolders
          .map((folder) => AudioFolder([], folder, 0, 0, _aliasFor(folder)))
          .toList();
      return library._cacheAggregatedRootFolders(result, userFolders);
    }
    return library._buildAggregatedRootFolders(userFolders);
  }

  List<({String path, String key})> _inferAggregatedRoots() {
    final keys = folders
        .map((folder) => folder._pathLookupKey)
        .toList(growable: false);
    final keySet = keys.toSet();
    final roots = <int>[];
    for (var i = 0; i < keys.length; i++) {
      if (!_keyHasAncestor(keys[i], keySet)) roots.add(i);
    }
    return [for (final i in roots) (path: folders[i].path, key: keys[i])];
  }

  bool _keyHasAncestor(String key, Set<String> keySet) {
    var ancestor = key;
    while (true) {
      final separator = ancestor.lastIndexOf('/');
      if (separator <= 0) return false;
      ancestor = ancestor.substring(0, separator);
      if (keySet.contains(ancestor)) return true;
    }
  }

  List<AudioFolder> _buildAggregatedRootFolders(List<String> userFolders) {
    final targetRoots = userFolders.isNotEmpty
        ? [
            for (final path in userFolders)
              (path: path, key: pendingFolderKey(path)),
          ]
        : _inferAggregatedRoots();
    if (targetRoots.isEmpty) {
      return _cacheAggregatedRootFolders(
        List<AudioFolder>.of(folders),
        userFolders,
      );
    }
    final grouped = _groupFoldersByTargetRoots(targetRoots);
    final result = <AudioFolder>[
      for (var i = 0; i < targetRoots.length; i++)
        _aggregatedFolderForRoot(i, targetRoots, grouped),
    ];
    return _cacheAggregatedRootFolders(result, userFolders);
  }

  ({
    List<AudioFolder?> matchingFolders,
    List<List<AudioFolder>> sourceFolders,
    List<int> audioCounts,
  })
  _groupFoldersByTargetRoots(List<({String path, String key})> targetRoots) {
    final rootIndexes = <String, List<int>>{};
    for (var i = 0; i < targetRoots.length; i++) {
      rootIndexes.putIfAbsent(targetRoots[i].key, () => <int>[]).add(i);
    }
    final matchingFolders = List<AudioFolder?>.filled(targetRoots.length, null);
    final sourceFolders = List<List<AudioFolder>>.generate(
      targetRoots.length,
      (_) => <AudioFolder>[],
    );
    final audioCounts = List<int>.filled(targetRoots.length, 0);
    for (final folder in folders) {
      _assignFolderToRoots(
        folder,
        rootIndexes,
        matchingFolders,
        sourceFolders,
        audioCounts,
      );
    }
    return (
      matchingFolders: matchingFolders,
      sourceFolders: sourceFolders,
      audioCounts: audioCounts,
    );
  }

  void _recordFolderAgainstRoots(
    AudioFolder folder,
    List<int>? indexes,
    List<AudioFolder?> matchingFolders,
    List<List<AudioFolder>> sourceFolders,
    List<int> audioCounts, {
    required bool isExact,
  }) {
    if (indexes == null) return;
    for (final index in indexes) {
      sourceFolders[index].add(folder);
      audioCounts[index] += folder.audios.length;
      if (isExact) matchingFolders[index] = folder;
    }
  }

  void _assignFolderToRoots(
    AudioFolder folder,
    Map<String, List<int>> rootIndexes,
    List<AudioFolder?> matchingFolders,
    List<List<AudioFolder>> sourceFolders,
    List<int> audioCounts,
  ) {
    final folderKey = folder._pathLookupKey;
    var ancestor = folderKey;
    while (true) {
      _recordFolderAgainstRoots(
        folder,
        rootIndexes[ancestor],
        matchingFolders,
        sourceFolders,
        audioCounts,
        isExact: ancestor == folderKey,
      );
      final separator = ancestor.lastIndexOf('/');
      if (separator <= 0) break;
      ancestor = ancestor.substring(0, separator);
    }
  }

  AudioFolder _aggregatedFolderForRoot(
    int rootIndex,
    List<({String path, String key})> targetRoots,
    ({
      List<AudioFolder?> matchingFolders,
      List<List<AudioFolder>> sourceFolders,
      List<int> audioCounts,
    })
    grouped,
  ) {
    final matchingFolder = grouped.matchingFolders[rootIndex];
    final rootPath = targetRoots[rootIndex].path;
    final resolvedPath = matchingFolder?.path ?? rootPath;
    return AudioFolder(
      _aggregateAudiosForRoot(
        grouped.sourceFolders[rootIndex],
        grouped.audioCounts[rootIndex],
      ),
      resolvedPath,
      matchingFolder?.modified ?? 0,
      matchingFolder?.latest ?? 0,
      _aliasFor(resolvedPath),
    );
  }

  List<Audio> _aggregateAudiosForRoot(
    List<AudioFolder> sources,
    int audioCount,
  ) {
    if (audioCount == 0) return <Audio>[];
    AudioFolder? onlyNonEmptySource;
    for (final source in sources) {
      if (source.audios.isEmpty) continue;
      if (onlyNonEmptySource != null) {
        onlyNonEmptySource = null;
        break;
      }
      onlyNonEmptySource = source;
    }
    if (onlyNonEmptySource != null) return onlyNonEmptySource.audios;
    final firstAudio = sources
        .firstWhere((source) => source.audios.isNotEmpty)
        .audios
        .first;
    final result = List<Audio>.filled(audioCount, firstAudio, growable: false);
    var offset = 0;
    for (final source in sources) {
      final audios = source.audios;
      result.setRange(offset, offset + audios.length, audios);
      offset += audios.length;
    }
    return result;
  }

  static String? _aliasFor(String path) =>
      AppPreference.instance.folderAliases[pendingFolderKey(path)];
}

class AudioFolder {
  String _path;
  String? _pathLookupKeyCache;
  List<Audio> audios;

  /// absolute path
  String get path => _path;
  set path(String value) {
    if (_path == value) return;
    _path = value;
    _pathLookupKeyCache = null;
  }

  String get _pathLookupKey => _pathLookupKeyCache ??= pendingFolderKey(_path);

  /// secs since UNIX EPOCH
  int modified;

  /// secs since UNIX EPOCH
  int latest;

  /// 用户设置的别名（来自 AppPreference.folderAliases，不写入索引）
  String? alias;

  AudioFolder(
    this.audios,
    String path,
    this.modified,
    this.latest, [
    this.alias,
  ]) : _path = path;

  /// 展示名：别名优先，否则目录名
  String get displayName => alias ?? p.basename(path);

  factory AudioFolder.fromMap(Map map, List<Audio> audios) => AudioFolder(
    audios,
    map['path'] ?? '',
    map['modified'] ?? 0,
    map['latest'] ?? 0,
  );

  @override
  String toString() {
    return {
      'audios': audios.toString(),
      'path': path,
      'modified': DateTime.fromMillisecondsSinceEpoch(
        modified * 1000,
      ).toString(),
    }.toString();
  }
}

class Audio {
  int _libraryIndex = -1;
  int _audiosPageIndex = -1;
  String? _pathLookupKeyCache;
  String title;

  /// 从音乐标签中读取的艺术家字符串，可能包含多个艺术家，以“、”，“/”等分隔。
  String artist;

  /// 分割[artist]得到的结果
  List<String> splitedArtists;

  String album;

  String? albumArtist;

  List<String> splitedAlbumArtists;

  /// 0: 没有track
  int track;

  /// 0 or null: no disc number
  int? disc;

  /// audio's duration in secs
  int duration;

  /// kbps
  int? bitrate;

  int? sampleRate;

  /// absolute path
  String path;

  /// secs since UNIX EPOCH
  int modified;

  /// secs since UNIX EPOCH
  int created;

  /// 标签来源（Lofty、Windows、null）
  String? by;

  /// 播放次数（从 library.sqlite 读取/写入）
  int playCount;

  String? _searchNorm;
  String? _searchPinyin;

  /// 缓存 ImageProvider 实例，避免每次创建新实例导致 Flutter ImageCache 失效
  /// 使用 WeakReference 让 CoverImageCache 的 LRU 驱逐后能被 GC 回收
  WeakReference<ImageProvider>? _coverImage;
  WeakReference<ImageProvider>? _mediumCoverImage;
  WeakReference<ImageProvider>? _largeCoverImage;

  /// 小封面原始字节（48×48 PNG）：
  /// 列表 tile 同步检查此字段，已缓存则直接用 Image.memory 渲染，
  /// 不走 FutureBuilder，彻底避免闪烁。
  Uint8List? _smallCoverBytes;

  /// 上一次封面被访问的时间戳，用于冷数据回收
  int _coverLastAccessMs = 0;
  int _coverCacheGeneration = 0;
  String? _folderCoverDirectory;
  String? _folderCoverPath;
  bool _folderCoverResolved = false;
  Future<String?>? _folderCoverResolution;

  void _touchCoverAccess() {
    _coverLastAccessMs = DateTime.now().millisecondsSinceEpoch;
  }

  /// 按当前设置拆分艺术家，白名单与别名一并生效
  static List<String> _splitArtistNames(String raw) {
    return AppSettings.instance.splitArtistNames(raw);
  }

  Audio(
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.track,
    this.duration,
    this.bitrate,
    this.sampleRate,
    this.path,
    this.modified,
    this.created,
    this.by, {
    this.disc,
    this.playCount = 0,
  }) : splitedArtists = _splitArtistNames(artist),
       splitedAlbumArtists = _splitArtistNames(albumArtist ?? '');

  factory Audio._fromLoaded(
    String title,
    String artist,
    String album,
    String? albumArtist,
    int track,
    int duration,
    int? bitrate,
    int? sampleRate,
    String path,
    int modified,
    int created,
    String? by,
    _AudioLoadPool pool, {
    int? disc,
    int playCount = 0,
  }) {
    final pooledArtist = pool.text(artist);
    final pooledAlbumArtist = pool.optionalText(albumArtist);
    return Audio._withArtistLists(
      title,
      pooledArtist,
      pool.text(album),
      pooledAlbumArtist,
      track,
      duration,
      bitrate,
      sampleRate,
      path,
      modified,
      created,
      pool.optionalText(by),
      pool.artistList(pooledArtist),
      pool.artistList(pooledAlbumArtist ?? ''),
      disc: disc,
      playCount: playCount,
    ).._primeSearchCache(pool);
  }

  Audio._withArtistLists(
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.track,
    this.duration,
    this.bitrate,
    this.sampleRate,
    this.path,
    this.modified,
    this.created,
    this.by,
    this.splitedArtists,
    this.splitedAlbumArtists, {
    this.disc,
    this.playCount = 0,
  });

  String get _pathLookupKey =>
      _pathLookupKeyCache ??= _audioPathLookupKey(path);

  void _primeSearchCache(_AudioLoadPool pool) {
    _searchNorm = pool.text(normalizedSearchQuery(title).toLowerCase());
    _searchPinyin = pool.text(title.getPinyinInitials().toLowerCase());
  }

  void _invalidateSearchCache() {
    _searchNorm = null;
    _searchPinyin = null;
  }

  bool matchesSearchQuery(String queryInLowerCase) {
    final norm = _searchNorm ??= normalizedSearchQuery(title).toLowerCase();
    if (norm.contains(queryInLowerCase)) return true;
    final pinyin = _searchPinyin ??= title.getPinyinInitials().toLowerCase();
    return pinyin.contains(queryInLowerCase);
  }

  void _replaceMetadataFrom(Audio other) {
    if (modified != other.modified) {
      evictCoverCacheIfPresent();
    }
    if (path != other.path) {
      _folderCoverDirectory = null;
      _folderCoverPath = null;
      _folderCoverResolved = false;
      _folderCoverResolution = null;
      _pathLookupKeyCache = other._pathLookupKeyCache;
    }
    final titleChanged = title != other.title;
    title = other.title;
    if (titleChanged) {
      _searchNorm = other._searchNorm;
      _searchPinyin = other._searchPinyin;
    }
    artist = other.artist;
    album = other.album;
    albumArtist = other.albumArtist;
    track = other.track;
    disc = other.disc;
    duration = other.duration;
    bitrate = other.bitrate;
    sampleRate = other.sampleRate;
    path = other.path;
    modified = other.modified;
    created = other.created;
    by = other.by;
    playCount = other.playCount;
    splitedArtists = other.splitedArtists;
    splitedAlbumArtists = other.splitedAlbumArtists;
  }

  bool _metadataMatches(Audio other) =>
      title == other.title &&
      artist == other.artist &&
      album == other.album &&
      albumArtist == other.albumArtist &&
      track == other.track &&
      disc == other.disc &&
      duration == other.duration &&
      bitrate == other.bitrate &&
      sampleRate == other.sampleRate &&
      path == other.path &&
      modified == other.modified &&
      created == other.created &&
      by == other.by &&
      playCount == other.playCount &&
      listEquals(splitedArtists, other.splitedArtists) &&
      listEquals(splitedAlbumArtists, other.splitedAlbumArtists);

  bool _collectionMetadataMatches(Audio other) =>
      artist == other.artist &&
      album == other.album &&
      albumArtist == other.albumArtist &&
      listEquals(splitedArtists, other.splitedArtists) &&
      listEquals(splitedAlbumArtists, other.splitedAlbumArtists);

  factory Audio.fromMap(Map map) => Audio(
    map['title'] ?? '',
    map['artist'] ?? '',
    map['album'] ?? '',
    map['album_artist'],
    map['track'] ?? 0,
    map['duration'] ?? 0,
    map['bitrate'],
    map['sample_rate'],
    map['path'] ?? '',
    map['modified'] ?? 0,
    map['created'] ?? 0,
    map['by'],
    disc: _optionalInt(map['disc']),
    playCount: map['play_count'] ?? 0,
  );

  Map toMap() => {
    'title': title,
    'artist': artist,
    'album': album,
    'album_artist': albumArtist,
    'track': track,
    'disc': disc,
    'duration': duration,
    'bitrate': bitrate,
    'sample_rate': sampleRate,
    'path': path,
    'modified': modified,
    'created': created,
    'play_count': playCount,
    'by': by,
  };

  ImageProvider _folderCoverProvider({
    required String coverPath,
    required int width,
    required int height,
  }) {
    final ratio = PlatformDispatcher.instance.views.first.devicePixelRatio;
    return ResizeImage(
      FileImage(File(coverPath)),
      width: (width * ratio).round(),
      height: (height * ratio).round(),
    );
  }

  ImageProvider? _getCachedFolderCover({
    required int width,
    required int height,
  }) {
    final directory = File(path).parent.path;
    if (!_folderCoverResolved || _folderCoverDirectory != directory) {
      return null;
    }
    final coverPath = _folderCoverPath;
    if (coverPath == null) return null;
    return _folderCoverProvider(
      coverPath: coverPath,
      width: width,
      height: height,
    );
  }

  Future<String?> resolveFolderCoverPath() async {
    final directory = File(path).parent.path;
    if (_folderCoverResolved && _folderCoverDirectory == directory) {
      return _folderCoverPath;
    }
    final pending = _folderCoverResolution;
    if (pending != null && _folderCoverDirectory == directory) {
      return pending;
    }

    _folderCoverDirectory = directory;
    _folderCoverPath = null;
    _folderCoverResolved = false;
    final future = () async {
      String? resolvedPath;
      for (final name in const ['cover.jpg', 'cover.png']) {
        final candidate = File(p.join(directory, name));
        if (await candidate.exists()) {
          resolvedPath = candidate.path;
          break;
        }
      }
      if (_folderCoverDirectory != directory) return null;
      _folderCoverPath = resolvedPath;
      _folderCoverResolved = true;
      return resolvedPath;
    }();
    _folderCoverResolution = future;
    try {
      return await future;
    } finally {
      if (identical(_folderCoverResolution, future)) {
        _folderCoverResolution = null;
      }
    }
  }

  Future<ImageProvider?> _getFolderCover({
    required int width,
    required int height,
  }) async {
    final coverPath = await resolveFolderCoverPath();
    if (coverPath == null) return null;
    return _folderCoverProvider(
      coverPath: coverPath,
      width: width,
      height: height,
    );
  }

  /// 缓存ImageProvider实例，避免每次创建新实例导致Flutter ImageCache失效
  /// 缓存bytes时，每次加载图片都要重新解码，内存占用很大。快速滚动时能到700mb
  /// 缓存ImageProvider不用重新解码。快速滚动时最多250mb
  ///
  /// 先检查 _coverImage，命中直接返回同一实例；永不走 FFI
  Future<ImageProvider?> get cover async {
    _touchCoverAccess();
    final cached = _coverImage?.target;
    if (cached != null) return cached;
    final generation = _coverCacheGeneration;
    try {
      final data = await CoverImageCache.instance.get(
        path: path,
        modified: modified,
        width: 48,
        height: 48,
      );
      if (generation != _coverCacheGeneration) {
        if (data != null) unawaited(data.evict());
        return null;
      }
      _coverImage = data != null ? WeakReference(data) : null;
      if (data != null) AudioLibrary.instance._registerCoverCache(this);
      return data;
    } catch (_) {
      return null;
    }
  }

  /// 同步取已缓存的小封面字节（48×48 PNG）
  /// 用于列表 tile 同步渲染，零闪烁。
  Uint8List? get smallCoverBytes {
    final bytes = _smallCoverBytes;
    if (bytes != null) {
      _touchCoverAccess();
      AudioLibrary.instance._registerSmallCoverBytes(this);
    }
    return bytes;
  }

  /// 异步加载小封面字节并缓存在 [_smallCoverBytes] 中
  Future<Uint8List?> loadSmallCoverBytes() async {
    final cached = smallCoverBytes;
    if (cached != null) return cached;
    final generation = _coverCacheGeneration;
    try {
      final bytes = await CoverImageCache.instance.loadBytes(
        path: path,
        modified: modified,
        width: 48,
        height: 48,
      );
      if (generation != _coverCacheGeneration) {
        return null;
      }
      if (bytes != null) {
        _smallCoverBytes = bytes;
        _touchCoverAccess();
        AudioLibrary.instance._registerSmallCoverBytes(this);
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 同步获取已缓存的封面（不触发异步加载）
  /// 用于需要立即显示封面的场景，避免异步等待导致的闪烁
  ImageProvider? get cachedMediumCover => _mediumCoverImage?.target;
  ImageProvider? get cachedLargeCover => _largeCoverImage?.target;

  /// Evict cover cache only when this Audio actually retains one.
  bool evictCoverCacheIfPresent() {
    if (_coverImage?.target == null &&
        _mediumCoverImage?.target == null &&
        _largeCoverImage?.target == null &&
        _smallCoverBytes == null) {
      return false;
    }
    evictCoverCache();
    return true;
  }

  bool _releaseRetainedCoverCache() {
    if (_coverImage?.target == null &&
        _mediumCoverImage?.target == null &&
        _largeCoverImage?.target == null &&
        _smallCoverBytes == null) {
      return false;
    }
    _coverImage = null;
    _mediumCoverImage = null;
    _largeCoverImage = null;
    _smallCoverBytes = null;
    AudioLibrary.instance._smallCoverOrder.remove(path);
    AudioLibrary.instance._coverCachePaths.remove(path);
    return true;
  }

  void evictCoverCache() {
    _coverCacheGeneration++;
    final coverImage = _coverImage?.target;
    final mediumCoverImage = _mediumCoverImage?.target;
    final largeCoverImage = _largeCoverImage?.target;

    _coverImage = null;
    _mediumCoverImage = null;
    _largeCoverImage = null;
    _smallCoverBytes = null;
    AudioLibrary.instance._smallCoverOrder.remove(path);
    AudioLibrary.instance._coverCachePaths.remove(path);
    CoverImageCache.instance.evictPath(path);

    if (coverImage != null) unawaited(coverImage.evict());
    if (mediumCoverImage != null) unawaited(mediumCoverImage.evict());
    if (largeCoverImage != null) unawaited(largeCoverImage.evict());
  }

  void _unregisterCoverCacheIfEmpty() {
    if (_coverImage?.target == null &&
        _mediumCoverImage?.target == null &&
        _largeCoverImage?.target == null &&
        _smallCoverBytes == null) {
      AudioLibrary.instance._coverCachePaths.remove(path);
    }
  }

  /// audio detail page
  /// 200 * 200
  Future<ImageProvider?> get mediumCover async {
    _touchCoverAccess();
    final cached = _mediumCoverImage?.target;
    if (cached != null) return cached;
    final generation = _coverCacheGeneration;
    try {
      final data = await CoverImageCache.instance.get(
        path: path,
        modified: modified,
        width: 200,
        height: 200,
      );
      if (generation != _coverCacheGeneration) {
        if (data != null) unawaited(data.evict());
        return null;
      }
      _mediumCoverImage = data != null ? WeakReference(data) : null;
      if (data != null) AudioLibrary.instance._registerCoverCache(this);
      return data;
    } catch (_) {
      return null;
    }
  }

  /// now playing
  /// size: 520 * devicePixelRatio（屏幕缩放大小）
  Future<ImageProvider?> get largeCover async {
    _touchCoverAccess();
    final cached = _largeCoverImage?.target;
    if (cached != null) return cached;
    final generation = _coverCacheGeneration;
    try {
      final data = await CoverImageCache.instance.get(
        path: path,
        modified: modified,
        width: 420,
        height: 420,
      );
      if (generation != _coverCacheGeneration) {
        if (data != null) unawaited(data.evict());
        return null;
      }
      _largeCoverImage = data != null ? WeakReference(data) : null;
      if (data != null) AudioLibrary.instance._registerCoverCache(this);
      return data;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() {
    return {
      'title': title,
      'artist': artist,
      'album': album,
      'path': path,
      'modified': DateTime.fromMillisecondsSinceEpoch(
        modified * 1000,
      ).toString(),
      'created': DateTime.fromMillisecondsSinceEpoch(created * 1000).toString(),
    }.toString();
  }
}

class Artist {
  String name;
  int _collectionGeneration = 0;
  int _libraryIndex = -1;

  /// 所有专辑
  Map<String, Album> albumsMap = {};

  /// 作品
  List<Audio> works = [];

  /// 缓存 ImageProvider 实例，使用 WeakReference
  WeakReference<ImageProvider>? _pictureCache;
  String? _pictureCachePath;
  final Map<int, _CollectionThumbnail> _thumbnailPictures = {};

  String? get primaryPath => works.firstOrNull?.path;

  /// 只能用在artist detail page
  /// 200*200
  Future<ImageProvider?> get picture async {
    final path = primaryPath;
    if (_pictureCachePath != path) {
      _pictureCache = null;
      _pictureCachePath = path;
    }
    final cached = _pictureCache?.target;
    if (cached != null) return cached;
    if (path == null) return null;
    final data = await CoverImageCache.instance.get(
      path: path,
      modified: works.first.modified,
      width: 200,
      height: 200,
    );
    if (primaryPath == path) {
      _pictureCache = data != null ? WeakReference(data) : null;
      _pictureCachePath = path;
    }
    return data;
  }

  void _retainThumbnail(int size, String path, ImageProvider provider) {
    _thumbnailPictures[size] = _CollectionThumbnail(path, provider);
    AudioLibrary.instance._retainCollectionThumbnail(this, size, () {
      final retained = _thumbnailPictures[size];
      if (retained?.path == path && identical(retained?.provider, provider)) {
        _thumbnailPictures.remove(size);
      }
    });
  }

  bool evictPictureCache() {
    final retained = HashSet<ImageProvider>.identity();
    final pictureCache = _pictureCache?.target;
    if (pictureCache != null) retained.add(pictureCache);
    retained.addAll(_thumbnailPictures.values.map((entry) => entry.provider));
    _pictureCache = null;
    _pictureCachePath = null;
    AudioLibrary.instance._forgetCollectionThumbnails(this);
    _thumbnailPictures.clear();
    if (retained.isEmpty) return false;
    for (final provider in retained) {
      unawaited(provider.evict());
    }
    return true;
  }

  Future<ImageProvider?> thumbnailPicture({int size = 48}) async {
    final path = primaryPath;
    if (path == null) return null;
    final cached = cachedThumbnailPicture(size: size);
    if (cached != null) return cached;
    final data = await CoverImageCache.instance.get(
      path: path,
      modified: works.first.modified,
      width: size,
      height: size,
    );
    if (data != null && primaryPath == path) {
      _retainThumbnail(size, path, data);
    }
    return data;
  }

  ImageProvider? cachedThumbnailPicture({int size = 48}) {
    final path = primaryPath;
    if (path == null) {
      AudioLibrary.instance._forgetCollectionThumbnails(this);
      _thumbnailPictures.clear();
      return null;
    }
    if (_thumbnailPictures.values.any((entry) => entry.path != path)) {
      AudioLibrary.instance._forgetCollectionThumbnails(this);
      _thumbnailPictures.removeWhere((_, entry) => entry.path != path);
    }
    final retained = _thumbnailPictures[size]?.provider;
    if (retained != null) {
      AudioLibrary.instance._touchCollectionThumbnail(this, size);
      return retained;
    }
    final cached = CoverImageCache.instance.getCached(
      path: path,
      modified: works.first.modified,
      width: size,
      height: size,
    );
    if (cached != null) {
      _retainThumbnail(size, path, cached);
    }
    return cached;
  }

  Artist({required this.name});
}

class Album {
  String name;
  int _collectionGeneration = 0;
  int _libraryIndex = -1;

  /// 参与的艺术家
  Map<String, Artist> artistsMap = {};

  /// 作品
  List<Audio> works = [];

  /// 缓存 ImageProvider 实例，使用 WeakReference
  WeakReference<ImageProvider>? _coverCache;
  String? _coverCachePath;
  final Map<int, _CollectionThumbnail> _thumbnailCovers = {};

  String? get primaryPath => works.firstOrNull?.path;

  /// 只能用在album detail page
  /// 200*200
  Future<ImageProvider?> get cover async {
    final path = primaryPath;
    if (_coverCachePath != path) {
      _coverCache = null;
      _coverCachePath = path;
    }
    final cached = _coverCache?.target;
    if (cached != null) return cached;
    if (path == null) return null;
    final folderCover = await works.first._getFolderCover(
      width: 200,
      height: 200,
    );
    if (folderCover != null) {
      if (primaryPath == path) {
        _coverCache = WeakReference(folderCover);
        _coverCachePath = path;
      }
      return folderCover;
    }
    final data = await CoverImageCache.instance.get(
      path: path,
      modified: works.first.modified,
      width: 200,
      height: 200,
    );
    if (primaryPath == path) {
      _coverCache = data != null ? WeakReference(data) : null;
      _coverCachePath = path;
    }
    return data;
  }

  void _retainThumbnail(int size, String path, ImageProvider provider) {
    _thumbnailCovers[size] = _CollectionThumbnail(path, provider);
    AudioLibrary.instance._retainCollectionThumbnail(this, size, () {
      final retained = _thumbnailCovers[size];
      if (retained?.path == path && identical(retained?.provider, provider)) {
        _thumbnailCovers.remove(size);
      }
    });
  }

  bool evictCoverCache() {
    final retained = HashSet<ImageProvider>.identity();
    final coverCache = _coverCache?.target;
    if (coverCache != null) retained.add(coverCache);
    retained.addAll(_thumbnailCovers.values.map((entry) => entry.provider));
    _coverCache = null;
    _coverCachePath = null;
    AudioLibrary.instance._forgetCollectionThumbnails(this);
    _thumbnailCovers.clear();
    if (retained.isEmpty) return false;
    for (final provider in retained) {
      unawaited(provider.evict());
    }
    return true;
  }

  Future<ImageProvider?> thumbnailCover({int size = 48}) async {
    final path = primaryPath;
    if (path == null) return null;
    final cached = cachedThumbnailCover(size: size);
    if (cached != null) return cached;
    final folderCover = await works.first._getFolderCover(
      width: size,
      height: size,
    );
    final data =
        folderCover ??
        await CoverImageCache.instance.get(
          path: path,
          modified: works.first.modified,
          width: size,
          height: size,
        );
    if (data != null && primaryPath == path) {
      _retainThumbnail(size, path, data);
    }
    return data;
  }

  ImageProvider? cachedThumbnailCover({int size = 48}) {
    final path = primaryPath;
    if (path == null) {
      AudioLibrary.instance._forgetCollectionThumbnails(this);
      _thumbnailCovers.clear();
      return null;
    }
    if (_thumbnailCovers.values.any((entry) => entry.path != path)) {
      AudioLibrary.instance._forgetCollectionThumbnails(this);
      _thumbnailCovers.removeWhere((_, entry) => entry.path != path);
    }
    final retained = _thumbnailCovers[size]?.provider;
    if (retained != null) {
      AudioLibrary.instance._touchCollectionThumbnail(this, size);
      return retained;
    }
    final cached =
        works.first._getCachedFolderCover(width: size, height: size) ??
        CoverImageCache.instance.getCached(
          path: path,
          modified: works.first.modified,
          width: size,
          height: size,
        );
    if (cached != null) {
      _retainThumbnail(size, path, cached);
    }
    return cached;
  }

  Album({required this.name});
}

class _CollectionThumbnail {
  const _CollectionThumbnail(this.path, this.provider);

  final String path;
  final ImageProvider provider;
}
