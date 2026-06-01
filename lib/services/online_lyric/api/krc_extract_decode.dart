import 'dart:convert';
import 'package:flutter/foundation.dart';

/// 从 KRC 解密后的内容中提取翻译和罗马音
/// 支持两种来源：
/// 1. 酷狗搜索 API 返回的 JSON 格式
/// 2. KRC 文本内嵌的 [language:...] Base64 标签
KrcLanguageData? extractKrcLanguage(String krcContent) {
  final fromTag = _parseLanguageTag(krcContent);
  if (fromTag != null) return fromTag;

  return _parseSearchApiJson(krcContent);
}

/// 解析 KRC 文本中的 [language:base64json] 标签
KrcLanguageData? _parseLanguageTag(String krcContent) {
  try {
    final languageRegex = RegExp(r'\[language:(.+?)]');
    final match = languageRegex.firstMatch(krcContent);
    if (match == null) return null;

    final base64Str = match.group(1)!.trim();
    if (base64Str.isEmpty) return null;

    final jsonStr = utf8.decode(base64Decode(base64Str));
    final json = jsonDecode(jsonStr);
    return _extractFromJson(json, krcContent);
  } catch (e) {
    debugPrint('KRC language tag parse failed: $e');
    return null;
  }
}

/// 解析酷狗搜索 API 返回的 JSON 格式
KrcLanguageData? _parseSearchApiJson(String krcContent) {
  try {
    final json = jsonDecode(krcContent);
    final contentList = json['content'];
    if (contentList is! List || contentList.isEmpty) return null;
    return _extractFromJson(json);
  } catch (e) {
    return null;
  }
}

/// 从 KRC 原文中识别哪些 [start,end] 行是非空的
/// 匹配 LrcTool._parseKaraOk 的行为：行中有至少一个字标签带非空内容即为非空
List<bool> _identifyNonEmptyKrcLines(String krcContent) {
  final lineRegex = RegExp(r'\[(\d+),(\d+)](.*)');
  final wordRegex = RegExp(r'<(\d+),(\d+),\d+>([^<]*)');
  final result = <bool>[];
  for (final line in krcContent.split('\n')) {
    final m = lineRegex.firstMatch(line.trim());
    if (m == null) continue;
    final body = m.group(3) ?? '';
    bool hasContent = false;
    for (final wm in wordRegex.allMatches(body)) {
      final text = wm.group(3) ?? '';
      if (text.isNotEmpty) {
        hasContent = true;
        break;
      }
    }
    if (!hasContent) {
      final plain = body.replaceAll(RegExp(r'<\d+,\d+,\d+>'), '').trim();
      if (plain.isNotEmpty) hasContent = true;
    }
    result.add(hasContent);
  }
  return result;
}

KrcLanguageData? _extractFromJson(Map<String, dynamic> json, [String? krcContent]) {
  final contentList = json['content'];
  if (contentList is! List || contentList.isEmpty) return null;

  String? translation;
  String? romanization;

  List<bool>? nonEmptyLines;
  if (krcContent != null) {
    nonEmptyLines = _identifyNonEmptyKrcLines(krcContent);
  }

  for (final content in contentList) {
    final type = content['type'];
    final lyricContent = content['lyricContent'];
    if (lyricContent is! List) continue;

    if (type == 1) {
      translation = _formatKrcTranslation(lyricContent, nonEmptyLines);
    } else if (type == 0) {
      romanization = _formatKrcRomanization(lyricContent);
    }
  }

  if (translation == null && romanization == null) return null;
  return KrcLanguageData(
    translation: translation,
    romanization: romanization,
  );
}

/// 格式化翻译文本
/// 若提供 nonEmptyLines 信息，则跳过对应空 KRC 行的翻译条目，
/// 使输出的行数与主解析器（LrcTool._parseKaraOk）的输出行数一致。
String? _formatKrcTranslation(dynamic lyricContent, [List<bool>? nonEmptyLines]) {
  if (lyricContent is! List) return null;

  final List<String> lines = [];
  for (int i = 0; i < lyricContent.length; i++) {
    final line = lyricContent[i];
    if (line is! List) continue;
    if (nonEmptyLines != null && i < nonEmptyLines.length && !nonEmptyLines[i]) {
      continue;
    }
    lines.add(line.isNotEmpty ? line.first.toString() : '');
  }
  return lines.join('\n');
}

String? _formatKrcRomanization(dynamic lyricContent) {
  if (lyricContent is! List) return null;

  final List<String> lines = [];
  for (final line in lyricContent) {
    if (line is List) {
      final syllables = line
          .map((s) => s.toString().trim())
          .where((s) => s.isNotEmpty)
          .join(' ');
      if (syllables.isNotEmpty) {
        lines.add(syllables);
      } else {
        lines.add('');
      }
    }
  }
  return lines.join('\n');
}

class KrcLanguageData {
  final String? translation;
  final String? romanization;

  const KrcLanguageData({
    required this.translation,
    required this.romanization,
  });
}
