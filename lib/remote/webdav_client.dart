import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pure_music/remote/id3_reader.dart';
import 'package:pure_music/remote/remote_client.dart';
import 'package:pure_music/remote/remote_source.dart';
import 'package:xml/xml.dart';

class WebDavClient implements RemoteClient {
  static const _maxDirectories = 10000;
  static const _maxTracks = 200000;
  static const _audioExtensions = {
    'mp3',
    'flac',
    'wav',
    'm4a',
    'aac',
    'ogg',
    'opus',
    'wma',
    'ape',
    'aiff',
    'aif',
    'dsf',
    'dff',
  };
  static const _coverNames = {
    'cover',
    'folder',
    'front',
    'album',
    'albumart',
    'thumb',
  };
  static const _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:resourcetype/><d:getcontentlength/><d:getlastmodified/>'
      '</d:prop></d:propfind>';

  Dio _dio(RemoteSource source, String password) {
    final headers = <String, String>{
      'Depth': '1',
      'Content-Type': 'application/xml; charset=utf-8',
      'Accept': '*/*',
    };
    if (source.username.isNotEmpty || password.isNotEmpty) {
      final token = base64Encode(utf8.encode('${source.username}:$password'));
      headers['Authorization'] = 'Basic $token';
    }
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 30),
        headers: headers,
        responseType: ResponseType.plain,
        // 跟随重定向时 Dio 会把 PROPFIND 降级成 GET，拿到的是网页而不是目录列表，
        // 所以这里自己处理 3xx，保证方法不变。
        followRedirects: false,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400,
      ),
    );
  }

  /// 同主机才算同源：协议/端口变化（http→https 升级）可以接受，
  /// 但主机一换就必须断掉——否则 Basic 凭据会被转发给别的服务器。
  bool _sameHost(Uri base, Uri target) =>
      base.host.toLowerCase() == target.host.toLowerCase();

  @override
  Future<List<RemoteTrack>> fetchTracks(
    RemoteSource source,
    String password, {
    RemoteSyncProgress? onProgress,
    Map<String, RemoteTrack> existingTracks = const {},
    void Function()? checkCancelled,
  }) async {
    final dio = _dio(source, password);
    final base = Uri.parse(
      source.baseUrl.endsWith('/') ? source.baseUrl : '${source.baseUrl}/',
    );
    final tracks = <RemoteTrack>[];
    final sizes = <String, int>{};
    final visited = <String>{};
    final pending = <Uri>[base];
    while (pending.isNotEmpty) {
      checkCancelled?.call();
      final directory = pending.removeLast();
      final key = directory.toString();
      if (!visited.add(key)) continue;
      if (visited.length > _maxDirectories) {
        throw StateError('WebDAV 远程目录数量超过限制');
      }
      final response = await _propfind(dio, key);
      final status = response.statusCode ?? 0;
      if (status >= 300) {
        final location = response.headers.value('location');
        if (location == null || location.trim().isEmpty) {
          throw StateError('WebDAV 地址发生重定向（$status）但缺少 Location');
        }
        final target = directory.resolve(location.trim());
        if (!_sameHost(base, target)) {
          // 拒绝对跨主机重定向继续带凭据：把用户密码送给别人家的服务器
          // 比同步失败严重得多。
          throw StateError(
            'WebDAV 重定向到了其他主机（${target.host}），'
            '出于安全考虑已中止，请检查地址',
          );
        }
        if (!visited.contains(target.toString())) pending.add(target);
        continue;
      }
      final xml = response.data;
      if (xml == null || xml.trim().isEmpty) continue;
      final XmlDocument document;
      try {
        document = XmlDocument.parse(xml);
      } catch (_) {
        throw StateError('WebDAV 返回的不是目录列表，请检查地址是否正确（HTTP $status）');
      }
      final responses = document.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'response')
          .toList(growable: false);
      String? coverUrl;
      for (final entry in responses) {
        final href = _textOf(entry, 'href');
        if (href == null || href.isEmpty) continue;
        final uri = directory.resolve(href);
        if (!_sameHost(base, uri)) continue;
        if (uri.toString() == key) continue;
        if (_isCollection(entry)) continue;
        if (_isCover(uri.path)) {
          coverUrl ??= uri.toString();
        }
      }
      for (final entry in responses) {
        final href = _textOf(entry, 'href');
        if (href == null || href.isEmpty) continue;
        final uri = directory.resolve(href);
        // 列表里混进其他主机的条目时不收：后续取标签/封面/播放都会
        // 带着凭据访问这个 URL，跨主机就等于把凭据送出去。
        if (!_sameHost(base, uri)) continue;
        final normalized = uri.toString();
        if (normalized == key) continue;
        if (_isCollection(entry)) {
          if (!visited.contains(normalized)) pending.add(uri);
          continue;
        }
        if (!_isAudio(uri.path)) continue;
        if (tracks.length >= _maxTracks) {
          throw StateError('WebDAV 远程曲目数量超过限制');
        }
        final size = int.tryParse(_textOf(entry, 'getcontentlength') ?? '');
        if (size != null) sizes[uri.toString()] = size;
        final modified = _parseHttpDate(_textOf(entry, 'getlastmodified'));
        tracks.add(
          _trackFromUri(
            source,
            uri,
            size: size,
            modified: modified,
            coverId: coverUrl,
          ),
        );
      }
      // 目录遍历阶段不知道总数，只能给一个收敛的估计值；真正的线性进度
      // 留给后面的标签读取（总数已知）。
      onProgress?.call(
        (tracks.length / (tracks.length + 1000)).clamp(0.0, 0.2),
        '已发现 ${tracks.length} 首',
      );
    }
    await _enrichTags(
      dio,
      tracks,
      sizes: sizes,
      existingTracks: existingTracks,
      checkCancelled: checkCancelled,
      onProgress: onProgress,
    );
    tracks.sort((a, b) {
      final album = a.album.toLowerCase().compareTo(b.album.toLowerCase());
      if (album != 0) return album;
      final disc = (a.disc ?? 1).compareTo(b.disc ?? 1);
      if (disc != 0) return disc;
      final track = a.track.compareTo(b.track);
      if (track != 0) return track;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    onProgress?.call(0.88, '已读取 ${tracks.length} 首');
    return tracks;
  }

  /// 逐个文件用 Range 只取头部一小段，解 ID3 拿真实标题、艺术家、专辑和时长。
  /// 目录列表本身不带任何标签，不补这一步就只能按文件名猜。
  Future<void> _enrichTags(
    Dio dio,
    List<RemoteTrack> tracks, {
    required Map<String, int> sizes,
    Map<String, RemoteTrack> existingTracks = const {},
    void Function()? checkCancelled,
    RemoteSyncProgress? onProgress,
  }) async {
    const parallel = 8;
    final total = tracks.length;
    if (total == 0) return;
    var done = 0;
    var next = 0;

    Future<void> worker() async {
      while (true) {
        // 放在 try 外面：取消异常不能被下面「单个文件失败不拖垮同步」
        // 的兜底 catch 吞掉。
        checkCancelled?.call();
        final index = next++;
        if (index >= total) return;
        final track = tracks[index];
        final previous = existingTracks[track.trackId];
        if (previous != null &&
            previous.modified > 0 &&
            previous.modified == track.modified &&
            previous.duration > 0) {
          // 修改时间没变、上次也解析出过时长：直接沿用，省掉一次 Range 请求。
          tracks[index] = previous;
          done++;
          if (onProgress != null && (done % 20 == 0 || done == total)) {
            onProgress(
              (0.2 + 0.68 * done / total).clamp(0.0, 0.88),
              '读取标签 $done/$total',
            );
          }
          continue;
        }
        try {
          final data = await _getRangeCapped(
            dio,
            track.trackId,
            start: 0,
            length: remoteTagProbeBytes,
          );
          if (data != null && data.isNotEmpty) {
            var tags = parseMp3Tags(data, fileSize: sizes[track.trackId]);
            // 内嵌封面会把音频帧挤出探测窗口：标签拿到了但时长是 0，
            // 这时按 ID3 里记录的偏移再取 16KB，只补时长和码率。
            if (tags != null &&
                tags.duration == 0 &&
                tags.audioStart >= data.length) {
              final start = tags.audioStart;
              final tailData = await _getRangeCapped(
                dio,
                track.trackId,
                start: start,
                length: 16384,
              );
              if (tailData != null && tailData.isNotEmpty) {
                final info = parseMp3AudioInfo(
                  tailData,
                  fileSize: sizes[track.trackId],
                );
                if (info != null) {
                  tags = RemoteAudioTags(
                    title: tags.title,
                    artist: tags.artist,
                    album: tags.album,
                    albumArtist: tags.albumArtist,
                    duration: info.duration,
                    bitrate: info.bitrate,
                    sampleRate: info.sampleRate,
                    audioStart: tags.audioStart,
                  );
                }
              }
            }
            if (tags != null) {
              tracks[index] = track.copyWith(
                title: tags.title,
                artist: tags.artist,
                album: tags.album,
                albumArtist: tags.albumArtist,
                duration: tags.duration > 0 ? tags.duration : null,
                bitrate: tags.bitrate,
                sampleRate: tags.sampleRate,
                by: tags.artist,
              );
            }
          }
        } catch (_) {
          // 单个文件读失败（权限、格式怪）不该拖垮整次同步。
        }
        done++;
        if (onProgress != null && (done % 20 == 0 || done == total)) {
          onProgress(
            (0.2 + 0.68 * done / total).clamp(0.0, 0.88),
            '读取标签 $done/$total',
          );
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < parallel && i < total; i++) worker(),
    ]);
  }

  /// Range 请求但硬性限量：有的服务器忽略 Range 直接吐整个文件，
  /// 不封顶的话一首几百 MB 的曲子会被整只塞进内存。
  Future<Uint8List?> _getRangeCapped(
    Dio dio,
    String url, {
    required int start,
    required int length,
  }) async {
    final response = await dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {'Range': 'bytes=$start-${start + length - 1}'},
      ),
    );
    final stream = response.data?.stream;
    if (stream == null) return null;
    final builder = BytesBuilder(copy: false);
    // break 会取消订阅，多余的字节连下载都停掉，不只是丢弃。
    await for (final chunk in stream) {
      builder.add(chunk);
      if (builder.length >= length) break;
    }
    final bytes = builder.takeBytes();
    return bytes.isEmpty ? null : Uint8List.fromList(bytes);
  }

  /// 把 Dio 的裸异常翻译成能指导用户改配置的提示。
  /// 最常见的错法是拿管理界面的地址当 WebDAV 地址：那种反向代理通常直接
  /// 屏蔽 PROPFIND，任何路径都回 405，用户看到的是一串英文 DioException。
  Future<Response<String>> _propfind(Dio dio, String url) async {
    try {
      return await dio.request<String>(
        url,
        data: _propfindBody,
        options: Options(method: 'PROPFIND'),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 405) {
        throw StateError(
          '服务器不接受 WebDAV 的 PROPFIND 请求（HTTP 405）。'
          '这个地址多半是管理界面而不是 WebDAV 服务，'
          '请换成 NAS 提供的 WebDAV 地址和端口',
        );
      }
      if (status == 401 || status == 403) {
        throw StateError('WebDAV 认证失败（HTTP $status），请检查用户名和密码');
      }
      if (status == 404) {
        throw StateError(
          'WebDAV 路径不存在（HTTP 404），请检查地址里的目录前缀是否完整',
        );
      }
      rethrow;
    }
  }

  bool _isCollection(XmlElement entry) {
    return entry.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'resourcetype')
        .any(
          (element) => element.children.whereType<XmlElement>().any(
            (child) => child.name.local == 'collection',
          ),
        );
  }

  bool _isAudio(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    return _audioExtensions.contains(path.substring(dot + 1).toLowerCase());
  }

  bool _isCover(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return false;
    final extension = path.substring(dot + 1).toLowerCase();
    if (extension != 'jpg' &&
        extension != 'jpeg' &&
        extension != 'png' &&
        extension != 'webp') {
      return false;
    }
    final slash = path.lastIndexOf('/');
    final name = path.substring(slash + 1, dot).toLowerCase();
    return _coverNames.contains(name);
  }

  RemoteTrack _trackFromUri(
    RemoteSource source,
    Uri uri, {
    int? size,
    int? modified,
    String? coverId,
  }) {
    // pathSegments 已经是解码后的结果，再解一次会让带 % 的文件名抛异常。
    final segments = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    final fileName = segments.isEmpty ? uri.path : segments.last;
    final album = segments.length >= 2 ? segments[segments.length - 2] : '';
    var name = fileName;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    var track = 0;
    // 分隔符后允许紧跟标题（「01-Title」），不必强制有空格。
    final leading = RegExp(r'^(\d{1,3})\s*[-._．、]\s*').firstMatch(name);
    if (leading != null) {
      track = int.tryParse(leading.group(1)!) ?? 0;
      name = name.substring(leading.end).trim();
    }
    // QQ 音乐这类下载器遇到重名会追加「 (2)」去重后缀，它不属于歌曲信息。
    name = name
        .replaceFirst(RegExp(r'\s*\((?:[1-9]|[1-9]\d)\)\s*$'), '')
        .trim();
    // 这类曲库统一是「歌名 - 歌手」，所以取最后一个分隔符：
    // 歌名自己带连字符时（Time-Bomb）也不会被拆错。
    var title = name;
    var artist = '未知艺术家';
    final separator = name.lastIndexOf(' - ');
    if (separator > 0) {
      final left = name.substring(0, separator).trim();
      final right = name.substring(separator + 3).trim();
      if (left.isNotEmpty) title = left;
      if (right.isNotEmpty) artist = right;
    }
    return RemoteTrack(
      sourceId: source.id,
      trackId: uri.toString(),
      title: title.isEmpty ? fileName : title,
      artist: artist,
      album: album.isEmpty ? '未知专辑' : album,
      track: track,
      duration: 0,
      modified: modified ?? 0,
      created: 0,
      by: artist,
      coverId: coverId,
    );
  }

  String? _textOf(XmlElement element, String localName) {
    for (final child in element.descendants.whereType<XmlElement>()) {
      if (child.name.local == localName) return child.innerText.trim();
    }
    return null;
  }

  int? _parseHttpDate(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return HttpDate.parse(value).millisecondsSinceEpoch ~/ 1000;
    } catch (_) {
      return null;
    }
  }

  @override
  String playbackUrl(RemoteSource source, String password, String trackId) {
    final url = Uri.parse(trackId).replace(userInfo: '').toString();
    if (source.username.isEmpty && password.isEmpty) return url;
    final token = base64Encode(utf8.encode('${source.username}:$password'));
    // BASS 通过 URL 后追加 CRLF 行的方式携带请求头。
    return '$url\r\nAuthorization: Basic $token\r\n';
  }

  /// 只取文件头部若干字节，用于解析内嵌标签 / 封面 / 歌词。
  Future<Uint8List?> readHead(
    RemoteSource source,
    String password,
    String url,
    int length,
  ) async {
    try {
      return await _getRangeCapped(
        _dio(source, password),
        url,
        start: 0,
        length: length,
      );
    } catch (_) {
      return null;
    }
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
      final dio = _dio(source, password);
      final response = await dio.get<List<int>>(
        coverId,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
        ),
      );
      final data = response.data;
      if (data == null || data.isEmpty) return null;
      return Uint8List.fromList(data);
    } catch (_) {
      return null;
    }
  }
}
