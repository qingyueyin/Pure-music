import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as library_db;
import 'package:pure_music/native/rust/api/tag_reader.dart';
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

/// from index.json
class AudioLibrary {
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

  /// must call [initFromIndex]
  static AudioLibrary get instance {
    _instance ??= AudioLibrary._([]);
    return _instance!;
  }

  static AudioLibrary? _instance;

  /// Incremented on every initFromIndex call to notify pages
  /// (e.g. AudiosPage) that library content has changed.
  static final libraryVersion = ValueNotifier<int>(0);

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
      CoverImageCache.instance.clear();
      PaintingBinding.instance.imageCache.clear();
      final supportPath = (await getAppDataDir()).path;
      final indexPath = p.join(supportPath, 'index.json');
      final sqlitePath = p.join(supportPath, 'library.sqlite');

      if (!File(sqlitePath).existsSync() && File(indexPath).existsSync()) {
        try {
          await library_db.migrateIndexJsonToSqlite(indexPath: supportPath);
        } catch (err, trace) {
          logger.e(err, stackTrace: trace);
        }
      }

      try {
        final dbFolders =
            await library_db.readIndexFromSqlite(indexPath: supportPath);
        final folders = <AudioFolder>[];
        for (final folder in dbFolders) {
          final audios = <Audio>[];
          for (final audio in folder.audios) {
            audios.add(Audio.fromMap({
              'title': audio.title,
              'artist': audio.artist,
              'album': audio.album,
              'album_artist': audio.albumArtist,
              'track': audio.track,
              'duration': audio.duration.toInt(),
              'bitrate': audio.bitrate,
              'sample_rate': audio.sampleRate,
              'path': audio.path,
              'modified': audio.modified.toInt(),
              'created': audio.created.toInt(),
              'by': audio.by,
              'play_count': audio.playCount,
            }));
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

        _instance = AudioLibrary._(folders);
        instance._filterExcludedFolders();
        instance.artistCollection.clear();
        instance.albumCollection.clear();
        instance._buildCollections();
        instance._startCoverBytesEviction();
        logger.i(
          'AudioLibrary init from sqlite: ${stopwatch.elapsedMilliseconds}ms, audios=${instance.audioCollection.length}',
        );
        libraryVersion.value++;
        return;
      } catch (_) {}

      final indexStr = await File(indexPath).readAsString();
      final Map indexJson = json.decode(indexStr);
      final List foldersJson = indexJson['folders'];
      final List<AudioFolder> folders = [];

      for (Map folderMap in foldersJson) {
        final List audiosJson = folderMap['audios'];
        final List<Audio> audios = [];
        for (Map audioMap in audiosJson) {
          audios.add(Audio.fromMap(audioMap));
        }
        folders.add(AudioFolder.fromMap(folderMap, audios));
      }

      _instance = AudioLibrary._(folders);
      instance._filterExcludedFolders();

      instance.artistCollection.clear();
      instance.albumCollection.clear();
      instance._buildCollections();
      instance._startCoverBytesEviction();
      logger.i(
        'AudioLibrary init from json: ${stopwatch.elapsedMilliseconds}ms, audios=${instance.audioCollection.length}',
      );
      libraryVersion.value++;
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
    }
  }

  void _filterExcludedFolders() {
    final excluded = AppPreference.instance.excludedFolderPaths;
    if (excluded.isNotEmpty) {
      folders.removeWhere(
        (f) => isFolderPathExcluded(
          excludedPaths: excluded,
          folderPath: f.path,
        ),
      );
    }
  }

  void _buildCollections() {
    audioCollection.clear();
    _audioByPath.clear();
    artistCollection.clear();
    albumCollection.clear();

    for (var f in folders) {
      audioCollection.addAll(f.audios);
    }

    for (Audio audio in audioCollection) {
      final pathKey = _audioPathLookupKey(audio.path);
      if (pathKey.isNotEmpty) {
        _audioByPath.putIfAbsent(pathKey, () => audio);
      }

      final artistNames = <String>{
        ...audio.splitedArtists,
        ...audio.splitedAlbumArtists,
      };
      for (String artistName in artistNames) {
        /// 如果artistCollection中有artistName指向的artist，putIfAbsent会返回该artist。
        /// 随后往这个artist里添加该audio。
        ///
        /// 如果没有，创建一个名字为artistName的空艺术家，并将artistName与之相连。
        /// 随后往这个artist里添加该audio。
        artistCollection
            .putIfAbsent(artistName, () => Artist(name: artistName))
            .works
            .add(audio);
      }

      /// 如果albumCollection中有audio.album指向的album，putIfAbsent会返回该album。
      /// 随后往这个album里添加该audio。
      ///
      /// 如果没有，创建一个名字为audio.album的空专辑，并将audio.album与之相连。
      /// 随后往这个album里添加该audio。
      albumCollection
          .putIfAbsent(audio.album, () => Album(name: audio.album))
          .works
          .add(audio);
    }

    /// 将艺术家和专辑链接起来
    for (Artist artist in artistCollection.values) {
      for (Audio audio in artist.works) {
        artist.albumsMap.putIfAbsent(
          audio.album,
          () => albumCollection[audio.album] ?? Album(name: audio.album),
        );
      }
    }

    /// 将专辑和艺术家链接起来
    for (Album album in albumCollection.values) {
      final albumArtistNames = <String>{};
      for (Audio audio in album.works) {
        albumArtistNames.addAll(audio.splitedAlbumArtists);
      }

      final namesToUse = albumArtistNames.isNotEmpty
          ? albumArtistNames
          : album.works.expand((a) => a.splitedArtists).toSet();

      for (String artistName in namesToUse) {
        final artist = artistCollection[artistName];
        if (artist == null) continue;
        album.artistsMap.putIfAbsent(artistName, () => artist);
      }
    }
  }

