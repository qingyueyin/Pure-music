import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:pure_music/core/lyric/models/lyric_entry.dart';
import 'package:pure_music/core/lyric/parsers/lrc_tool.dart';
import 'package:pure_music/core/net_lyrics/krc_decryptor.dart';
import 'package:pure_music/core/net_lyrics/qrc_decryptor.dart';
import 'package:pure_music/core/net_lyrics/krc_extract_decode.dart';

const _neSearchUrl = 'https://music.163.com/api/cloudsearch/pc';
const _neLrcUrl = 'https://music.163.com/api/song/lyric';

const _qmSearchUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
const _kgSearchUrl = 'http://mobilecdn.kugou.com/api/v3/search/song';
const _kgSearchLrcUrl = 'http://lyrics.kugou.com/search';
const _kgDownloadLrcUrl = 'http://lyrics.kugou.com/download';

const _coverSize = 800;

final _dio = Dio(
  BaseOptions(
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
      'Connection': 'keep-alive',
    },
  ),
);

final _qmDio = Dio(
  BaseOptions(
    headers: {
      "Host": "u.y.qq.com",
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
      'Connection': 'keep-alive',
      "Content-Type": "text/plain; charset=utf-8",
    },
  ),
);

String _generateSearchId() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final random = (now * 123456789) % 1000000000000000;
  return (10000000000000000 + random).toString();
}

// Lyrico方案: QQ音乐Lite搜索接口
Future<dynamic> _qmSearchByLyrico({
  required String text,
  required int offset,
  required int limit,
}) async {
  final searchId = _generateSearchId();
  final response = await _qmDio.post(
    _qmSearchUrl,
    data: jsonEncode({
      "comm": {
        "ct": "11",
        "cv": "1003006",
        "v": "1003006",
        "os_ver": "15",
        "phonetype": "24122RKC7C",
        "tmeAppID": "qqmusiclight",
        "nettype": "NETWORK_WIFI",
      },
      "req_0": {
        "method": "DoSearchForQQMusicLite",
        "module": "music.search.SearchCgiService",
        "param": {
          "search_id": searchId,
          "remoteplace": "search.android.keyboard",
          "query": text,
          "search_type": 0,
          "num_per_page": limit,
          "page_num": offset,
          "highlight": 0,
          "nqc_flag": 0,
          "page_id": 1,
          "grp": 1,
        },
      },
    }),
    options: Options(responseType: ResponseType.bytes),
  );
  if (response.data != null) {
    final rawString = utf8.decode(response.data as List<int>);
    return jsonDecode(rawString);
  }
  return null;
}

// Lyrico方案: GetPlayLyricInfo获取歌词
Future<Map<String, String?>> _qmGetLrcByLyrico({
  required int id,
  required String title,
  required String album,
  required String artist,
  required int durationSec,
}) async {
  final titleB64 = base64Encode(utf8.encode(title));
  final albumB64 = base64Encode(utf8.encode(album));
  final singerB64 = base64Encode(utf8.encode(artist));

  final response = await _qmDio.post(
    _qmSearchUrl,
    data: jsonEncode({
      "comm": {
        "ct": "11",
        "cv": "1003006",
        "v": "1003006",
        "os_ver": "15",
        "phonetype": "24122RKC7C",
        "tmeAppID": "qqmusiclight",
        "nettype": "NETWORK_WIFI",
      },
      "req_0": {
        "method": "GetPlayLyricInfo",
        "module": "music.musichallSong.PlayLyricInfo",
        "param": {
          "songID": id,
          "songName": titleB64,
          "albumName": albumB64,
          "singerName": singerB64,
          "crypt": 1,
          "qrc": 1,
          "trans": 1,
          "roma": 1,
          "cv": 2111,
          "ct": 19,
          "lrc_t": 0,
          "qrc_t": 0,
          "roma_t": 0,
          "trans_t": 0,
          "type": 0,
          "interval": durationSec,
        },
      },
    }),
    options: Options(responseType: ResponseType.bytes),
  );

  if (response.data == null) return {'lyric': null, 'trans': null, 'roma': null};

  final rawString = utf8.decode(response.data as List<int>);
  final data = jsonDecode(rawString);
  final lyricData = data['req_0']?['data'];

  if (lyricData == null) return {'lyric': null, 'trans': null, 'roma': null};

  final encryptedLyric = lyricData['lyric']?.toString() ?? '';
  final encryptedTrans = lyricData['trans']?.toString() ?? '';
  final encryptedRoma = lyricData['roma']?.toString() ?? '';

  String? decryptedLyric;
  String? decryptedTrans;
  String? decryptedRoma;

  if (encryptedLyric.isNotEmpty) {
    try {
      decryptedLyric = qrcDecryptLyrico(encryptedLyric);
    } catch (e) {
      debugPrint('_qmGetLrcByLyrico decrypt lyric error: $e');
    }
  }

  if (encryptedTrans.isNotEmpty) {
    try {
      decryptedTrans = qrcDecryptLyrico(encryptedTrans);
    } catch (e) {
      debugPrint('_qmGetLrcByLyrico decrypt trans error: $e');
    }
  }

  if (encryptedRoma.isNotEmpty) {
    try {
      decryptedRoma = qrcDecryptLyrico(encryptedRoma);
    } catch (e) {
      debugPrint('_qmGetLrcByLyrico decrypt roma error: $e');
    }
  }

  return {
    'lyric': decryptedLyric,
    'trans': decryptedTrans,
    'roma': decryptedRoma,
  };
}

