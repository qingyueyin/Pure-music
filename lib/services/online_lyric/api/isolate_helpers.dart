import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

const _kgSearchUrl = 'https://mobilecdn.kugou.com/api/v3/search/song';
const _kgSearchFallbackUrl = 'https://songsearch.kugou.com/song_search_v2';
const _kgSearchLrcUrl = 'https://lyrics.kugou.com/search';
const _kgDownloadLrcUrl = 'https://lyrics.kugou.com/download';
const _neSearchUrl = 'https://music.163.com/api/cloudsearch/pc';
const _neLrcUrl = 'https://music.163.com/api/song/lyric';
const _qmSearchUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
const _musicApiHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/138.0.0.0 Safari/537.36',
  'Accept': 'application/json,text/plain,*/*',
  'Referer': 'https://music.163.com/',
};
const _kgApiHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/138.0.0.0 Safari/537.36',
  'Accept': 'application/json,text/plain,*/*',
};

Future<T> _runCancelable<T>(
  Future<T> Function() operation, {
  required Duration timeout,
  required T timeoutValue,
}) async {
  if (timeout <= Duration.zero) return timeoutValue;
  final receivePort = ReceivePort();
  final isolate = await Isolate.spawn(_runCancelableEntry<T>, (
    sendPort: receivePort.sendPort,
    operation: operation,
  ));
  try {
    final result = await receivePort.first.timeout(timeout);
    if (result case (true, final T value)) return value;
    throw StateError((result as (bool, Object?)).$2.toString());
  } on TimeoutException {
    return timeoutValue;
  } finally {
    isolate.kill(priority: Isolate.immediate);
    receivePort.close();
  }
}

Future<void> _runCancelableEntry<T>(
  ({SendPort sendPort, Future<T> Function() operation}) message,
) async {
  try {
    message.sendPort.send((true, await message.operation()));
  } catch (error, trace) {
    message.sendPort.send((false, '$error\n$trace'));
  }
}

Duration _effectiveTimeout(Duration? requested, Duration fallback) {
  if (requested == null) return fallback;
  return requested < fallback ? requested : fallback;
}

Future<String?> _httpPost(
  String urlStr,
  String body,
  Map<String, String> headers,
) async {
  HttpClient? client;
  try {
    final uri = Uri.parse(urlStr);
    client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);
    final request = await client.postUrl(uri);
    for (final entry in headers.entries) {
      request.headers.add(entry.key, entry.value);
    }
    request.write(body);
    final response = await request.close();
    if (response.statusCode != 200) return null;
    return await response.transform(utf8.decoder).join();
  } catch (_) {
    return null;
  } finally {
    client?.close(force: true);
  }
}

