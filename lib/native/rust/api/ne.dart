import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:pure_music/core/ne_crypto_utils.dart';
import 'package:logger/logger.dart';

final logger = Logger(
  filter: ProductionFilter(),
  printer: SimplePrinter(colors: false),
  level: Level.debug,
);

class NeSession {
  String? userId;
  final Map<String, String> cookies = {};
  bool isInitialized = false;
  int initTime = 0;

  static const expireTime = 10 * 24 * 60 * 60 * 1000;

  bool isValid() {
    if (!isInitialized) return false;
    return DateTime.now().millisecondsSinceEpoch - initTime < expireTime;
  }
}

final _session = NeSession();
final _mutex = _Mutex();

class _Mutex {
  Future<T> withLock<T>(Future<T> Function() body) async {
    return await body();
  }
}

String _generateClientSign() {
  final random = Random.secure();
  final mac = List.generate(6, (_) => random.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
  final randomStr = List.generate(8, (_) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    return chars[random.nextInt(chars.length)];
  }).join();
  final hashPart = List.generate(64, (_) {
    const chars = '0123456789abcdef';
    return chars[random.nextInt(chars.length)];
  }).join();
  return '$mac@@@$randomStr@@@@@@$hashPart';
}

String _generateDeviceId() {
  final random = Random.secure();
  return List.generate(32, (_) {
    return random.nextInt(16).toRadixString(16);
  }).join();
}

String _getAnonimousUsername(String deviceId) {
  const deviceXorKey = r'3go8&$8*3*3h0k(2)2';
  final sb = StringBuffer();
  for (int i = 0; i < deviceId.length; i++) {
    final keyChar = deviceXorKey[i % deviceXorKey.length];
    sb.writeCharCode(deviceId.codeUnitAt(i) ^ keyChar.codeUnitAt(0));
  }
  final xoredString = sb.toString();
  final md5Hash = NeCryptoUtils.md5(xoredString);
  final md5Bytes = hex.decode(md5Hash) as Uint8List;
  final base64Md5 = base64Encode(md5Bytes);
  final combinedStr = '$deviceId $base64Md5';
  return base64Encode(utf8.encode(combinedStr));
}

Map<String, String> _buildHeaders({String? cookieStr}) {
  return {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.3.203419',
    'Referer': 'https://music.163.com/',
    if (cookieStr != null) 'Cookie': cookieStr,
    'Accept': '*/*',
    'Host': 'interface.music.163.com',
    'Content-Type': 'application/x-www-form-urlencoded',
  };
}

String _buildCookieString(Map<String, String> cookies) {
  return cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

Future<void> _ensureInit() async {
  if (_session.isValid()) return;

  await _mutex.withLock(() async {
    if (_session.isValid()) return;

    logger.d('NeSource: 开始执行匿名登录流程...');

    final deviceId = _generateDeviceId();
    final clientSign = _generateClientSign();
    final osVer =
        'Microsoft-Windows-10--build-${20000 + Random.secure().nextInt(10000)}-64bit';
    final modes = [
      'MS-iCraft B760M WIFI',
      'ASUS ROG STRIX Z790',
      'MSI MAG B550 TOMAHAWK',
      'ASRock X670E Taichi',
      'GIGABYTE Z790 AORUS ELITE'
    ];
    final mode = modes[Random.secure().nextInt(modes.length)];

    final preCookies = {
      'os': 'pc',
      'deviceId': deviceId,
      'osver': osVer,
      'clientSign': clientSign,
      'channel': 'netease',
      'mode': mode,
      'appver': '3.1.3.203419'
    };

    final username = _getAnonimousUsername(deviceId);

    final path = '/eapi/register/anonimous';
    final encryptPath = '/api/register/anonimous';

    final headerParam = {
      'clientSign': clientSign,
      'osver': osVer,
      'deviceId': deviceId,
      'os': 'pc',
      'appver': '3.1.3.203419',
      'requestId': DateTime.now().millisecondsSinceEpoch.toString(),
    };

    final finalParams = jsonEncode({
      'username': username,
      'e_r': true,
      'header': jsonEncode(headerParam),
    });

    final encryptedBytes = NeCryptoUtils.encryptParams(encryptPath, finalParams);
    final encryptedHexString =
        hex.encode(encryptedBytes).toUpperCase();
    final formBody = 'params=$encryptedHexString';

    final cookieStr = _buildCookieString(preCookies);
    final headers = _buildHeaders(cookieStr: cookieStr);

    try {
      final client = HttpClient();
      final uri = Uri.parse('https://interface.music.163.com$path');
      final request = await client.postUrl(uri);

      headers.forEach((key, value) {
        request.headers.set(key, value);
      });

      request.write(formBody);
      final response = await request.close();

      final setCookieHeaders = response.headers['set-cookie'] ?? [];
      final responseCookies = <String, String>{};
      for (final cookieLine in setCookieHeaders) {
        final cookiePair = cookieLine.split(';')[0].split('=');
        if (cookiePair.length >= 2) {
          responseCookies[cookiePair[0]] = cookiePair[1];
        }
      }

      final responseBodyBytes =
          await response.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
              .then((b) => b.takeBytes());

      if (responseBodyBytes.isNotEmpty) {
        final decrypted =
            NeCryptoUtils.aesDecrypt(responseBodyBytes, NeCryptoUtils.eapiKey);
        final jsonRes = jsonDecode(decrypted);

        if (jsonRes['code'] == 200) {
          _session.cookies.clear();
          _session.cookies.addAll(preCookies);
          if (responseCookies.containsKey('MUSIC_A')) _session.cookies['MUSIC_A'] = responseCookies['MUSIC_A']!;
          if (responseCookies.containsKey('NMTID')) _session.cookies['NMTID'] = responseCookies['NMTID']!;
          if (responseCookies.containsKey('__csrf')) _session.cookies['__csrf'] = responseCookies['__csrf']!;

          final random = Random.secure();
          final wnmcid =
              '${List.generate(6, (_) {
                    const chars = 'abcdefghijklmnopqrstuvwxyz';
                    return chars[random.nextInt(chars.length)];
                  }).join()}.${DateTime.now().millisecondsSinceEpoch}.01.0';
          _session.cookies['WNMCID'] = wnmcid;

          _session.userId = jsonRes['userId']?.toString();
          _session.isInitialized = true;
          _session.initTime = DateTime.now().millisecondsSinceEpoch;

          logger.d(
              'NeSource: 匿名登录成功: userId=${_session.userId}, 缓存已更新');
        } else {
          logger.e('NeSource: 登录失败, 服务器返回: ${jsonRes["code"]}');
        }
      }

      client.close();
    } catch (e) {
      logger.e('NeSource: 初始化过程中发生异常: $e');
    }
  });
}

