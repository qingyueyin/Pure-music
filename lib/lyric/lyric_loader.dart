import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/ttml.dart';
import 'package:pure_music/lyric/karaok_parser.dart';
import 'package:pure_music/lyric/lyric_stripper.dart';
import 'package:pure_music/lyric/exclude_data.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/services/online_lyric/api/krc_decryptor.dart';
import 'package:pure_music/services/online_lyric/api/qrc_decryptor.dart';
import 'package:fl_charset/fl_charset.dart';

// ──────────────────────────────────────────────
// 支持的歌词扩展名（按优先级从高到低）
// ──────────────────────────────────────────────
const _kLyricExts = ['.yrc', '.qrc', '.krc', '.ttml', '.lrc'];

/// 编码检测优先级（仅用于 UTF-8 解码失败后的 fallback）
/// 不包含 ascii——utf8 完全覆盖 ascii，且 ascii 检测会误判中文文件。
/// 不包含过多的 latin 变体——它们几乎不会用在 LRC 文件中，徒增误检概率。
final _kFallbackEncodings = <Encoding>[
  utf8,
  gbk,
  shiftJis,
  eucJp,
  eucKr,
  windows874,
  latin1,
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
  // 不硬编码元素名，匹配任一元素上的 LyricContent 属性
  final match = RegExp(
    r'LyricContent\s*=\s*"([\s\S]*?)"\s*/?\s*>',
    dotAll: true,
  ).firstMatch(raw);
  if (match == null) return null;
  // 对 HTML 实体解码（引号、尖括号等）
  return _decodeXmlEntities(match.group(1)!);
}

String _decodeXmlEntities(String text) {
  return text
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&#10;', '\n')
      .replaceAll('&#13;', '\r');
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
// 搜索目录下包含歌曲名的歌词文件（模糊匹配，按 exts 优先级）
// ──────────────────────────────────────────────
Future<_ExternalLyricResult?> _findLyricInDirectory(
  Directory dir,
  String songName,
  List<String> exts,
) async {
  if (!await dir.exists()) return null;

  try {
    final songNameLower = songName.toLowerCase();
    _ExternalLyricResult? best;
    int bestPriority = 999;

    await for (final entity in dir.list()) {
      if (entity is File) {
        final ext = p.extension(entity.path).toLowerCase();
        final priority = exts.indexOf(ext);
        if (priority == -1) continue;

        final base = p.basenameWithoutExtension(entity.path).toLowerCase();
        if (!base.contains(songNameLower)) continue;

        // 已找到更高优先级的，跳过
        if (priority >= bestPriority) continue;

        final content = await _safeReadFile(entity.path);
        if (content != null && content.trim().isNotEmpty) {
          logger.i('lyric_loader:   fuzzy match OK: $ext ($base)');
          best = _ExternalLyricResult(content: content, ext: ext);
          bestPriority = priority;
        }
      }
    }
    return best;
  } catch (e) {
    logger.e('lyric_loader: error scanning directory: $e');
    return null;
  }
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

    // ── LRC / YRC：优先 UTF-8 解码（覆盖 95%+ 文件） ──
    try {
      return utf8.decode(bytes);
    } catch (_) {
      // UTF-8 解码失败，走编码检测 fallback
    }

    final detected = Charset.detect(bytes, orders: _kFallbackEncodings);
    if (detected != null) {
      try {
        return detected.decode(bytes);
      } catch (_) {}
    }

    // 终极 fallback：容忍乱码
    return utf8.decode(bytes, allowMalformed: true);
  } catch (e) {
    logger.e('lyric_loader: error reading $filePath: $e');
    return null;
  }
}

