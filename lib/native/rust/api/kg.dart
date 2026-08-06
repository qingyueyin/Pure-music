import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:logger/logger.dart';

final logger = Logger(
  filter: ProductionFilter(),
  printer: SimplePrinter(colors: false),
  level: Level.debug,
);

class KgSession {
  String? dfid;
  String? mid;
  String? token;
  bool isInitialized = false;
  int initTime = 0;

  static const expireTime = 10 * 24 * 60 * 60 * 1000;

  bool isValid() {
    if (!isInitialized) return false;
    return DateTime.now().millisecondsSinceEpoch - initTime < expireTime;
  }
}

final _session = KgSession();
final _mutex = _Mutex();

class _Mutex {
  Future<T> withLock<T>(Future<T> Function() body) async {
    return body();
  }
}

class KgCryptoUtils {
  static const String signSalt = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';

  static String md5(String input) {
    final bytes = utf8.encode(input);
    final digest = crypto.md5.convert(bytes);
    return digest.toString();
  }

  static String signParams(Map<String, dynamic> params,
      {String body = '', String salt = signSalt}) {
    final sortedEntries = params.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final sortedString =
        sortedEntries.map((e) => '${e.key}=${e.value}').join('');
    final raw = '$salt$sortedString$body$salt';
    return md5(raw);
  }

  static String decryptKrc(String base64Content) {
    try {
      final encryptedBytes = base64Decode(base64Content);
      if (encryptedBytes.length <= 4) return '';

      final dataBytes = encryptedBytes.sublist(4);
      final key = <int>[
        64,
        71,
        97,
        119,
        94,
        50,
        116,
        71,
        81,
        54,
        49,
        45,
        206,
        210,
        110,
        105
      ];

      for (int i = 0; i < dataBytes.length; i++) {
        dataBytes[i] = dataBytes[i] ^ key[i % key.length];
      }

      final decoder = ZLibDecoder().convert(dataBytes);
      return utf8.decode(decoder);
    } catch (e) {
      return '';
    }
  }
}

Future<void> _ensureInit() async {
  if (_session.isValid()) return;

  await _mutex.withLock(() async {
    if (_session.isValid()) return;

    try {
      final deviceMid =
          KgCryptoUtils.md5(DateTime.now().millisecondsSinceEpoch.toString());
      final params = {
        'appid': '1014',
        'platid': '4',
        'mid': deviceMid,
      };

      final sortedValues = params.values.where((v) => v.isNotEmpty).toList()
        ..sort();
      final sortedString = sortedValues.join('');
      final signature = KgCryptoUtils.md5('1014${sortedString}1014');
      params['signature'] = signature;

      final queryStr =
          params.entries.map((e) => '${e.key}=${e.value}').join('&');
      final uri = Uri.parse(
          'https://userservice.kugou.com/risk/v1/r_register_dev?$queryStr');

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      final request = await client.postUrl(uri);

      request.headers.set('Content-Type', 'text/plain');
      const bodyJson = '{"uuid":""}';
      final bodyBase64 = base64Encode(utf8.encode(bodyJson));
      request.write(bodyBase64);

      final response = await request.close();
      logger.d('[KG] init HTTP ${response.statusCode}');

      final responseBodyBytes = await response
          .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
          .then((b) => b.takeBytes());
      client.close();

      if (responseBodyBytes.isNotEmpty) {
        final respStr = utf8.decode(responseBodyBytes);
        final resp = jsonDecode(respStr);
        if (resp['status'] == 1 &&
            resp['data'] != null &&
            resp['error_code'] == 0) {
          _session.dfid = resp['data']['dfid'];
          _session.mid = deviceMid;
          _session.isInitialized = true;
          _session.initTime = DateTime.now().millisecondsSinceEpoch;
          logger.d('[KG] init succeeded');
        } else {
          logger.e('[KG] init failed: code=${resp['error_code']}');
        }
      }
    } catch (e) {
      logger.e('[KG] init failed: ${e.runtimeType}');
    }
  });
}

Map<String, String> _buildSignedParams(
  Map<String, String> customParams, {
  required String module,
}) {
  final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final baseParams = <String, String>{};

  if (module == 'Lyric') {
    baseParams['appid'] = '3116';
    baseParams['clientver'] = '11070';
  } else {
    baseParams['userid'] = '0';
    baseParams['appid'] = '3116';
    baseParams['token'] = '';
    baseParams['clienttime'] = currentTime.toString();
    baseParams['iscorrection'] = '1';
    baseParams['uuid'] = '-';
    baseParams['mid'] = _session.mid ?? '-';
    baseParams['dfid'] = _session.dfid ?? '-';
    baseParams['clientver'] = '11070';
    baseParams['platform'] = 'AndroidFilter';
  }

  baseParams.addAll(customParams);

  final sortedEntries = baseParams.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final sortedParamStr =
      sortedEntries.map((e) => '${e.key}=${e.value}').join('');

  final raw =
      '${KgCryptoUtils.signSalt}$sortedParamStr${KgCryptoUtils.signSalt}';
  baseParams['signature'] = KgCryptoUtils.md5(raw);

  return baseParams;
}

