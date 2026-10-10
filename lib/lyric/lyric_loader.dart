import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/core/log/log_record.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/ttml.dart';
import 'package:pure_music/lyric/vtt.dart';
import 'package:pure_music/lyric/karaok_parser.dart';
import 'package:pure_music/lyric/lyric_stripper.dart';
import 'package:pure_music/lyric/exclude_data.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/services/online_lyric/api/krc_decryptor.dart';
import 'package:pure_music/services/online_lyric/api/qrc_decryptor.dart';
import 'package:fl_charset/fl_charset.dart';

// ──────────────────────────────────────────────
// 支持的歌词扩展名（按优先级从高到低）
// ──────────────────────────────────────────────
LogRecord lyricLoadRecord({
  required bool found,
  required String source,
  required int lines,
  required int elapsedMs,
}) {
  return LogRecord(
    time: DateTime.now(),
    level: LogLevel.info,
    module: LogModule.lyric,
    event: found ? 'lyric.loaded' : 'lyric.missing',
    message: found ? '歌词已加载' : '没有歌词',
    fields: {'source': source, 'lines': lines, 'elapsedMs': elapsedMs},
  );
}

const supportedLyricFileExtensions = [
  '.yrc',
  '.qrc',
  '.krc',
  '.ttml',
  '.lrc',
  '.vtt',
];

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
          log.lyric.debug(
            'lyric.candidate',
            'lyric_loader: fuzzy match OK: $ext',
          );
          best = _ExternalLyricResult(content: content, ext: ext);
          bestPriority = priority;
        }
      }
    }
    return best;
  } catch (e) {
    log.lyric.error(
      'legacy',
      'lyric_loader: directory scan failed: ${e.runtimeType}',
    );
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
    log.lyric.error(
      'legacy',
      'lyric_loader: file read failed: ${e.runtimeType}',
    );
    return null;
  }
}

