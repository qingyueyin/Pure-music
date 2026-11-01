import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pure_music/remote/lyrics_builder.dart';
import 'package:pure_music/remote/remote_client.dart';
import 'package:pure_music/remote/remote_source.dart';

/// Jellyfin 原生客户端。
///
/// 和 Subsonic 系的区别只有两点：
/// 1. 认证是「登录换 token」，不是每次带密码；token 和 userId 一起存在
///    source.secret 里（DPAPI 加密），格式是 `{"t":"…","u":"…"}`。
/// 2. 列表走 `/Items` 而不是 `search3`，返回里有 `TotalRecordCount`，
///    所以进度条可以做成真正的线性百分比。
class JellyfinClient implements RemoteClient {
  static const _pageSize = 500;
  static const _maxItems = 200000;
  static const _deviceId = 'pure-music-desktop';
  static const _clientName = 'PureMusic';

  String _base(RemoteSource source) =>
      source.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');

  Dio _dio(String token) {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 30),
        responseType: ResponseType.plain,
        headers: {if (token.isNotEmpty) 'Authorization': 'MediaBrowser Token="$token"'},
      ),
    );
  }

  /// 从 secret 里取 token / userId。老数据或手填的 API 密钥也能兜住。
  ({String token, String userId}) _credentials(String secret) {
    final text = secret.trim();
    if (text.startsWith('{')) {
      try {
        final map = jsonDecode(text) as Map<String, dynamic>;
        return (
          token: map['t']?.toString() ?? '',
          userId: map['u']?.toString() ?? '',
        );
      } catch (_) {}
    }
    return (token: text, userId: '');
  }

  /// 用用户名密码换 token。密码栏允许直接填 API 密钥（32 位十六进制）。
  static Future<String> login({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final base = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 20),
        responseType: ResponseType.plain,
      ),
    );
    final looksLikeKey = RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(password.trim());

    if (looksLikeKey) {
      // 已经是 API 密钥：拿第一个用户即可（密钥本身有服务端权限）。
      final response = await dio.get<dynamic>(
        '$base/Users',
        options: Options(
          headers: {'Authorization': 'MediaBrowser Token="${password.trim()}"'},
        ),
      );
      final list = _asList(response.data);
      final match = list.firstWhere(
        (item) =>
            username.trim().isEmpty ||
            (item['Name']?.toString() ?? '') == username.trim(),
        orElse: () => list.isEmpty ? <String, dynamic>{} : list.first,
      );
      final userId = match['Id']?.toString() ?? '';
      if (userId.isEmpty) {
        throw StateError('API 密钥有效，但服务器上没有可用用户');
      }
      return jsonEncode({'t': password.trim(), 'u': userId});
    }

    final response = await dio.post<dynamic>(
      '$base/Users/AuthenticateByName',
      data: {'Username': username.trim(), 'Pw': password},
      options: Options(
        contentType: 'application/json',
        headers: {
          'Authorization':
              'MediaBrowser Client="$_clientName", Device="Desktop", '
                  'DeviceId="$_deviceId", Version="1.0.0"',
        },
      ),
    );
    final body = response.data is String
        ? jsonDecode(response.data as String) as Map<String, dynamic>
        : response.data as Map<String, dynamic>;
    final token = body['AccessToken']?.toString() ?? '';
    final user = body['User'];
    final userId = user is Map ? (user['Id']?.toString() ?? '') : '';
    if (token.isEmpty || userId.isEmpty) {
      throw StateError('Jellyfin 登录失败，请检查用户名和密码');
    }
    return jsonEncode({'t': token, 'u': userId});
  }

  static List<Map<String, dynamic>> _asList(Object? data) {
    final decoded = data is String
        ? jsonDecode(data)
        : data;
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<Object?, Object?>>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
  }

  @override
  Future<List<RemoteTrack>> fetchTracks(
    RemoteSource source,
    String password, {
    RemoteSyncProgress? onProgress,
    Map<String, RemoteTrack> existingTracks = const {},
    void Function()? checkCancelled,
  }) async {
    final credentials = _credentials(password);
    if (credentials.token.isEmpty || credentials.userId.isEmpty) {
      throw StateError('Jellyfin 凭据已失效，请重新编辑这个源填写密码');
    }
    final dio = _dio(credentials.token);
    final tracks = <RemoteTrack>[];
    final seen = <String>{};
    var offset = 0;
    var total = 0;

    while (offset < _maxItems) {
      checkCancelled?.call();
      final response = await dio.get<dynamic>(
        '${_base(source)}/Items',
        queryParameters: {
          'userId': credentials.userId,
          'Recursive': 'true',
          'IncludeItemTypes': 'Audio',
          'Fields': 'Path,MediaSources,AlbumArtist,Artists,RunTimeTicks,'
              'IndexNumber,ParentIndexNumber,DateCreated',
          'SortBy': 'DateCreated',
          'SortOrder': 'Ascending',
          // EnableImages=false 会导致返回里没有 ImageTags，封面就丢了。
          'EnableImages': 'true',
          'StartIndex': '$offset',
          'Limit': '$_pageSize',
        },
      );
      final body = response.data is String
          ? jsonDecode(response.data as String) as Map<String, dynamic>
          : response.data as Map<String, dynamic>;
      total = (body['TotalRecordCount'] as num?)?.toInt() ?? total;
      final items = body['Items'];
      final list = items is List ? items : const <Object?>[];
      if (list.isEmpty) break;
      for (final raw in list) {
        if (raw is! Map) continue;
        final track = _trackFromItem(source, Map<String, dynamic>.from(raw));
        if (track == null) continue;
        if (!seen.add(track.trackId)) continue;
        tracks.add(track);
      }
      onProgress?.call(
        total == 0
            ? (tracks.length / (tracks.length + 500)).clamp(0.0, 0.85)
            : (tracks.length / total).clamp(0.0, 0.88),
        '已获取 ${tracks.length}/${total == 0 ? '?' : total} 首',
      );
      if (list.length < _pageSize) break;
      offset += list.length;
    }
    // 超过上限被截断时不能把半截结果当成功：那会用残缺集合替换掉
    // 本来完整的曲库，超出部分的歌全部消失。
    if (tracks.length >= _maxItems && total > tracks.length) {
      throw StateError(
        'Jellyfin 曲库共 $total 首，超过 $_maxItems 首上限。'
        '为避免截断丢歌已中止同步',
      );
    }
    onProgress?.call(0.88, '已获取 ${tracks.length} 首');
    return tracks;
  }

  RemoteTrack? _trackFromItem(RemoteSource source, Map<String, dynamic> item) {
    final id = item['Id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final title = item['Name']?.toString() ?? '';
    // 只在专辑标签完全缺失时退回目录名。标签即使等于歌名也照原样保留——
    // 四个源显示同一份数据，别让 Jellyfin 源看起来和 Navidrome 不一样。
    var album = item['Album']?.toString() ?? '';
    if (album.trim().isEmpty) {
      final path = item['Path']?.toString() ?? '';
      final segments = path
          .split(RegExp(r'[\\/]'))
          .where((segment) => segment.isNotEmpty)
          .toList(growable: false);
      if (segments.length >= 2) {
        album = segments[segments.length - 2];
      }
    }
    final artistsRaw = item['Artists'];
    final artists = artistsRaw is List
        ? artistsRaw.map((e) => e.toString()).where((e) => e.isNotEmpty)
        : const Iterable<String>.empty();
    final albumArtist = item['AlbumArtist']?.toString() ?? '';
    final artist = artists.isNotEmpty ? artists.join(', ') : albumArtist;
    final ticks = (item['RunTimeTicks'] as num?)?.toInt() ?? 0;
    final sources = item['MediaSources'];
    final media = sources is List && sources.isNotEmpty && sources.first is Map
        ? Map<String, dynamic>.from(sources.first as Map)
        : const <String, dynamic>{};
    final bitrate = (media['Bitrate'] as num?)?.toInt();
    final images = item['ImageTags'];
    final hasPrimary =
        images is Map && (images['Primary']?.toString().isNotEmpty ?? false);
    return RemoteTrack(
      sourceId: source.id,
      trackId: id,
      title: title,
      artist: artist.isEmpty ? '未知艺术家' : artist,
      album: album,
      albumArtist: albumArtist.isEmpty ? null : albumArtist,
      track: (item['IndexNumber'] as num?)?.toInt() ?? 0,
      disc: (item['ParentIndexNumber'] as num?)?.toInt(),
      duration: ticks ~/ 10000000,
      bitrate: bitrate == null ? null : bitrate ~/ 1000,
      sampleRate: null,
      modified: _parseDate(item['DateCreated']) ?? 0,
      created: _parseDate(item['DateCreated']) ?? 0,
      by: artist,
      // 有主图就把曲目 id 当封面 id，取图时直接 /Items/{id}/Images/Primary。
      coverId: hasPrimary ? id : null,
    );
  }

  int? _parseDate(Object? value) {
    if (value == null) return null;
    final parsed = DateTime.tryParse(value.toString());
    return parsed == null ? null : parsed.millisecondsSinceEpoch ~/ 1000;
  }

  @override
  String playbackUrl(RemoteSource source, String password, String trackId) {
    final credentials = _credentials(password);
    // 必须用 /stream?static=true：
    // - /universal 在 Jellyfin 12.x 上要求完整会话协商，只带 api_key 会返回
    //   401（0 字节）；经反向代理时甚至变成 502。播放器拿到空响应就会表现成
    //   「只有 1 秒、没有声音」。
    // - /stream?static=true 直接吐原文件，支持 Range，兼容所有版本。
    final query = {
      'static': 'true',
      'api_key': credentials.token,
      'DeviceId': _deviceId,
    };
    final uri = Uri.parse('${_base(source)}/Audio/$trackId/stream')
        .replace(queryParameters: query);
    return uri.toString();
  }

  @override
  Future<Uint8List?> cover(
    RemoteSource source,
    String password,
    String? coverId,
    int size,
  ) async {
    if (coverId == null || coverId.isEmpty) return null;
    final credentials = _credentials(password);
    try {
      final response = await _dio(credentials.token).get<List<int>>(
        '${_base(source)}/Items/$coverId/Images/Primary',
        queryParameters: {'maxWidth': '$size', 'quality': '90'},
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      return data == null ? null : Uint8List.fromList(data);
    } catch (_) {
      return null;
    }
  }

  /// 歌词：Jellyfin 返回的 `Lyrics[].Cues` 带逐字位置，拼成增强 LRC。
  Future<String?> lyrics(
    RemoteSource source,
    String secret,
    String trackId,
  ) async {
    final credentials = _credentials(secret);
    try {
      final response = await _dio(credentials.token).get<dynamic>(
        '${_base(source)}/Audio/$trackId/Lyrics',
      );
      final body = response.data is String
          ? jsonDecode(response.data as String) as Map<String, dynamic>
          : response.data as Map<String, dynamic>;
      return buildLyricTextFromJellyfin(body['Lyrics'])?.text;
    } catch (_) {
      return null;
    }
  }
}
