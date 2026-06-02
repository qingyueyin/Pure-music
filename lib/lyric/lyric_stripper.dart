import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/exclude_data.dart';

// 分隔符列表（用于判断关键词后的字符是否为有效分隔符）
const _separators = <String>[
  ':', '：', ',', '，', '.', '。', '!', '！', '-', '_',
  '(', '（', '[', '【', '{', '『', '「',
];

// 括号对（用于清理文本前后的括号包裹）
const _bracketPairs = <List<String>>[
  ['(', ')'],
  ['（', '）'],
  ['【', '】'],
  ['[', ']'],
  ['{', '}'],
  ['『', '』'],
  ['「', '」'],
];

/// 歌词元数据剥离选项
class StripOptions {
  final List<String> keywords;
  final List<RegExp> regexes;
  final List<RegExp> softRegexes;
  /// 歌曲名+歌手，用于过滤第 1 行 "歌名 - 歌手" 格式
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
          processed = processed.substring(open.length, processed.length - close.length).trim();
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
  final normalized = cleaned.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  for (final kw in keywords) {
    final nkw = kw.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (normalized.startsWith(nkw)) {
      final remainder = normalized.substring(nkw.length);
      if (remainder.isEmpty) return true;
      // 关键词后紧跟分隔符，如「混音：李荣浩」
      if (_separators.contains(remainder[0])) return true;
      // 关键词后有后缀再跟分隔符，如「混音师：李荣浩」「母带后期制作人：李荣浩」
      if (remainder.contains('：') || remainder.contains(':')) return true;
    }
  }

  for (final reg in regexes) {
    if (reg.hasMatch(text)) return true;
  }

  return false;
}

