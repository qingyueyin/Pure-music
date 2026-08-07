import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/ttml.dart';
import 'package:pure_music/lyric/exclude_data.dart';
import 'package:pure_music/lyric/metadata_detector.dart';
import 'package:pure_music/core/zh_converter.dart';

// 括号对（用于清理文本前后的括号包裹）
const _bracketPairs = <List<String>>[
  ['(', ')'],
  ['（', '）'],
  ['【', '】'],
  ['[', ']'],
  ['{', '}'],
  ['『', '』'],
  ['「', '」'],
  ['《', '》'],
];

/// 歌词元数据剥离选项
class StripOptions {
  final List<String> keywords;
  final List<RegExp> regexes;
  final List<RegExp> softRegexes;

  /// 歌曲名+歌手，用于识别与当前歌曲对应的标题行
  final String? matchTitle;
  final List<String> matchArtists;

  const StripOptions({
    this.keywords = const [],
    this.regexes = const [],
    this.softRegexes = const [],
    this.matchTitle,
    this.matchArtists = const [],
  });
}

// ── 工具函数 ──

/// 从一行中提取纯文本内容
String _lineText(LyricLine line) {
  if (line is SyncLyricLine) {
    return line.words.map((w) => w.content).join();
  }
  if (line is UnsyncLyricLine) {
    return line.content;
  }
  return '';
}

/// 去除外层括号，提取内容
/// 如 "(作曲：周杰伦)" → "作曲：周杰伦"
String _cleanText(String text) {
  var processed = text.trim();
  var changed = true;
  var loop = 0;
  while (changed && loop < 5) {
    changed = false;
    loop++;
    for (final pair in _bracketPairs) {
      final open = pair[0], close = pair[1];
      if (processed.startsWith(open)) {
        if (processed.endsWith(close)) {
          processed = processed
              .substring(open.length, processed.length - close.length)
              .trim();
          changed = true;
          break;
        }
        final closeIdx = processed.indexOf(close);
        if (closeIdx > -1) {
          final after = processed.substring(closeIdx + close.length).trim();
          if (after.isNotEmpty) {
            processed = after;
            changed = true;
            break;
          }
        }
      }
    }
  }
  return processed;
}

/// 强匹配：关键词 + 分隔符，或正则匹配
bool _isStrictMatch(String text, List<String> keywords, List<RegExp> regexes) {
  final cleaned = _cleanText(text);
  if (isLyricMetadataText(cleaned)) return true;
  final normalized = cleaned.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  for (final kw in keywords) {
    final nkw = kw.toLowerCase().replaceAll(RegExp(r'\s+'), '');

    // 开头匹配：关键词在文本开头，后面紧跟分隔符或为空
    if (normalized.startsWith(nkw)) {
      final remainder = normalized.substring(nkw.length);
      if (remainder.startsWith(':') || remainder.startsWith('：')) return true;
    }

    // 模糊匹配：关键词出现在文本中任意位置，且后面紧跟分隔符
    // 用于匹配「片尾曲)」「作词：方文山」等中间嵌入的元数据关键词
    var searchStart = 1;
    while (true) {
      final kwIndex = normalized.indexOf(nkw, searchStart);
      if (kwIndex < 0) break;
      final afterKw = normalized.substring(kwIndex + nkw.length);
      if (afterKw.startsWith(':') || afterKw.startsWith('：')) {
        return true;
      }
      searchStart = kwIndex + 1;
    }
  }

  for (final reg in regexes) {
    if (reg.hasMatch(text)) return true;
  }

  return false;
}

/// 弱匹配：只保留首尾扫描需要的上下文信号
bool _looksLikeMetadata(String text, List<RegExp> softRegexes) {
  final cleaned = _cleanText(text);
  if (RegExp(r'^[^:：]{1,40}[:：]\s*\S').hasMatch(cleaned)) {
    return true;
  }
  for (final reg in softRegexes) {
    if (reg.hasMatch(text)) return true;
  }
  return false;
}

bool _isBracketedTitleArtistLine(String text) {
  final cleaned = text.trim();
  return RegExp(
    r'^(?:【[^】]+】|\[[^\]]+\])\s*[-－–—]\s*(?:【[^】]+】|\[[^\]]+\])$',
  ).hasMatch(cleaned);
}