// Lyrico方案: QRC解密 (3DES + zlib)
String? qrcDecryptLyrico(String hexString) {
  final cleaned = hexString.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
  if (cleaned.isEmpty) return null;

  final bytes = _hexToBytes(cleaned);
  if (bytes.length % 8 != 0) return null;

  final keyBytes = utf8.encode('!@#)(*\$%123ZXC!@!@#)(NHL');
  final schedules = _tripleDesKeySetup(keyBytes, false);
  final decrypted = _tripleDesDecrypt(bytes, schedules);

  return _zlibDecompress(decrypted);
}

List<int> _hexToBytes(String hex) {
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return bytes;
}

String? _zlibDecompress(List<int> data) {
  try {
    return utf8.decode(zlib.decode(data));
  } catch (e) {
    return null;
  }
}

// 3DES常量
const _initialPermutation = [
  58, 50, 42, 34, 26, 18, 10, 2,
  60, 52, 44, 36, 28, 20, 12, 4,
  62, 54, 46, 38, 30, 22, 14, 6,
  64, 56, 48, 40, 32, 24, 16, 8,
  57, 49, 41, 33, 25, 17, 9, 1,
  59, 51, 43, 35, 27, 19, 11, 3,
  61, 53, 45, 37, 29, 21, 13, 5,
  63, 55, 47, 39, 31, 23, 15, 7,
];

const _finalPermutation = [
  40, 8, 48, 16, 56, 24, 64, 32,
  39, 7, 47, 15, 55, 23, 63, 31,
  38, 6, 46, 14, 54, 22, 62, 30,
  37, 5, 45, 13, 53, 21, 61, 29,
  36, 4, 44, 12, 52, 20, 60, 28,
  35, 3, 43, 11, 51, 19, 59, 27,
  34, 2, 42, 10, 50, 18, 58, 26,
  33, 1, 41, 9, 49, 17, 57, 25,
];

const _expansionBox = [
  32, 1, 2, 3, 4, 5,
  4, 5, 6, 7, 8, 9,
  8, 9, 10, 11, 12, 13,
  12, 13, 14, 15, 16, 17,
  16, 17, 18, 19, 20, 21,
  20, 21, 22, 23, 24, 25,
  24, 25, 26, 27, 28, 29,
  28, 29, 30, 31, 32, 1,
];

const _sBoxes = [
  [
    14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
    0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
    4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
    15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
  ],
  [
    15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
    3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
    0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
    13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
  ],
  [
    10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
    13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
    13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
    1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
  ],
  [
    7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
    13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
    10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
    3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
  ],
  [
    2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
    14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
    4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
    11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
  ],
  [
    12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
    10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
    9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
    4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
  ],
  [
    4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
    13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
    1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
    6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
  ],
  [
    13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
    1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 2, 0, 14, 9, 11,
    7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
    2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
  ],
];