Future<List<dynamic>> _kgSearchInIsolate(Map<String, dynamic> params) async {
  final Map<String, String> queryParameters = {
    'format': 'json',
    'keyword': params['text'].toString(),
    'page': params['offset'].toString(),
    'pagesize': params['limit'].toString(),
    if (params['cacheBust'] != null) '_': params['cacheBust'].toString(),
  };
  var body = await _httpGet(_kgSearchUrl, queryParameters, _kgApiHeaders);
  var useFallbackShape = false;
  if (body == null || body.isEmpty) {
    body = await _httpGet(_kgSearchFallbackUrl, {
      'keyword': params['text'].toString(),
      'page': params['offset'].toString(),
      'pagesize': params['limit'].toString(),
      if (params['cacheBust'] != null) '_': params['cacheBust'].toString(),
    }, _kgApiHeaders);
    useFallbackShape = true;
  }
  if (body == null || body.isEmpty) return [];
  try {
    var data = jsonDecode(body) as Map<String, dynamic>;
    var dataBody = data['data'];
    var songList = dataBody is Map
        ? (useFallbackShape ? dataBody['lists'] : dataBody['info'])
        : null;
    if ((songList is! List || songList.isEmpty) && !useFallbackShape) {
      final fallbackBody = await _httpGet(_kgSearchFallbackUrl, {
        'keyword': params['text'].toString(),
        'page': params['offset'].toString(),
        'pagesize': params['limit'].toString(),
        if (params['cacheBust'] != null) '_': params['cacheBust'].toString(),
      }, _kgApiHeaders);
      if (fallbackBody != null && fallbackBody.isNotEmpty) {
        data = jsonDecode(fallbackBody) as Map<String, dynamic>;
        dataBody = data['data'];
        useFallbackShape = true;
        songList = dataBody is Map ? dataBody['lists'] : null;
      }
    }
    if (songList is! List) return [];
    final normalized = <Map<String, dynamic>>[];
    for (final rawItem in songList) {
      if (rawItem is! Map) continue;
      final item = rawItem;
      final groupList = !useFallbackShape && item['group'] is List
          ? item['group'] as List
          : null;
      String? albumName;
      if (groupList != null && groupList.isNotEmpty) {
        final firstGroup = groupList.first;
        if (firstGroup is Map) {
          albumName = firstGroup['album_name']?.toString();
        }
      }
      final result = <String, dynamic>{
        'hash':
            (useFallbackShape ? item['FileHash'] : item['hash'])?.toString() ??
            '',
        'id': (useFallbackShape ? item['ID'] : item['id'])?.toString() ?? '',
        'songname':
            (useFallbackShape ? item['SongName'] : item['songname'])
                ?.toString() ??
            'UNKNOWN',
        'singername':
            (useFallbackShape ? item['SingerName'] : item['singername'])
                ?.toString() ??
            'UNKNOWN',
        'album_name':
            albumName ??
            (useFallbackShape ? item['AlbumName'] : item['album_name'])
                ?.toString() ??
            '',
        'duration':
            int.tryParse(
              (useFallbackShape ? item['Duration'] : item['duration'])
                      ?.toString() ??
                  '0',
            ) ??
            0,
      };
      if ((result['hash'] as String).isNotEmpty) normalized.add(result);
    }
    return normalized;
  } catch (_) {
    return [];
  }
}

Future<String?> _httpGet(
  String urlStr,
  Map<String, String> queryParameters,
  Map<String, String>? headers, {
  String? uriSuffix,
}) async {
  HttpClient? client;
  try {
    Uri uri;
    if (uriSuffix != null) {
      uri = Uri.parse('$urlStr$uriSuffix');
    } else {
      uri = Uri.parse(urlStr).replace(queryParameters: queryParameters);
    }
    client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);
    final request = await client.getUrl(uri);
    request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
    if (headers != null) {
      for (final entry in headers.entries) {
        request.headers.add(entry.key, entry.value);
      }
    }
    final response = await request.close();
    if (response.statusCode != 200) return null;
    return await response.transform(utf8.decoder).join();
  } catch (_) {
    return null;
  } finally {
    client?.close(force: true);
  }
}

Future<List<dynamic>> kgSearchIsolate({
  required String text,
  required int offset,
  required int limit,
  int? cacheBust,
  Duration? timeout,
}) async {
  return _runCancelable(
    () => _kgSearchInIsolate({
      'text': text,
      'offset': offset,
      'limit': limit,
      'cacheBust': cacheBust,
    }),
    timeout: _effectiveTimeout(timeout, const Duration(seconds: 8)),
    timeoutValue: const [],
  );
}