bool _isUnbracketedTitleArtistLine(String text) {
  final cleaned = text.trim();
  if (cleaned.length > 140) return false;
  final matches =
      RegExp(r'\s*[-－–—]\s*').allMatches(cleaned).toList(growable: false);
  if (matches.length != 1) return false;

  final match = matches.first;
  final left = cleaned.substring(0, match.start).trim();
  final right = cleaned.substring(match.end).trim();
  if (left.isEmpty || right.isEmpty) return false;
  final separator = cleaned.substring(match.start, match.end);
  final hasSeparatorSpace = RegExp(r'\s').hasMatch(separator);
  final hasAsian = RegExp(r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]')
      .hasMatch('$left$right');
  if (!hasSeparatorSpace && !(hasAsian && left.length + right.length >= 4)) {
    return false;
  }

  return (_looksLikeArtistList(left) && _looksLikeSongTitle(right)) ||
      (_looksLikeSongTitle(left) && _looksLikeArtistList(right));
}

String _normalizeMetadataValue(String text) {
  return ZhConverter.toSimple(text.trim().toLowerCase()).replaceAll(
    RegExp(
      r'''[-‐‑‒–—―\s_/\\|,，、.&＆+＋·・:：;；!！?？'"“”‘’`~～^()（）\[\]【】{}《》〈〉「」『』♪♫♬♩♭♮♯🎵🎶]+''',
    ),
    '',
  );
}

bool _containsTitleVersionQualifier(String text) {
  return RegExp(
    r'\b(?:a\s*cappella|acapella|acoustic|album|anniversary|bonus|clean|cover|deluxe|demo|dirty|edit|explicit|extended|instrumental|karaoke|live|mix|mono|original|radio|remaster(?:ed|ing)?|remix|reverb|single|slowed(?:\s+down)?|sped\s+up|stereo|studio|uncensored|version|ver\.?)\b|'
    r'伴奏|纯音乐|純音樂|翻唱|混音|重混|重制|重製|原版|完整版|特别版|特別版|加速|慢速|新版|现场|現場|演唱会|演唱會|音乐节|音樂節|版|'
    r'アコースティック|インスト(?:ゥルメンタル)?|ライブ|リミックス|弾き語り|라이브|리믹스|버전',
    caseSensitive: false,
  ).hasMatch(text);
}

bool _isTitleVariantQualifier(String text) {
  if (_containsTitleVersionQualifier(text)) return true;
  return RegExp(
    r'^(?:国|國|国语|國語|粤|粵|粤语|粵語|台|台语|台語|日语|日語|韩语|韓語|英语|英語)$|'
    r'^(?:mandarin|cantonese|taiwanese|japanese|korean|english)(?:\s+version)?$',
    caseSensitive: false,
  ).hasMatch(text.trim());
}

String? _textLanguageGroup(String value) {
  if (RegExp(r'[\u3040-\u30ff]').hasMatch(value)) return 'ja';
  if (RegExp(r'[\uac00-\ud7af]').hasMatch(value)) return 'ko';
  final hasHan = RegExp(r'[\u3400-\u9fff]').hasMatch(value);
  final hasLatin = RegExp(r'[A-Za-z]').hasMatch(value);
  if (hasHan && !hasLatin) return 'han';
  if (hasLatin && !hasHan) return 'latin';
  return null;
}