const _permutationBox = [
  16, 7, 20, 21, 29, 12, 28, 17,
  1, 15, 23, 26, 5, 18, 31, 10,
  2, 8, 24, 14, 32, 27, 3, 9,
  19, 13, 30, 6, 22, 11, 4, 25,
];

const _leftShifts = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];

List<List<int>> _tripleDesKeySetup(List<int> key, bool encrypt) {
  final schedules = <List<int>>[];
  final key64 = _bytesToBits(key, 0, 24);
  final c = List<int>.from(key64.take(28));
  final d = List<int>.from(key64.skip(28).take(28));

  for (int round = 0; round < 16; round++) {
    _leftShift(c, _leftShifts[round]);
    _leftShift(d, _leftShifts[round]);
    final combined = [...c, ...d];
    final subKey = _permute(combined, _permutationBox, 48);
    schedules.add(encrypt ? subKey : subKey.reversed.toList());
  }
  return schedules;
}

void _leftShift(List<int> bits, int shift) {
  for (int i = 0; i < shift; i++) {
    final first = bits[0];
    for (int j = 0; j < bits.length - 1; j++) {
      bits[j] = bits[j + 1];
    }
    bits[bits.length - 1] = first;
  }
}

List<int> _permute(List<int> input, List<int> table, int outputLength) {
  final result = List<int>.filled(outputLength, 0);
  for (int i = 0; i < outputLength; i++) {
    result[i] = input[table[i] - 1];
  }
  return result;
}

List<int> _tripleDesDecrypt(List<int> data, List<List<int>> schedules) {
  final output = <int>[];
  for (int offset = 0; offset < data.length; offset += 8) {
    final block = data.sublist(offset, offset + 8);
    final bits = _bytesToBits(block, 0, 8);
    final ip = _permute(bits, _initialPermutation, 64);

    var l = ip.take(32).toList();
    var r = ip.skip(32).take(32).toList();

    for (int round = 0; round < 16; round++) {
      final expanded = _permute(r, _expansionBox, 48);
      final xored = List<int>.generate(48, (i) => expanded[i] ^ schedules[round][i]);

      final sBoxOutput = List<int>.filled(32, 0);
      for (int s = 0; s < 8; s++) {
        final row = (xored[s * 6] << 1) | xored[s * 6 + 5];
        final col = (xored[s * 6 + 1] << 3) | (xored[s * 6 + 2] << 2) | (xored[s * 6 + 3] << 1) | xored[s * 6 + 4];
        final val = _sBoxes[s][row * 16 + col];
        for (int b = 0; b < 4; b++) {
          sBoxOutput[s * 4 + b] = (val >> (3 - b)) & 1;
        }
      }

      final permuted = _permute(sBoxOutput, _permutationBox, 32);
      final newR = List<int>.generate(32, (i) => l[i] ^ permuted[i]);
      l = r;
      r = newR;
    }

    final combined = [...r, ...l];
    final fp = _permute(combined, _finalPermutation, 64);
    output.addAll(_bitsToBytes(fp));
  }
  return output;
}

List<int> _bytesToBits(List<int> bytes, int offset, int count) {
  final bits = <int>[];
  for (int i = offset * 8; i < (offset + count) * 8; i++) {
    final byteIndex = i ~/ 8;
    final bitIndex = 7 - (i % 8);
    bits.add((bytes[byteIndex] >> bitIndex) & 1);
  }
  return bits;
}

List<int> _bitsToBytes(List<int> bits) {
  final bytes = <int>[];
  for (int i = 0; i < bits.length; i += 8) {
    int byte = 0;
    for (int b = 0; b < 8; b++) {
      byte = (byte << 1) | (bits[i + b]);
    }
    bytes.add(byte);
  }
  return bytes;
}

Future<dynamic> _neSearchByText({
  required String text,
  required int offset,
  required int limit,
}) async {
  final response = await _dio.get(
    _neSearchUrl,
    queryParameters: {
      "s": text,
      "type": 1,
      "offset": offset,
      "total": true,
      "limit": limit,
    },
    options: Options(responseType: ResponseType.plain),
  );
  if (response.data != null) {
    return jsonDecode(response.data);
  }
  return null;
}