/// 弱匹配：含冒号或连字符
bool _looksLikeMetadata(String text, List<RegExp> softRegexes) {
  final cleaned = _cleanText(text);
  if (cleaned.contains(':') || cleaned.contains('：') || cleaned.contains('-')) {
    return true;
  }
  for (final reg in softRegexes) {
    if (reg.hasMatch(text)) return true;
  }
  return false;
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
    final strict = (text.isNotEmpty && _isStrictMatch(text, keywords, regexes)) ||
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
    final strict = (text.isNotEmpty && _isStrictMatch(text, keywords, regexes)) ||
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
List<LyricLine> stripLyricMetadata(List<LyricLine>? lines, [StripOptions? options]) {
  if (lines == null || lines.isEmpty) return [];
  options ??= const StripOptions();

  var scanStart = 0;

  // 检查第 1 行是否为 "歌名 - 歌手" 格式
  if (options.matchTitle != null && options.matchArtists.isNotEmpty) {
    final firstText = _lineText(lines[0]).toLowerCase();
    final firstTrans = (lines[0].translation ?? '').toLowerCase();
    final combined = '$firstText $firstTrans';
    if (combined.contains(options.matchTitle!.toLowerCase())) {
      final hasArtist = options.matchArtists.any((a) => combined.contains(a.toLowerCase()));
      if (hasArtist) scanStart = 1;
    }
  }

  if (options.keywords.isEmpty && options.regexes.isEmpty && options.softRegexes.isEmpty) {
    return lines;
  }

  final totalLines = lines.length;
  final headerLimit = _scanLimit(totalLines, 0.2, 20, 70);
  final footerLimit = _scanLimit(totalLines, 0.2, 20, 50);

  final startIdx = _findHeaderCutoff(
    lines, scanStart,
    options.keywords, options.regexes, options.softRegexes, headerLimit,
  );
  final endIdx = _findFooterCutoff(
    lines, startIdx,
    options.keywords, options.regexes, options.softRegexes, footerLimit,
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
final List<_ProfanityRule> _profanityRules = [
  // ── fuck / fucking / fucker / fucked / motherfucker ──
  _ProfanityRule(RegExp(r'mother\*{4}er', caseSensitive: false), 'motherfucker'),
  _ProfanityRule(RegExp(r'f\*{2}k', caseSensitive: false), 'fuck'),
  _ProfanityRule(RegExp(r'fu\*k', caseSensitive: false), 'fuck'),
  _ProfanityRule(RegExp(r'f\*{3}(?!\w)', caseSensitive: false), 'fuck'),        // f*** → fuck
  _ProfanityRule(RegExp(r'\*{4}ing', caseSensitive: false), 'fucking'),          // ****ing
  _ProfanityRule(RegExp(r'\*{4}er', caseSensitive: false), 'fucker'),            // ****er
  _ProfanityRule(RegExp(r'\*{4}ed', caseSensitive: false), 'fucked'),            // ****ed

  // ── shit / bullshit ──
  _ProfanityRule(RegExp(r'bulls\*{2}t', caseSensitive: false), 'bullshit'),
  _ProfanityRule(RegExp(r'bullsh\*t', caseSensitive: false), 'bullshit'),
  _ProfanityRule(RegExp(r's\*{2}t', caseSensitive: false), 'shit'),              // s**t
  _ProfanityRule(RegExp(r'sh\*t', caseSensitive: false), 'shit'),                // sh*t
  _ProfanityRule(RegExp(r'sh\*{2}', caseSensitive: false), 'shit'),              // sh**

  // ── piss / pissed ──
  _ProfanityRule(RegExp(r'p\*{2}sed', caseSensitive: false), 'pissed'),          // p**sed
  _ProfanityRule(RegExp(r'pi\*{2}ed', caseSensitive: false), 'pissed'),          // pi**ed
  _ProfanityRule(RegExp(r'p\*{2}s', caseSensitive: false), 'piss'),              // p**s
  _ProfanityRule(RegExp(r'pi\*s', caseSensitive: false), 'piss'),                // pi*s

  // ── pussy ──
  _ProfanityRule(RegExp(r'p\*{3}y', caseSensitive: false), 'pussy'),             // p***y
  _ProfanityRule(RegExp(r'pu\*{2}y', caseSensitive: false), 'pussy'),            // pu**y

  // ── bitch ──
  _ProfanityRule(RegExp(r'b\*{3}h', caseSensitive: false), 'bitch'),             // b***h
  _ProfanityRule(RegExp(r'bi\*{2}h', caseSensitive: false), 'bitch'),            // bi**h

  // ── cunt ──
  _ProfanityRule(RegExp(r'c\*{2}t', caseSensitive: false), 'cunt'),              // c**t
  _ProfanityRule(RegExp(r'cu\*t', caseSensitive: false), 'cunt'),                // cu*t

  // ── cock ──
  _ProfanityRule(RegExp(r'c\*{2}k', caseSensitive: false), 'cock'),              // c**k
  _ProfanityRule(RegExp(r'co\*k', caseSensitive: false), 'cock'),                // co*k
  _ProfanityRule(RegExp(r'co\*{2}', caseSensitive: false), 'cock'),              // co**

  // ── dick ──
  _ProfanityRule(RegExp(r'd\*{2}k', caseSensitive: false), 'dick'),              // d**k
  _ProfanityRule(RegExp(r'di\*k', caseSensitive: false), 'dick'),                // di*k

  // ── damn ──
  _ProfanityRule(RegExp(r'd\*{2}n', caseSensitive: false), 'damn'),              // d**n
  _ProfanityRule(RegExp(r'da\*n', caseSensitive: false), 'damn'),                // da*n

  // ── ass / asshole ──
  _ProfanityRule(RegExp(r'ass\*{2}le', caseSensitive: false), 'asshole'),        // ass**le
  _ProfanityRule(RegExp(r'as\*{2}le', caseSensitive: false), 'asshole'),         // as**le
  _ProfanityRule(RegExp(r'a\*{2}hole', caseSensitive: false), 'asshole'),        // a**hole
  _ProfanityRule(RegExp(r'a\*{2}(?!\w)', caseSensitive: false), 'ass'),          // a** → ass

  // ── whore ──
  _ProfanityRule(RegExp(r'w\*{3}e', caseSensitive: false), 'whore'),             // w***e
  _ProfanityRule(RegExp(r'wh\*{2}e', caseSensitive: false), 'whore'),            // wh**e

  // ── slut ── (s**t 已分配给 shit，sl*t 是 slut 的专属模式)
  _ProfanityRule(RegExp(r'sl\*t', caseSensitive: false), 'slut'),                // sl*t

  // ── bastard ──
  _ProfanityRule(RegExp(r'bas\*{4}', caseSensitive: false), 'bastard'),           // bas****
  _ProfanityRule(RegExp(r'b\*{2}tard', caseSensitive: false), 'bastard'),         // b**tard

  // ── prick ──
  _ProfanityRule(RegExp(r'pr\*{2}k', caseSensitive: false), 'prick'),            // pr**k

  // ── twat ──
  _ProfanityRule(RegExp(r'tw\*t', caseSensitive: false), 'twat'),                // tw*t

  // ── wanker ──
  _ProfanityRule(RegExp(r'w\*{2}ker', caseSensitive: false), 'wanker'),          // w**ker
  _ProfanityRule(RegExp(r'wa\*{2}er', caseSensitive: false), 'wanker'),          // wa**er

  // ── sucker ──
  _ProfanityRule(RegExp(r's\*{2}ker', caseSensitive: false), 'sucker'),          // s**ker
  _ProfanityRule(RegExp(r'su\*{2}er', caseSensitive: false), 'sucker'),          // su**er

  // ── fag / faggot ──
  _ProfanityRule(RegExp(r'f\*{3}ot', caseSensitive: false), 'faggot'),           // f***ot
  _ProfanityRule(RegExp(r'fa\*{3}t', caseSensitive: false), 'faggot'),           // fa***t
  _ProfanityRule(RegExp(r'f\*g(?!\w)', caseSensitive: false), 'fag'),            // f*g → fag

  // ── retard ──
  _ProfanityRule(RegExp(r'r\*{4}d', caseSensitive: false), 'retard'),            // r****d
  _ProfanityRule(RegExp(r're\*{3}d', caseSensitive: false), 'retard'),           // re***d

  // ── douche ──
  _ProfanityRule(RegExp(r'do\*{3}e', caseSensitive: false), 'douche'),           // do***e
  _ProfanityRule(RegExp(r'd\*{4}e', caseSensitive: false), 'douche'),            // d****e

  // ── nigga / nigger ──
  _ProfanityRule(RegExp(r'n\*{3}a', caseSensitive: false), 'nigga'),             // n***a
  _ProfanityRule(RegExp(r'ni\*{2}a', caseSensitive: false), 'nigga'),            // ni**a
  _ProfanityRule(RegExp(r'n\*{4}r', caseSensitive: false), 'nigger'),            // n****r
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
/// 1. 强匹配（关键词+分隔符 / 正则）→ 全曲任意位置清空
/// 2. 弱匹配（含冒号/连字符）→ 仅当在头部/尾部且与强匹配行相邻时清空
/// 3. 真正的歌词行作为"防火墙"，阻止弱匹配蔓延

/// 预编译的正则列表，避免每次调用都重新编译
final List<RegExp> _cachedExcludeRegexes = defaultExcludeRegexes
    .map((p) => RegExp(p, caseSensitive: false))
    .toList();

void blankMetadataLines(List<LyricLine> lines, [StripOptions? options]) {
  if (lines.isEmpty) return;
  options ??= const StripOptions();

  final keywords = options.keywords.isNotEmpty
      ? options.keywords
      : defaultExcludeKeywords;
  final regexes = options.regexes.isNotEmpty
      ? options.regexes
      : _cachedExcludeRegexes;

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
  for (int i = 0; i < totalLines; i++) {
    final text = _lineText(lines[i]);
    final transText = lines[i].translation ?? '';
    isStrict[i] = (text.isNotEmpty && _isStrictMatch(text, keywords, regexes)) ||
        (transText.isNotEmpty && _isStrictMatch(transText, keywords, regexes));
    isWeak[i] = (text.isNotEmpty && _looksLikeMetadata(text, options.softRegexes)) ||
        (transText.isNotEmpty && _looksLikeMetadata(transText, options.softRegexes));
  }

  // ── 头部扫描：找元数据区截止位置 ──
  int lastStrictInHeader = -1;
  for (int i = 0; i < headerLimit && i < totalLines; i++) {
    if (isStrict[i]) {
      lastStrictInHeader = i;
    } else if (!isWeak[i]) {
      break; // 非元数据行 → 停止
    }
  }
  final headerCutoff = lastStrictInHeader + 1;

  // ── 尾部扫描：找元数据区起始位置 ──
  int firstStrictInFooter = totalLines;
  for (int i = totalLines - 1;
      i >= (totalLines - footerLimit).clamp(0, totalLines);
      i--) {
    if (isStrict[i]) {
      firstStrictInFooter = i;
    } else if (!isWeak[i]) {
      break;
    }
  }

  // ── 清空头部元数据（全清，含弱匹配） ──
  for (int i = 0; i < headerCutoff; i++) {
    if (isStrict[i] || isWeak[i]) {
      blankLine(lines[i]);
    }
  }

  // ── 清空尾部元数据（全清，含弱匹配） ──
  if (firstStrictInFooter < totalLines) {
    for (int i = firstStrictInFooter; i < totalLines; i++) {
      if (isStrict[i] || isWeak[i]) {
        blankLine(lines[i]);
      }
    }
  }

  // ── 中间区域：仅强匹配 ──
  for (int i = headerCutoff; i < totalLines; i++) {
    if (isStrict[i]) {
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

    if (blankCount > 1 && firstRealStart > Duration.zero) {
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
  return SyncLyricLine(Duration.zero, length, []);
}