Set<String> _titleMatchCandidates(String text) {
  final candidates = <String>{};
  final pending = <String>[text.trim()];
  final visited = <String>{};

  while (pending.isNotEmpty) {
    final value = pending.removeLast().trim();
    if (value.isEmpty || !visited.add(value)) continue;
    final normalized = _normalizeMetadataValue(value);
    if (normalized.isNotEmpty) candidates.add(normalized);

    final bracketMatch = RegExp(
      r'^(.*?)\s*[（(【\[]([^）)】\]]+)[）)】\]]\s*$',
    ).firstMatch(value);
    if (bracketMatch != null) {
      final base = bracketMatch.group(1)!.trim();
      final suffix = bracketMatch.group(2)!.trim();
      final baseLanguage = _textLanguageGroup(base);
      final suffixLanguage = _textLanguageGroup(suffix);
      if (_isTitleVariantQualifier(suffix) ||
          RegExp(r'^(?:feat(?:uring)?|ft)\.?\s+', caseSensitive: false)
              .hasMatch(suffix)) {
        pending.add(base);
      } else if (baseLanguage != null &&
          suffixLanguage != null &&
          baseLanguage != suffixLanguage) {
        pending
          ..add(base)
          ..add(suffix);
      }
    }

    final featuredArtistSuffix = RegExp(
      r'^(.*?)\s+(?:feat(?:uring)?|ft)\.?\s+\S.+$',
      caseSensitive: false,
    ).firstMatch(value);
    if (featuredArtistSuffix != null) {
      pending.add(featuredArtistSuffix.group(1)!);
    }

    for (final separator in RegExp(r'\s+').allMatches(value)) {
      final base = value.substring(0, separator.start).trim();
      final suffix = value.substring(separator.end).trim();
      final baseLanguage = _textLanguageGroup(base);
      final suffixLanguage = _textLanguageGroup(suffix);
      if (baseLanguage != null &&
          suffixLanguage != null &&
          baseLanguage != suffixLanguage) {
        pending
          ..add(base)
          ..add(suffix);
      }
    }

    final separators = RegExp(r'\s+[-－–—]\s+').allMatches(value).toList();
    if (separators.isNotEmpty) {
      final last = separators.last;
      final suffix = value.substring(last.end).trim();
      if (_isTitleVariantQualifier(suffix)) {
        pending.add(value.substring(0, last.start));
      }
    }

    final plainVersion = RegExp(
      r'^(.*?)\s+(?:a\s*cappella|acapella|acoustic|album version|clean|cover|demo|dirty|explicit|extended|instrumental|karaoke|live|original version|radio edit|remaster(?:ed)?|remix|slowed(?:\s+down)?|sped\s+up|stereo|uncensored|version|伴奏版?|纯音乐版?|純音樂版?|翻唱版?|混音版?|重混版?|重制版?|重製版?|原版|完整版|特别版|特別版|加速版?|慢速版?|新版|现场版?|現場版?)$',
      caseSensitive: false,
    ).firstMatch(value);
    if (plainVersion != null) pending.add(plainVersion.group(1)!);
  }
  return candidates;
}

Set<String> _artistMatchCandidates(String text) {
  final candidates = <String>{};
  final pending = <String>[text.trim()];
  final visited = <String>{};

  while (pending.isNotEmpty) {
    final value = pending.removeLast().trim();
    if (value.isEmpty || !visited.add(value)) continue;
    final normalized = _normalizeMetadataValue(value);
    if (normalized.isNotEmpty) {
      candidates.add(normalized);
      if (RegExp(r'^[a-z0-9]+$').hasMatch(normalized) &&
          normalized.startsWith('the') &&
          normalized.length > 6) {
        candidates.add(normalized.substring(3));
      }
      final scriptParts = RegExp(
        r'[a-z0-9]+|[\u3400-\u9fff]+|[\u3040-\u30ff]+|[\uac00-\ud7af]+',
      ).allMatches(normalized).map((match) => match.group(0)!).toList();
      if (scriptParts.length > 1) candidates.addAll(scriptParts);
    }

    final bracketMatches =
        RegExp(r'[（(【\[]([^）)】\]]+)[）)】\]]').allMatches(value).toList();
    if (bracketMatches.isNotEmpty) {
      pending.add(value.replaceAll(RegExp(r'[（(【\[][^）)】\]]+[）)】\]]'), ' '));
      pending.addAll(bracketMatches.map((match) => match.group(1)!));
    }

    final separated = value
        .replaceAll(
          RegExp(
            r'\s+(?:feat(?:uring)?|ft|with|vs)\.?\s+',
            caseSensitive: false,
          ),
          ';',
        )
        .replaceAll(RegExp(r'\s+[x×]\s+', caseSensitive: false), ';');
    final parts = separated.split(RegExp(r'[、,，/&＆;；|+＋]+'));
    if (parts.length > 1) pending.addAll(parts);
  }
  return candidates;
}

bool _hasCandidateOverlap(Set<String> actual, Set<String> expected) {
  if (actual.isEmpty || expected.isEmpty) return false;
  return actual.any(expected.contains);
}

bool _matchesKnownTitleArtistLine(
  String text,
  String? title,
  List<String> artists,
) {
  if (title == null || title.trim().isEmpty || artists.isEmpty) return false;
  final cleaned = text.trim();
  final titleCandidates = _titleMatchCandidates(title);
  final artistCandidates = <String>{
    for (final artist in artists) ..._artistMatchCandidates(artist),
  };
  for (final separator in RegExp(r'[-－–—]').allMatches(cleaned)) {
    final left = cleaned.substring(0, separator.start).trim();
    final right = cleaned.substring(separator.end).trim();
    if (left.isEmpty || right.isEmpty) continue;
    final leftIsTitle =
        _hasCandidateOverlap(_titleMatchCandidates(left), titleCandidates);
    final rightIsTitle =
        _hasCandidateOverlap(_titleMatchCandidates(right), titleCandidates);
    final leftIsArtist =
        _hasCandidateOverlap(_artistMatchCandidates(left), artistCandidates);
    final rightIsArtist =
        _hasCandidateOverlap(_artistMatchCandidates(right), artistCandidates);
    if ((leftIsTitle && rightIsArtist) || (rightIsTitle && leftIsArtist)) {
      return true;
    }
  }
  return false;
}