Future<String> _doRequest(String path, Map<String, dynamic> params,
    {String? encryptPath}) async {
  await _ensureInit();

  if (!_session.isInitialized) {
    logger.e('NeSource: _doRequest called but session NOT initialized! Returning empty.');
    return '';
  }

  final headerParam = {
    'clientSign': _session.cookies['clientSign'] ?? '',
    'osver': _session.cookies['osver'] ?? '',
    'deviceId': _session.cookies['deviceId'] ?? '',
    'os': _session.cookies['os'] ?? 'pc',
    'appver': _session.cookies['appver'] ?? '3.1.3.203419',
    'requestId': DateTime.now().millisecondsSinceEpoch.toString(),
  };

  final finalParams = Map<String, dynamic>.from(params);
  finalParams['header'] = jsonEncode(headerParam);
  if (!finalParams.containsKey('e_r')) {
    finalParams['e_r'] = true;
  }

  final actualEncryptPath = encryptPath ?? path.replaceFirst('/eapi/', '/api/');
  final paramsStr = jsonEncode(finalParams);
  logger.d('NeSource: _doRequest path=$path, params=$paramsStr');

  final encryptedBytes =
      NeCryptoUtils.encryptParams(actualEncryptPath, paramsStr);
  final encryptedHexString = hex.encode(encryptedBytes).toUpperCase();
  final formBody = 'params=$encryptedHexString';
  logger.d('NeSource: encrypted params length=${formBody.length}');

  final cookieStr = _buildCookieString(_session.cookies);
  final headers = _buildHeaders(cookieStr: cookieStr);

  try {
    final client = HttpClient();
    final uri = Uri.parse('https://interface.music.163.com$path');
    logger.d('NeSource: POST $uri');
    final request = await client.postUrl(uri);

    headers.forEach((key, value) {
      request.headers.set(key, value);
    });

    request.write(formBody);
    final response = await request.close();
    logger.d('NeSource: HTTP ${response.statusCode}');

    final responseBodyBytes =
        await response.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
            .then((b) => b.takeBytes());
    client.close();

    logger.d('NeSource: response bytes=${responseBodyBytes.length}');
    if (responseBodyBytes.isEmpty) {
      logger.e('NeSource: empty response body');
      return '';
    }

    final decrypted =
        NeCryptoUtils.aesDecrypt(responseBodyBytes, NeCryptoUtils.eapiKey);
    logger.d('NeSource: decrypted (first 200): ${decrypted.substring(0, decrypted.length.clamp(0, 200))}');

    if (decrypted.contains('"code":301') || decrypted.contains('"code":401')) {
      logger.w('NeSource: Session invalid (code 301/401), clearing cache...');
      _session.isInitialized = false;
    }

    return decrypted;
  } catch (e, st) {
    logger.e('NeSource: 请求失败: $e', stackTrace: st);
    return '';
  }
}

Future<List<Map<String, dynamic>>> neSearch(String keyword,
    {int limit = 10}) async {
  try {
    final path = '/eapi/search/song/list/page';
    final params = {
      'limit': limit.toString(),
      'offset': '0',
      'keyword': keyword,
      'scene': 'NORMAL',
      'needCorrect': 'true',
    };

    final rawJson = await _doRequest(path, params);
    if (rawJson.isEmpty) return [];

    final resp = jsonDecode(rawJson);
    if (resp['code'] != 200) return [];

    final resources = resp['data']?['resources'] as List?;
    if (resources == null) return [];

    return resources.map((res) {
      final song = res['baseInfo']?['simpleSongData'] ?? {};
      return {
        'id': song['id'],
        'name': song['name'] ?? '',
        'artists': (song['ar'] as List?)
                ?.map((a) => {'name': a['name']?.toString() ?? ''})
                .toList() ??
            [],
        'album': {'name': song['al']?['name'] ?? ''},
        'duration': song['dt'],
        'publishTime': song['publishTime'],
      };
    }).toList().cast<Map<String, dynamic>>();
  } catch (e) {
    logger.e('NetEase search failed: $e');
    return [];
  }
}

Future<Map<String, dynamic>?> neLyric(String songId) async {
  try {
    final path = '/eapi/song/lyric/v1';
    final params = {
      'id': int.parse(songId),
      'lv': -1,
      'tv': -1,
      'rv': -1,
      'yv': -1,
    };

    final rawJson = await _doRequest(path, params);
    if (rawJson.isEmpty) return null;

    final resp = jsonDecode(rawJson);
    return {
      'code': resp['code'],
      'yrc': resp['yrc'],
      'lrc': resp['lrc'],
      'tlyric': resp['tlyric'],
      'romalrc': resp['romalrc'],
    };
  } catch (e) {
    logger.e('NetEase lyric failed: $e');
    return null;
  }
}
