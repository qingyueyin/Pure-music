import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

const _kgSearchUrl = 'http://mobilecdn.kugou.com/api/v3/search/song';
const _kgSearchLrcUrl = 'http://lyrics.kugou.com/search';
const _kgDownloadLrcUrl = 'http://lyrics.kugou.com/download';
const _neSearchUrl = 'https://music.163.com/api/cloudsearch/pc';
const _neLrcUrl = 'https://music.163.com/api/song/lyric';
const _qmSearchUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
const _qmLyricUrl = 'https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg';

Future<String?> _httpPost(String urlStr, String body, Map<String, String> headers) async {
  try {
    final uri = Uri.parse(urlStr);
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);
    final request = await client.postUrl(uri);
    for (final entry in headers.entries) {
      request.headers.add(entry.key, entry.value);
    }
    request.write(body);
    final response = await request.close();
    if (response.statusCode != 200) {
      client.close();
      return null;
    }
    final result = await response.transform(utf8.decoder).join();
    client.close();
    return result;
  } catch (_) {
    return null;
  }
}

// ============================================================
// Kugou search - 带 MD5 签名 (complexsearch.kugou.com)
// ============================================================

Future<List<dynamic>> _kgSearchInIsolate(Map<String, dynamic> params) async {
  final body = await _httpGet(_kgSearchUrl, {
    'format': 'json',
    'keyword': params['text'],
    'page': params['offset'].toString(),
    'pagesize': params['limit'].toString(),
  }, null);
  if (body == null || body.isEmpty) return [];
  try {
    final Map<String, dynamic> data = jsonDecode(body);
    final songList = data['data']?['info'];
    if (songList is! List) return [];
    return songList.map((item) {
      final groupList = item['group'] as List?;
      String? albumName;
      if (groupList != null && groupList.isNotEmpty) {
        albumName = groupList.first['album_name']?.toString();
      }
      return {
        'hash': item['hash']?.toString() ?? '',
        'id': item['id']?.toString() ?? '',
        'songname': item['songname'] ?? 'UNKNOWN',
        'singername': item['singername'] ?? 'UNKNOWN',
        'album_name': albumName ?? item['album_name']?.toString() ?? '',
        'duration': int.tryParse(item['duration']?.toString() ?? '0') ?? 0,
      };
    }).toList();
  } catch (_) {
    return [];
  }
}

Future<String?> _httpGet(String urlStr, Map<String, String> queryParameters, Map<String, String>? headers, {String? uriSuffix}) async {
  try {
    Uri uri;
    if (uriSuffix != null) {
      uri = Uri.parse('$urlStr$uriSuffix');
    } else {
      uri = Uri.parse(urlStr).replace(queryParameters: queryParameters);
    }
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);
    final request = await client.getUrl(uri);
    request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
    if (headers != null) {
      for (final entry in headers.entries) {
        request.headers.add(entry.key, entry.value);
      }
    }
    final response = await request.close();
    if (response.statusCode != 200) {
      client.close();
      return null;
    }
    final res = await response.transform(utf8.decoder).join();
    client.close();
    return res;
  } catch (_) {
    return null;
  }
}

Future<List<dynamic>> kgSearchIsolate({
  required String text,
  required int offset,
  required int limit,
}) async {
  return Isolate.run(() => _kgSearchInIsolate({'text': text, 'offset': offset, 'limit': limit}))
      .timeout(const Duration(seconds: 8), onTimeout: () => []);
}

// ============================================================
// Kugou lyric - 简单 API（ZeroBit-Player 已验证可工作的方案）
// ============================================================