bool _looksLikeArtistList(String text) {
  if (RegExp(r'[/、,&]|\b(?:feat\.?|ft\.?|with|x)\b', caseSensitive: false)
      .hasMatch(text)) {
    return true;
  }
  if (RegExp(r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]').hasMatch(text) &&
      text.length <= 30) {
    return true;
  }
  final words = RegExp(r"[A-Z][a-zA-Z0-9']+").allMatches(text).length;
  return words >= 1 && text.length <= 40;
}

bool _looksLikeSongTitle(String text) {
  if (text.length < 2 || text.length > 70) return false;
  return RegExp(r'[A-Za-z0-9\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]')
      .hasMatch(text);
}

/// 判断一行是否已被清空（适用于 blankMetadataLines 后的检查）
bool _isLineBlanked(LyricLine line) {
  if (line is SyncLyricLine) return line.words.isEmpty;
  if (line is LrcLine) return line.isBlank;
  if (line is UnsyncLyricLine) return line.content.isEmpty;
  return false;
}

// ── 扫描范围计算 ──

int _scanLimit(int totalLines, double ratio, int minLines, int maxLines) {
  final proportional = (totalLines * ratio).ceil();
  var limit = proportional.clamp(minLines, maxLines);
  return limit.clamp(0, totalLines);
}

// ── 头部扫描 ──

int _findHeaderCutoff(
  List<LyricLine> lines,
  int startIndex,
  List<String> keywords,
  List<RegExp> regexes,
  List<RegExp> softRegexes,
  int limit,
) {
  var lastValidIndex = startIndex - 1;
  for (int i = startIndex; i < limit && i < lines.length; i++) {
    final text = _lineText(lines[i]);
    final transText = lines[i].translation ?? '';
    final strict = (text.isNotEmpty &&
            _isStrictMatch(text, keywords, regexes)) ||
        (transText.isNotEmpty && _isStrictMatch(transText, keywords, regexes));
    final weak = (text.isNotEmpty && _looksLikeMetadata(text, softRegexes)) ||
        (transText.isNotEmpty && _looksLikeMetadata(transText, softRegexes));
    if (!strict && !weak) break;
    if (strict) lastValidIndex = i;
  }
  return lastValidIndex + 1;
}

// ── 尾部扫描 ──

int _findFooterCutoff(
  List<LyricLine> lines,
  int startIndex,
  List<String> keywords,
  List<RegExp> regexes,
  List<RegExp> softRegexes,
  int limit,
) {
  if (startIndex >= lines.length) return startIndex;
  final scanEnd = (lines.length - limit).clamp(0, lines.length);
  var firstValidIndex = lines.length;

  for (int i = lines.length - 1; i >= scanEnd; i--) {
    final text = _lineText(lines[i]);
    final transText = lines[i].translation ?? '';
    final strict = (text.isNotEmpty &&
            _isStrictMatch(text, keywords, regexes)) ||
        (transText.isNotEmpty && _isStrictMatch(transText, keywords, regexes));
    final weak = (text.isNotEmpty && _looksLikeMetadata(text, softRegexes)) ||
        (transText.isNotEmpty && _looksLikeMetadata(transText, softRegexes));
    if (!strict && !weak) break;
    if (strict) firstValidIndex = i;
  }
  return firstValidIndex;
}

// ── 对外接口 ──

