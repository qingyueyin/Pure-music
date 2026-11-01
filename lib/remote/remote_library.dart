import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/remote/dpapi.dart';
import 'package:pure_music/remote/id3_reader.dart';
import 'package:pure_music/remote/jellyfin_client.dart';
import 'package:pure_music/remote/url_probe.dart';
import 'package:pure_music/remote/navidrome_client.dart';
import 'package:pure_music/remote/remote_client.dart';
import 'package:pure_music/remote/remote_source.dart';
import 'package:pure_music/remote/remote_store.dart';
import 'package:pure_music/remote/smb_client.dart';
import 'package:pure_music/remote/webdav_client.dart';

export 'package:pure_music/remote/remote_client.dart' show RemoteSyncCancelled;

/// Windows 的 MAX_PATH（260）对 `\\server\share\...` 同样生效：
/// 长中文文件名会被 Win32 API 直接拒掉，报 0x800700A1。
/// 加 `\\?\UNC\` 前缀走扩展长度路径，Rust 侧的 std::fs 也认这种形式。
String windowsExtendedPath(String path) {
  if (path.isEmpty || path.startsWith(r'\\?\')) return path;
  if (path.startsWith(r'\\')) return '\\\\?\\UNC\\${path.substring(2)}';
  return path;
}

/// 远程曲目的可读来源信息。`remote://<id>/<base64>` 这种内部路径对用户没有意义。
class RemoteLocation {
  const RemoteLocation({
    required this.kindLabel,
    required this.sourceName,
    required this.location,
  });

  /// Navidrome / WebDAV / SMB / 共享文件夹
  final String kindLabel;
  final String sourceName;

  /// 人类可读的路径。Navidrome 只给曲目 ID、没有文件路径，这里会是空串。
  final String location;
}

class RemoteLibrary {
  RemoteLibrary._();

  static final instance = RemoteLibrary._();

  final _store = const RemoteStore();
  final _sources = <RemoteSource>[];
  final _sourceById = <String, RemoteSource>{};
  final _tracksByPath = <String, RemoteTrack>{};
  final _tracksByLowerPath = <String, RemoteTrack>{};
  final _audioByPath = <String, Audio>{};
  final _audioByLowerPath = <String, Audio>{};
  final _passwordCache = <String, String>{};
  final _syncingSourceIds = <String>{};

  /// 同步中被删除的源：后台任务在下一个检查点主动退出。
  final _cancelledSourceIds = <String>{};
  final _clients = <RemoteSourceKind, RemoteClient>{
    RemoteSourceKind.navidrome: NavidromeClient(),
    RemoteSourceKind.webdav: WebDavClient(),
    RemoteSourceKind.smb: SmbClient(),
    RemoteSourceKind.jellyfin: JellyfinClient(),
  };

  final ValueNotifier<int> version = ValueNotifier<int>(0);

  bool _initialized = false;

  List<RemoteSource> get sources => List.unmodifiable(_sources);

  List<Audio> get audios => List.unmodifiable(_audioByPath.values);

  List<Audio> audiosForSource(String sourceId) {
    return _audioByPath.values
        .where((audio) => remoteSourceIdOf(audio.path) == sourceId)
        .toList(growable: false);
  }

  bool get isEmpty => _audioByPath.isEmpty;

  static bool isRemotePath(String path) => path.startsWith(remotePathPrefix);

  RemoteSource? sourceById(String id) => _sourceById[id];

  RemoteTrack? trackForPath(String path) {
    return _tracksByPath[path] ?? _tracksByLowerPath[path.toLowerCase()];
  }

  /// 挂在 AudioLibrary.audioByPath 上，本地路径也会先经过这里，
  /// 因此非远程路径必须立刻返回，不能做任何遍历。
  /// 能否在资源管理器里打开。SMB 源的曲目有真实的盘符 / UNC 路径，
  /// WebDAV 只是 URL、Navidrome 只有曲目 ID，都打不开。
  String? explorerPathFor(String path) {
    if (!isRemotePath(path)) return path;
    final track = trackForPath(path);
    if (track == null) return null;
    final source = _sourceById[track.sourceId];
    if (source == null) return null;
    if (source.kind != RemoteSourceKind.smb) return null;
    try {
      return _clientFor(source).playbackUrl(source, '', track.trackId);
    } catch (_) {
      return null;
    }
  }

  /// 把内部 remote:// 路径翻译成「协议 · 源名称 + 可读路径」。
  RemoteLocation? describePath(String path) {
    if (!isRemotePath(path)) return null;
    final track = trackForPath(path);
    if (track == null) return null;
    final source = _sourceById[track.sourceId];
    if (source == null) return null;
    var location = '';
    switch (source.kind) {
      case RemoteSourceKind.smb:
        try {
          location = _clientFor(
            source,
          ).playbackUrl(source, '', track.trackId);
        } catch (_) {
          location = track.trackId;
        }
      case RemoteSourceKind.webdav:
        location = _readableUrl(track.trackId);
      case RemoteSourceKind.navidrome:
      case RemoteSourceKind.jellyfin:
        // 这两类服务器的 trackId 都是不透明的曲目 ID，不暴露文件路径。
        location = '';
    }
    return RemoteLocation(
      kindLabel: source.kind.label,
      sourceName: source.name,
      location: location,
    );
  }

  /// WebDAV 的 trackId 是百分号编码的完整 URL，解码后才看得懂。
  String _readableUrl(String url) {
    try {
      return Uri.decodeFull(url);
    } catch (_) {
      return url;
    }
  }

  Audio? audioForPath(String path) {
    if (!isRemotePath(path)) return null;
    return _audioByPath[path] ?? _audioByLowerPath[path.toLowerCase()];
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    AudioLibrary.remoteAudioResolver = audioForPath;
    AudioLibrary.remoteAudiosProvider = () => audios;
    AudioLibrary.remoteFoldersProvider = _virtualFolders;
    version.addListener(_syncIntoMainLibrary);
    await reload();
    _warmUpSmbSources();
  }

  /// 每个远程源在「文件夹」视图里充当一个虚拟目录。
  List<AudioFolder> _virtualFolders() {
    final result = <AudioFolder>[];
    for (final source in _sources) {
      final tracks = audiosForSource(source.id);
      if (tracks.isEmpty) continue;
      var modified = 0;
      var latest = 0;
      for (final audio in tracks) {
        if (audio.modified > modified) modified = audio.modified;
        if (audio.created > latest) latest = audio.created;
      }
      result.add(
        AudioFolder(
          tracks,
          '$remotePathPrefix${source.id}',
          modified,
          latest,
          source.name,
          source.kind.label,
        ),
      );
    }
    return result;
  }

  /// 远程曲目变化后重建主集合。用微任务合并同一轮里的多次变化。
  bool _mainLibrarySyncScheduled = false;

  void _syncIntoMainLibrary() {
    if (_mainLibrarySyncScheduled) return;
    _mainLibrarySyncScheduled = true;
    Future<void>.microtask(() {
      _mainLibrarySyncScheduled = false;
      AudioLibrary.instance.rebuildForRemoteChange();
    });
  }

  void _warmUpSmbSources() {
    final client = _clients[RemoteSourceKind.smb];
    if (client is! SmbClient) return;
    for (final source in _sources) {
      if (source.kind != RemoteSourceKind.smb) continue;
      unawaited(client.warmUp(source, passwordFor(source)));
    }
  }

  /// reload 代次：并发的 reload 里只有最新一次的结果可以落地，
  /// 否则旧快照最后完成会把新状态（比如刚删掉的源）又盖回去。
  int _reloadGeneration = 0;

  Future<void> reload() async {
    final generation = ++_reloadGeneration;
    final sources = await _store.readSources();
    final tracks = await _store.readTracks();
    final playCounts = await _store.readPlayCounts();
    if (generation != _reloadGeneration) return;
    _sources
      ..clear()
      ..addAll(sources);
    _sourceById
      ..clear()
      ..addEntries(sources.map((source) => MapEntry(source.id, source)));
    _tracksByPath.clear();
    _tracksByLowerPath.clear();
    // 先统计每个小写键对应几个不同的精确路径：WebDAV URL 区分大小写，
    // 「Song.mp3」和「song.mp3」是两首歌，小写回退查找会张冠李戴，
    // 只对无歧义的键提供不区分大小写的回退。
    final lowerCounts = <String, int>{};
    for (final track in tracks) {
      final lower = _pathOf(track).toLowerCase();
      lowerCounts[lower] = (lowerCounts[lower] ?? 0) + 1;
    }
    for (final track in tracks) {
      final path = _pathOf(track);
      _tracksByPath[path] = track;
      if (lowerCounts[path.toLowerCase()] == 1) {
        _tracksByLowerPath[path.toLowerCase()] = track;
      }
    }
    _audioByPath.clear();
    _audioByLowerPath.clear();
    for (final track in tracks) {
      final source = _sourceById[track.sourceId];
      if (source == null) continue;
      final path = _pathOf(track);
      final audio = _audioFromTrack(
        track,
        source,
        playCount: playCounts[path] ?? 0,
      );
      _audioByPath[path] = audio;
      if (lowerCounts[path.toLowerCase()] == 1) {
        _audioByLowerPath[path.toLowerCase()] = audio;
      }
    }
    version.value++;
  }

  Audio _audioFromTrack(
    RemoteTrack track,
    RemoteSource source, {
    int playCount = 0,
  }) {
    final disc = track.disc;
    return Audio(
      track.title.isEmpty ? '未知标题' : track.title,
      track.artist.isEmpty ? '未知艺术家' : track.artist,
      track.album.isEmpty ? '未知专辑' : track.album,
      track.albumArtist,
      track.track,
      track.duration,
      track.bitrate,
      track.sampleRate,
      _pathOf(track),
      track.modified,
      track.created,
      track.by ?? source.name,
      disc: disc == null || disc <= 0 ? null : disc,
      playCount: playCount,
    );
  }

  String _pathOf(RemoteTrack track) =>
      remotePathFor(track.sourceId, track.trackId);

  /// 播放/封面等路径上失败时退回匿名，避免整个界面报错。
  String passwordFor(RemoteSource source) {
    try {
      return _requirePassword(source);
    } catch (_) {
      return '';
    }
  }

  /// 同步路径上必须让解密失败暴露出来，否则会变成「账号密码错误」的误导提示。
  String _requirePassword(RemoteSource source) {
    final cached = _passwordCache[source.id];
    if (cached != null) return cached;
    if (source.secret.isEmpty) {
      _passwordCache[source.id] = '';
      return '';
    }
    try {
      final password = unprotectSecret(source.secret);
      _passwordCache[source.id] = password;
      return password;
    } catch (error, trace) {
      log.app.error(
        'legacy',
        '远程源密码解密失败',
        fields: {'sourceId': source.id},
        error: error,
        stackTrace: trace,
      );
      throw StateError('无法解密已保存的密码，请在「编辑」里重新填写密码（$error）');
    }
  }

  RemoteClient _clientFor(RemoteSource source) {
    return _clients[source.kind] ?? NavidromeClient();
  }

  String resolvePlaybackPath(String path) {
    if (!isRemotePath(path)) return path;
    final track = trackForPath(path);
    if (track == null) return path;
    final source = _sourceById[track.sourceId];
    if (source == null) return path;
    try {
      return _clientFor(
        source,
      ).playbackUrl(source, passwordFor(source), track.trackId);
    } catch (_) {
      return path;
    }
  }

  Future<Uint8List?> coverBytes(String path, int size) async {
    final track = trackForPath(path);
    if (track == null) return null;
    final source = _sourceById[track.sourceId];
    if (source == null) return null;
    final password = passwordFor(source);
    // 必须带上尺寸：列表先取 48px 缩略图，详情页要 200px 时若命中同一
    // 路径的缓存就会拿到小图，放大后就是糊的。
    // 还要带上 coverId 和修改时间：同步刷新封面后旧缓存会把过期的图
    // 一直端上来，键里带版本号，曲目一变自然失效。
    final key = '$path#$size#${track.coverId ?? ''}#${track.modified}';
    final cached = _coverCache.remove(key);
    if (cached != null) {
      _coverCache[key] = cached;
      return cached;
    }
    final future = _loadCover(source, password, track, size, path);
    _coverCache[key] = future;
    unawaited(
      future.then((value) {
        if (value == null && identical(_coverCache[key], future)) {
          _coverCache.remove(key);
        }
      }, onError: (_) {}),
    );
    while (_coverCache.length > _coverCacheCapacity) {
      _coverCache.remove(_coverCache.keys.first)?.ignore();
    }
    return future;
  }

  static const _coverCacheCapacity = 120;
  final LinkedHashMap<String, Future<Uint8List?>> _coverCache =
      LinkedHashMap<String, Future<Uint8List?>>();

  Future<Uint8List?> _loadCover(
    RemoteSource source,
    String password,
    RemoteTrack track,
    int size,
    String path,
  ) async {
    final direct = await _clientFor(
      source,
    ).cover(source, password, track.coverId, size);
    if (direct != null) return direct;
    // 目录里没有 cover.jpg 时退回内嵌 APIC。
    final head = await _headFor(path);
    if (head == null) return null;
    return extractApic(head)?.bytes;
  }

  /// 按协议取歌词：
  /// - Navidrome 走 getLyricsBySongId（库里有结构化歌词，带逐字时间轴）
  /// - WebDAV 读文件里的 USLT
  /// - SMB 交给 Rust 直接按 UNC 路径读标签
  /// 都没有就返回 null，调用方再退到在线歌词源。
  Future<String?> lyricText(String path) async {
    if (!isRemotePath(path)) return null;
    final track = trackForPath(path);
    if (track == null) return null;
    final source = _sourceById[track.sourceId];
    if (source == null) return null;
    switch (source.kind) {
      case RemoteSourceKind.navidrome:
        final client = _clientFor(source);
        if (client is! NavidromeClient) return null;
        try {
          return await client.lyrics(
            source,
            passwordFor(source),
            track.trackId,
          );
        } catch (error, trace) {
          log.app.warn(
            'legacy',
            'Navidrome 歌词获取失败',
            error: error,
            stackTrace: trace,
          );
          return null;
        }
      case RemoteSourceKind.jellyfin:
        final client = _clientFor(source);
        if (client is! JellyfinClient) return null;
        return client.lyrics(source, passwordFor(source), track.trackId);
      case RemoteSourceKind.webdav:
        final head = await _headFor(path);
        if (head == null) return null;
        return extractUslt(head);
      case RemoteSourceKind.smb:
        try {
          final unc = _clientFor(
            source,
          ).playbackUrl(source, passwordFor(source), track.trackId);
          return await getLyricFromPath(path: windowsExtendedPath(unc));
        } catch (_) {
          return null;
        }
    }
  }

  /// 封面、歌词、标签共用的头部字节缓存。
  /// 一首歌最多一个 512KB 的 Range 请求，LRU 保留最近 32 首（约 16MB 上限）。
  static const _headByteLimit = 512 * 1024;
  static const _headCacheCapacity = 32;
  final LinkedHashMap<String, Future<Uint8List?>> _headCache =
      LinkedHashMap<String, Future<Uint8List?>>();

  Future<Uint8List?> _headFor(String path) {
    final cached = _headCache.remove(path);
    if (cached != null) {
      _headCache[path] = cached;
      return cached;
    }
    final future = _readHead(path);
    _headCache[path] = future;
    // 失败结果不留在缓存里，否则一次超时就永久拿不到标签/封面/歌词。
    unawaited(
      future.then((value) {
        if (value == null && identical(_headCache[path], future)) {
          _headCache.remove(path);
        }
      }, onError: (_) {}),
    );
    while (_headCache.length > _headCacheCapacity) {
      // 被淘汰的 Future 可能已经被调用方持有，这里只是不再缓存。
      _headCache.remove(_headCache.keys.first)?.ignore();
    }
    return future;
  }

  Future<Uint8List?> _readHead(String path) async {
    final track = trackForPath(path);
    if (track == null) return null;
    final source = _sourceById[track.sourceId];
    if (source == null) return null;
    final client = _clientFor(source);
    if (client is WebDavClient) {
      return client.readHead(
        source,
        passwordFor(source),
        track.trackId,
        _headByteLimit,
      );
    }
    if (source.kind == RemoteSourceKind.smb) {
      // SMB 的曲目有真实 UNC 路径，直接读文件头；
      // 走 Rust 的 getPictureFromPath（shell API）反而不认 \\?\\UNC\\ 前缀。
      return _readLocalHead(source, passwordFor(source), track.trackId);
    }
    return null;
  }

  Future<Uint8List?> _readLocalHead(
    RemoteSource source,
    String password,
    String trackId,
  ) async {
    try {
      final unc = _clientFor(
        source,
      ).playbackUrl(source, password, trackId);
      final raf = await File(windowsExtendedPath(unc)).open();
      try {
        final length = await raf.length();
        final count =
            length < _headByteLimit ? length : _headByteLimit;
        return await raf.read(count);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> recordPlay(String path) async {
    if (!isRemotePath(path)) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _store.recordPlay(path, now);
    version.value++;
  }

  Future<void> updateTrackDuration(String path, int duration) async {
    if (!isRemotePath(path) || duration <= 0) return;
    final audio = _audioByPath[path];
    if (audio == null || audio.duration > 0) return;
    audio.duration = duration;
    await _store.updateTrackDuration(path, duration);
    version.value++;
  }

  Future<Map<String, List<int>>> playHistory() => _store.readPlayHistory();

  Future<RemoteSource> saveSource({
    RemoteSource? existing,
    required RemoteSourceKind kind,
    required String name,
    required String baseUrl,
    required String username,
    String? password,
    required String root,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final typed = (kind == RemoteSourceKind.smb ? root : baseUrl).trim();
    // 用户只写 `192.168.5.91:8096` 时自动补协议并探测（https 优先，其次 http）；
    // SMB 是盘符/UNC 路径，跟 URL 无关，不做这一步。
    final address = kind == RemoteSourceKind.smb
        ? typed
        : await resolveRemoteBaseUrl(typed, kind: kind);
    // Jellyfin 不是每次带密码，而是登录换 token（密码栏也允许直接填 API 密钥），
    // 这里先把凭据换成 token + userId，再跟其他源一样 DPAPI 加密存起来。
    var resolvedSecret = password;
    if (kind == RemoteSourceKind.jellyfin &&
        password != null &&
        password.isNotEmpty) {
      resolvedSecret = await JellyfinClient.login(
        baseUrl: address,
        username: username,
        password: password,
      );
    }
    final requested = name.trim();
    final String resolvedName;
    if (requested.isNotEmpty) {
      resolvedName = requested;
    } else if (existing != null && existing.name.trim().isNotEmpty) {
      resolvedName = existing.name.trim();
    } else {
      resolvedName = uniqueRemoteSourceName(
        defaultRemoteSourceName(kind, address),
        _sources
            .where((item) => item.id != existing?.id)
            .map((item) => item.name),
      );
    }
    final source = RemoteSource(
      id: existing?.id ?? newRemoteId(),
      kind: kind,
      name: resolvedName,
      baseUrl: address,
      username: username.trim(),
      secret: resolvedSecret == null
          ? (existing?.secret ?? '')
          : protectSecret(resolvedSecret),
      root: root.trim(),
      createdAt: existing?.createdAt ?? now,
      lastSyncAt: existing?.lastSyncAt ?? 0,
      sortOrder: existing?.sortOrder ?? _sources.length,
    );
    if (existing != null && _syncingSourceIds.contains(existing.id)) {
      throw StateError('远程源正在同步，请完成后再编辑');
    }
    if (source.kind == RemoteSourceKind.smb) {
      final client = _clients[RemoteSourceKind.smb];
      if (client is SmbClient) client.validateSource(source);
    }
    await _store.upsertSource(source);
    _passwordCache.remove(source.id);
    await reload();
    return source;
  }

  Future<void> deleteSource(String id) async {
    // 扫描/同步中允许删除：先打取消标记，再立即移除记录。
    // 后台同步会在下一个检查点抛 RemoteSyncCancelled，并在 finally 里兜底清库。
    if (_syncingSourceIds.contains(id)) {
      _cancelledSourceIds.add(id);
    }
    await _store.deleteSource(id);
    _passwordCache.remove(id);
    await reload();
  }

  /// 判断两次抓取结果是否完全一致，决定要不要重写库。
  /// 必须比对全部持久化字段：漏掉的字段一变，跳过写库就会让界面停留在旧数据上。
  bool _sameTracks(List<RemoteTrack> previous, List<RemoteTrack> next) {
    if (previous.length != next.length) return false;
    final index = {for (final track in previous) track.trackId: track};
    for (final track in next) {
      final old = index[track.trackId];
      if (old == null) return false;
      if (old.sourceId != track.sourceId ||
          old.title != track.title ||
          old.artist != track.artist ||
          old.album != track.album ||
          old.albumArtist != track.albumArtist ||
          old.track != track.track ||
          old.disc != track.disc ||
          old.duration != track.duration ||
          old.bitrate != track.bitrate ||
          old.sampleRate != track.sampleRate ||
          old.modified != track.modified ||
          old.created != track.created ||
          old.by != track.by ||
          old.coverId != track.coverId) {
        return false;
      }
    }
    return true;
  }

  Future<int> syncSource(
    RemoteSource source, {
    RemoteSyncProgress? onProgress,
  }) async {
    if (!_syncingSourceIds.add(source.id)) {
      throw StateError('远程源正在同步');
    }
    final client = _clientFor(source);
    var cancelled = false;
    try {
      final password = _requirePassword(source);
      onProgress?.call(0.02, '正在连接…');
      // 增量同步：把上次结果交给客户端，未变化的文件不必重新解析。
      final existing = await _store.readTracksForSource(source.id);
      final tracks = await client.fetchTracks(
        source,
        password,
        onProgress: onProgress,
        existingTracks: {for (final track in existing) track.trackId: track},
        checkCancelled: () => _throwIfCancelled(source.id),
      );
      _throwIfCancelled(source.id);
      if (tracks.isEmpty) {
        throw StateError(
          '远程服务器没有返回歌曲，请检查地址、账号和音乐目录。'
          '若确实已清空远程目录，请删除该源后重新添加',
        );
      }
      if (_sameTracks(existing, tracks)) {
        // 一首都没变：不重写库，避免几千行 DELETE + INSERT 的无谓开销。
        onProgress?.call(0.98, '曲目没有变化，跳过写入');
      } else {
        onProgress?.call(0.9, '正在写入曲库（${tracks.length} 首）…');
        await _store.replaceTracks(
          source.id,
          tracks,
          _pathOf,
          onProgress: (done, total) {
            // 每批提交前检查一次：源被删了就中断，让 replaceTracks 回滚。
            _throwIfCancelled(source.id);
            if (total == 0) return;
            onProgress?.call(
              0.9 + 0.09 * (done / total),
              '正在写入曲库 $done/$total',
            );
          },
        );
      }
      _throwIfCancelled(source.id);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _store.upsertSource(source.copyWith(lastSyncAt: now));
      // upsert 之后再查一次取消：删除可能正好发生在上一个检查点和写入
      // 之间，这一步抛出后 finally 会把「复活」的源重新删掉。
      _throwIfCancelled(source.id);
      await reload();
      return tracks.length;
    } on RemoteSyncCancelled {
      cancelled = true;
      rethrow;
    } finally {
      if (cancelled) {
        // 删除时清过一次，这里兜底：避免刚提交的批次留下孤儿曲目。
        try {
          await _store.deleteSource(source.id);
          await reload();
        } catch (_) {}
      }
      _cancelledSourceIds.remove(source.id);
      _syncingSourceIds.remove(source.id);
    }
  }

  void _throwIfCancelled(String sourceId) {
    if (_cancelledSourceIds.contains(sourceId)) {
      throw const RemoteSyncCancelled();
    }
  }
}
