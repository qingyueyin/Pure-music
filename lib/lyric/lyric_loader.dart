import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/ttml.dart';
import 'package:pure_music/lyric/karaok_parser.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/services/online_lyric/api/krc_decryptor.dart';
import 'package:pure_music/services/online_lyric/api/qrc_decryptor.dart';
import 'package:fl_charset/fl_charset.dart';

// ──────────────────────────────────────────────
// 支持的歌词扩展名（按优先级从高到低）
// ──────────────────────────────────────────────
const _kLyricExts = ['.yrc', '.qrc', '.krc', '.lrc'];

/// 编码检测优先级
final _kEncodingOrders = <Encoding>[
  ascii,
  utf8,
  gbk,
  shiftJis,
  eucJp,
  eucKr,
  windows874,
  latin1,
  latin2,
  latin3,
  latin4,
  latinCyrillic,
  latinArabic,
  latinGreek,
  latinHebrew,
  latin5,
  latin6,
  latinThai,
  latin7,
  latin8,
  latin9,
  latin10,
];

// ──────────────────────────────────────────────
// 内部数据：外挂文件读取结果
// ──────────────────────────────────────────────
class _ExternalLyricResult {
  final String content;
  final String ext;
  final String? transContent;
  const _ExternalLyricResult({
    required this.content,
    required this.ext,
    this.transContent,
  });
}

// ──────────────────────────────────────────────
// QRC XML 包裹提取（LyricContent 属性）
// ──────────────────────────────────────────────
String? _extractQrcContent(String raw) {
  // 匹配 <Lyric_1 ... LyricContent="..." ... />
  final match = RegExp(
    r'<Lyric_1\s[^>]*LyricContent="([^"]*)"[^/]*/>',
    dotAll: true,
  ).firstMatch(raw);
  if (match == null) return null;
  // 对 HTML 实体解码（引号、尖括号等）
  return match.group(1)!
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'");
}

// ──────────────────────────────────────────────
// 路径生成
// ──────────────────────────────────────────────
List<String> _candidatePaths(String filePath, List<String> exts) {
  final dir = p.dirname(filePath);
  final base = p.basenameWithoutExtension(filePath);
  return exts.map((e) => p.join(dir, '$base$e')).toList();
}

// ──────────────────────────────────────────────
// 安全读文件（编码检测 + 解密）
// ──────────────────────────────────────────────
Future<String?> _safeReadFile(String filePath) async {
  try {
    final file = File(filePath);
    if (!await file.exists()) return null;

    final bytes = await file.readAsBytes();
    final ext = p.extension(filePath).toLowerCase();

    // ── QRC：可能加密，先尝试解密 ──
    if (ext == '.qrc') {
      // 尝试解码为文本判断是否已经是 XML 明文
      final asText = utf8.decode(bytes, allowMalformed: true);
      if (!asText.trimLeft().startsWith('<?xml') &&
          !asText.trimLeft().startsWith('<Qrc')) {
        final decrypted = await qrcDecrypt(encryptedQrc: bytes, isLocal: true);
        if (decrypted != null) {
          return _extractQrcContent(decrypted) ?? decrypted;
        }
      }
      return _extractQrcContent(asText) ?? asText;
    }

    // ── KRC：可能加密（Base64），需要检测 ──
    if (ext == '.krc') {
      final asText = utf8.decode(bytes, allowMalformed: true);
      if (!asText.trimLeft().startsWith('[ti:') &&
          !asText.trimLeft().contains(']\u003C0') &&
          !asText.trimLeft().startsWith('[')) {
        final decrypted = await compute(krcDecrypt, asText);
        if (decrypted != null) return decrypted;
      }
      return asText;
    }

    // ── LRC / YRC：编码检测 ──
    final detected = Charset.detect(bytes, orders: _kEncodingOrders);
    if (detected == null) {
      // fallback：用 utf8 尝试解码
      return utf8.decode(bytes, allowMalformed: true);
    }
    return detected.decode(bytes);
  } catch (e) {
    debugPrint('lyric_loader: error reading $filePath: $e');
    return null;
  }
}