/// 剥离歌词元数据行（头部 + 尾部）。
///
/// 策略：
/// 1. 强匹配（关键词+分隔符 / 正则）→ 确定为元数据行
/// 2. 弱匹配（含冒号/连字符）→ 若夹在强匹配行之间则视为元数据
/// 3. 真正的歌词行作为防火墙，阻止误删
List<LyricLine> stripLyricMetadata(List<LyricLine>? lines,
    [StripOptions? options]) {
  if (lines == null || lines.isEmpty) return [];
  options ??= const StripOptions();

  var scanStart = 0;

  // 检查第 1 行是否为与当前歌曲精确对应的“歌名 - 歌手”格式
  final firstText = _lineText(lines[0]);
  final firstTrans = lines[0].translation ?? '';
  if (_matchesKnownTitleArtistLine(
        firstText,
        options.matchTitle,
        options.matchArtists,
      ) ||
      _matchesKnownTitleArtistLine(
        firstTrans,
        options.matchTitle,
        options.matchArtists,
      )) {
    scanStart = 1;
  }

  if (options.keywords.isEmpty &&
      options.regexes.isEmpty &&
      options.softRegexes.isEmpty) {
    return lines;
  }

  final totalLines = lines.length;
  final headerLimit = _scanLimit(totalLines, 0.2, 20, 70);
  final footerLimit = _scanLimit(totalLines, 0.2, 20, 50);

  final startIdx = _findHeaderCutoff(
    lines,
    scanStart,
    options.keywords,
    options.regexes,
    options.softRegexes,
    headerLimit,
  );
  final endIdx = _findFooterCutoff(
    lines,
    startIdx,
    options.keywords,
    options.regexes,
    options.softRegexes,
    footerLimit,
  );

  if (startIdx == 0 && endIdx == totalLines) return lines;

  return lines.sublist(startIdx, endIdx);
}

// ── 脏话反屏蔽 ──