Future<Map<String, String?>> _kgLyricInIsolate(Map<String, dynamic> params) async {
  final hash = params['hash'] as String;

  // Step 1: 搜索歌词候选
  final body1 = await _httpGet(_kgSearchLrcUrl, {
    'ver': '1', 'man': 'yes', 'client': 'pc', 'hash': hash,
  }, null);
  if (body1 == null || body1.isEmpty) return {'encrypted': null};
  final candidate = jsonDecode(body1)?['candidates'];
  if (candidate is! List || candidate.isEmpty) return {'encrypted': null};
  final String? id_ = candidate.first['id'];
  final String? accesskey = candidate.first['accesskey'];
  if (id_ == null || accesskey == null || id_.isEmpty || accesskey.isEmpty) {
    return {'encrypted': null};
  }

  // Step 2: 下载歌词
  final body2 = await _httpGet(_kgDownloadLrcUrl, {
    'ver': '1', 'client': 'pc',
    'id': id_, 'accesskey': accesskey,
    'fmt': 'krc', 'charset': 'utf8',
  }, null);
  if (body2 == null || body2.isEmpty) return {'encrypted': null};
  try {
    final String? content = jsonDecode(body2)?['content'];
    if (content == null || content.isEmpty) return {'encrypted': null};
    return {'encrypted': content};
  } catch (_) {
    return {'encrypted': null};
  }
}

Future<Map<String, String?>> kgLyricIsolate({required String hash}) async {
  return Isolate.run(() => _kgLyricInIsolate({'hash': hash}))
      .timeout(const Duration(seconds: 8), onTimeout: () => {'encrypted': null});
}

// ============================================================
// NetEase search
// ============================================================

Future<List<dynamic>> _neSearchInIsolate(Map<String, dynamic> params) async {
  final body = await _httpGet(_neSearchUrl, {
    's': params['text'],
    'type': '1',
    'offset': params['offset'].toString(),
    'total': 'true',
    'limit': params['limit'].toString(),
  }, null);
  if (body == null || body.isEmpty) return [];
  try {
    final Map<String, dynamic> data = jsonDecode(body);
    final songs = data['result']?['songs'];
    if (songs is! List) return [];
    return songs.map((item) {
      final artistList = item['ar'];
      String? artist;
      if (artistList is List && artistList.isNotEmpty) {
        artist = artistList.map((a) => a['name']?.toString()).join('、');
      }
      return {
        'id': item['id']?.toString() ?? '',
        'name': item['name'] ?? 'UNKNOWN',
        'artist': artist ?? 'UNKNOWN',
        'album': item['al']?['name']?.toString() ?? '',
        'dt': (item['dt'] ?? 0) as int,
      };
    }).toList();
  } catch (_) {
    return [];
  }
}

Future<List<dynamic>> neSearchIsolate({
  required String text,
  required int offset,
  required int limit,
}) async {
  return Isolate.run(() => _neSearchInIsolate({'text': text, 'offset': offset, 'limit': limit}))
      .timeout(const Duration(seconds: 8), onTimeout: () => []);
}

// ============================================================
// NetEase lyric
// ============================================================

