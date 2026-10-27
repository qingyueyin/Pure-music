import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:pure_music/remote/remote_client.dart';
import 'package:pure_music/remote/remote_source.dart';

List<Map<String, dynamic>> subsonicEntries(Object? value) {
  if (value is Map) return [Map<String, dynamic>.from(value)];
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map) Map<String, dynamic>.from(item),
  ];
}

class NavidromeClient implements RemoteClient {
  static const _albumPageSize = 500;
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

  @override
  Future<List<RemoteTrack>> fetchTracks(
    RemoteSource source,
    String password, {
    RemoteSyncProgress? onProgress,
  }) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 30),
        responseType: ResponseType.plain,
      ),
    );
    final tracks = <RemoteTrack>[];
    final seenIds = <String>{};
    final seenAlbums = <String>{};
    var offset = 0;
    // search3 的偏移经常被忽略，只能拿到第一页。改为按专辑分页再取曲目。
    while (tracks.length < _maxSongs) {
      final response = await dio.get<dynamic>(
        '${_restBase(source)}/getAlbumList2.view',
        queryParameters: {
          ..._authParams(source, password),
          'type': 'alphabeticalByName',
          'size': _albumPageSize,
          'offset': offset,
        },
      );
      final body = _decode(response);
      final listRoot = body['albumList2'];
      final albums = subsonicEntries(
        listRoot is Map ? listRoot['album'] : null,
      );
      if (albums.isEmpty) break;
      var addedAlbums = 0;
      for (final album in albums) {
        final albumId = album['id']?.toString() ?? '';
        if (albumId.isEmpty || !seenAlbums.add(albumId)) continue;
        addedAlbums++;
        final detailResponse = await dio.get<dynamic>(
          '${_restBase(source)}/getAlbum.view',
          queryParameters: {..._authParams(source, password), 'id': albumId},
        );
        final detail = _decode(detailResponse);
        final albumBody = detail['album'];
        final songs = subsonicEntries(
          albumBody is Map ? albumBody['song'] : null,
        );
        for (final song in songs) {
          if (tracks.length >= _maxSongs) break;
          final track = _trackFromSong(source, song);
          if (!seenIds.add(track.trackId)) continue;
          tracks.add(track);
        }
        onProgress?.call(
          (tracks.length / _maxSongs).clamp(0.0, 0.99),
          '已获取 ${tracks.length} 首',
        );
      }
      if (albums.length < _albumPageSize || addedAlbums == 0) break;
      offset += albums.length;
    }
    onProgress?.call(1, '已获取 ${tracks.length} 首');
    return tracks;
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
