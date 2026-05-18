import 'dart:convert';

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

  ParsedLyricResult? toParsedLyric() {
    if (!hasContent) return null;
    return LrcTool.parse(
      mainLyric!,
      transText: transLyric,
      romanizationText: romaLyric,
    );
  }
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
    return qrcDecryptSingle(raw);
  }

  return NetLyricResult(
    mainLyric: await decrypt(lyricData['encryptedLyric'] as String?),
    transLyric: await decrypt(lyricData['encryptedTrans'] as String?),
    romaLyric: await decrypt(lyricData['roma'] as String?),
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
    offset: page,
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
  return NetLyricResult(
    mainLyric: main,
    transLyric: result['trans'],
    romaLyric: result['roma'],
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
  final encrypted = result['encrypted'] as String?;
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
