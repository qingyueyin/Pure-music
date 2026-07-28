import 'dart:isolate';

import 'package:pure_music/native/rust/api/amll_ttml.dart' as frb_amll;

import 'package:pure_music/services/online_lyric/models/lyric_entry.dart';
import 'package:pure_music/services/online_lyric/parsers/lrc_tool.dart';
import 'package:pure_music/services/online_lyric/api/krc_decryptor.dart';
import 'package:pure_music/services/online_lyric/api/qrc_decryptor.dart';
import 'package:pure_music/services/online_lyric/api/krc_extract_decode.dart';
import 'package:pure_music/services/online_lyric/api/isolate_helpers.dart' as iso;

// ──────────────────────────────────────────────
// 搜索结果模型
// ──────────────────────────────────────────────

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

// ──────────────────────────────────────────────
// 歌词结果
// ──────────────────────────────────────────────

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

  Future<ParsedLyricResult?> toParsedLyric() async {
    if (!hasContent) return null;
    return Isolate.run(() {
      return LrcTool.parse(
        mainLyric!,
        transText: transLyric,
        romanizationText: romaLyric,
      );
    });
  }
}

// LRC metadata patterns to strip (e.g., [ar:Artist], [ti:Title], [by:Editor])
final _lrcMetadataRegex = RegExp(
  r'^\s*\[(ar|ti|al|au|length|by|re|ve|offset|id|uid|arid|ty|lang|tlyric|language):[^\]]*\]\s*$',
  multiLine: true,
  caseSensitive: false,
);

/// Strip LRC metadata tags (ar/ti/al/by/etc.) while preserving timestamp lines and lyric content.
String _stripLrcMetadata(String text) {
  return text.split('\n').where((line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return true;
    if (_lrcMetadataRegex.hasMatch(trimmed)) return false;
    return true;
  }).join('\n');
}

// ──────────────────────────────────────────────
// QQ 音乐
// ──────────────────────────────────────────────

Future<List<QmSearchItem>> qqSearchLyric({
  required String keyword,
  int page = 1,
  int pageSize = 8,
}) async {
  final rawResults = await iso.qqSearchIsolate(
    text: keyword,
    offset: page,
    limit: pageSize,
  );
  return rawResults.map((e) {
    final item = e as Map;
    return QmSearchItem(
      id: item['id'] as String,
      mid: item['mid'] as String,
      title: item['title'] as String,
      artist: item['artist'] as String,
      album: item['album'] as String,
      durationMs: (item['interval'] as int) * 1000,
    );
  }).toList();
}

Future<NetLyricResult?> qqGetLyric({
  required int id,
  String? title,
  String? album,
  String? artist,
  int? durationSec,
}) async {
  final lyricData = await iso.qqLyricIsolate(
    id: id,
    title: title,
    album: album,
    artist: artist,
    durationSec: durationSec,
  );

  Future<String?> decrypt(String? raw) async {
    if (raw == null || raw.isEmpty) return null;
    if (raw.contains('[00') || raw.startsWith('[')) return raw;
    final decrypted = await qrcDecryptSingle(raw);
    if (decrypted == null) return null;
    return _stripLrcMetadata(decrypted);
  }

  return NetLyricResult(
    mainLyric: await decrypt(lyricData['encryptedLyric']),
    transLyric: await decrypt(lyricData['encryptedTrans']),
    romaLyric: await decrypt(lyricData['roma']),
    format: LyricFormat.qrc,
  );
}

Future<NetLyricResult?> qqGetLyricById({required int id}) async {
  return qqGetLyric(id: id);
}

// ──────────────────────────────────────────────
// 网易云
// ──────────────────────────────────────────────

Future<List<NeSearchItem>> neSearchLyric({
  required String keyword,
  int page = 1,
  int pageSize = 8,
}) async {
  final rawResults = await iso.neSearchIsolate(
    text: keyword,
    offset: (page - 1) * pageSize,
    limit: pageSize,
  );
  return rawResults.map((e) {
    final item = e as Map<String, dynamic>;
    final artistList = item['artist'];
    return NeSearchItem(
      id: item['id'] as String,
      title: item['name'] as String,
      artist: (artistList ?? 'UNKNOWN') as String,
      album: item['album'] as String,
      durationMs: item['dt'] as int,
    );
  }).toList();
}

Future<NetLyricResult?> neGetLyric({required int id}) async {
  final result = await iso.neLyricIsolate(id: id);
  final main = result['main'];
  if (main == null || main.isEmpty) return null;
  final format = result['format'] == 'yrc' ? LyricFormat.yrc : LyricFormat.lrc;
  final isLrcFormat = format == LyricFormat.lrc;
  return NetLyricResult(
    mainLyric: isLrcFormat ? _stripLrcMetadata(main) : main,
    transLyric: isLrcFormat && result['trans'] != null
        ? _stripLrcMetadata(result['trans']!)
        : result['trans'],
    romaLyric: isLrcFormat && result['roma'] != null
        ? _stripLrcMetadata(result['roma']!)
        : result['roma'],
    format: format,
  );
}

// ──────────────────────────────────────────────
// 酷狗
// ──────────────────────────────────────────────

Future<List<KgSearchItem>> kgSearchLyric({
  required String keyword,
  int page = 1,
  int pageSize = 8,
}) async {
  final rawResults = await iso.kgSearchIsolate(
    text: keyword,
    offset: page,
    limit: pageSize,
  );
  return rawResults.map((e) {
    final item = e as Map;
    return KgSearchItem(
      hash: item['hash'] as String,
      id: item['id'] as String,
      title: item['songname'] as String,
      artist: item['singername'] as String,
      album: item['album_name'] as String,
      durationMs: (int.tryParse(item['duration']?.toString() ?? '0') ?? 0) * 1000,
    );
  }).toList();
}

Future<NetLyricResult?> kgGetLyric({required String hash}) async {
  final result = await iso.kgLyricIsolate(hash: hash);
  final encrypted = result['encrypted'];
  if (encrypted == null || encrypted.isEmpty) return null;

  final decrypted = await krcDecryptSingle(encrypted);
  if (decrypted == null) return null;

  final langData = extractKrcLanguage(decrypted);
  return NetLyricResult(
    mainLyric: decrypted,
    transLyric: langData?.translation,
    romaLyric: langData?.romanization,
    format: LyricFormat.krc,
  );
}

// ──────────────────────────────────────────────
// AMLL TTML 歌词库 (Rust FRB)
// ──────────────────────────────────────────────

typedef AmllSearchItem = frb_amll.AmllSearchItem;

Future<List<AmllSearchItem>> amllSearchSingle({
  required String keyword,
  int page = 1,
  int pageSize = 15,
}) =>
    frb_amll.amllSearchLyrics(
      keyword: keyword,
      page: page,
      pageSize: pageSize,
    );

Future<String?> amllGetTtml(String id) =>
    frb_amll.amllGetTtml(id: id);

void amllClearCache() => frb_amll.amllClearCache();