String? _safeString(dynamic val) {
  if (val == null) return null;
  if (val is String && val.isNotEmpty) return val;
  return null;
}

Future<NetLyricResult?> _neGetLrc({required int id}) async {
  final response = await _dio.get(
    _neLrcUrl,
    queryParameters: {"id": id, "lv": -1, "yv": -1, "tv": -1, "os": 'pc'},
    options: Options(responseType: ResponseType.plain),
  );
  final body = response.data as String?;
  if (body == null || body.isEmpty) {
    return NetLyricResult(
      mainLyric: null,
      transLyric: null,
      romaLyric: null,
      format: LyricFormat.lrc,
    );
  }
  final Map<String, dynamic> data = jsonDecode(body);

  final String? lrcLyric = _safeString(data['lrc']?['lyric']);
  final String? yrcLyric = _safeString(data['yrc']?['lyric']);
  final String? tLyric = _safeString(data['tlyric']?['lyric']);
  final String? romaLyric = _safeString(data['romalrc']?['lyric']);
  final LyricFormat type =
      yrcLyric != null && yrcLyric.isNotEmpty
          ? LyricFormat.yrc
          : LyricFormat.lrc;

  return NetLyricResult(
    mainLyric: yrcLyric ?? lrcLyric,
    transLyric: tLyric,
    romaLyric: romaLyric,
    format: type,
  );
}

Future<List<NeSearchItem>> _neSearch({
  required String text,
  required int offset,
  required int limit,
}) async {
  final List<NeSearchItem> results = [];
  try {
    final data = await _neSearchByText(
      text: text,
      offset: offset,
      limit: limit,
    );
    final songs = data["result"]?["songs"];
    if (songs is! List || songs.isEmpty) {
      return [];
    }

    for (final item in songs) {
      final artistList = item["ar"];
      String? artist;
      if (artistList is List && artistList.isNotEmpty) {
        artist = artistList.map((a) => a["name"]?.toString()).join('、');
      }

      results.add(NeSearchItem(
        id: item["id"]?.toString() ?? '',
        title: item["name"] ?? 'UNKNOWN',
        artist: artist ?? 'UNKNOWN',
        album: item["al"]?["name"]?.toString() ?? '',
        durationMs: (item["dt"] ?? 0) as int,
      ));
    }
  } catch (err) {
    debugPrint('_neSearch error: ${err.toString()}');
  }
  return results;
}

Future<dynamic> _kgSearchByText({
  required String text,
  required int offset,
  required int limit,
}) async {
  final response = await _dio.get(
    _kgSearchUrl,
    queryParameters: {
      "format": "json",
      "keyword": text,
      "page": offset,
      "pagesize": limit,
    },
    options: Options(responseType: ResponseType.plain),
  );
  if (response.data != null) {
    return jsonDecode(response.data);
  }
  return null;
}

Future<NetLyricResult?> _kgGetLrc({required String id}) async {
  final response = await _dio.get(
    _kgSearchLrcUrl,
    queryParameters: {"ver": '1', "man": 'yes', "client": "pc", "hash": id},
    options: Options(responseType: ResponseType.plain),
  );

  if (response.data == null) {
    return null;
  }

  final candidate = jsonDecode(response.data)?['candidates'];

  if (candidate is! List || candidate.isEmpty) {
    return null;
  }

  final String? id_ = candidate.first['id'];
  final String? accesskey = candidate.first['accesskey'];

  if (id_ == null || accesskey == null || id_.isEmpty || accesskey.isEmpty) {
    return null;
  }

  final lyricResponse = await _dio.get(
    _kgDownloadLrcUrl,
    queryParameters: {
      "ver": '1',
      "client": "pc",
      "id": id_,
      "accesskey": accesskey,
      'fmt': 'krc',
      'charset': 'utf8',
    },
    options: Options(responseType: ResponseType.plain),
  );

  if (lyricResponse.data == null) {
    return null;
  }

  final String? content = jsonDecode(lyricResponse.data)?['content'];

  if (content == null || content.isEmpty) {
    return null;
  }

  final String? contentcDecrypted = krcDecrypt(content);
  final langData = contentcDecrypted != null ? extractKrcLanguage(contentcDecrypted) : null;

  return NetLyricResult(
    mainLyric: contentcDecrypted,
    transLyric: langData?.translation,
    romaLyric: langData?.romanization,
    format: LyricFormat.krc,
  );
}