Future<Map<String, String?>> _kgLyricInIsolate(
  Map<String, dynamic> params,
) async {
  final hash = params['hash'] as String;

  // 搜索歌词候选。
  final body1 = await _httpGet(_kgSearchLrcUrl, {
    'ver': '1',
    'man': 'yes',
    'client': 'pc',
    'hash': hash,
  }, _kgApiHeaders);
  if (body1 == null || body1.isEmpty) return {'encrypted': null};
  dynamic decoded;
  try {
    decoded = jsonDecode(body1);
  } catch (_) {
    return {'encrypted': null};
  }
  if (decoded is! Map) return {'encrypted': null};
  final candidate = decoded['candidates'];
  if (candidate is! List || candidate.isEmpty) return {'encrypted': null};
  for (final rawItem in candidate.take(5)) {
    if (rawItem is! Map) continue;
    final item = rawItem;
    final id = item['id']?.toString() ?? '';
    final accesskey = item['accesskey']?.toString() ?? '';
    if (id.isEmpty || accesskey.isEmpty) continue;

    final body2 = await _httpGet(_kgDownloadLrcUrl, {
      'ver': '1',
      'client': 'pc',
      'id': id,
      'accesskey': accesskey,
      'fmt': 'krc',
      'charset': 'utf8',
    }, _kgApiHeaders);
    if (body2 == null || body2.isEmpty) continue;
    try {
      final content = jsonDecode(body2)?['content']?.toString() ?? '';
      if (content.isNotEmpty) return {'encrypted': content};
    } catch (_) {}
  }
  return {'encrypted': null};
}

Future<Map<String, String?>> kgLyricIsolate({
  required String hash,
  Duration? timeout,
}) async {
  return _runCancelable(
    () => _kgLyricInIsolate({'hash': hash}),
    timeout: _effectiveTimeout(timeout, const Duration(seconds: 8)),
    timeoutValue: const {'encrypted': null},
  );
}

Future<List<dynamic>> _neSearchInIsolate(Map<String, dynamic> params) async {
  final body = await _httpGet(_neSearchUrl, {
    's': params['text'].toString(),
    'type': '1',
    'offset': params['offset'].toString(),
    'total': 'true',
    'limit': params['limit'].toString(),
    if (params['cacheBust'] != null) '_': params['cacheBust'].toString(),
  }, _musicApiHeaders);
  if (body == null || body.isEmpty) return [];
  try {
    final Map<String, dynamic> data = jsonDecode(body);
    final songs = data['result']?['songs'];
    if (songs is! List) return [];
    final normalized = <Map<String, dynamic>>[];
    for (final rawItem in songs) {
      if (rawItem is! Map) continue;
      final item = rawItem;
      final artistList = item['ar'];
      String? artist;
      if (artistList is List && artistList.isNotEmpty) {
        artist = artistList
            .whereType<Map>()
            .map((a) => a['name']?.toString())
            .whereType<String>()
            .where((name) => name.isNotEmpty)
            .join('、');
      }
      final id = item['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      normalized.add({
        'id': item['id']?.toString() ?? '',
        'name': item['name']?.toString() ?? 'UNKNOWN',
        'artist': artist ?? 'UNKNOWN',
        'album': item['al']?['name']?.toString() ?? '',
        'dt': int.tryParse(item['dt']?.toString() ?? '0') ?? 0,
      });
    }
    return normalized;
  } catch (_) {
    return [];
  }
}

Future<List<dynamic>> neSearchIsolate({
  required String text,
  required int offset,
  required int limit,
  int? cacheBust,
  Duration? timeout,
}) async {
  return _runCancelable(
    () => _neSearchInIsolate({
      'text': text,
      'offset': offset,
      'limit': limit,
      'cacheBust': cacheBust,
    }),
    timeout: _effectiveTimeout(timeout, const Duration(seconds: 8)),
    timeoutValue: const [],
  );
}

Future<Map<String, String?>> _neLyricInIsolate(
  Map<String, dynamic> params,
) async {
  final body = await _httpGet(_neLrcUrl, {
    'id': params['id'].toString(),
    'lv': '-1',
    'yv': '-1',
    'tv': '-1',
    'rv': '-1',
    'os': 'pc',
  }, _musicApiHeaders);
  if (body == null || body.isEmpty) {
    return {'main': null, 'trans': null, 'roma': null, 'format': 'lrc'};
  }
  try {
    final Map<String, dynamic> data = jsonDecode(body);
    final String? lrcLyric = data['lrc']?['lyric'];
    final String? yrcLyric = data['yrc']?['lyric'];
    final String? tLyric = data['tlyric']?['lyric'];
    final String? romaLyric = data['romalrc']?['lyric'];
    final bool hasYrc = yrcLyric != null && yrcLyric.isNotEmpty;
    return {
      'main': hasYrc ? yrcLyric : lrcLyric,
      'trans': tLyric,
      'roma': romaLyric,
      'format': hasYrc ? 'yrc' : 'lrc',
    };
  } catch (_) {
    return {'main': null, 'trans': null, 'roma': null, 'format': 'lrc'};
  }
}

