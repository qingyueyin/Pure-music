import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pure_music/remote/remote_client.dart';
import 'package:pure_music/remote/remote_source.dart';
import 'package:xml/xml.dart';

/// pathSegments 已经解码过，再 decode 会让文件名里的 % 直接中断同步。
({String fileName, String album}) webDavNames(Uri uri) {
  final segments = uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  final fileName = segments.isEmpty ? uri.path : segments.last;
  final album = segments.length >= 2 ? segments[segments.length - 2] : '未知专辑';
  return (fileName: fileName, album: album);
}

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
        followRedirects: true,
        validateStatus: (status) => status == 200 || status == 207,
      ),
    );
  }

  @override
  Future<List<RemoteTrack>> fetchTracks(
    RemoteSource source,
    String password, {
    RemoteSyncProgress? onProgress,
  }) async {
    final dio = _dio(source, password);
    final base = Uri.parse(
      source.baseUrl.endsWith('/') ? source.baseUrl : '${source.baseUrl}/',
    );
    final tracks = <RemoteTrack>[];
    final visited = <String>{};
    final pending = <Uri>[base];
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      final key = directory.toString();
      if (!visited.add(key)) continue;
      if (visited.length > _maxDirectories) {
        throw StateError('WebDAV 远程目录数量超过限制');
      }
      final response = await dio.request<String>(
        key,
        data: _propfindBody,
        options: Options(method: 'PROPFIND'),
      );
      final xml = response.data;
      if (xml == null || xml.trim().isEmpty) continue;
      final document = XmlDocument.parse(xml);
      final responses = document.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'response')
          .toList(growable: false);
      String? coverUrl;
      for (final entry in responses) {
        final href = _textOf(entry, 'href');
        if (href == null || href.isEmpty) continue;
        final uri = directory.resolve(href);
        if (uri.toString() == key) continue;
        final isCollection = entry.descendants
            .whereType<XmlElement>()
            .where((element) => element.name.local == 'resourcetype')
            .any(
              (element) => element.children.whereType<XmlElement>().any(
                (child) => child.name.local == 'collection',
              ),
            );
        if (isCollection) continue;
        if (_isCover(uri.path)) {
          coverUrl ??= uri.toString();
        }
      }
      for (final entry in responses) {
        final href = _textOf(entry, 'href');
        if (href == null || href.isEmpty) continue;
        final uri = directory.resolve(href);
        final normalized = uri.toString();
        if (normalized == key) continue;
        final isCollection = entry.descendants
            .whereType<XmlElement>()
            .where((element) => element.name.local == 'resourcetype')
            .any(
              (element) => element.children.whereType<XmlElement>().any(
                (child) => child.name.local == 'collection',
              ),
            );
        if (isCollection) {
          if (!visited.contains(normalized)) pending.add(uri);
          continue;
        }
        if (!_isAudio(uri.path)) continue;
        if (tracks.length >= _maxTracks) {
          throw StateError('WebDAV 远程曲目数量超过限制');
        }
        final size = int.tryParse(_textOf(entry, 'getcontentlength') ?? '');
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
      onProgress?.call(
        (tracks.length / (tracks.length + 20)).clamp(0.0, 0.99),
        '已发现 ${tracks.length} 首',
      );
    }
    tracks.sort((a, b) {
      final album = a.album.toLowerCase().compareTo(b.album.toLowerCase());
      if (album != 0) return album;
      final disc = (a.disc ?? 1).compareTo(b.disc ?? 1);
      if (disc != 0) return disc;
      final track = a.track.compareTo(b.track);
      if (track != 0) return track;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    onProgress?.call(1, '已发现 ${tracks.length} 首');
    return tracks;
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
    final names = webDavNames(uri);
    final fileName = names.fileName;
    final album = names.album;
    var title = fileName;
    final dot = title.lastIndexOf('.');
    if (dot > 0) title = title.substring(0, dot);
    var track = 0;
    final leading = RegExp(r'^(\d{1,3})[\s._-]+').firstMatch(title);
    if (leading != null) {
      track = int.tryParse(leading.group(1)!) ?? 0;
      title = title.substring(leading.end).trim();
    }
    var artist = '未知艺术家';
    final separator = title.indexOf(' - ');
    if (separator > 0) {
      final left = title.substring(0, separator).trim();
      final right = title.substring(separator + 3).trim();
      if (left.isNotEmpty) artist = left;
      if (right.isNotEmpty) title = right;
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
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null || data.isEmpty) return null;
      return Uint8List.fromList(data);
    } catch (_) {
      return null;
    }
  }
}