// ──────────────────────────────────────────────
// 读取外挂歌词文件（按优先级搜索）
// ──────────────────────────────────────────────
Future<_ExternalLyricResult?> _loadExternalLyric(String audioPath) async {
  final paths = _candidatePaths(audioPath, supportedLyricFileExtensions);
  final songName = p.basenameWithoutExtension(audioPath);

  log.lyric.debug(
    'lyric.candidate',
    'lyric_loader: checking ${paths.length} candidate paths',
  );
  for (final path in paths) {
    final content = await _safeReadFile(path);
    log.lyric.debug(
      'lyric.candidate',
      'lyric_loader: candidate ${content != null ? 'found(len=${content.length})' : 'not found'}',
    );
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

  log.lyric.debug(
    'lyric.candidate',
    'lyric_loader: exact match failed, trying fuzzy match...（all exts）',
  );
  // ── 精确同名文件未找到，尝试同目录模糊匹配（所有支持格式，按优先级）──
  final dir = Directory(p.dirname(audioPath));
  final fuzzy = await _findLyricInDirectory(
    dir,
    songName,
    supportedLyricFileExtensions,
  );
  if (fuzzy != null) return fuzzy;

  // ── 同目录模糊匹配失败，尝试父目录模糊匹配 ──
  final parent = dir.parent;
  if (parent.path != dir.path) {
    final parentFuzzy = await _findLyricInDirectory(
      parent,
      songName,
      supportedLyricFileExtensions,
    );
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
      return Lrc.fromLrcTextAuto(
        result.content,
        LyricFormat.local,
        separator: separator,
      );
    case '.ttml':
      return Ttml.fromTtmlText(result.content, separator: separator);
    case '.vtt':
      return Vtt.fromVttText(result.content, separator: separator);
    default:
      return null;
  }
}

// ──────────────────────────────────────────────
// 将 Rust 内嵌歌词解析为 Pure Music 的 Lyric 类型
// ──────────────────────────────────────────────
@visibleForTesting
bool isVttLyricText(String text) {
  final withoutBom = text.startsWith('\uFEFF') ? text.substring(1) : text;
  return withoutBom.trimLeft().startsWith('WEBVTT');
}

Lyric? _parseEmbeddedToPureLyric(
  String embeddedLyric, {
  String? separator = '┃',
}) {
  // 先检测格式
  if (isVttLyricText(embeddedLyric)) {
    return Vtt.fromVttText(embeddedLyric, separator: separator);
  }
  if (embeddedLyric.trimLeft().startsWith('<?xml') ||
      embeddedLyric.trimLeft().startsWith('<tt') ||
      embeddedLyric.contains('<body>')) {
    // TTML 格式
    return Ttml.fromTtmlText(embeddedLyric, separator: separator);
  }

  // 按 LRC 及其变体解析
  return Lrc.fromLrcTextAuto(
    embeddedLyric,
    LyricFormat.local,
    separator: separator,
  );
}

// ──────────────────────────────────────────────
// 🎯 对外统一入口：加载歌词（外挂优先 → 内嵌回退）
// ──────────────────────────────────────────────

/// 加载音频文件的歌词，同时返回实际来源标记。
///
/// 策略：
/// 1. 在音频文件同目录搜索外挂歌词文件（.yrc > .qrc > .krc > .ttml > .lrc > .vtt）
/// 2. 自动检测文件编码，解密加密的 KRC/QRC
/// 3. 外挂 YRC/QRC 自动配对同目录 .lrc 作为翻译
/// 4. 若无外挂文件，回退到 Rust FFI 读取音频标签内嵌歌词
/// 5. 内嵌歌词自动检测 TTML / 增强 LRC / 逐字 LRC / 普通 LRC
///
/// 返回 `({Lyric lyric, bool isExternal})?`：
/// - `isExternal == true`：歌词来自外置文件
/// - `isExternal == false`：歌词来自音频内嵌标签
Future<({Lyric lyric, bool isExternal})?> loadLyricFromAudio(
  String audioPath, {
  String? separator = '┃',
}) async {
  final watch = Stopwatch()..start();
  log.lyric.debug('lyric.candidate', 'lyric_loader: loading');

  // ── 第 1 步：外挂歌词文件 ──
  final external = await _loadExternalLyric(audioPath);

  // 如果有外部歌词，检查内嵌歌词是否有逐字标签（如用户手动写入的场景）
  if (external != null) {
    String? embeddedRaw;
    try {
      embeddedRaw = await getLyricFromPath(path: audioPath);
    } catch (_) {}
    final embeddedHasWordTags =
        embeddedRaw != null &&
        (RegExp(r'<(\d+:\d+\.\d+|\d+)>').hasMatch(embeddedRaw) ||
            embeddedRaw.contains('[awlrc:'));

    if (embeddedHasWordTags) {
      log.lyric.debug(
        'lyric.candidate',
        'lyric_loader: embedded has word tags, preferring over external',
      );
      // 内嵌标签可能损坏（如 LX 标签负载不可用）：确认解析出可用行后才优先使用，
      // 否则回退到外挂歌词。
      Lyric? embedded;
      try {
        embedded = _parseEmbeddedToPureLyric(embeddedRaw, separator: separator);
      } catch (_) {}
      final embeddedStripped = embedded == null
          ? null
          : _stripMetadata(embedded);
      if (embeddedStripped != null &&
          embeddedStripped.lines.isNotEmpty &&
          embeddedStripped.isWordByWord) {
        log.lyric.debug(
          'lyric.candidate',
          'lyric_loader: loaded embedded lyric, lines=${embeddedStripped.lines.length}',
        );
        _reportLyricLoad(
          found: true,
          source: 'embedded',
          lines: embeddedStripped.lines.length,
          elapsedMs: watch.elapsedMilliseconds,
        );
        return (lyric: embeddedStripped, isExternal: false);
      }
      log.lyric.debug(
        'lyric.candidate',
        'lyric_loader: embedded word-tag lyric unusable, falling back to external',
      );
    } else {
      log.lyric.debug(
        'lyric.candidate',
        'lyric_loader: found external ${external.ext}, content len=${external.content.length}',
      );
    }

    final lyric = _parseExternalToPureLyric(external, separator: separator);
    if (lyric != null && lyric.lines.isNotEmpty) {
      log.lyric.debug(
        'lyric.candidate',
        'lyric_loader: loaded external ${external.ext}',
      );
      final stripped = _stripMetadata(lyric);
      log.lyric.debug(
        'lyric.candidate',
        'lyric_loader: external return lines=${stripped?.lines.length ?? "null"}',
      );
      if (stripped != null) {
        _reportLyricLoad(
          found: true,
          source: 'external',
          lines: stripped.lines.length,
          elapsedMs: watch.elapsedMilliseconds,
        );
        return (lyric: stripped, isExternal: true);
      }
    } else {
      log.lyric.debug(
        'lyric.candidate',
        'lyric_loader: external ${external.ext} parse FAILED',
      );
    }
  } else {
    log.lyric.debug('lyric.candidate', 'lyric_loader: no external lyric found');
  }

  // ── 第 2 步：内嵌歌词 ──
  try {
    final embedded = await getLyricFromPath(path: audioPath);
    if (embedded != null && embedded.isNotEmpty) {
      log.lyric.debug(
        'lyric.candidate',
        'lyric_loader: embedded lyric found, len=${embedded.length}',
      );
      final lyric = _parseEmbeddedToPureLyric(embedded, separator: separator);
      if (lyric != null && lyric.lines.isNotEmpty) {
        log.lyric.debug(
          'lyric.candidate',
          'lyric_loader: loaded embedded lyric, lines=${lyric.lines.length}',
        );
        final stripped = _stripMetadata(lyric);
        log.lyric.debug(
          'lyric.candidate',
          'lyric_loader: embedded return lines=${stripped?.lines.length ?? "null"}',
        );
        if (stripped != null) {
          _reportLyricLoad(
            found: true,
            source: 'embedded',
            lines: stripped.lines.length,
            elapsedMs: watch.elapsedMilliseconds,
          );
          return (lyric: stripped, isExternal: false);
        }
      } else {
        log.lyric.debug(
          'lyric.candidate',
          'lyric_loader: embedded lyric parse FAILED',
        );
      }
    } else {
      log.lyric.debug(
        'lyric.candidate',
        'lyric_loader: no embedded lyric found',
      );
    }
  } catch (e) {
    log.lyric.error(
      'legacy',
      'lyric_loader: embedded lyric failed: ${e.runtimeType}',
    );
  }

  log.lyric.debug('lyric.candidate', 'lyric_loader: returning null');
  _reportLyricLoad(
    found: false,
    source: 'none',
    lines: 0,
    elapsedMs: watch.elapsedMilliseconds,
  );
  return null;
}

void _reportLyricLoad({
  required bool found,
  required String source,
  required int lines,
  required int elapsedMs,
}) {
  log.write(
    lyricLoadRecord(
      found: found,
      source: source,
      lines: lines,
      elapsedMs: elapsedMs,
    ),
  );
}

/// 只加载指定的歌词文件，不搜索其他文件或回退到音频内嵌歌词。
Future<Lyric?> loadLyricFromFile(
  String lyricPath, {
  String? separator = '┃',
}) async {
  final ext = p.extension(lyricPath).toLowerCase();
  if (!supportedLyricFileExtensions.contains(ext)) return null;

  final content = await _safeReadFile(lyricPath);
  if (content == null || content.trim().isEmpty) return null;

  final lyric = _parseExternalToPureLyric(
    _ExternalLyricResult(content: content, ext: ext),
    separator: separator,
  );
  if (lyric == null || lyric.lines.isEmpty) return null;
  return _stripMetadata(lyric);
}

Lyric? _stripMetadata(Lyric lyric) {
  if (AppSettings.instance.keepLyricMetadata) return lyric;
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
