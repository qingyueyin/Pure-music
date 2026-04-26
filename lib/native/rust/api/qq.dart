import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:pure_music/lyric/qrc_decryptor.dart';

final logger = Logger(
  filter: ProductionFilter(),
  printer: SimplePrinter(colors: false),
  level: Level.debug,
);

class QmSession {
  String? guid;
  bool isInitialized = false;

  static const expireTime = 10 * 24 * 60 * 60 * 1000;
  int initTime = 0;

  bool isValid() {
    if (!isInitialized) return false;
    return DateTime.now().millisecondsSinceEpoch - initTime < expireTime;
  }
}

final _session = QmSession();
final _mutex = _Mutex();

class _Mutex {
  Future<T> withLock<T>(Future<T> Function() body) async {
    return await body();
  }
}

class QmRequestBody {
  final QmComm comm;
  final QmRequestModule? req_0;

  QmRequestBody({required this.comm, this.req_0});

  String toJson() {
    final map = {
      'comm': comm.toJson(),
    };
    if (req_0 != null) {
      map['req_0'] = req_0!.toJson();
    }
    return jsonEncode(map);
  }
}

class QmComm {
  final String guid;
  final String ct;
  final String cv;
  final String v;
  // ignore: non_constant_identifier_names
  final String os_ver;
  final String phonetype;
  final String tmeAppID;
  final String nettype;

  QmComm({
    required this.guid,
    this.ct = '11',
    this.cv = '1003006',
    this.v = '1003006',
    // ignore: non_constant_identifier_names
    this.os_ver = '15',
    this.phonetype = '24122RKC7C',
    this.tmeAppID = 'qqmusiclight',
    this.nettype = 'NETWORK_WIFI',
  });

  Map<String, dynamic> toJson() {
    return {
      'ct': ct,
      'cv': cv,
      'v': v,
      'os_ver': os_ver,
      'phonetype': phonetype,
      'tmeAppID': tmeAppID,
      'nettype': nettype,
      'guid': guid,
    };
  }
}

class QmRequestModule {
  final String module;
  final String method;
  final Map<String, dynamic> param;

  QmRequestModule({
    required this.module,
    required this.method,
    required this.param,
  });

  Map<String, dynamic> toJson() {
    return {
      'module': module,
      'method': method,
      'param': param,
    };
  }
}

Future<void> _ensureInit() async {
  if (_session.isValid()) return;

  await _mutex.withLock(() async {
    if (_session.isValid()) return;

    final random = Random.secure();
    final guid = List.generate(8, (_) {
      return random.nextInt(256).toRadixString(16).padLeft(2, '0');
    }).join();

    _session.guid = guid;
    _session.isInitialized = true;
    _session.initTime = DateTime.now().millisecondsSinceEpoch;

    logger.d('QmSource: 初始化完成: guid=${_session.guid}');
  });
}

Future<String> _doRequest(QmRequestBody body) async {
  await _ensureInit();

  try {
    final client = HttpClient();
    final uri = Uri.parse('https://u.y.qq.com/cgi-bin/musicu.fcg');
    final request = await client.postUrl(uri);

    request.headers.set('Content-Type', 'application/json');
    request.headers.set(
        'User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164');
    request.headers.set('Referer', 'https://y.qq.com/');
    request.headers.set('Accept', '*/*');

    request.write(body.toJson());
    logger.d('QmSource: request body: ${body.toJson().substring(0, body.toJson().length.clamp(0, 300))}...');
    final response = await request.close();
    logger.d('QmSource: HTTP ${response.statusCode}');

    final responseBodyBytes =
        await response.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
            .then((b) => b.takeBytes());
    client.close();

    if (responseBodyBytes.isEmpty) {
      logger.e('QmSource: empty response body');
      return '';
    }

    final respStr = utf8.decode(responseBodyBytes);
    logger.d('QmSource: response: ${respStr.substring(0, respStr.length.clamp(0, 300))}...');
    return respStr;
  } catch (e, st) {
    logger.e('QmSource: 请求失败: $e', stackTrace: st);
    return '';
  }
}