  Audio? audioByPath(String path) {
    final key = _audioPathLookupKey(path);
    if (key.isEmpty) return null;
    return _audioByPath[key];
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

  /// 定时清理 Audio 实例中的原始 cover bytes。
  /// 大曲库下 _coverBytes 会占用大量内存，周期性释放可减少内存压力。
  /// Cover 仍可通过 CoverImageCache 重新获取。
  Timer? _coverBytesEvictionTimer;

  void _startCoverBytesEviction() {
    _coverBytesEvictionTimer?.cancel();
    // 每 2 分钟清理非活跃 Audio 的封面缓存，防止浏览大量歌曲后
    // MemoryImage / Uint8List 在 Dart 堆上堆积。
    _coverBytesEvictionTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => evictStaleCoverBytes(),
    );
  }

  /// 只清理一段时间内未被访问过的"冷"封面，保护当前播放歌曲
  void evictStaleCoverBytes() {
    final now = DateTime.now().millisecondsSinceEpoch;
    const coldMs = 2 * 60 * 1000;
    final playingPath = PlayService.instance.playbackService.nowPlaying?.path;
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
        continue;
      }
      if (audio.path == playingPath) continue;
      if (now - audio._coverLastAccessMs < coldMs) continue;
      audio.evictCoverCache();
      evicted++;
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
    _coverBytesEvictionTimer?.cancel();
    _coverBytesEvictionTimer = null;
    _smallCoverOrder.clear();
    _coverCachePaths.clear();
    _audioByPath.clear();
    audioCollection.clear();
    artistCollection.clear();
    albumCollection.clear();
    folders.clear();
  }

  /// 只返回用户手动添加的根文件夹，每项聚合该根下所有子文件夹的音频。
  static List<AudioFolder> aggregatedRootFolders() {
    if (instance.folders.isEmpty) return [];
    final userFolders = AppPreference.instance.userFolders;
    // 从 instance.folders 反推出根目录（没有其他文件夹以它为前缀）
    List<String> inferRoots() {
      final keys = instance.folders
          .map((f) => pendingFolderKey(f.path))
          .toList();
      final roots = <int>[];
      for (var i = 0; i < keys.length; i++) {
        var isChild = false;
        for (var j = 0; j < keys.length; j++) {
          if (i == j) continue;
          if (keys[i].startsWith('${keys[j]}/')) {
            isChild = true;
            break;
          }
        }
        if (!isChild) roots.add(i);
      }
      return roots.map((i) => instance.folders[i].path).toList();
    }
    final targetRoots = userFolders.isNotEmpty ? userFolders : inferRoots();
    if (targetRoots.isEmpty) return List.from(instance.folders);

    final result = <AudioFolder>[];
    for (final rootPath in targetRoots) {
      final rootKey = pendingFolderKey(rootPath);
      AudioFolder? matchingFolder;
      final allAudios = <Audio>[];
      for (final f in instance.folders) {
        final fKey = pendingFolderKey(f.path);
        if (fKey == rootKey) matchingFolder = f;
        if (fKey == rootKey || fKey.startsWith('$rootKey/')) {
          allAudios.addAll(f.audios);
        }
      }
      if (allAudios.isEmpty) continue;
      result.add(AudioFolder(
        allAudios,
        matchingFolder?.path ?? rootPath,
        matchingFolder?.modified ?? 0,
        matchingFolder?.latest ?? 0,
      ));
    }
    return result;
  }
}

class AudioFolder {
  List<Audio> audios;

  /// absolute path
  String path;

  /// secs since UNIX EPOCH
  int modified;

  /// secs since UNIX EPOCH
  int latest;

  AudioFolder(this.audios, this.path, this.modified, this.latest);

  factory AudioFolder.fromMap(Map map, List<Audio> audios) => AudioFolder(
      audios, map['path'] ?? '', map['modified'] ?? 0, map['latest'] ?? 0);

  @override
  String toString() {
    return {
      'audios': audios.toString(),
      'path': path,
      'modified':
          DateTime.fromMillisecondsSinceEpoch(modified * 1000).toString(),
    }.toString();
  }
}

class Audio {
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

  void _touchCoverAccess() {
    _coverLastAccessMs = DateTime.now().millisecondsSinceEpoch;
  }