Future<List<Map<String, dynamic>>> kgSearch(String keyword,
    {int limit = 10}) async {
  try {
    logger.d('[KG] search started: limit=$limit');
    await _ensureInit();

    final params = _buildSignedParams({
      'keyword': keyword,
      'page': '1',
      'pagesize': limit.toString(),
    }, module: 'Search');

    final queryStr = params.entries.map((e) => '${e.key}=${e.value}').join('&');
    final uri =
        Uri.parse('http://complexsearch.kugou.com/v2/search/song?$queryStr');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final request = await client.getUrl(uri);
    request.headers.set('User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/45.0.2454.101 Safari/537.36');
    final response = await request.close();
    logger.d('[KG] status: ${response.statusCode}');

    final responseBodyBytes = await response
        .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
        .then((b) => b.takeBytes());
    client.close();

    if (responseBodyBytes.isEmpty) {
      logger.e('[KG] empty response body');
      return [];
    }

    final respStr = utf8.decode(responseBodyBytes);
    final resp = jsonDecode(respStr);
    logger.d(
        '[KG] status=${resp['status']}, data=${resp['data'] != null ? "present" : "null"}');
    if (resp['status'] != 1 || resp['data'] == null) {
      logger.e('[KG] API error: status=${resp['status']}');
      return [];
    }

    final lists = resp['data']['lists'] as List?;
    if (lists == null) {
      logger.e('[KG] no lists in response');
      return [];
    }
    logger.d('[KG] got ${lists.length} items');

    return lists
        .map((song) {
          final singers = song['Singers'] as List?;
          final singername =
              singers?.map((s) => s['name']?.toString() ?? '').join('、') ?? '';
          return {
            'songname': song['SongName'] ?? '',
            'album_name': song['AlbumName'] ?? '',
            'singername': singername,
            'hash': song['FileHash'] ?? '',
            'id': song['ID']?.toString() ?? '',
            'duration':
                song['Duration'] != null ? (song['Duration'] as int) * 1000 : 0,
            'publishDate': song['PublishDate'] ?? '',
          };
        })
        .toList()
        .cast<Map<String, dynamic>>();
  } catch (e) {
    logger.e('[KG] search failed: ${e.runtimeType}');
    return [];
  }
}

Future<Map<String, dynamic>?> kgLyric(String hash) async {
  try {
    await _ensureInit();
    if (_session.dfid == null) {
      logger.e('[KG] lyric: dfid is null');
      return null;
    }

    // 搜索歌词候选。
    final searchParams = _buildSignedParams({
      'hash': hash,
      'keyword': '',
      'lrctxt': '1',
      'man': 'no',
    }, module: 'Lyric');

    final queryStr =
        searchParams.entries.map((e) => '${e.key}=${e.value}').join('&');
    final searchUri = Uri.parse('https://lyrics.kugou.com/v1/search?$queryStr');
    var client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    var request = await client.getUrl(searchUri);
    request.headers.set('User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/45.0.2454.101 Safari/537.36');
    var response = await request.close();
    logger.d('[KG] lyric: search HTTP ${response.statusCode}');
    var responseBodyBytes = await response
        .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
        .then((b) => b.takeBytes());
    client.close();

    if (responseBodyBytes.isEmpty) {
      logger.d('[KG] lyric: search response body empty');
      return null;
    }

    final searchResp = jsonDecode(utf8.decode(responseBodyBytes));
    final candidates = searchResp['candidates'] as List?;
    logger.d('[KG] lyric: candidates count=${candidates?.length}');
    if (candidates == null || candidates.isEmpty) {
      logger.d('[KG] lyric: no candidates');
      return null;
    }

    final candidate = candidates.first as Map<String, dynamic>;
    final id = candidate['id'];
    final accessKey = candidate['accesskey'];

    // 下载选中的歌词。
    final downloadParams = _buildSignedParams({
      'accesskey': accessKey,
      'charset': 'utf8',
      'client': 'mobi',
      'fmt': 'krc',
      'id': id,
      'ver': '1',
    }, module: 'Lyric');

    final downloadQueryStr =
        downloadParams.entries.map((e) => '${e.key}=${e.value}').join('&');
    final downloadUri =
        Uri.parse('http://lyrics.kugou.com/download?$downloadQueryStr');
    client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    request = await client.getUrl(downloadUri);
    request.headers.set('User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/45.0.2454.101 Safari/537.36');
    response = await request.close();
    logger.d('[KG] lyric: download HTTP ${response.statusCode}');
    responseBodyBytes = await response
        .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
        .then((b) => b.takeBytes());
    client.close();

    if (responseBodyBytes.isEmpty) {
      logger.d('[KG] lyric: download response body empty');
      return null;
    }

    final downloadResp = jsonDecode(utf8.decode(responseBodyBytes));
    logger.d(
        '[KG] lyric: resp keys=${downloadResp.keys.toList()}, code=${downloadResp['code']}');
    final content = downloadResp['content'];
    final contentType = downloadResp['contenttype'];
    logger.d(
        '[KG] lyric: content length=${content?.toString().length}, contentType=$contentType');

    if (content == null || content.isEmpty) {
      logger.d('[KG] lyric: content null or empty');
      return null;
    }

    String? lyricText;
    if (contentType == 0 || contentType == 1) {
      try {
        lyricText = KgCryptoUtils.decryptKrc(content);
      } catch (e) {
        logger.e('[KG] lyric decode failed: ${e.runtimeType}');
      }
    } else {
      try {
        lyricText = utf8.decode(base64Decode(content));
      } catch (e) {
        lyricText = content;
      }
    }

    if (lyricText == null || lyricText.isEmpty) return null;

    lyricText = _decodeHtmlEntities(lyricText);

    return {
      'lyric': lyricText,
      'fmt': downloadResp['fmt'] ?? 'lrc',
      'contentType': contentType,
    };
  } catch (e) {
    logger.e('[KG] lyric failed: ${e.runtimeType}');
    return null;
  }
}

String _decodeHtmlEntities(String input) {
  return input
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ');
}
