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
import 'package:pure_music/library/library_page_order_cache.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

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

class _AudioLoadPool {
  _AudioLoadPool(this._artistSplitRegex);

  static const int _maxTexts = 65536;
  static const int _maxArtistLists = 32768;
  final RegExp _artistSplitRegex;
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
    final parts = Audio._splitAndDedup(canonicalValue, _artistSplitRegex);
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
  bool reuseEqualKeys = false,
}) {
  final indexes = Uint32List(length);
  for (var index = 0; index < length; index++) {
    indexes[index] = index;
  }
  if (naturalValues != null) {
    sortNaturallyBy(
      indexes,
      (index) => naturalValues[index],
      descending: descending,
      reuseEqualKeys: reuseEqualKeys,
    );
    return indexes;
  }
  final values = integerValues!;
  if (descending) {
    indexes.sort((a, b) => values[b].compareTo(values[a]));
  } else {
    indexes.sort((a, b) => values[a].compareTo(values[b]));
  }
  return indexes;
}

typedef _SecondaryPageSortRequest = ({
  SendPort sendPort,
  int artistCount,
  List<String>? artistNaturalValues,
  List<int>? artistIntegerValues,
  bool artistDescending,
  int albumCount,
  List<String>? albumNaturalValues,
  List<int>? albumIntegerValues,
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
      descending: request.artistDescending,
    );
    request.sendPort.send(<Object?>[0, _transferPageOrder(artistOrder)]);
    final albumOrder = _sortLibraryPageIndexes(
      length: request.albumCount,
      naturalValues: request.albumNaturalValues,
      integerValues: request.albumIntegerValues,
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

class _PageOrderCacheSpec {
  const _PageOrderCacheSpec({
    required this.sourcePath,
    required this.cachePath,
    required this.sourceSignature,
    required this.context,
  });

  final String sourcePath;
  final String cachePath;
  final LibraryPageSourceSignature sourceSignature;
  final String context;
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
  Future<void>? _pageOrderCacheWrite;
  int _pageOrderCacheWriteRequest = 0;
  _PageOrderCacheSpec? _activePageOrderCacheSpec;
  List<AudioFolder>? _aggregatedRootFoldersCache;
  List<AudioFolder>? _aggregatedRootFoldersSource;
  int _aggregatedRootFoldersSourceLength = -1;
  List<String> _aggregatedRootFoldersUserPaths = const <String>[];

  static Future<_LibraryInstallMetrics> _installLoadedFolders(
    List<AudioFolder> loadedFolders, {
    required String pageCacheSourcePath,
    required String pageCachePath,
    required int objectBatchSize,
  }) async {
    while (true) {
      final pending = _collectionInstallInProgress;
      if (pending == null) break;
      await pending;
    }

    final completer = Completer<void>();
    _collectionInstallInProgress = completer.future;
    try {
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
      instance._activePageOrderCacheSpec = cacheSpec;
      final restored = cacheSpec == null
          ? (audios: false, artists: false, albums: false)
          : await instance._restorePreferredPageSnapshots(cacheSpec);
      final restoredAll =
          restored.audios && restored.artists && restored.albums;
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
        pagePreparationMilliseconds:
            pagePreparationStopwatch.elapsedMilliseconds,
      );
    } finally {
      _collectionInstallInProgress = null;
      completer.complete();
    }
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
          logger.e(err, stackTrace: trace);
        }
      }

      try {
        final sqliteReadStopwatch = Stopwatch()..start();
        final dbFolders = await library_db.readIndexFromSqlite(
          indexPath: supportPath,
        );
        sqliteReadStopwatch.stop();
        final rssAfterRead = ProcessInfo.currentRss;
        final conversionStopwatch = Stopwatch()..start();
        final folders = <AudioFolder>[];
        final loadPool = _AudioLoadPool(AppSettings.instance.artistSplitRegex);
        var convertedAudioCount = 0;
        for (final folder in dbFolders) {
          final sourceAudios = folder.audios;
          final audioCount = sourceAudios.length;
          final List<Audio> audios;
          if (audioCount == 0) {
            audios = <Audio>[];
          } else {
            final lastIndex = audioCount - 1;
            final lastAudio = _audioFromIndex(
              sourceAudios.removeLast(),
              loadPool,
            );
            audios = List<Audio>.filled(audioCount, lastAudio, growable: false);
            convertedAudioCount++;
            if (convertedAudioCount % objectBatchSize == 0) {
              await Future<void>.delayed(Duration.zero);
            }
            for (var index = lastIndex - 1; index >= 0; index--) {
              audios[index] = _audioFromIndex(
                sourceAudios.removeLast(),
                loadPool,
              );
              convertedAudioCount++;
              if (convertedAudioCount % objectBatchSize == 0) {
                await Future<void>.delayed(Duration.zero);
              }
            }
          }
          folders.add(
            AudioFolder(
              audios,
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
        final rssAfterConversion = ProcessInfo.currentRss;

        final installMetrics = await _installLoadedFolders(
          folders,
          pageCacheSourcePath: indexPath,
          pageCachePath: pageCachePath,
          objectBatchSize: objectBatchSize,
        );
        logger.i(
          '[perf] library sqlite total=${stopwatch.elapsedMilliseconds}ms '
          'read=${sqliteReadStopwatch.elapsedMilliseconds}ms '
          'convert=${conversionStopwatch.elapsedMilliseconds}ms '
          'collections=${installMetrics.collectionsMilliseconds}ms '
          'pages=${installMetrics.pagePreparationMilliseconds}ms '
          'batch=$objectBatchSize '
          'audios=${instance.audioCollection.length} '
          'pooledTexts=$pooledTextCount '
          'pooledArtistLists=$pooledArtistListCount '
          'rssRead=${_rssMegabytes(rssAfterRead)}MB '
          'rssConvert=${_rssMegabytes(rssAfterConversion)}MB',
        );
        libraryVersion.value++;
        instance._publishArtistAlbumVersionIfReady(
          instance._collectionGeneration,
        );
        return;
      } catch (err, trace) {
        logger.w('SQLite 曲库读取失败，回退到 JSON 索引', error: err, stackTrace: trace);
      }

      final jsonReadStopwatch = Stopwatch()..start();
      var indexStr = await File(indexPath).readAsString();
      jsonReadStopwatch.stop();
      final jsonDecodeStopwatch = Stopwatch()..start();
      final Map indexJson = json.decode(indexStr);
      indexStr = '';
      jsonDecodeStopwatch.stop();
      final rssAfterDecode = ProcessInfo.currentRss;
      final conversionStopwatch = Stopwatch()..start();
      final List foldersJson = indexJson['folders'];
      final List<AudioFolder> folders = [];
      final loadPool = _AudioLoadPool(AppSettings.instance.artistSplitRegex);
      var convertedAudioCount = 0;

      for (Map folderMap in foldersJson) {
        final List audiosJson = folderMap['audios'];
        final audioCount = audiosJson.length;
        final List<Audio> audios;
        if (audioCount == 0) {
          audios = <Audio>[];
        } else {
          final lastIndex = audioCount - 1;
          final lastAudio = _audioFromMap(
            audiosJson.removeLast() as Map,
            loadPool,
          );
          audios = List<Audio>.filled(audioCount, lastAudio, growable: false);
          convertedAudioCount++;
          if (convertedAudioCount % objectBatchSize == 0) {
            await Future<void>.delayed(Duration.zero);
          }
          for (var index = lastIndex - 1; index >= 0; index--) {
            audios[index] = _audioFromMap(
              audiosJson.removeLast() as Map,
              loadPool,
            );
            convertedAudioCount++;
            if (convertedAudioCount % objectBatchSize == 0) {
              await Future<void>.delayed(Duration.zero);
            }
          }
        }
        folders.add(AudioFolder.fromMap(folderMap, audios));
        folderMap.clear();
      }
      final pooledTextCount = loadPool.textCount;
      final pooledArtistListCount = loadPool.artistListCount;
      loadPool.release();
      foldersJson.clear();
      indexJson.clear();
      conversionStopwatch.stop();
      final rssAfterConversion = ProcessInfo.currentRss;

      final installMetrics = await _installLoadedFolders(
        folders,
        pageCacheSourcePath: indexPath,
        pageCachePath: pageCachePath,
        objectBatchSize: objectBatchSize,
      );
      logger.i(
        '[perf] library json total=${stopwatch.elapsedMilliseconds}ms '
        'read=${jsonReadStopwatch.elapsedMilliseconds}ms '
        'decode=${jsonDecodeStopwatch.elapsedMilliseconds}ms '
        'convert=${conversionStopwatch.elapsedMilliseconds}ms '
        'collections=${installMetrics.collectionsMilliseconds}ms '
        'pages=${installMetrics.pagePreparationMilliseconds}ms '
        'batch=$objectBatchSize '
        'audios=${instance.audioCollection.length} '
        'pooledTexts=$pooledTextCount '
        'pooledArtistLists=$pooledArtistListCount '
        'rssDecode=${_rssMegabytes(rssAfterDecode)}MB '
        'rssConvert=${_rssMegabytes(rssAfterConversion)}MB',
      );
      libraryVersion.value++;
      instance._publishArtistAlbumVersionIfReady(
        instance._collectionGeneration,
      );
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
    }
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
    _activePageOrderCacheSpec = null;
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

    var album = albumCollection[audio.album];
    if (album == null) {
      album = Album(name: audio.album);
      albumCollection[audio.album] = album;
    }
    album._collectionGeneration = state.generation;
    album.works.add(audio);

    for (final artistName in audio.splitedArtists) {
      final artist = _resolveArtist(artistName, state.generation);
      artist.works.add(audio);
      if (artist.albumsMap[audio.album] == null) {
        artist.albumsMap[audio.album] = album;
      }
    }
    for (final artistName in audio.splitedAlbumArtists) {
      if (audio.splitedArtists.contains(artistName)) continue;
      final artist = _resolveArtist(artistName, state.generation);
      artist.works.add(audio);
      if (artist.albumsMap[audio.album] == null) {
        artist.albumsMap[audio.album] = album;
      }
    }

    final albumArtistNames = audio.splitedAlbumArtists;
    if (albumArtistNames.isNotEmpty) {
      if (state.albumsUsingAlbumArtists.add(album)) {
        album.artistsMap.clear();
      }
      for (final artistName in albumArtistNames) {
        final artist = artistCollection[artistName];
        if (artist != null && album.artistsMap[artistName] == null) {
          album.artistsMap[artistName] = artist;
        }
      }
    } else if (!state.albumsUsingAlbumArtists.contains(album)) {
      for (final artistName in audio.splitedArtists) {
        final artist = artistCollection[artistName];
        if (artist != null && album.artistsMap[artistName] == null) {
          album.artistsMap[artistName] = artist;
        }
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
        prepared.sortMethod != preference.sortMethod.clamp(0, 4).toInt() ||
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
      'excludedFolders': excluded,
    });
  }

  Future<_PageOrderCacheSpec?> _resolvePageOrderCacheSpec({
    required String sourcePath,
    required String cachePath,
  }) async {
    final signature = await LibraryPageOrderCache.sourceSignature(sourcePath);
    if (signature == null) return null;
    return _PageOrderCacheSpec(
      sourcePath: sourcePath,
      cachePath: cachePath,
      sourceSignature: signature,
      context: _pageOrderCacheContext(),
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
        preference.sortMethod.clamp(0, 4).toInt() != sortMethod ||
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
  _restorePreferredPageSnapshots(_PageOrderCacheSpec spec) async {
    final stopwatch = Stopwatch()..start();
    final generation = _collectionGeneration;
    final cached = await LibraryPageOrderCache.read(
      cachePath: spec.cachePath,
      sourceSignature: spec.sourceSignature,
      context: spec.context,
      audioCount: audioCollection.length,
      artistCount: artistCollection.length,
      albumCount: albumCollection.length,
    );
    if (cached == null ||
        generation != _collectionGeneration ||
        spec.context != _pageOrderCacheContext()) {
      logger.i(
        '[perf] page order cache miss elapsed=${stopwatch.elapsedMilliseconds}ms',
      );
      return (audios: false, artists: false, albums: false);
    }

    var restoredAudios = false;
    var restoredArtists = false;
    var restoredAlbums = false;
    final audioPreference = AppPreference.instance.audiosPagePref;
    if (_cachedPageMatches(cached.audios, audioPreference, 4)) {
      restoredAudios = await _installPreparedAudioOrder(
        source: audioCollection,
        indexes: cached.audios.indexes,
        sortMethod: cached.audios.sortMethod,
        sortOrder: SortOrder.values[cached.audios.sortOrderIndex],
        generation: generation,
      );
    }
    final artistPreference = AppPreference.instance.artistsPagePref;
    if (generation == _collectionGeneration &&
        _cachedPageMatches(cached.artists, artistPreference, 1)) {
      final artists = artistCollection.values.toList(growable: false);
      final preparedArtists = await _materializeSortedItems(
        artists,
        cached.artists.indexes,
      );
      if (generation == _collectionGeneration) {
        final currentPreference = AppPreference.instance.artistsPagePref;
        if (currentPreference.sortMethod.clamp(0, 1).toInt() ==
                cached.artists.sortMethod &&
            currentPreference.sortOrder.index ==
                cached.artists.sortOrderIndex) {
          _preparedArtistsPage = PreparedLibraryPage(
            items: preparedArtists,
            sortMethod: cached.artists.sortMethod,
            sortOrder: SortOrder.values[cached.artists.sortOrderIndex],
          );
          restoredArtists = true;
        }
      }
    }
    final albumPreference = AppPreference.instance.albumsPagePref;
    if (generation == _collectionGeneration &&
        _cachedPageMatches(cached.albums, albumPreference, 1)) {
      final albums = albumCollection.values.toList(growable: false);
      final preparedAlbums = await _materializeSortedItems(
        albums,
        cached.albums.indexes,
      );
      if (generation == _collectionGeneration) {
        final currentPreference = AppPreference.instance.albumsPagePref;
        if (currentPreference.sortMethod.clamp(0, 1).toInt() ==
                cached.albums.sortMethod &&
            currentPreference.sortOrder.index == cached.albums.sortOrderIndex) {
          _preparedAlbumsPage = PreparedLibraryPage(
            items: preparedAlbums,
            sortMethod: cached.albums.sortMethod,
            sortOrder: SortOrder.values[cached.albums.sortOrderIndex],
          );
          restoredAlbums = true;
        }
      }
    }
    stopwatch.stop();
    logger.i(
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

  Future<bool> preparePreferredPageSnapshotsUsingCache({
    required String sourcePath,
    required String cachePath,
    bool initialLoad = true,
  }) async {
    final spec = await _resolvePageOrderCacheSpec(
      sourcePath: sourcePath,
      cachePath: cachePath,
    );
    _activePageOrderCacheSpec = spec;
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
    required _PageOrderCacheSpec? cacheSpec,
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
    while (true) {
      final pending = _pageOrderCacheWrite;
      if (pending == null) return;
      await pending;
      if (identical(_pageOrderCacheWrite, pending)) return;
    }
  }

  Future<void> _prepareSecondaryPagesAndCache(_PageOrderCacheSpec? spec) async {
    final generation = _collectionGeneration;
    try {
      final delay = deferredSecondaryPagePreparationDelayFor(
        processorBudget: applicationProcessorBudget,
        hasPlaybackSession: PlayService.hasInitializedPlaybackSession,
      );
      if (delay > Duration.zero) {
        logger.i(
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
      logger.w('后台页面顺序准备失败', error: error, stackTrace: trace);
    }
  }

  void _schedulePageOrderCacheWrite(_PageOrderCacheSpec spec) {
    final generation = _collectionGeneration;
    final request = ++_pageOrderCacheWriteRequest;
    final previous = _pageOrderCacheWrite;
    late final Future<void> future;
    future = () async {
      await Future<void>.delayed(Duration.zero);
      try {
        if (previous != null) await previous;
        bool isCurrentRequest() =>
            request == _pageOrderCacheWriteRequest &&
            generation == _collectionGeneration;
        if (!isCurrentRequest() || spec.context != _pageOrderCacheContext()) {
          return;
        }
        final sourceSignature = await LibraryPageOrderCache.sourceSignature(
          spec.sourcePath,
        );
        if (!isCurrentRequest() || sourceSignature != spec.sourceSignature) {
          return;
        }
        final audios = preparedAudiosPage;
        final artists = preparedArtistsPage;
        final albums = preparedAlbumsPage;
        if (audios == null || artists == null || albums == null) return;
        final audioIndexes = await _pageIndexes(
          audios.items,
          (audio) => audio._libraryIndex,
          isCurrentRequest,
        );
        if (audioIndexes == null) return;
        final artistIndexes = await _pageIndexes(
          artists.items,
          (artist) => artist._libraryIndex,
          isCurrentRequest,
        );
        if (artistIndexes == null) return;
        final albumIndexes = await _pageIndexes(
          albums.items,
          (album) => album._libraryIndex,
          isCurrentRequest,
        );
        if (albumIndexes == null) return;
        final orders = LibraryPageOrders(
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
        await LibraryPageOrderCache.write(
          cachePath: spec.cachePath,
          orders: orders,
        );
      } catch (error, trace) {
        logger.w('页面顺序缓存写入失败', error: error, stackTrace: trace);
      } finally {
        if (identical(_pageOrderCacheWrite, future)) {
          _pageOrderCacheWrite = null;
        }
      }
    }();
    _pageOrderCacheWrite = future;
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
    final sortMethod = preference.sortMethod.clamp(0, 4).toInt();
    final sortOrder = preference.sortOrder;
    final descending = sortOrder == SortOrder.decending;
    final naturalValues = switch (sortMethod) {
      0 => audios.map((audio) => audio.title).toList(growable: false),
      1 => audios.map((audio) => audio.artist).toList(growable: false),
      2 => audios.map((audio) => audio.album).toList(growable: false),
      _ => null,
    };
    final integerValues = switch (sortMethod) {
      3 => audios.map((audio) => audio.created).toList(growable: false),
      4 => audios.map((audio) => audio.modified).toList(growable: false),
      _ => null,
    };
    final audioCount = audios.length;
    final order = await Isolate.run(
      () => _sortLibraryPageIndexes(
        length: audioCount,
        naturalValues: naturalValues,
        integerValues: integerValues,
        descending: descending,
        reuseEqualKeys: sortMethod == 1 || sortMethod == 2,
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
        sortMethod: sortMethod.clamp(0, 4).toInt(),
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
    final cacheSpec = _activePageOrderCacheSpec;
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
    final prepareArtists = preparedArtistsPage == null;
    final prepareAlbums = preparedAlbumsPage == null;
    if (!prepareArtists && !prepareAlbums) return;
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
    final artistDescending = artistSortOrder == SortOrder.decending;
    final albumDescending = albumSortOrder == SortOrder.decending;
    final artistNaturalValues = prepareArtists && artistSortMethod == 0
        ? artists.map((artist) => artist.name).toList(growable: false)
        : null;
    final artistIntegerValues = prepareArtists && artistSortMethod == 1
        ? artists.map((artist) => artist.works.length).toList(growable: false)
        : null;
    final albumNaturalValues = prepareAlbums && albumSortMethod == 0
        ? albums.map((album) => album.name).toList(growable: false)
        : null;
    final albumIntegerValues = prepareAlbums && albumSortMethod == 1
        ? albums.map((album) => album.works.length).toList(growable: false)
        : null;
    final artistCount = artists.length;
    final albumCount = albums.length;
    Uint32List? artistOrder;
    Uint32List? albumOrder;
    if (prepareArtists && prepareAlbums && concurrency >= 2) {
      final orders = await Future.wait<Uint32List>([
        Isolate.run(
          () => _sortLibraryPageIndexes(
            length: artistCount,
            naturalValues: artistNaturalValues,
            integerValues: artistIntegerValues,
            descending: artistDescending,
          ),
        ),
        Isolate.run(
          () => _sortLibraryPageIndexes(
            length: albumCount,
            naturalValues: albumNaturalValues,
            integerValues: albumIntegerValues,
            descending: albumDescending,
          ),
        ),
      ]);
      artistOrder = orders[0];
      albumOrder = orders[1];
    } else if (prepareArtists && prepareAlbums) {
      await _prepareSecondaryPageSnapshotsSerially(
        generation: generation,
        artists: artists,
        albums: albums,
        artistNaturalValues: artistNaturalValues,
        artistIntegerValues: artistIntegerValues,
        artistSortMethod: artistSortMethod,
        artistSortOrder: artistSortOrder,
        artistDescending: artistDescending,
        albumNaturalValues: albumNaturalValues,
        albumIntegerValues: albumIntegerValues,
        albumSortMethod: albumSortMethod,
        albumSortOrder: albumSortOrder,
        albumDescending: albumDescending,
      );
      return;
    } else if (prepareArtists) {
      artistOrder = await Isolate.run(
        () => _sortLibraryPageIndexes(
          length: artistCount,
          naturalValues: artistNaturalValues,
          integerValues: artistIntegerValues,
          descending: artistDescending,
        ),
      );
    } else {
      albumOrder = await Isolate.run(
        () => _sortLibraryPageIndexes(
          length: albumCount,
          naturalValues: albumNaturalValues,
          integerValues: albumIntegerValues,
          descending: albumDescending,
        ),
      );
    }
    final preparedArtists = artistOrder == null
        ? null
        : await _materializeSortedItems(artists, artistOrder);
    final preparedAlbums = albumOrder == null
        ? null
        : await _materializeSortedItems(albums, albumOrder);
    if (generation != _collectionGeneration) return;
    final currentArtistPreference = AppPreference.instance.artistsPagePref;
    if (preparedArtists != null &&
        currentArtistPreference.sortMethod.clamp(0, 1).toInt() ==
            artistSortMethod &&
        currentArtistPreference.sortOrder == artistSortOrder) {
      _preparedArtistsPage = PreparedLibraryPage(
        items: preparedArtists,
        sortMethod: artistSortMethod,
        sortOrder: artistSortOrder,
      );
      _publishArtistPageVersion(generation);
    }
    final currentAlbumPreference = AppPreference.instance.albumsPagePref;
    if (preparedAlbums != null &&
        currentAlbumPreference.sortMethod.clamp(0, 1).toInt() ==
            albumSortMethod &&
        currentAlbumPreference.sortOrder == albumSortOrder) {
      _preparedAlbumsPage = PreparedLibraryPage(
        items: preparedAlbums,
        sortMethod: albumSortMethod,
        sortOrder: albumSortOrder,
      );
      _publishAlbumPageVersion(generation);
    }
  }

  Future<void> _prepareSecondaryPageSnapshotsSerially({
    required int generation,
    required List<Artist> artists,
    required List<Album> albums,
    required List<String>? artistNaturalValues,
    required List<int>? artistIntegerValues,
    required int artistSortMethod,
    required SortOrder artistSortOrder,
    required bool artistDescending,
    required List<String>? albumNaturalValues,
    required List<int>? albumIntegerValues,
    required int albumSortMethod,
    required SortOrder albumSortOrder,
    required bool albumDescending,
  }) async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(_sortSecondaryPageIndexes, (
      sendPort: receivePort.sendPort,
      artistCount: artists.length,
      artistNaturalValues: artistNaturalValues,
      artistIntegerValues: artistIntegerValues,
      artistDescending: artistDescending,
      albumCount: albums.length,
      albumNaturalValues: albumNaturalValues,
      albumIntegerValues: albumIntegerValues,
      albumDescending: albumDescending,
    ));
    try {
      messageLoop:
      await for (final rawMessage in receivePort) {
        if (generation != _collectionGeneration) break messageLoop;
        final message = rawMessage as List<Object?>;
        switch (message.first as int) {
          case 0:
            if (preparedArtistsPage != null) continue messageLoop;
            final order = _materializeTransferredPageOrder(
              message[1]! as TransferableTypedData,
            );
            final items = await _materializeSortedItems(artists, order);
            final preference = AppPreference.instance.artistsPagePref;
            if (generation == _collectionGeneration &&
                preparedArtistsPage == null &&
                preference.sortMethod.clamp(0, 1).toInt() == artistSortMethod &&
                preference.sortOrder == artistSortOrder) {
              _preparedArtistsPage = PreparedLibraryPage(
                items: items,
                sortMethod: artistSortMethod,
                sortOrder: artistSortOrder,
              );
              _publishArtistPageVersion(generation);
            }
          case 1:
            if (preparedAlbumsPage != null) continue messageLoop;
            final order = _materializeTransferredPageOrder(
              message[1]! as TransferableTypedData,
            );
            final items = await _materializeSortedItems(albums, order);
            final preference = AppPreference.instance.albumsPagePref;
            if (generation == _collectionGeneration &&
                preparedAlbumsPage == null &&
                preference.sortMethod.clamp(0, 1).toInt() == albumSortMethod &&
                preference.sortOrder == albumSortOrder) {
              _preparedAlbumsPage = PreparedLibraryPage(
                items: items,
                sortMethod: albumSortMethod,
                sortOrder: albumSortOrder,
              );
              _publishAlbumPageVersion(generation);
            }
          case 2:
            break messageLoop;
          case 3:
            throw StateError(
              'Secondary page sort failed: ${message[1]}\n${message[2]}',
            );
        }
      }
    } finally {
      receivePort.close();
      isolate.kill(priority: Isolate.immediate);
    }
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
    audio.splitedArtists = Audio._splitAndDedup(
      audio.artist,
      AppSettings.instance.artistSplitRegex,
    );
    audio.splitedAlbumArtists = Audio._splitAndDedup(
      audio.albumArtist ?? '',
      AppSettings.instance.artistSplitRegex,
    );
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
    final excluded = AppPreference.instance.excludedFolderPaths;
    final excludedKeys = _folderPathKeySet(excluded);
    final includedRefreshedFolders = excludedKeys.isEmpty
        ? refreshedFolders
        : refreshedFolders
              .where((folder) {
                final key = folder._pathLookupKey;
                return key.isEmpty || !excludedKeys.contains(key);
              })
              .toList(growable: false);
    if (folders.isEmpty) {
      folders = includedRefreshedFolders;
      _buildCollections();
      return;
    }

    final existingFolders = <String, AudioFolder>{};
    for (final folder in folders) {
      existingFolders[folder._pathLookupKey] = folder;
    }

    var collectionsChanged = includedRefreshedFolders.length != folders.length;
    final mergedFolders = <AudioFolder>[];
    Map<String, Audio>? fallbackAudios;
    var fallbackAudiosBuilt = false;
    Audio? resolveExistingAudio(String key) {
      final indexed = _audioByPath[key];
      if (indexed != null || _audioByPath.isNotEmpty) return indexed;
      if (!fallbackAudiosBuilt) {
        fallbackAudiosBuilt = true;
        fallbackAudios = <String, Audio>{};
        for (final folder in folders) {
          for (final audio in folder.audios) {
            fallbackAudios![_audioPathLookupKey(audio.path)] = audio;
          }
        }
      }
      return fallbackAudios![key];
    }

    for (
      var folderIndex = 0;
      folderIndex < includedRefreshedFolders.length;
      folderIndex++
    ) {
      final refreshedFolder = includedRefreshedFolders[folderIndex];
      final folderKey = refreshedFolder._pathLookupKey;
      final existingFolder = existingFolders[folderKey];
      if (existingFolder == null ||
          folderIndex >= folders.length ||
          folders[folderIndex]._pathLookupKey != folderKey) {
        collectionsChanged = true;
      }
      final existingAudios = existingFolder?.audios;
      if (existingAudios == null ||
          existingAudios.length != refreshedFolder.audios.length) {
        collectionsChanged = true;
      }

      final refreshedAudios = refreshedFolder.audios;
      var canReuseExistingAudios =
          existingFolder != null &&
          existingAudios != null &&
          existingAudios.length == refreshedAudios.length;
      List<Audio>? mergedAudios;
      void ensureMergedAudios() {
        if (mergedAudios != null) return;
        if (refreshedAudios.isEmpty) {
          mergedAudios = <Audio>[];
          return;
        }
        mergedAudios = List<Audio>.filled(
          refreshedAudios.length,
          refreshedAudios.first,
          growable: false,
        );
        if (existingAudios == null) return;
        final copyCount = existingAudios.length < mergedAudios!.length
            ? existingAudios.length
            : mergedAudios!.length;
        for (var index = 0; index < copyCount; index++) {
          mergedAudios![index] = existingAudios[index];
        }
      }

      for (
        var audioIndex = 0;
        audioIndex < refreshedAudios.length;
        audioIndex++
      ) {
        final refreshedAudio = refreshedAudios[audioIndex];
        final refreshedPathKey = _audioPathLookupKey(refreshedAudio.path);
        final existing = resolveExistingAudio(refreshedPathKey);
        if (existing == null) {
          collectionsChanged = true;
          canReuseExistingAudios = false;
          ensureMergedAudios();
          refreshedAudio._pathLookupKeyCache = refreshedPathKey;
          mergedAudios![audioIndex] = refreshedAudio;
        } else {
          final metadataMatches = existing._metadataMatches(refreshedAudio);
          final sameAudioSlot =
              existingAudios != null &&
              audioIndex < existingAudios.length &&
              existingAudios[audioIndex]._pathLookupKey == refreshedPathKey;
          final collectionMetadataMatches = existing._collectionMetadataMatches(
            refreshedAudio,
          );
          if (!sameAudioSlot || !collectionMetadataMatches) {
            collectionsChanged = true;
          }
          if (!sameAudioSlot) {
            canReuseExistingAudios = false;
            ensureMergedAudios();
          }
          if (!metadataMatches) {
            if (existing.path != refreshedAudio.path) {
              refreshedAudio._pathLookupKeyCache = refreshedPathKey;
            }
            existing._replaceMetadataFrom(refreshedAudio);
          }
          if (!canReuseExistingAudios) {
            ensureMergedAudios();
            mergedAudios![audioIndex] = existing;
          }
        }
      }

      if (!canReuseExistingAudios) ensureMergedAudios();
      final resolvedAudios = canReuseExistingAudios
          ? existingAudios!
          : mergedAudios!;
      if (existingFolder == null) {
        refreshedFolder.audios = resolvedAudios;
        mergedFolders.add(refreshedFolder);
      } else {
        existingFolder
          ..audios = resolvedAudios
          ..path = refreshedFolder.path
          ..modified = refreshedFolder.modified
          ..latest = refreshedFolder.latest;
        mergedFolders.add(existingFolder);
      }
    }

    if (_audioByPath.isEmpty && fallbackAudiosBuilt) {
      _audioByPath.addAll(fallbackAudios!);
    }
    folders = mergedFolders;
    if (collectionsChanged) {
      _buildCollections();
    } else {
      logger.i(
        '[perf] library collections rebuild=skipped '
        'collectionMetadataOnly=true',
      );
    }
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
      logger.i('[mem] evicted $evicted cold cover caches');
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
      logger.i('[mem] evicted $evicted covers on song change');
    }
  }

  /// 完全释放数据库资源
  void dispose() {
    _collectionGeneration++;
    _preparedAudiosPage = null;
    _preparedArtistsPage = null;
    _preparedAlbumsPage = null;
    _activePageOrderCacheSpec = null;
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
    // 从 instance.folders 反推出根目录（没有其他文件夹是它的父目录）
    List<({String path, String key})> inferRoots() {
      final keys = library.folders
          .map((folder) => folder._pathLookupKey)
          .toList(growable: false);
      final keySet = keys.toSet();
      final roots = <int>[];
      for (var i = 0; i < keys.length; i++) {
        var isChild = false;
        var ancestor = keys[i];
        while (true) {
          final separator = ancestor.lastIndexOf('/');
          if (separator <= 0) break;
          ancestor = ancestor.substring(0, separator);
          if (keySet.contains(ancestor)) {
            isChild = true;
            break;
          }
        }
        if (!isChild) roots.add(i);
      }
      return roots
          .map((i) => (path: library.folders[i].path, key: keys[i]))
          .toList(growable: false);
    }

    final List<({String path, String key})> targetRoots = userFolders.isNotEmpty
        ? userFolders
              .map((path) => (path: path, key: pendingFolderKey(path)))
              .toList(growable: false)
        : inferRoots();
    if (targetRoots.isEmpty) {
      return library._cacheAggregatedRootFolders(
        List<AudioFolder>.of(library.folders),
        userFolders,
      );
    }

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
    for (final folder in library.folders) {
      final folderKey = folder._pathLookupKey;
      var ancestor = folderKey;
      while (true) {
        final indexes = rootIndexes[ancestor];
        if (indexes != null) {
          for (final index in indexes) {
            sourceFolders[index].add(folder);
            audioCounts[index] += folder.audios.length;
            if (ancestor == folderKey) {
              matchingFolders[index] = folder;
            }
          }
        }
        final separator = ancestor.lastIndexOf('/');
        if (separator <= 0) break;
        ancestor = ancestor.substring(0, separator);
      }
    }

    List<Audio> aggregateAudios(int rootIndex) {
      final sources = sourceFolders[rootIndex];
      final audioCount = audioCounts[rootIndex];
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
      final result = List<Audio>.filled(
        audioCount,
        firstAudio,
        growable: false,
      );
      var offset = 0;
      for (final source in sources) {
        final audios = source.audios;
        result.setRange(offset, offset + audios.length, audios);
        offset += audios.length;
      }
      return result;
    }

    final result = <AudioFolder>[];
    for (var i = 0; i < targetRoots.length; i++) {
      final matchingFolder = matchingFolders[i];
      final rootPath = targetRoots[i].path;
      final resolvedPath = matchingFolder?.path ?? rootPath;
      result.add(
        AudioFolder(
          aggregateAudios(i),
          resolvedPath,
          matchingFolder?.modified ?? 0,
          matchingFolder?.latest ?? 0,
          _aliasFor(resolvedPath),
        ),
      );
    }
    return library._cacheAggregatedRootFolders(result, userFolders);
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

  /// split + trim + 去空 + 去重（保持首次出现顺序）
  static List<String> _splitAndDedup(String raw, RegExp regex) {
    if (raw.isEmpty) return const [];
    if (regex.firstMatch(raw) == null) {
      final trimmed = raw.trim();
      return trimmed.isEmpty ? const [] : [trimmed];
    }
    final seen = <String>{};
    final result = <String>[];
    for (final part in raw.split(regex)) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      if (seen.add(trimmed)) {
        result.add(trimmed);
      }
    }
    return result;
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
  }) : splitedArtists = _splitAndDedup(
         artist,
         AppSettings.instance.artistSplitRegex,
       ),
       splitedAlbumArtists = _splitAndDedup(
         albumArtist ?? '',
         AppSettings.instance.artistSplitRegex,
       );

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
    );
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
    title = other.title;
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