// ──────────────────────────────────────────────
// 读取外挂歌词文件（按优先级搜索）
// ──────────────────────────────────────────────
Future<_ExternalLyricResult?> _loadExternalLyric(String audioPath) async {
  final paths = _candidatePaths(audioPath, _kLyricExts);
  final songName = p.basenameWithoutExtension(audioPath);

  logger.i('lyric_loader: checking paths: $paths');
  for (final path in paths) {
    final content = await _safeReadFile(path);
    logger.i('lyric_loader:   $path -> ${content != null ? 'found(len=${content.length})' : 'null'}');
    if (content == null || content.trim().isEmpty) continue;

    final ext = p.extension(path).toLowerCase();

    String? transContent;

    // YRC / QRC / KRC / TTML：尝试配对读取同目录 .lrc 作为翻译
    if (ext == '.yrc' || ext == '.qrc' || ext == '.krc' || ext == '.ttml') {
      final vtsPaths = _candidatePaths(audioPath, ['.lrc']);
      for (final vp in vtsPaths) {
        final tc = await _safeReadFile(vp);
        if (tc != null && tc.trim().isNotEmpty) {
          transContent = tc;
          break;
        }
      }
      transContent ??= (await _findLyricInDirectory(
        Directory(p.dirname(audioPath)),
        songName,
        ['.lrc'],
      ))?.content;
    }

    return _ExternalLyricResult(
      content: content,
      ext: ext,
      transContent: transContent,
    );
  }

  logger.i('lyric_loader: exact match failed, trying fuzzy match...（all exts）');
  // ── 精确同名文件未找到，尝试同目录模糊匹配（所有支持格式，按优先级）──
  final dir = Directory(p.dirname(audioPath));
  final fuzzy = await _findLyricInDirectory(dir, songName, _kLyricExts);
  if (fuzzy != null) return fuzzy;

  // ── 同目录模糊匹配失败，尝试父目录模糊匹配 ──
  final parent = dir.parent;
  if (parent.path != dir.path) {
    final parentFuzzy = await _findLyricInDirectory(parent, songName, _kLyricExts);
    if (parentFuzzy != null) return parentFuzzy;
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
      // YRC/QRC/KRC 使用 KaraOK 解析器（正则健壮、时间戳正确）
      return parseKaraokToPureLyric(
        result.ext,
        result.content,
        result.transContent,
      );
    case '.lrc':
      return Lrc.fromLrcTextAuto(result.content, LyricFormat.local,
          separator: separator);
    case '.ttml':
      return Ttml.fromTtmlText(result.content, separator: separator);
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
/// 1. 在音频文件同目录搜索外挂歌词文件（.yrc > .qrc > .krc > .ttml > .lrc）
/// 2. 自动检测文件编码，解密加密的 KRC/QRC
/// 3. 外挂 YRC/QRC 自动配对同目录 .lrc 作为翻译
/// 4. 若无外挂文件，回退到 Rust FFI 读取音频标签内嵌歌词
/// 5. 内嵌歌词自动检测 TTML / 增强 LRC / 逐字 LRC / 普通 LRC
Future<Lyric?> loadLyricFromAudio(
  String audioPath, {
  String? separator = '┃',
}) async {
  logger.i('lyric_loader: loading for $audioPath');

  // ── 第 1 步：外挂歌词文件 ──
  final external = await _loadExternalLyric(audioPath);

  // 如果有外部歌词，检查内嵌歌词是否有逐字标签（如用户手动写入的场景）
  String? embeddedRaw;
  bool? embeddedHasWordTags; // null = not fetched yet

  if (external != null) {
    try {
      embeddedRaw = await getLyricFromPath(path: audioPath);
    } catch (_) {}
    embeddedHasWordTags = embeddedRaw != null &&
        RegExp(r'<(\d+:\d+\.\d+|\d+)>').hasMatch(embeddedRaw);

    if (embeddedHasWordTags) {
      logger.i(
          'lyric_loader: embedded has word tags, preferring over external');
    } else {
      logger.i(
          'lyric_loader: found external ${external.ext}, content len=${external.content.length}');
      final lyric = _parseExternalToPureLyric(external, separator: separator);
      if (lyric != null && lyric.lines.isNotEmpty) {
        logger.i(
            'lyric_loader: loaded external ${external.ext} for $audioPath');
        final stripped = _stripMetadata(lyric);
        logger.i('lyric_loader: external return lines=${stripped?.lines.length ?? "null"}');
        return stripped;
      } else {
        logger.i('lyric_loader: external ${external.ext} parse FAILED');
      }
    }
  } else {
    logger.i('lyric_loader: no external lyric found');
  }

  // ── 第 2 步：内嵌歌词 ──
  try {
    final embedded = embeddedHasWordTags == true
        ? embeddedRaw
        : await getLyricFromPath(path: audioPath);
    if (embedded != null && embedded.isNotEmpty) {
      logger.i(
          'lyric_loader: embedded lyric found, len=${embedded.length}, preview=${embedded.length > 80 ? embedded.substring(0, 80) : embedded}');
      final lyric = _parseEmbeddedToPureLyric(embedded, separator: separator);
      if (lyric != null && lyric.lines.isNotEmpty) {
        logger.i(
            'lyric_loader: loaded embedded lyric for $audioPath, lines=${lyric.lines.length}');
        final stripped = _stripMetadata(lyric);
        logger.i('lyric_loader: embedded return lines=${stripped?.lines.length ?? "null"}');
        return stripped;
      } else {
        logger.i('lyric_loader: embedded lyric parse FAILED');
      }
    } else {
      logger.i('lyric_loader: no embedded lyric found');
    }
  } catch (e) {
    logger.i('lyric_loader: embedded catch: $e');
    logger.e('lyric_loader: error reading embedded lyric: $e');
  }

  logger.i('lyric_loader: returning null for $audioPath');
  return null;
}

Lyric? _stripMetadata(Lyric lyric) {
  final regList = defaultExcludeRegexes
      .map((p) => RegExp(p, caseSensitive: false))
      .toList();
  final softRegList = defaultExcludeSoftRegexes
      .map((p) => RegExp(p, caseSensitive: false))
      .toList();
  final options = StripOptions(
    keywords: defaultExcludeKeywords,
    regexes: regList,
    softRegexes: softRegList,
  );
  final filtered = stripLyricMetadata(lyric.lines, options);
  if (!identical(lyric.lines, filtered)) {
    lyric.lines
      ..clear()
      ..addAll(filtered);
  }
  return lyric;
}
