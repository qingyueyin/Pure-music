import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:pure_music/remote/lyrics_builder.dart';
import 'package:pure_music/remote/remote_client.dart';
import 'package:pure_music/remote/remote_source.dart';

class NavidromeClient implements RemoteClient {
  static const _pageSize = 500;
  static const _maxSongs = 200000;

  String _restBase(RemoteSource source) {
    final base = source.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    return base.endsWith('/rest') ? base : '$base/rest';
  }

  Map<String, String> _authParams(RemoteSource source, String password) {
    final salt = List.generate(
      8,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return {
      'u': source.username,
      't': md5.convert(utf8.encode('$password$salt')).toString(),
      's': salt,
      'v': '1.16.1',
      'c': 'PureMusic',
      'f': 'json',
    };
  }

  Map<String, dynamic> _decode(Response<dynamic> response) {
    final data = response.data;
    final map = data is String
        ? jsonDecode(data) as Map<String, dynamic>
        : data as Map<String, dynamic>;
    final body = map['subsonic-response'] ?? map['subsonicResponse'];
    if (body is! Map<String, dynamic>) {
      throw StateError('Navidrome 返回格式异常');
    }
    if (body['status'] == 'failed') {
      final error = body['error'];
      final message = error is Map ? error['message'] : null;
      throw StateError(message?.toString() ?? 'Navidrome 请求失败');
    }
    return body;
  }

  Dio _dio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 30),
        responseType: ResponseType.plain,
      ),
    );
  }

  /// OpenSubsonic getLyricsBySongId：Navidrome 扫描时已经把内嵌歌词抽进库，
  /// 返回的 line 带 start/end，cue 是逐字时间轴，直接拼成增强 LRC 给现有解析器。
  Future<String?> lyrics(
    RemoteSource source,
    String password,
    String trackId,
  ) async {
    // enhanced=true 才会返回 cueLine（逐字）；老服务器不认这个参数时再退回。
    final body =
        await _lyricsBody(source, password, trackId, enhanced: true) ??
        await _lyricsBody(source, password, trackId, enhanced: false);
    if (body == null) return null;

    final list = body['lyricsList'];
    // OpenSubsonic 的字段名是 structuredLyrics；老版本才用 lyrics。
    final raw = list is Map
        ? (list['structuredLyrics'] ?? list['lyrics'])
        : null;
    final blocks = raw is List
        ? raw
        : (raw is Map ? <Object?>[raw] : const <Object?>[]);

    String? withCues;
    String? timed;
    String? plain;
    for (final block in blocks) {
      if (block is! Map) continue;
      // 译文块不采信逐字（原文的 cue 才对应发音）。
      final kind = block['kind']?.toString().toLowerCase() ?? '';
      final parsed = buildLyricTextFromStructuredBlock(block);
      if (parsed == null) continue;
      if (parsed.hasCues) {
        if (kind != 'translation') return parsed.text;
        withCues ??= parsed.text;
      } else if (parsed.hasTiming) {
        timed ??= parsed.text;
      } else {
        plain ??= parsed.text;
      }
    }
    return withCues ?? timed ?? plain;
  }

  Future<Map<String, dynamic>?> _lyricsBody(
    RemoteSource source,
    String password,
    String trackId, {
    required bool enhanced,
  }) async {
    try {
      final response = await _dio().get<dynamic>(
        '${_restBase(source)}/getLyricsBySongId.view',
        queryParameters: {
          ..._authParams(source, password),
          'id': trackId,
          if (enhanced) 'enhanced': 'true',
        },
      );
      return _decode(response);
    } catch (_) {
      return null;
    }
  }

  /// Navidrome 走 search3 全量拉取，标签由服务器提供，没有需要沿用的本地解析结果。
  @override
  Future<List<RemoteTrack>> fetchTracks(
    RemoteSource source,
    String password, {
    RemoteSyncProgress? onProgress,
    Map<String, RemoteTrack> existingTracks = const {},
    void Function()? checkCancelled,
  }) async {
    final dio = _dio();

    // search3 分页在 0.64.x 上是可靠的（500 首/页，全库几次请求就够），
    // 比逐张专辑取（几千次请求）快两个数量级。
    final search = await _collectBySearch(
      dio,
      source,
      password,
      onProgress,
      checkCancelled,
    );
    if (search.tracks.isNotEmpty && search.reliable) {
      onProgress?.call(0.88, '已获取 ${search.tracks.length} 首');
      return search.tracks;
    }

    // search3 被忽略 offset 或返回空时，退回逐张专辑遍历。
    final tracks = <RemoteTrack>[];
    final seenIds = <String>{};
    try {
      await _collectByAlbum(
        dio,
        source,
        password,
        tracks,
        seenIds,
        onProgress,
        checkCancelled,
      );
    } on RemoteSyncCancelled {
      rethrow;
    } catch (error) {
      if (tracks.isEmpty) rethrow;
      // 抓到一半失败：不能把残缺结果当成功写进库（会少歌）。
      throw StateError('曲库拉取中断（已获取 ${tracks.length} 首）：$error');
    }
    if (tracks.isEmpty) {
      // 专辑遍历也空了，只能退回 search3 的结果（可能不全，但总比没有好）。
      onProgress?.call(0.88, '已获取 ${search.tracks.length} 首');
      return search.tracks;
    }
    onProgress?.call(0.88, '已获取 ${tracks.length} 首');
    return tracks;
  }

  Future<void> _collectByAlbum(
    Dio dio,
    RemoteSource source,
    String password,
    List<RemoteTrack> tracks,
    Set<String> seenIds,
    RemoteSyncProgress? onProgress,
    void Function()? checkCancelled,
  ) async {
    var offset = 0;
    var albumCount = 0;
    var failedAlbums = 0;
    while (offset < _maxSongs) {
      checkCancelled?.call();
      final response = await dio.get<dynamic>(
        '${_restBase(source)}/getAlbumList2.view',
        queryParameters: {
          ..._authParams(source, password),
          'type': 'alphabeticalByName',
          'size': _pageSize,
          'offset': offset,
        },
      );
      final body = _decode(response);
      final albumList = body['albumList2'];
      final rawAlbums = albumList is Map ? albumList['album'] : null;
      final albums = rawAlbums is List ? rawAlbums : const <Object?>[];
      if (albums.isEmpty) break;
      for (final raw in albums) {
        checkCancelled?.call();
        if (raw is! Map) continue;
        final albumId = raw['id']?.toString() ?? '';
        if (albumId.isEmpty) continue;
        final albumName = raw['name']?.toString() ?? '';
        try {
          await _collectAlbum(
            dio,
            source,
            password,
            albumId,
            tracks,
            seenIds,
          );
        } on RemoteSyncCancelled {
          rethrow;
        } catch (_) {
          // 单张专辑失败（封面损坏、权限等）不能悄悄跳过：跳过的专辑
          // 会从曲库里消失。计数后统一中止，让用户重试。
          failedAlbums++;
          continue;
        }
        albumCount++;
        onProgress?.call(
          (tracks.length / (tracks.length + 80)).clamp(0.0, 0.88),
          albumName.isEmpty
              ? '已获取 ${tracks.length} 首（$albumCount 张专辑）'
              : '已获取 ${tracks.length} 首 · $albumName',
        );
      }
      if (albums.length < _pageSize) break;
      if (tracks.length >= _maxSongs) break;
      offset += albums.length;
    }
    if (failedAlbums > 0) {
      throw StateError(
        '$failedAlbums 张专辑拉取失败。为避免曲库缺歌已中止同步，请稍后重试',
      );
    }
  }

  Future<void> _collectAlbum(
    Dio dio,
    RemoteSource source,
    String password,
    String albumId,
    List<RemoteTrack> tracks,
    Set<String> seenIds,
  ) async {
    final response = await dio.get<dynamic>(
      '${_restBase(source)}/getAlbum.view',
      queryParameters: {..._authParams(source, password), 'id': albumId},
    );
    final body = _decode(response);
    final album = body['album'];
    final rawSongs = album is Map ? album['song'] : null;
    final songs = rawSongs is List ? rawSongs : const <Object?>[];
    for (final raw in songs) {
      if (raw is! Map) continue;
      final track = _trackFromSong(source, Map<String, dynamic>.from(raw));
      if (!seenIds.add(track.trackId)) continue;
      tracks.add(track);
      if (tracks.length >= _maxSongs) return;
    }
  }

  Future<({List<RemoteTrack> tracks, bool reliable})> _collectBySearch(
    Dio dio,
    RemoteSource source,
    String password,
    RemoteSyncProgress? onProgress,
    void Function()? checkCancelled,
  ) async {
    final tracks = <RemoteTrack>[];
    final seenIds = <String>{};
    var reliable = true;
    var offset = 0;
    while (offset < _maxSongs) {
      checkCancelled?.call();
      final response = await dio.get<dynamic>(
        '${_restBase(source)}/search3.view',
        queryParameters: {
          ..._authParams(source, password),
          'query': '',
          'songCount': _pageSize,
          'songOffset': offset,
          'artistCount': 0,
          'albumCount': 0,
        },
      );
      final body = _decode(response);
      final result = body['searchResult3'];
      final songs = result is Map ? result['song'] : null;
      // 只有一首歌时服务器可能返回对象而不是数组。
      final list = songs is List
          ? songs
          : (songs is Map ? <Object?>[songs] : const <Object?>[]);
      var added = 0;
      for (final raw in list) {
        if (raw is! Map) continue;
        final song = Map<String, dynamic>.from(raw);
        final track = _trackFromSong(source, song);
        if (!seenIds.add(track.trackId)) continue;
        tracks.add(track);
        added++;
      }
      onProgress?.call(
        (tracks.length / (tracks.length + 500)).clamp(0.0, 0.85),
        '已获取 ${tracks.length} 首',
      );
      if (list.length < _pageSize) break;
      // 服务器忽略 songOffset 时本页不会带来新歌曲：说明分页不可信，
      // 这个结果只是前 500 首，得让调用方改用专辑遍历。
      if (added == 0) {
        reliable = false;
        break;
      }
      offset += list.length;
    }
    onProgress?.call(0.85, '已获取 ${tracks.length} 首');
    return (tracks: tracks, reliable: reliable);
  }

  RemoteTrack _trackFromSong(RemoteSource source, Map<String, dynamic> song) {
    final created = _parseDate(song['created']);
    final modified = _parseDate(song['changed']);
    return RemoteTrack(
      sourceId: source.id,
      trackId: '${song['id']}',
      title: (song['title'] ?? '').toString(),
      artist: (song['artist'] ?? '').toString(),
      album: (song['album'] ?? '').toString(),
      albumArtist: song['albumArtist']?.toString(),
      track: _int(song['track']),
      disc: _int(song['discNumber']),
      duration: _int(song['duration']),
      bitrate: _int(song['bitRate']),
      sampleRate: _int(song['samplingRate']),
      modified: modified ?? created ?? 0,
      created: created ?? 0,
      by: song['artist']?.toString(),
      coverId: song['coverArt']?.toString(),
    );
  }

  int? _parseDate(Object? value) {
    if (value == null) return null;
    final parsed = DateTime.tryParse(value.toString());
    return parsed == null ? null : parsed.millisecondsSinceEpoch ~/ 1000;
  }

  int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  @override
  String playbackUrl(RemoteSource source, String password, String trackId) {
    final uri = Uri.parse('${_restBase(source)}/stream.view');
    return uri
        .replace(
          queryParameters: {
            ..._authParams(source, password),
            'id': trackId,
            'format': 'raw',
          },
        )
        .toString();
  }

  @override
  Future<Uint8List?> cover(
    RemoteSource source,
    String password,
    String? coverId,
    int size,
  ) async {
    if (coverId == null || coverId.isEmpty) return null;
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          responseType: ResponseType.bytes,
        ),
      );
      final response = await dio.get<List<int>>(
        '${_restBase(source)}/getCoverArt.view',
        queryParameters: {
          ..._authParams(source, password),
          'id': coverId,
          'size': size,
        },
      );
      final data = response.data;
      return data == null ? null : Uint8List.fromList(data);
    } catch (_) {
      return null;
    }
  }
}