/// 预编译的正则-替换对，避免每次调用都重新编译 RegExp
// 脏话反屏蔽规则。
// 流媒体平台审查策略各异（保留首尾字母 / 只保留首字母 / 纯星号），
// 每个词覆盖多种常见变体。替换是链式的，派生后缀（-ing/-ed/-er/-ty）
// 由基础词规则自动处理，无需单独列出。
// 注意：规则按从具体到通用的顺序排列，避免通用模式过早匹配。
final List<_ProfanityRule> _profanityRules = [
  // ── fuck / fucking / fucker / fucked / motherfucker ──
  _ProfanityRule(
      RegExp(r'mother\*{4}er', caseSensitive: false), 'motherfucker'),
  _ProfanityRule(RegExp(r'f\*{3}k', caseSensitive: false), 'fuck'), // f***k
  _ProfanityRule(RegExp(r'f\*{2}k', caseSensitive: false), 'fuck'),
  _ProfanityRule(RegExp(r'fu\*k', caseSensitive: false), 'fuck'),
  _ProfanityRule(
      RegExp(r'f\*{3}(?!\w)', caseSensitive: false), 'fuck'), // f*** → fuck
  _ProfanityRule(
      RegExp(r'\*{4}ing', caseSensitive: false), 'fucking'), // ****ing
  _ProfanityRule(RegExp(r'\*{4}er', caseSensitive: false), 'fucker'), // ****er
  _ProfanityRule(RegExp(r'\*{4}ed', caseSensitive: false), 'fucked'), // ****ed

  // ── shit / bullshit ──
  _ProfanityRule(RegExp(r'bulls\*{2}t', caseSensitive: false), 'bullshit'),
  _ProfanityRule(RegExp(r'bullsh\*t', caseSensitive: false), 'bullshit'),
  _ProfanityRule(RegExp(r'sh\*{2}t', caseSensitive: false), 'shit'), // sh**t
  _ProfanityRule(RegExp(r's\*{2}t', caseSensitive: false), 'shit'), // s**t
  _ProfanityRule(RegExp(r'sh\*t', caseSensitive: false), 'shit'), // sh*t
  _ProfanityRule(RegExp(r'sh\*{2}(?!\w)', caseSensitive: false),
      'shit'), // sh** → shit (only at word end)

  // ── piss / pissed ──
  _ProfanityRule(
      RegExp(r'p\*{2}sed', caseSensitive: false), 'pissed'), // p**sed
  _ProfanityRule(
      RegExp(r'pi\*{2}ed', caseSensitive: false), 'pissed'), // pi**ed
  _ProfanityRule(RegExp(r'p\*{2}s', caseSensitive: false), 'piss'), // p**s
  _ProfanityRule(RegExp(r'pi\*s', caseSensitive: false), 'piss'), // pi*s

  // ── pussy ──
  _ProfanityRule(RegExp(r'p\*{3}y', caseSensitive: false), 'pussy'), // p***y
  _ProfanityRule(RegExp(r'pu\*{2}y', caseSensitive: false), 'pussy'), // pu**y

  // ── bitch ──
  _ProfanityRule(RegExp(r'b\*{3}h', caseSensitive: false), 'bitch'), // b***h
  _ProfanityRule(RegExp(r'bi\*{2}h', caseSensitive: false), 'bitch'), // bi**h
  _ProfanityRule(
      RegExp(r'b\*{4}(?!\w)', caseSensitive: false), 'bitch'), // b**** → bitch

  // ── cunt ──
  _ProfanityRule(RegExp(r'cu\*{2}t', caseSensitive: false), 'cunt'), // cu**t
  _ProfanityRule(RegExp(r'c\*{2}t', caseSensitive: false), 'cunt'), // c**t
  _ProfanityRule(RegExp(r'cu\*t', caseSensitive: false), 'cunt'), // cu*t

  // ── cock ──
  _ProfanityRule(RegExp(r'c\*{3}k', caseSensitive: false), 'cock'), // c***k
  _ProfanityRule(RegExp(r'c\*{2}k', caseSensitive: false), 'cock'), // c**k
  _ProfanityRule(RegExp(r'co\*k', caseSensitive: false), 'cock'), // co*k
  _ProfanityRule(
      RegExp(r'co\*{2}(?!\w)', caseSensitive: false), 'cock'), // co** → cock

  // ── dick ──
  _ProfanityRule(RegExp(r'd\*{2}k', caseSensitive: false), 'dick'), // d**k
  _ProfanityRule(RegExp(r'di\*k', caseSensitive: false), 'dick'), // di*k

  // ── damn ──
  _ProfanityRule(RegExp(r'd\*{2}n', caseSensitive: false), 'damn'), // d**n
  _ProfanityRule(RegExp(r'da\*n', caseSensitive: false), 'damn'), // da*n

  // ── ass / asshole ──
  _ProfanityRule(
      RegExp(r'ass\*{2}le', caseSensitive: false), 'asshole'), // ass**le
  _ProfanityRule(
      RegExp(r'as\*{2}le', caseSensitive: false), 'asshole'), // as**le
  _ProfanityRule(
      RegExp(r'a\*{2}hole', caseSensitive: false), 'asshole'), // a**hole
  _ProfanityRule(
      RegExp(r'a\*{2}(?!\w)', caseSensitive: false), 'ass'), // a** → ass

  // ── whore ──
  _ProfanityRule(RegExp(r'w\*{3}e', caseSensitive: false), 'whore'), // w***e
  _ProfanityRule(RegExp(r'wh\*{2}e', caseSensitive: false), 'whore'), // wh**e

  // ── slut ── (s**t 已分配给 shit，sl*t 是 slut 的专属模式)
  _ProfanityRule(RegExp(r'sl\*t', caseSensitive: false), 'slut'), // sl*t

  // ── bastard ──
  _ProfanityRule(
      RegExp(r'bas\*{4}', caseSensitive: false), 'bastard'), // bas****
  _ProfanityRule(
      RegExp(r'b\*{2}tard', caseSensitive: false), 'bastard'), // b**tard

  // ── prick ──
  _ProfanityRule(RegExp(r'pr\*{2}k', caseSensitive: false), 'prick'), // pr**k

  // ── twat ──
  _ProfanityRule(RegExp(r'tw\*t', caseSensitive: false), 'twat'), // tw*t

  // ── wanker ──
  _ProfanityRule(
      RegExp(r'w\*{2}ker', caseSensitive: false), 'wanker'), // w**ker
  _ProfanityRule(
      RegExp(r'wa\*{2}er', caseSensitive: false), 'wanker'), // wa**er

  // ── sucker ──
  _ProfanityRule(
      RegExp(r's\*{2}ker', caseSensitive: false), 'sucker'), // s**ker
  _ProfanityRule(
      RegExp(r'su\*{2}er', caseSensitive: false), 'sucker'), // su**er

  // ── fag / faggot ──
  _ProfanityRule(RegExp(r'f\*{3}ot', caseSensitive: false), 'faggot'), // f***ot
  _ProfanityRule(RegExp(r'fa\*{3}t', caseSensitive: false), 'faggot'), // fa***t
  _ProfanityRule(
      RegExp(r'f\*g(?!\w)', caseSensitive: false), 'fag'), // f*g → fag

  // ── retard ──
  _ProfanityRule(RegExp(r'r\*{4}d', caseSensitive: false), 'retard'), // r****d
  _ProfanityRule(RegExp(r're\*{3}d', caseSensitive: false), 'retard'), // re***d

  // ── douche ──
  _ProfanityRule(RegExp(r'do\*{3}e', caseSensitive: false), 'douche'), // do***e
  _ProfanityRule(RegExp(r'd\*{4}e', caseSensitive: false), 'douche'), // d****e

  // ── nigga / nigger ──
  _ProfanityRule(RegExp(r'n\*{3}a', caseSensitive: false), 'nigga'), // n***a
  _ProfanityRule(RegExp(r'ni\*{2}a', caseSensitive: false), 'nigga'), // ni**a
  _ProfanityRule(RegExp(r'n\*{4}r', caseSensitive: false), 'nigger'), // n****r
];