Future<List<Map<String, dynamic>>> qqSearch(String keyword,
    {int limit = 10}) async {
  try {
    logger.d('[QQ] qqSearch: keyword="$keyword" limit=$limit');
    await _ensureInit();
    logger.d('[QQ] session guid=${_session.guid}');

    final body = QmRequestBody(
      comm: QmComm(guid: _session.guid ?? ''),
      req_0: QmRequestModule(
        module: 'music.search.SearchCgiService',
        method: 'DoSearchForQQMusicLite',
        param: {
          'search_id': (10000000000000000 +
                  Random.secure().nextInt(80000000000000000))
              .toString(),
          'remoteplace': 'search.android.keyboard',
          'query': keyword,
          'search_type': 0,
          'num_per_page': limit,
          'page_num': 1,
          'highlight': 0,
          'nqc_flag': 0,
          'page_id': 1,
          'grp': 1,
        },
      ),
    );

    final rawJson = await _doRequest(body);
    if (rawJson.isEmpty) return [];

    final resp = jsonDecode(rawJson);
    final result = resp['req_0']?['data']?['body']?['item_song'] as List?;
    if (result == null) return [];

    return result.map((song) {
      return {
        'id': song['id']?.toString() ?? '',
        'mid': song['mid'] ?? '',
        'name': song['title'] ?? '',
        'artists': (song['singer'] as List?)
                ?.map((s) => s['name']?.toString() ?? '')
                .toList() ??
            [],
        'album': song['album']?['name'] ?? '',
        'duration': song['interval'] as int? ?? 0,
        'publishTime': song['time_public'] ?? '',
      };
    }).toList().cast<Map<String, dynamic>>();
  } catch (e) {
    logger.e('QQ search failed: $e');
    return [];
  }
}

Future<Map<String, dynamic>?> qqLyric(String songId) async {
  try {
    await _ensureInit();

    final body = QmRequestBody(
      comm: QmComm(guid: _session.guid ?? ''),
      req_0: QmRequestModule(
        module: 'music.musichallSong.PlayLyricInfo',
        method: 'GetPlayLyricInfo',
        param: {
          'songID': int.tryParse(songId) ?? 0,
          'trans_t': 1,
          'decrypt': 1,
          'crypt': 1,
          'qrc': 1,
          'trans': 1,
          'roma': 1,
          'lrc_t': 0,
          'qrc_t': 0,
          'roma_t': 0,
        },
      ),
    );

    final rawJson = await _doRequest(body);
    if (rawJson.isEmpty) return null;

    final resp = jsonDecode(rawJson);
    final data = resp['req_0']?['data'];
    if (data == null) return null;

    final lyric = data['lyric'] ?? '';
    final qrc = data['qrc'] ?? '';
    final trans = data['trans'] ?? '';
    final roma = data['roma'] ?? '';

    String? decryptedLyric;
    if (qrc.isNotEmpty && qrc != lyric) {
      try {
        final qrcBytes = base64Decode(qrc);
        final decryptedBytes = TripleDesDecryptor.decrypt(qrcBytes);
        decryptedLyric = utf8.decode(decryptedBytes);
      } catch (e) {
        logger.e('QmSource: QRC解密失败: $e');
      }
    }

    if (decryptedLyric == null && lyric.isNotEmpty) {
      try {
        final decryptedQrc = await qrcDecrypt(
          encryptedQrc: lyric,
          isLocal: false,
        );
        if (decryptedQrc != null) {
          decryptedLyric = decryptedQrc;
        } else {
          final lyricBytes = base64Decode(lyric);
          decryptedLyric = utf8.decode(lyricBytes);
        }
      } catch (e) {
        final lyricBytes = base64Decode(lyric);
        decryptedLyric = utf8.decode(lyricBytes);
      }
    }

    String? decryptedTrans;
    if (trans.isNotEmpty && trans != lyric) {
      try {
        final transBytes = base64Decode(trans);
        final decryptedBytes = TripleDesDecryptor.decrypt(transBytes);
        decryptedTrans = utf8.decode(decryptedBytes);
      } catch (e) {
        logger.e('QmSource: 翻译解密失败: $e');
      }
    }

    String? decryptedRoma;
    if (roma.isNotEmpty && roma != lyric) {
      try {
        final romaBytes = base64Decode(roma);
        final decryptedBytes = TripleDesDecryptor.decrypt(romaBytes);
        decryptedRoma = utf8.decode(decryptedBytes);
      } catch (e) {
        logger.e('QmSource: 罗马音解密失败: $e');
      }
    }

    if (decryptedLyric == null) return null;

    final hasQrcWordTags = RegExp(r'<\d+,\d+>').hasMatch(decryptedLyric);
    final hasYrcWordTags = RegExp(r'\(\d+,\d+,\d+\)').hasMatch(decryptedLyric);

    String format;
    if (hasQrcWordTags) {
      format = 'qrc';
    } else if (hasYrcWordTags) {
      format = 'yrc';
    } else {
      format = 'lrc';
    }

    final result = <String, dynamic>{
      'lyric': decryptedLyric,
      'format': format,
    };
    if (decryptedTrans != null && decryptedTrans.isNotEmpty) {
      result['trans'] = decryptedTrans;
    }
    if (decryptedRoma != null && decryptedRoma.isNotEmpty) {
      result['roma'] = decryptedRoma;
    }
    return result;
  } catch (e) {
    logger.e('QQ lyric failed: $e');
    return null;
  }
}