Future<List<KgSearchItem>> _kgSearch({
  required String text,
  required int offset,
  required int limit,
}) async {
  final List<KgSearchItem> results = [];
  try {
    final Map<String, dynamic> data = await _kgSearchByText(
      text: text,
      offset: offset,
      limit: limit,
    );
    final songList = data["data"]?["info"];
    if (songList is! List || songList.isEmpty) {
      return [];
    }

    for (final item in songList) {
      results.add(KgSearchItem(
        hash: item["hash"]?.toString() ?? '',
        id: item["id"]?.toString() ?? '',
        title: item["songname"] ?? 'UNKNOWN',
        artist: item["singername"] ?? 'UNKNOWN',
        album: item["album_name"]?.toString() ?? '',
        durationMs: int.tryParse(item["duration"]?.toString() ?? '0') ?? 0,
      ));
    }
  } catch (err) {
    debugPrint('_kgSearch error: ${err.toString()}');
  }
  return results;
}

class NetLyricResult {
  final String? mainLyric;
  final String? transLyric;
  final String? romaLyric;
  final LyricFormat format;

  const NetLyricResult({
    required this.mainLyric,
    required this.transLyric,
    required this.romaLyric,
    required this.format,
  });

  bool get hasContent => mainLyric != null && mainLyric!.isNotEmpty;

  ParsedLyricResult? toParsedLyric() {
    if (!hasContent) return null;
    return LrcTool.parse(
      mainLyric!,
      transText: transLyric,
      romanizationText: romaLyric,
      rawContent: mainLyric,
    );
  }
}

class QmSearchItem {
  final String id;
  final String mid;
  final String title;
  final String artist;
  final String album;
  final int durationMs;

  const QmSearchItem({
    required this.id,
    required this.mid,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
  });
}

class NeSearchItem {
  final String id;
  final String title;
  final String artist;
  final String album;
  final int durationMs;

  const NeSearchItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
  });
}

class KgSearchItem {
  final String hash;
  final String id;
  final String title;
  final String artist;
  final String album;
  final int durationMs;

  const KgSearchItem({
    required this.hash,
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
  });
}

Future<List<QmSearchItem>> qqSearchLyric({
  required String keyword,
  int page = 1,
  int pageSize = 8,
}) async {
  return _qmSearch(
    text: keyword,
    offset: page,
    limit: pageSize,
  );
}

Future<NetLyricResult?> qqGetLyric({required int id, String? title, String? album, String? artist, int? durationSec}) async {
  if (title == null || album == null || artist == null || durationSec == null) {
    return NetLyricResult(
      mainLyric: null,
      transLyric: null,
      romaLyric: null,
      format: LyricFormat.qrc,
    );
  }
  final lyricData = await _qmGetLrcByLyrico(
    id: id,
    title: title,
    album: album,
    artist: artist,
    durationSec: durationSec,
  );
  return NetLyricResult(
    mainLyric: lyricData['lyric'],
    transLyric: lyricData['trans'],
    romaLyric: lyricData['roma'],
    format: LyricFormat.qrc,
  );
}

Future<NetLyricResult?> qqGetLyricById({required int id}) async {
  // 回退到旧API，如果不知道歌曲信息
  return _qmGetLrcFallback(id: id);
}

