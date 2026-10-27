import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/remote/dpapi.dart';
import 'package:pure_music/remote/navidrome_client.dart';
import 'package:pure_music/remote/remote_client.dart';
import 'package:pure_music/remote/remote_source.dart';
import 'package:pure_music/remote/remote_store.dart';
import 'package:pure_music/remote/smb_client.dart';
import 'package:pure_music/remote/webdav_client.dart';

class RemoteLibrary {
  RemoteLibrary._();

  static final instance = RemoteLibrary._();

  final _store = const RemoteStore();
  final _sources = <RemoteSource>[];
  final _sourceById = <String, RemoteSource>{};
  final _tracksByPath = <String, RemoteTrack>{};
  final _audioByPath = <String, Audio>{};
  final _passwordCache = <String, String>{};
  final _syncingSourceIds = <String>{};
  final _clients = <RemoteSourceKind, RemoteClient>{
    RemoteSourceKind.navidrome: NavidromeClient(),
    RemoteSourceKind.webdav: WebDavClient(),
    RemoteSourceKind.smb: SmbClient(),
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
    final track = _tracksByPath[path];
    if (track != null) return track;
    for (final entry in _tracksByPath.entries) {
      if (entry.key.toLowerCase() == path.toLowerCase()) return entry.value;
    }
    return null;
  }

  Audio? audioForPath(String path) {
    final audio = _audioByPath[path];
    if (audio != null) return audio;
    for (final entry in _audioByPath.entries) {
      if (entry.key.toLowerCase() == path.toLowerCase()) return entry.value;
    }
    return null;
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    AudioLibrary.remoteAudioResolver = audioForPath;
    await reload();
    _warmUpSmbSources();
  }

  void _warmUpSmbSources() {
    final client = _clients[RemoteSourceKind.smb];
    if (client is! SmbClient) return;
    for (final source in _sources) {
      if (source.kind != RemoteSourceKind.smb) continue;
      final String password;
      try {
        password = passwordFor(source);
      } catch (_) {
        continue;
      }
      unawaited(client.warmUp(source, password));
    }
  }

  Future<void> reload() async {
    final sources = await _store.readSources();
    final tracks = await _store.readTracks();
    final playCounts = await _store.readPlayCounts();
    _sources
      ..clear()
      ..addAll(sources);
    _sourceById
      ..clear()
      ..addEntries(sources.map((source) => MapEntry(source.id, source)));
    _tracksByPath
      ..clear()
      ..addEntries(tracks.map((track) => MapEntry(_pathOf(track), track)));
    _audioByPath.clear();
    for (final track in tracks) {
      final source = _sourceById[track.sourceId];
      if (source == null) continue;
      final path = _pathOf(track);
      _audioByPath[path] = _audioFromTrack(
        track,
        source,
        playCount: playCounts[path] ?? 0,
      );
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

  String passwordFor(RemoteSource source) {
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
    } catch (_) {
      throw StateError('远程源密码无法解密，请重新填写密码');
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
    if (source.kind == RemoteSourceKind.smb) {
      try {
        final unc = _clientFor(
          source,
        ).playbackUrl(source, password, track.trackId);
        return getPictureFromPath(path: unc, width: size, height: size);
      } catch (_) {
        return null;
      }
    }
    return _clientFor(source).cover(source, password, track.coverId, size);
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
    final source = RemoteSource(
      id: existing?.id ?? newRemoteId(),
      kind: kind,
      name: name.trim(),
      baseUrl: baseUrl.trim(),
      username: username.trim(),
      secret: password == null
          ? (existing?.secret ?? '')
          : protectSecret(password),
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
    if (_syncingSourceIds.contains(id)) {
      throw StateError('远程源正在同步，请完成后再删除');
    }
    await _store.deleteSource(id);
    _passwordCache.remove(id);
    await reload();
  }

  Future<int> syncSource(
    RemoteSource source, {
    RemoteSyncProgress? onProgress,
  }) async {
    if (!_syncingSourceIds.add(source.id)) {
      throw StateError('远程源正在同步');
    }
    final client = _clientFor(source);
    final password = passwordFor(source);
    try {
      final tracks = await client.fetchTracks(
        source,
        password,
        onProgress: onProgress,
      );
      await _store.replaceTracks(
        source.id,
        tracks,
        _pathOf,
        onProgress: onProgress,
      );
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _store.upsertSource(source.copyWith(lastSyncAt: now));
      await reload();
      return tracks.length;
    } finally {
      _syncingSourceIds.remove(source.id);
    }
  }
}
