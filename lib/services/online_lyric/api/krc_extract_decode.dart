import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:pure_music/lyric/metadata_detector.dart';

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

List<_KrcLineInfo> _extractKrcLineInfo(String krcContent) {
  final lineRegex = RegExp(r'\[(\d+),(\d+)](.*)');
  final wordRegex = RegExp(r'<(\d+),(\d+),\d+>([^<]*)');
  final result = <_KrcLineInfo>[];
  for (final line in krcContent.split('\n')) {
    final m = lineRegex.firstMatch(line.trim());
    if (m == null) continue;
    final body = m.group(3) ?? '';
    var content =
        wordRegex.allMatches(body).map((match) => match.group(3) ?? '').join();
    if (content.isEmpty) {
      content = body.replaceAll(RegExp(r'<\d+,\d+,\d+>'), '').trim();
    }
    result.add(_KrcLineInfo(
      startMs: int.parse(m.group(1)!),
      isLyric: content.isNotEmpty && !isLyricMetadataText(content),
    ));
  }
  return result;
}

KrcLanguageData? _extractFromJson(Map<String, dynamic> json,
    [String? krcContent]) {
  final contentList = json['content'];
  if (contentList is! List || contentList.isEmpty) return null;

  String? translation;
  String? romanization;

  List<_KrcLineInfo>? lineInfo;
  if (krcContent != null) {
    lineInfo = _extractKrcLineInfo(krcContent);
  }

  for (final content in contentList) {
    final type = content['type'];
    final lyricContent = content['lyricContent'];
    if (lyricContent is! List) continue;

    if (type == 1) {
      translation = _formatKrcTranslation(lyricContent, lineInfo);
    } else if (type == 0) {
      romanization = _formatKrcRomanization(lyricContent, lineInfo);
    }
  }

  if (translation == null && romanization == null) return null;
  return KrcLanguageData(
    translation: translation,
    romanization: romanization,
  );
}

String? _formatKrcTranslation(
  dynamic lyricContent, [
  List<_KrcLineInfo>? lineInfo,
]) {
  if (lyricContent is! List) return null;

  final List<String> lines = [];
  for (int i = 0; i < lyricContent.length; i++) {
    final line = lyricContent[i];
    if (line is! List) continue;
    final text = line.isNotEmpty ? line.first.toString() : '';
    if (lineInfo != null) {
      if (i >= lineInfo.length || !lineInfo[i].isLyric || text.trim().isEmpty) {
        continue;
      }
      lines.add('${_formatLrcTimestamp(lineInfo[i].startMs)}$text');
    } else {
      lines.add(text);
    }
  }
  return lines.join('\n');
}

String? _formatKrcRomanization(
  dynamic lyricContent, [
  List<_KrcLineInfo>? lineInfo,
]) {
  if (lyricContent is! List) return null;

  final List<String> lines = [];
  for (int i = 0; i < lyricContent.length; i++) {
    final line = lyricContent[i];
    if (line is List) {
      final syllables = line
          .map((s) => s.toString().trim())
          .where((s) => s.isNotEmpty)
          .join(' ');
      if (syllables.isNotEmpty) {
        if (lineInfo != null) {
          if (i >= lineInfo.length || !lineInfo[i].isLyric) continue;
          lines.add(
            '${_formatLrcTimestamp(lineInfo[i].startMs)}$syllables',
          );
        } else {
          lines.add(syllables);
        }
      } else if (lineInfo == null) {
        lines.add('');
      }
    }
  }
  return lines.join('\n');
}

String _formatLrcTimestamp(int milliseconds) {
  final minutes = milliseconds ~/ Duration.millisecondsPerMinute;
  final seconds = (milliseconds % Duration.millisecondsPerMinute) ~/ 1000;
  final millis = milliseconds % 1000;
  return '[${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}.'
      '${millis.toString().padLeft(3, '0')}]';
}

class _KrcLineInfo {
  final int startMs;
  final bool isLyric;

  const _KrcLineInfo({required this.startMs, required this.isLyric});
}

class KrcLanguageData {
  final String? translation;
  final String? romanization;

  const KrcLanguageData({
    required this.translation,
    required this.romanization,
  });
}