Future<NetLyricResult?> _qmGetLrcFallback({required int id}) async {
  final response = await _qmDio.get(
    'https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg',
    queryParameters: {"version": '15', "lrctype": '4', "musicid": id},
    options: Options(responseType: ResponseType.plain),
  );

  final String? body = response.data?.toString();
  if (body == null || body.isEmpty) {
    return NetLyricResult(
      mainLyric: null,
      transLyric: null,
      romaLyric: null,
      format: LyricFormat.qrc,
    );
  }

  final data = _qrcParseLyricByRegex(body);
  String? encryptedOriginal = data['lyric'];
  String? encryptedTranslate = data['trans'];
  String? decryptedRoma = data['roma'];

  String? qrcDecrypted;
  String? translateDecrypted;

  if (encryptedOriginal != null && encryptedOriginal.isNotEmpty) {
    if (!encryptedOriginal.trimLeft().startsWith('<?xml') &&
        !encryptedOriginal.trimLeft().startsWith('<Qrc')) {
      try {
        qrcDecrypted = await qrcDecrypt(
          encryptedQrc: encryptedOriginal,
          isLocal: false,
        );
      } catch (e) {
        debugPrint('_qmGetLrcFallback qrcDecrypt original error: $e');
        qrcDecrypted = null;
      }
    }
  }

  if (encryptedTranslate != null && encryptedTranslate.isNotEmpty) {
    if (!encryptedTranslate.contains("[00") &&
        !encryptedTranslate.contains("[al")) {
      try {
        translateDecrypted = await qrcDecrypt(
          encryptedQrc: encryptedTranslate,
          isLocal: false,
        );
      } catch (e) {
        debugPrint('_qmGetLrcFallback qrcDecrypt translate error: $e');
        translateDecrypted = null;
      }
    } else {
      translateDecrypted = encryptedTranslate;
    }
  }

  return NetLyricResult(
    mainLyric: qrcDecrypted,
    transLyric: translateDecrypted,
    romaLyric: decryptedRoma,
    format: LyricFormat.qrc,
  );
}

List<QmSearchItem> _parseQmSearchResults(Map<String, dynamic> data) {
  final List<QmSearchItem> results = [];
  try {
    final songList = data["req_0"]?["data"]?["body"]?["item_song"]?.cast<Map<String, dynamic>>();
    if (songList == null || songList.isEmpty) {
      return [];
    }

    for (final item in songList) {
      final singerList = item["singer"] as List?;
      String? singer;
      if (singerList != null && singerList.isNotEmpty) {
        singer = singerList.map((s) => s["name"]?.toString()).where((n) => n != null).join('、');
      }

      results.add(QmSearchItem(
        id: item["id"]?.toString() ?? '',
        mid: item["mid"]?.toString() ?? '',
        title: item["title"] ?? 'UNKNOWN',
        artist: singer ?? 'UNKNOWN',
        album: item["album"]?["name"]?.toString() ?? '',
        durationMs: int.tryParse(item["interval"]?.toString() ?? '0') ?? 0,
      ));
    }
  } catch (err) {
    debugPrint('_parseQmSearchResults error: ${err.toString()}');
  }
  return results;
}

Future<List<QmSearchItem>> _qmSearch({
  required String text,
  required int offset,
  required int limit,
}) async {
  try {
    final Map<String, dynamic> data = await _qmSearchByLyrico(
      text: text,
      offset: offset,
      limit: limit,
    );
    if (data == null) return [];
    return _parseQmSearchResults(data);
  } catch (err) {
    debugPrint('_qmSearch error: ${err.toString()}');
    return [];
  }
}

Map<String, String?> _qrcParseLyricByRegex(String rawXml) {
  String? extract(String tagName) {
    final regExp = RegExp(
      '<$tagName[^>]*><!\\[CDATA\\[([\\s\\S]*?)\\]\\]><\\/$tagName>',
      caseSensitive: false,
    );
    final match = regExp.firstMatch(rawXml);
    return match?.group(1);
  }

  return {
    'lyric': extract('content'),
    'trans': extract('contentts'),
    'roma': extract('contentroma'),
  };
}

Future<List<NeSearchItem>> neSearchLyric({
  required String keyword,
  int page = 1,
  int pageSize = 8,
}) async {
  return _neSearch(
    text: keyword,
    offset: page,
    limit: pageSize,
  );
}

Future<NetLyricResult?> neGetLyric({required int id}) async {
  return _neGetLrc(id: id);
}

Future<List<KgSearchItem>> kgSearchLyric({
  required String keyword,
  int page = 1,
  int pageSize = 8,
}) async {
  return _kgSearch(
    text: keyword,
    offset: page,
    limit: pageSize,
  );
}

Future<NetLyricResult?> kgGetLyric({required String hash}) async {
  return _kgGetLrc(id: hash);
}