Future<Map<String, String?>> neLyricIsolate({
  required int id,
  Duration? timeout,
}) async {
  return _runCancelable(
    () => _neLyricInIsolate({'id': id}),
    timeout: _effectiveTimeout(timeout, const Duration(seconds: 8)),
    timeoutValue: const {
      'main': null,
      'trans': null,
      'roma': null,
      'format': 'lrc',
    },
  );
}

Future<List<dynamic>> _qqSearchInIsolate(Map<String, dynamic> params) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final random = (now * 123456789) % 1000000000000000;
  final searchId = (10000000000000000 + random).toString();
  final body = await _httpPost(
    _qmSearchUrl,
    jsonEncode({
      'comm': {
        'ct': '11',
        'cv': '1003006',
        'v': '1003006',
        'os_ver': '15',
        'phonetype': '24122RKC7C',
        'tmeAppID': 'qqmusiclight',
        'nettype': 'NETWORK_WIFI',
      },
      'req_0': {
        'method': 'DoSearchForQQMusicLite',
        'module': 'music.search.SearchCgiService',
        'param': {
          'search_id': searchId,
          'remoteplace': 'search.android.keyboard',
          'query': params['text'],
          'search_type': 0,
          'num_per_page': params['limit'],
          'page_num': params['offset'],
          'highlight': 0,
          'nqc_flag': 0,
          'page_id': 1,
          'grp': 1,
        },
      },
    }),
    {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
      'Host': 'u.y.qq.com',
      'Content-Type': 'text/plain; charset=utf-8',
    },
  );
  if (body == null || body.isEmpty) return [];
  try {
    final Map<String, dynamic> data = jsonDecode(body);
    final songList = data['req_0']?['data']?['body']?['item_song'];
    if (songList is! List) return [];
    return songList.map((item) {
      final singerList = item['singer'] as List?;
      String? singer;
      if (singerList != null && singerList.isNotEmpty) {
        singer = singerList
            .map((s) => s['name']?.toString())
            .where((n) => n != null)
            .join('、');
      }
      return {
        'id': item['id']?.toString() ?? '',
        'mid': item['mid']?.toString() ?? '',
        'title': item['title'] ?? 'UNKNOWN',
        'artist': singer ?? 'UNKNOWN',
        'album': item['album']?['name']?.toString() ?? '',
        'interval': int.tryParse(item['interval']?.toString() ?? '0') ?? 0,
      };
    }).toList();
  } catch (_) {
    return [];
  }
}

Future<List<dynamic>> qqSearchIsolate({
  required String text,
  required int offset,
  required int limit,
  Duration? timeout,
}) async {
  return _runCancelable(
    () => _qqSearchInIsolate({'text': text, 'offset': offset, 'limit': limit}),
    timeout: _effectiveTimeout(timeout, const Duration(seconds: 8)),
    timeoutValue: const [],
  );
}