  /// split + trim + 去空 + 去重（保持首次出现顺序）
  static List<String> _splitAndDedup(String raw, RegExp regex) {
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
    this.playCount = 0,
  })  : splitedArtists = _splitAndDedup(
          artist,
          AppSettings.instance.artistSplitRegex,
        ),
        splitedAlbumArtists = _splitAndDedup(
          albumArtist ?? '',
          AppSettings.instance.artistSplitRegex,
        );

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
        playCount: map['play_count'] ?? 0,
      );

  Map toMap() => {
        'title': title,
        'artist': artist,
        'album': album,
        'album_artist': albumArtist,
        'track': track,
        'duration': duration,
        'bitrate': bitrate,
        'sample_rate': sampleRate,
        'path': path,
        'modified': modified,
        'created': created,
        'play_count': playCount,
        'by': by
      };

  Future<ImageProvider?> _getFolderCover({
    required int width,
    required int height,
  }) async {
    try {
      final dir = Directory(File(path).parent.path);
      final candidates = [
        File(p.join(dir.path, 'cover.jpg')),
        File(p.join(dir.path, 'cover.png')),
      ];
      for (final f in candidates) {
        if (f.existsSync()) {
          final ratio =
              PlatformDispatcher.instance.views.first.devicePixelRatio;
          return ResizeImage(
            FileImage(f),
            width: (width * ratio).round(),
            height: (height * ratio).round(),
          );
        }
      }
    } catch (_) {}
    return null;
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
  Uint8List? get smallCoverBytes => _smallCoverBytes;

  /// 异步加载小封面字节并缓存在 [_smallCoverBytes] 中
  Future<Uint8List?> loadSmallCoverBytes() async {
    if (_smallCoverBytes != null) return _smallCoverBytes;
    final generation = _coverCacheGeneration;
    try {
      final ratio = PlatformDispatcher.instance.views.first.devicePixelRatio;
      final bytes = await getPictureFromPath(
        path: path,
        width: (48 * ratio).round(),
        height: (48 * ratio).round(),
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
      'modified':
          DateTime.fromMillisecondsSinceEpoch(modified * 1000).toString(),
      'created': DateTime.fromMillisecondsSinceEpoch(created * 1000).toString(),
    }.toString();
  }
}

class Artist {
  String name;

  /// 所有专辑
  Map<String, Album> albumsMap = {};

  /// 作品
  List<Audio> works = [];

  /// 缓存 ImageProvider 实例，使用 WeakReference
  WeakReference<ImageProvider>? _pictureCache;

  String? get primaryPath => works.firstOrNull?.path;

  /// 只能用在artist detail page
  /// 200*200
  Future<ImageProvider?> get picture async {
    final cached = _pictureCache?.target;
    if (cached != null) return cached;
    if (works.isEmpty) return null;
    final data = await CoverImageCache.instance.get(
      path: works.first.path,
      width: 200,
      height: 200,
    );
    _pictureCache = data != null ? WeakReference(data) : null;
    return data;
  }

  bool evictPictureCache() {
    final pictureCache = _pictureCache?.target;
    _pictureCache = null;
    if (pictureCache == null) return false;
    unawaited(pictureCache.evict());
    return true;
  }

  /// Lightweight picture for lists/pickers. Do not retain it on the Artist;
  /// CoverImageCache already has a bounded LRU.
  Future<ImageProvider?> thumbnailPicture({int size = 48}) async {
    if (works.isEmpty) return null;
    return CoverImageCache.instance.get(
      path: works.first.path,
      width: size,
      height: size,
    );
  }

  Artist({required this.name});
}

class Album {
  String name;

  /// 参与的艺术家
  Map<String, Artist> artistsMap = {};

  /// 作品
  List<Audio> works = [];

  /// 缓存 ImageProvider 实例，使用 WeakReference
  WeakReference<ImageProvider>? _coverCache;

  String? get primaryPath => works.firstOrNull?.path;

  /// 只能用在album detail page
  /// 200*200
  Future<ImageProvider?> get cover async {
    final cached = _coverCache?.target;
    if (cached != null) return cached;
    if (works.isEmpty) return null;
    final folderCover =
        await works.first._getFolderCover(width: 200, height: 200);
    if (folderCover != null) {
      _coverCache = WeakReference(folderCover);
      return folderCover;
    }
    final data = await CoverImageCache.instance.get(
      path: works.first.path,
      width: 200,
      height: 200,
    );
    _coverCache = data != null ? WeakReference(data) : null;
    return data;
  }

  bool evictCoverCache() {
    final coverCache = _coverCache?.target;
    _coverCache = null;
    if (coverCache == null) return false;
    unawaited(coverCache.evict());
    return true;
  }

  /// Lightweight cover for lists/pickers. Do not retain it on the Album;
  /// CoverImageCache already has a bounded LRU.
  Future<ImageProvider?> thumbnailCover({int size = 48}) async {
    if (works.isEmpty) return null;
    final folderCover =
        await works.first._getFolderCover(width: size, height: size);
    if (folderCover != null) return folderCover;
    return CoverImageCache.instance.get(
      path: works.first.path,
      width: size,
      height: size,
    );
  }

  Album({required this.name});
}
