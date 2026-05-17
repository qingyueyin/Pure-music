import 'dart:convert';
import 'package:flutter/foundation.dart';

/// 从 KRC 解密后的内容中提取翻译和罗马音
/// 支持两种来源：
/// 1. 酷狗搜索 API 返回的 JSON 格式
/// 2. KRC 文本内嵌的 [language:...] Base64 标签
KrcLanguageData? extractKrcLanguage(String krcContent) {
  // 先尝试从 [language] Base64 标签解析
  final fromTag = _parseLanguageTag(krcContent);
  if (fromTag != null) return fromTag;

  // 再尝试从搜索 API JSON 格式解析
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
    return _extractFromJson(json);
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

KrcLanguageData? _extractFromJson(Map<String, dynamic> json) {
  final contentList = json['content'];
  if (contentList is! List || contentList.isEmpty) return null;

  String? translation;
  String? romanization;

  for (final content in contentList) {
    final type = content['type'];
    final lyricContent = content['lyricContent'];
    if (lyricContent is! List) continue;

    if (type == 1) {
      // 翻译（逐行）
      translation = _formatKrcTranslation(lyricContent);
    } else if (type == 0) {
      // 罗马音/日文假名（逐字音节）
      romanization = _formatKrcRomanization(lyricContent);
    }
  }

  if (translation == null && romanization == null) return null;
  return KrcLanguageData(
    translation: translation,
    romanization: romanization,
  );
}

String? _formatKrcTranslation(dynamic lyricContent) {
  if (lyricContent is! List) return null;

  final List<String> lines = [];
  for (final line in lyricContent) {
    if (line is List && line.isNotEmpty) {
      lines.add(line.first.toString());
    }
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
