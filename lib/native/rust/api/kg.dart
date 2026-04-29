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

      final client = HttpClient();
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
        logger.d('[KG] init response: $respStr');
        final resp = jsonDecode(respStr);
        if (resp['status'] == 1 &&
            resp['data'] != null &&
            resp['error_code'] == 0) {
          _session.dfid = resp['data']['dfid'];
          _session.mid = deviceMid;
          _session.isInitialized = true;
          _session.initTime = DateTime.now().millisecondsSinceEpoch;
          logger
              .d('KgSource: 初始化成功: dfid=${_session.dfid}, mid=${_session.mid}');
        } else {
          logger.e(
              'KgSource: init failed: ${resp['error_code']} data=${resp['data']}');
        }
      }
    } catch (e) {
      logger.e('KgSource: 初始化失败: $e');
    }
  });
}

Map<String, String> _buildSearchSignedParams({
  required String keyword,
  required int page,
  required int pageSize,
}) {
  final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final baseParams = <String, String>{
    'userid': '0',
    'appid': '3116',
    'token': '',
    'clienttime': currentTime.toString(),
    'iscorrection': '1',
    'uuid': '-',
    'mid': _session.mid ?? '-',
    'dfid': '-',
    'clientver': '11070',
    'platform': 'AndroidFilter',
    'keyword': keyword,
    'page': page.toString(),
    'pagesize': pageSize.toString(),
  };

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
    logger.d('[KG] kgSearch: keyword="$keyword" limit=$limit');
    await _ensureInit();

    final params = _buildSearchSignedParams(
      keyword: keyword,
      page: 1,
      pageSize: limit,
    );

    final queryStr = params.entries.map((e) => '${e.key}=${e.value}').join('&');
    final uri =
        Uri.parse('http://complexsearch.kugou.com/v2/search/song?$queryStr');
    logger.d('[KG] uri: $uri');

    final client = HttpClient();
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
      logger.e('[KG] API error: ${resp['data'] ?? resp}');
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
    logger.e('[KG] search failed: $e');
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

    final searchUri = Uri.parse(
        'https://lyrics.kugou.com/v1/search?keyword=&accesskey=&hash=$hash&dfid=${_session.dfid ?? ''}&mid=${_session.mid ?? ''}&clienttime=${DateTime.now().millisecondsSinceEpoch}');

    var client = HttpClient();
    var request = await client.getUrl(searchUri);
    request.headers.set('User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/45.0.2454.101 Safari/537.36');
    var response = await request.close();
    var responseBodyBytes = await response
        .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
        .then((b) => b.takeBytes());
    client.close();

    if (responseBodyBytes.isEmpty) return null;

    final searchResp = jsonDecode(utf8.decode(responseBodyBytes));
    final candidates = searchResp['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) return null;

    final candidate = candidates.first;
    final id = candidate['id'];
    final accessKey = candidate['accesskey'];

    final downloadUri = Uri.parse(
        'http://lyrics.kugou.com/download?ver=1&clienttime=${DateTime.now().millisecondsSinceEpoch}&id=$id&accesskey=$accessKey&dfid=${_session.dfid ?? ''}&mid=${_session.mid ?? ''}');

    client = HttpClient();
    request = await client.getUrl(downloadUri);
    request.headers.set('User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/45.0.2454.101 Safari/537.36');
    response = await request.close();
    responseBodyBytes = await response
        .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
        .then((b) => b.takeBytes());
    client.close();

    if (responseBodyBytes.isEmpty) return null;

    final downloadResp = jsonDecode(utf8.decode(responseBodyBytes));
    final content = downloadResp['content'];
    final contentType = downloadResp['contenttype'];

    if (content == null || content.isEmpty) return null;

    String? lyricText;
    if (contentType == 0 || contentType == 1) {
      try {
        lyricText = KgCryptoUtils.decryptKrc(content);
      } catch (e) {
        logger.e('KgSource: KRC解密失败: $e');
      }
    } else {
      try {
        lyricText = utf8.decode(base64Decode(content));
      } catch (e) {
        lyricText = content;
      }
    }

    if (lyricText == null || lyricText.isEmpty) return null;

    return {
      'lyric': lyricText,
      'fmt': downloadResp['fmt'] ?? 'lrc',
      'contentType': contentType,
    };
  } catch (e) {
    logger.e('KgSource: lyric failed: $e');
    return null;
  }
}