class _ProfanityRule {
  final RegExp pattern;
  final String replacement;
  const _ProfanityRule(this.pattern, this.replacement);
}

/// 脏话反屏蔽：将歌词文本中被 `*` 屏蔽的脏话词还原
String uncensorProfanity(String text) {
  if (text.isEmpty) return text;
  var result = text;
  for (final rule in _profanityRules) {
    result = result.replaceAll(rule.pattern, rule.replacement);
  }
  return result;
}

/// 对 [Lyric] 对象中的所有歌词文本字段进行脏话还原（原地修改）。
/// 处理字段：[SyncLyricWord.content]、[UnsyncLyricLine.content]、
/// [LyricLine.translation]、[LyricLine.romanLyric]
void applyProfanityUncensor(Lyric lyric) {
  for (final line in lyric.lines) {
    if (line is SyncLyricLine) {
      for (final word in line.words) {
        word.content = uncensorProfanity(word.content);
      }
    } else if (line is UnsyncLyricLine) {
      line.content = uncensorProfanity(line.content);
    }
    if (line.translation != null && line.translation!.isNotEmpty) {
      line.translation = uncensorProfanity(line.translation!);
    }
    if (line.romanLyric != null && line.romanLyric!.isNotEmpty) {
      line.romanLyric = uncensorProfanity(line.romanLyric!);
    }
  }
}

/// 将歌词中匹配元数据的行清空为空白行（原地修改）。
/// 不删除行，保留时间戳结构，前奏/间奏不受影响。
///
/// 策略：
/// 1. 只清空头部/尾部连续元数据区，降低中段歌词误伤
/// 2. 元数据区必须包含强匹配或标题-歌手行作为锚点
/// 3. 弱匹配只在同一个首尾元数据区内跟随清空

/// 预编译的正则列表，避免每次调用都重新编译
final List<RegExp> _cachedExcludeRegexes =
    defaultExcludeRegexes.map((p) => RegExp(p, caseSensitive: false)).toList();

final List<RegExp> _cachedExcludeSoftRegexes = defaultExcludeSoftRegexes
    .map((p) => RegExp(p, caseSensitive: false))
    .toList();

final RegExp _amllTtmlCreatorPattern = RegExp(r'^【创作者：[^【】\r\n]+】$');

void blankAmllTtmlCreatorLines(List<LyricLine> lines) {
  for (final line in lines) {
    if (!_amllTtmlCreatorPattern.hasMatch(_lineText(line).trim())) continue;
    if (line is SyncLyricLine) {
      line.words.clear();
    } else if (line is UnsyncLyricLine) {
      line.content = '';
      if (line is LrcLine) line.isBlank = true;
    }
    line.translation = null;
    line.romanLyric = null;
  }
}