Future<Map<String, String?>> _qqLyricInIsolate(
  Map<String, dynamic> params,
) async {
  final int id = params['id'] as int;
  final String? title = params['title'] as String?;
  final String? album = params['album'] as String?;
  final String? artist = params['artist'] as String?;
  final int durationSec = params['durationSec'] as int? ?? 0;

  // ── 方案 A：GetPlayLyricInfo ──
  if (title != null && title.isNotEmpty) {
    final titleB64 = base64Encode(utf8.encode(title));
    final albumB64 = base64Encode(utf8.encode(album ?? ''));
    final singerB64 = base64Encode(utf8.encode(artist ?? ''));
    final body = await _httpPost(
      _qmSearchUrl,
      jsonEncode({
        'comm': {
          'ct': '11',
          'cv': '1003006',
          'v': '1003006',
          'os_ver': '15',
          'phonetype': '24122RKC7C',
          'tmeAppID': 'qqmusiclight',
          'nettype': 'NETWORK_WIFI',
        },
        'req_0': {
          'method': 'GetPlayLyricInfo',
          'module': 'music.musichallSong.PlayLyricInfo',
          'param': {
            'songID': id,
            'songName': titleB64,
            'albumName': albumB64,
            'singerName': singerB64,
            'crypt': 1,
            'qrc': 1,
            'trans': 1,
            'roma': 1,
            'cv': 2111,
            'ct': 19,
            'lrc_t': 0,
            'qrc_t': 0,
            'roma_t': 0,
            'trans_t': 0,
            'type': 0,
            'interval': durationSec,
          },
        },
      }),
      {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
        'Host': 'u.y.qq.com',
        'Content-Type': 'text/plain; charset=utf-8',
      },
    );

    if (body != null) {
      try {
        final Map<String, dynamic> data = jsonDecode(body);
        final lyricData = data['req_0']?['data'];
        if (lyricData != null) {
          final encLyric = lyricData['lyric']?.toString() ?? '';
          final encTrans = lyricData['trans']?.toString() ?? '';
          final encRoma = lyricData['roma']?.toString() ?? '';
          if (encLyric.isNotEmpty) {
            return {
              'encryptedLyric': encLyric,
              'encryptedTrans': encTrans.isNotEmpty ? encTrans : null,
              'roma': encRoma.isNotEmpty ? encRoma : null,
            };
          }
        }
      } catch (_) {}
    }
  }

  // ── 方案 B：lyric_download.fcg 降级 ──
  final fbBody = await _httpGet(
    'https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg',
    {
      'version': '15',
      'miniversion': '82',
      'lrctype': '4',
      'musicid': id.toString(),
    },
    null,
  );
  if (fbBody == null || fbBody.isEmpty) {
    return {'encryptedLyric': null, 'encryptedTrans': null, 'roma': null};
  }
  try {
    final cleaned = fbBody
        .replaceAll('<!--', '')
        .replaceAll('-->', '')
        .replaceAll('miniversion="1"', 'miniversion');
    String? extract(String tag) {
      final r = RegExp(
        '<$tag[^>]*>\\s*<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>\\s*<\\/$tag>',
        caseSensitive: false,
      );
      return r.firstMatch(cleaned)?.group(1);
    }

    final encLyric = extract('content');
    if (encLyric == null || encLyric.isEmpty) {
      return {'encryptedLyric': null, 'encryptedTrans': null, 'roma': null};
    }
    return {
      'encryptedLyric': encLyric,
      'encryptedTrans': extract('contentts'),
      'roma': extract('contentroma'),
    };
  } catch (_) {
    return {'encryptedLyric': null, 'encryptedTrans': null, 'roma': null};
  }
}

Future<Map<String, String?>> qqLyricIsolate({
  required int id,
  String? title,
  String? album,
  String? artist,
  int? durationSec,
  Duration? timeout,
}) async {
  return _runCancelable(
    () => _qqLyricInIsolate({
      'id': id,
      'title': title,
      'album': album,
      'artist': artist,
      'durationSec': durationSec ?? 0,
    }),
    timeout: _effectiveTimeout(timeout, const Duration(seconds: 12)),
    timeoutValue: const {
      'encryptedLyric': null,
      'encryptedTrans': null,
      'roma': null,
    },
  );
}

/// 仅使用歌曲 ID 的降级查询。
Future<Map<String, String?>> qqFallbackLyricIsolate({required int id}) async {
  return qqLyricIsolate(id: id);
}