// ──────────────────────────────────────────────
// 读取外挂歌词文件（按优先级搜索）
// ──────────────────────────────────────────────
Future<_ExternalLyricResult?> _loadExternalLyric(String audioPath) async {
  final paths = _candidatePaths(audioPath, _kLyricExts);

  for (final path in paths) {
    final content = await _safeReadFile(path);
    if (content == null || content.trim().isEmpty) continue;

    final ext = p.extension(path).toLowerCase();

    String? transContent;

    // YRC / QRC：尝试配对读取同目录 .lrc 作为翻译
    if (ext == '.yrc' || ext == '.qrc') {
      final vtsPaths = _candidatePaths(audioPath, ['.lrc']);
      for (final vp in vtsPaths) {
        final tc = await _safeReadFile(vp);
        if (tc != null && tc.trim().isNotEmpty) {
          transContent = tc;
          break;
        }
      }
    }

    return _ExternalLyricResult(
      content: content,
      ext: ext,
      transContent: transContent,
    );
  }

  return null;
}

// ──────────────────────────────────────────────
// 将外挂文件解析为 Pure Music 的 Lyric 类型
// ──────────────────────────────────────────────
Lyric? _parseExternalToPureLyric(
  _ExternalLyricResult result, {
  String? separator = '┃',
}) {
  switch (result.ext) {
    case '.yrc':
    case '.qrc':
    case '.krc':
      // YRC/QRC/KRC 使用 ZeroBit 移植的 KaraOK 解析器（正则健壮、时间戳正确）
      return parseKaraokToPureLyric(
        result.ext,
        result.content,
        result.transContent,
      );
    case '.lrc':
      return Lrc.fromLrcTextAuto(result.content, LyricFormat.local,
          separator: separator);
    default:
      return null;
  }
}

// ──────────────────────────────────────────────
// 将 Rust 内嵌歌词解析为 Pure Music 的 Lyric 类型
// ──────────────────────────────────────────────
Lyric? _parseEmbeddedToPureLyric(String embeddedLyric,
    {String? separator = '┃'}) {
  // 先检测格式
  if (embeddedLyric.trimLeft().startsWith('<?xml') ||
      embeddedLyric.trimLeft().startsWith('<tt') ||
      embeddedLyric.contains('<body>')) {
    // TTML 格式
    return Ttml.fromTtmlText(embeddedLyric, separator: separator);
  }

  // 按 LRC 及其变体解析
  return Lrc.fromLrcTextAuto(embeddedLyric, LyricFormat.local,
      separator: separator);
}

// ──────────────────────────────────────────────
// 🎯 对外统一入口：加载歌词（外挂优先 → 内嵌回退）
// ──────────────────────────────────────────────

/// 加载音频文件的歌词。
///
/// 策略：
/// 1. 在音频文件同目录搜索外挂歌词文件（.yrc > .qrc > .krc > .lrc）
/// 2. 自动检测文件编码，解密加密的 KRC/QRC
/// 3. 外挂 YRC/QRC 自动配对同目录 .lrc 作为翻译
/// 4. 若无外挂文件，回退到 Rust FFI 读取音频标签内嵌歌词
/// 5. 内嵌歌词自动检测 TTML / 增强 LRC / 逐字 LRC / 普通 LRC
Future<Lyric?> loadLyricFromAudio(
  String audioPath, {
  String? separator = '┃',
}) async {
  // ── 第 1 步：外挂歌词文件 ──
  final external = await _loadExternalLyric(audioPath);
  if (external != null) {
    final lyric = _parseExternalToPureLyric(external, separator: separator);
    if (lyric != null && lyric.lines.isNotEmpty) {
      debugPrint(
          'lyric_loader: loaded external ${external.ext} for $audioPath');
      return lyric;
    }
  }

  // ── 第 2 步：内嵌歌词 ──
  try {
    final embedded = await getLyricFromPath(path: audioPath);
    if (embedded != null && embedded.isNotEmpty) {
      final lyric = _parseEmbeddedToPureLyric(embedded, separator: separator);
      if (lyric != null && lyric.lines.isNotEmpty) {
        debugPrint('lyric_loader: loaded embedded lyric for $audioPath');
        return lyric;
      }
    }
  } catch (e) {
    debugPrint('lyric_loader: error reading embedded lyric: $e');
  }

  return null;
}