void blankMetadataLines(List<LyricLine> lines, [StripOptions? options]) {
  if (lines.isEmpty) return;
  options ??= const StripOptions();

  final keywords =
      options.keywords.isNotEmpty ? options.keywords : defaultExcludeKeywords;
  final regexes =
      options.regexes.isNotEmpty ? options.regexes : _cachedExcludeRegexes;
  final softRegexes = options.softRegexes.isNotEmpty
      ? options.softRegexes
      : _cachedExcludeSoftRegexes;

  final totalLines = lines.length;
  final headerLimit = _scanLimit(totalLines, 0.2, 20, 70);
  final footerLimit = _scanLimit(totalLines, 0.2, 20, 50);

  void blankLine(LyricLine line) {
    if (_isLineBlanked(line)) return; // 已清空过，不重复操作
    if (line is SyncLyricLine) {
      line.words.clear();
    } else if (line is UnsyncLyricLine) {
      line.content = '';
      if (line is LrcLine) {
        line.isBlank = true;
      }
    }
  }

  // ── 预计算每行的匹配状态 ──
  // 增强 LRC 会把同时戳的版权行合并为 translation，必须连同 translation 一起检查
  final isStrict = List<bool>.filled(totalLines, false);
  final isWeak = List<bool>.filled(totalLines, false);
  final isTitleArtist = List<bool>.filled(totalLines, false);
  final isMatchedTitleArtist = List<bool>.filled(totalLines, false);
  for (int i = 0; i < totalLines; i++) {
    final text = _lineText(lines[i]);
    final transText = lines[i].translation ?? '';
    isStrict[i] = (text.isNotEmpty &&
            _isStrictMatch(text, keywords, regexes)) ||
        (transText.isNotEmpty && _isStrictMatch(transText, keywords, regexes));
    isWeak[i] = (text.isNotEmpty && _looksLikeMetadata(text, softRegexes)) ||
        (transText.isNotEmpty && _looksLikeMetadata(transText, softRegexes));
    isTitleArtist[i] = (text.isNotEmpty &&
            (_isBracketedTitleArtistLine(text) ||
                _isUnbracketedTitleArtistLine(text))) ||
        (transText.isNotEmpty &&
            (_isBracketedTitleArtistLine(transText) ||
                _isUnbracketedTitleArtistLine(transText)));
    isMatchedTitleArtist[i] = _matchesKnownTitleArtistLine(
          text,
          options.matchTitle,
          options.matchArtists,
        ) ||
        _matchesKnownTitleArtistLine(
          transText,
          options.matchTitle,
          options.matchArtists,
        );
  }

  bool isAnchor(int index) => isStrict[index] || isMatchedTitleArtist[index];
  bool isCandidate(int index) =>
      isAnchor(index) || isWeak[index] || isTitleArtist[index];

  // ── 头部扫描：找连续元数据区截止位置 ──
  var headerCutoff = 0;
  var headerHasAnchor = false;
  for (int i = 0; i < headerLimit && i < totalLines; i++) {
    if (_isLineBlanked(lines[i])) {
      headerCutoff = i + 1;
      continue;
    }
    if (!isCandidate(i)) {
      break;
    }
    if (isAnchor(i)) {
      headerHasAnchor = true;
      headerCutoff = i + 1;
    }
  }
  if (!headerHasAnchor) headerCutoff = 0;

  // ── 尾部扫描：找连续元数据区起始位置 ──
  var firstAnyInFooter = totalLines;
  var footerHasAnchor = false;
  for (int i = totalLines - 1;
      i >= (totalLines - footerLimit).clamp(0, totalLines);
      i--) {
    if (_isLineBlanked(lines[i])) {
      firstAnyInFooter = i;
      continue;
    }
    if (!isCandidate(i)) {
      break;
    }
    if (isAnchor(i)) {
      footerHasAnchor = true;
      firstAnyInFooter = i;
    }
  }
  if (!footerHasAnchor) firstAnyInFooter = totalLines;

  // ── 清空头部元数据（全清，含弱匹配） ──
  for (int i = 0; i < headerCutoff; i++) {
    blankLine(lines[i]);
  }

  // ── 清空尾部元数据（全清，含弱匹配） ──
  if (firstAnyInFooter < totalLines) {
    for (int i = firstAnyInFooter; i < totalLines; i++) {
      blankLine(lines[i]);
    }
  }

  // ── 合并头部连续空白行为前奏 ──
  if (lines.isNotEmpty) {
    final firstElement = lines[0]; // 用于判断具体子类型
    int blankCount = 0;
    while (blankCount < lines.length && _isLineBlanked(lines[blankCount])) {
      blankCount++;
    }

    LyricLine? prelude;
    final firstRealStart = blankCount < lines.length
        ? lines[blankCount].start
        : const Duration(seconds: 30);

    if (blankCount > 0 && firstRealStart > Duration.zero) {
      prelude = _createPrelude(firstElement, firstRealStart);
      lines.removeRange(0, blankCount);
      lines.insert(0, prelude);
    } else if (blankCount == 0 && firstRealStart > const Duration(seconds: 3)) {
      prelude = _createPrelude(firstElement, firstRealStart);
      lines.insert(0, prelude);
    }
  }
}

/// 根据现有行类型创建前奏空白行，避免类型不匹配（如 EnhancedLrcLine 列表不能插入 SyncLyricLine）
LyricLine _createPrelude(LyricLine exemplar, Duration length) {
  if (exemplar is LrcLine) {
    return LrcLine(Duration.zero, '', requiredIsBlank: true)..length = length;
  }
  if (exemplar is EnhancedLrcLine) {
    return EnhancedLrcLine(Duration.zero, length, []);
  }
  if (exemplar is TtmlLine) {
    return TtmlLine(Duration.zero, length, []);
  }
  return SyncLyricLine(Duration.zero, length, []);
}