Future<Map<String, String?>> _neLyricInIsolate(Map<String, dynamic> params) async {
  final body = await _httpGet(_neLrcUrl, {
    'id': params['id'].toString(),
    'lv': '-1',
    'yv': '-1',
    'tv': '-1',
    'os': 'pc',
  }, null);
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

Future<Map<String, String?>> neLyricIsolate({required int id}) async {
  return Isolate.run(() => _neLyricInIsolate({'id': id}))
      .timeout(const Duration(seconds: 8), onTimeout: () => {'main': null, 'trans': null, 'roma': null, 'format': 'lrc'});
}

// ============================================================
// QQ search
// ============================================================

Future<List<dynamic>> _qqSearchInIsolate(Map<String, dynamic> params) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final random = (now * 123456789) % 1000000000000000;
  final searchId = (10000000000000000 + random).toString();
  final body = await _httpPost(_qmSearchUrl, jsonEncode({
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
  }), {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
    'Host': 'u.y.qq.com',
    'Content-Type': 'text/plain; charset=utf-8',
  });
  if (body == null || body.isEmpty) return [];
  try {
    final Map<String, dynamic> data = jsonDecode(body);
    final songList = data['req_0']?['data']?['body']?['item_song'];
    if (songList is! List) return [];
    return songList.map((item) {
      final singerList = item['singer'] as List?;
      String? singer;
      if (singerList != null && singerList.isNotEmpty) {
        singer = singerList.map((s) => s['name']?.toString()).where((n) => n != null).join('、');
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
}) async {
  return Isolate.run(() => _qqSearchInIsolate({'text': text, 'offset': offset, 'limit': limit}))
      .timeout(const Duration(seconds: 8), onTimeout: () => []);
}

// ============================================================
// QQ lyric - 主方案：Lyrico GetPlayLyricInfo（需元数据）
// 降级方案：lyric_download.fcg（仅 ID）
// Isolate 只做 HTTP，返回加密内容；解密由调用方用
// qrcDecryptSingle() 处理（它也在 Isolate 内解密）
// ============================================================

Future<Map<String, String?>> _qqLyricInIsolate(Map<String, dynamic> params) async {
  final int id = params['id'] as int;
  final String? title = params['title'] as String?;
  final String? album = params['album'] as String?;
  final String? artist = params['artist'] as String?;
  final int durationSec = params['durationSec'] as int? ?? 0;

  // ── 方案 A：Lyrico GetPlayLyricInfo ──
  if (title != null && title.isNotEmpty) {
    final titleB64 = base64Encode(utf8.encode(title));
    final albumB64 = base64Encode(utf8.encode(album ?? ''));
    final singerB64 = base64Encode(utf8.encode(artist ?? ''));
    final now = DateTime.now().millisecondsSinceEpoch;
    final random = (now * 123456789) % 1000000000000000;
    final searchId = (10000000000000000 + random).toString();

    final body = await _httpPost(_qmSearchUrl, jsonEncode({
      'comm': {
        'ct': '11', 'cv': '1003006', 'v': '1003006',
        'os_ver': '15', 'phonetype': '24122RKC7C',
        'tmeAppID': 'qqmusiclight', 'nettype': 'NETWORK_WIFI',
      },
      'req_0': {
        'method': 'GetPlayLyricInfo',
        'module': 'music.musichallSong.PlayLyricInfo',
        'param': {
          'songID': id,
          'songName': titleB64,
          'albumName': albumB64,
          'singerName': singerB64,
          'crypt': 1, 'qrc': 1, 'trans': 1, 'roma': 1,
          'cv': 2111, 'ct': 19,
          'lrc_t': 0, 'qrc_t': 0, 'roma_t': 0, 'trans_t': 0,
          'type': 0, 'interval': durationSec,
        },
      },
    }), {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
      'Host': 'u.y.qq.com',
      'Content-Type': 'text/plain; charset=utf-8',
    });

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
    {'version': '15', 'miniversion': '82', 'lrctype': '4', 'musicid': id.toString()},
    null,
  );
  if (fbBody == null || fbBody.isEmpty) {
    return {'encryptedLyric': null, 'encryptedTrans': null, 'roma': null};
  }
  try {
    final cleaned = fbBody
        .replaceAll('<!--', '').replaceAll('-->', '')
        .replaceAll('miniversion="1"', 'miniversion');
    String? extract(String tag) {
      final r = RegExp('<$tag[^>]*>\\s*<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>\\s*<\\/$tag>', caseSensitive: false);
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
}) async {
  return Isolate.run(() => _qqLyricInIsolate({
    'id': id,
    'title': title,
    'album': album,
    'artist': artist,
    'durationSec': durationSec ?? 0,
  })).timeout(const Duration(seconds: 12), onTimeout: () {
    return {'encryptedLyric': null, 'encryptedTrans': null, 'roma': null};
  });
}

/// QQ 歌词降级（仅 ID）
Future<Map<String, String?>> qqFallbackLyricIsolate({required int id}) async {
  return qqLyricIsolate(id: id);
}
