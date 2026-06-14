import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;
import 'package:path/path.dart' as p;
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as library_db;
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/painting.dart';

/// from index.json
class AudioLibrary {
  List<AudioFolder> folders;

  AudioLibrary._(this.folders);

  /// 所有音乐
  List<Audio> audioCollection = [];

  Map<String, Artist> artistCollection = {};

  Map<String, Album> albumCollection = {};

  /// 小封面字节缓存数量硬上限。
  /// 超出时按 LRU 逐出最旧的，避免大曲库快速浏览时 Uint8List 堆积。
  /// 200 × ~5KB ≈ 1MB 封顶。
  static const int _maxCachedSmallCovers = 200;

  /// 访问顺序追踪队列：最近访问的 path 在末尾，最旧的在开头。
  /// 仅用于 _smallCoverBytes 的 LRU 逐出，不涵盖 ImageProvider 缓存。
  final LinkedHashSet<String> _smallCoverOrder = LinkedHashSet<String>();

  /// must call [initFromIndex]
  static AudioLibrary get instance {
    _instance ??= AudioLibrary._([]);
    return _instance!;
  }

  static AudioLibrary? _instance;

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
        instance.artistCollection.clear();
        instance.albumCollection.clear();
        instance._buildCollections();
        instance._startCoverBytesEviction();
        logger.i(
          'AudioLibrary init from sqlite: ${stopwatch.elapsedMilliseconds}ms, audios=${instance.audioCollection.length}',
        );
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

      instance.artistCollection.clear();
      instance.albumCollection.clear();
      instance._buildCollections();
      instance._startCoverBytesEviction();
      logger.i(
        'AudioLibrary init from json: ${stopwatch.elapsedMilliseconds}ms, audios=${instance.audioCollection.length}',
      );
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
    }
  }

  void _buildCollections() {
    for (var f in folders) {
      audioCollection.addAll(f.audios);
    }

    for (Audio audio in audioCollection) {
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

  @override
  String toString() {
    return folders.toString();
  }

  /// 注册一个小封面字节缓存到追踪队列，超出上限时逐出最旧的。
  void _registerSmallCoverBytes(Audio audio) {
    _smallCoverOrder.remove(audio.path);
    _smallCoverOrder.add(audio.path);
    while (_smallCoverOrder.length > _maxCachedSmallCovers) {
      final oldest = _smallCoverOrder.first;
      _smallCoverOrder.remove(oldest);
      // 在 audioCollection 中找到对应 Audio 并逐出
      for (final a in audioCollection) {
        if (a.path == oldest) {
          a._smallCoverBytes = null;
          break;
        }
      }
    }
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
    for (final audio in audioCollection) {
      if (audio._coverImage == null &&
          audio._mediumCoverImage == null &&
          audio._largeCoverImage == null &&
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

  /// 切歌时调用：除当前播放外，全部 Audio 封面缓存立即释放
  void evictAllCoversExcept(String? playingPath) {
    int evicted = 0;
    for (final audio in audioCollection) {
      if (audio._coverImage == null &&
          audio._mediumCoverImage == null &&
          audio._largeCoverImage == null &&
          audio._smallCoverBytes == null) {
        continue;
      }
      if (audio.path == playingPath) continue;
      audio.evictCoverCache();
      evicted++;
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
    audioCollection.clear();
    artistCollection.clear();
    albumCollection.clear();
    folders.clear();
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

  /// 缓存 ImageProvider 实例，避免每次创建新实例导致 Flutter ImageCache 失效
  ImageProvider? _coverImage;
  ImageProvider? _mediumCoverImage;
  ImageProvider? _largeCoverImage;

  /// 小封面原始字节（48×48 PNG）：
  /// 列表 tile 同步检查此字段，已缓存则直接用 Image.memory 渲染，
  /// 不走 FutureBuilder，彻底避免闪烁。
  Uint8List? _smallCoverBytes;

  /// 上一次封面被访问的时间戳，用于冷数据回收
  int _coverLastAccessMs = 0;

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
    this.by,
  )   : splitedArtists = _splitAndDedup(
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
    if (_coverImage != null) return _coverImage;
    try {
      final data = await CoverImageCache.instance.get(
        path: path,
        width: 48,
        height: 48,
      );
      return _coverImage = data;
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
    try {
      final ratio = PlatformDispatcher.instance.views.first.devicePixelRatio;
      final bytes = await getPictureFromPath(
        path: path,
        width: (48 * ratio).round(),
        height: (48 * ratio).round(),
      );
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
  ImageProvider? get cachedMediumCover => _mediumCoverImage;

  /// 释放封面缓存（用于长时间不用时释放内存）
  void evictCoverCache() {
    _coverImage = null;
    _mediumCoverImage = null;
    _largeCoverImage = null;
    _smallCoverBytes = null;
    AudioLibrary.instance._smallCoverOrder.remove(path);
  }

  /// audio detail page
  /// 200 * 200
  Future<ImageProvider?> get mediumCover async {
    _touchCoverAccess();
    if (_mediumCoverImage != null) return _mediumCoverImage;
    try {
      final data = await CoverImageCache.instance.get(
        path: path,
        width: 200,
        height: 200,
      );
      return _mediumCoverImage = data;
    } catch (_) {
      return null;
    }
  }

  /// now playing
  /// size: 520 * devicePixelRatio（屏幕缩放大小）
  Future<ImageProvider?> get largeCover async {
    _touchCoverAccess();
    if (_largeCoverImage != null) return _largeCoverImage;
    try {
      final data = await CoverImageCache.instance.get(
        path: path,
        width: 520,
        height: 520,
      );
      return _largeCoverImage = data;
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

  /// 缓存 ImageProvider 实例
  ImageProvider? _pictureCache;

  /// 只能用在artist detail page
  /// 200*200
  Future<ImageProvider?> get picture async {
    if (_pictureCache != null) return _pictureCache;
    if (works.isEmpty) return null;
    return _pictureCache = await CoverImageCache.instance.get(
      path: works.first.path,
      width: 200,
      height: 200,
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

  /// 缓存 ImageProvider 实例
  ImageProvider? _coverCache;

  /// 只能用在album detail page
  /// 200*200
  Future<ImageProvider?> get cover async {
    if (_coverCache != null) return _coverCache;
    if (works.isEmpty) return null;
    final folderCover =
        await works.first._getFolderCover(width: 200, height: 200);
    if (folderCover != null) {
      return _coverCache = folderCover;
    }
    return _coverCache = await CoverImageCache.instance.get(
      path: works.first.path,
      width: 200,
      height: 200,
    );
  }

  Album({required this.name});
}
