import 'package:pure_music/lyric/exclude_data.dart';

final List<String> _metadataLabels = defaultExcludeKeywords
    .map((label) => label.trim().toLowerCase())
    .where((label) => label.isNotEmpty)
    .toList(growable: false)
  ..sort((a, b) => b.length.compareTo(a.length));

final Set<String> _structuredChineseCreditBases = <String>{
  ...defaultExcludeKeywords.where(
    (label) => RegExp(r'^[\u3400-\u9fff]+$').hasMatch(label.trim()),
  ),
  '人声',
  '录制',
  '录音棚',
  '混音师',
  '母带师',
  '音乐总监',
  '执行制作',
  '后期制作',
  '后期协力',
  '制作协力',
  '人声编辑',
  '人声录制',
};

final List<String> _structuredChineseCreditSegments = <String>{
  ..._structuredChineseCreditBases,
  '录制',
  '工程师',
  '工程',
  '后期',
  '处理',
  '编写',
  '编辑',
  '指导',
  '助理',
  '协力',
  '负责人',
  '棚',
  '师',
  '及',
  '与',
  '和',
  '兼',
}.toList()
  ..sort((a, b) => b.length.compareTo(a.length));

final RegExp _creditByPattern = RegExp(
  r'^(?:additional vocals?|arranged|background vocals?|composed|distributed|'
  r'lyrics?|mastered|mixed|produced|published|recorded|vocals?|words and music|written)\s+by\b',
  caseSensitive: false,
);

final RegExp _compoundCreditLabelPattern = RegExp(
  r'^(?:'
  r'(?:人声|配唱|弦乐|吉他|鼓)?(?:录音|混音|母带)'
  r'(?:\s*[/／&、]\s*(?:录音|混音|母带))*'
  r'(?:(?:后期|处理|工程师|工程|录音室|工作室|制作人|制作|棚))*'
  r'(?:\s+(?:(?:vocal\s+)?(?:recording|mixing|mastering)'
  r'(?:\s*(?:&|/)\s*(?:recording|mixing|mastering))*'
  r'(?:\s+(?:studio|engineer|producer))?))?'
  r'|(?:vocal\s+)?(?:recording|mixing|mastering)'
  r'(?:\s*(?:&|/)\s*(?:recording|mixing|mastering))*'
  r'\s+(?:studio|engineer|producer)'
  r')\s*[:：]',
  caseSensitive: false,
);

final RegExp _rightsPattern = RegExp(
  r'(?:QQ音乐|©|着作权|著作权|版权|copyright|all rights reserved|used by permission)',
  caseSensitive: false,
);

final RegExp _englishCreditRolePattern = RegExp(
  r'\b(?:arrangement|bass|cello|choir|drum programming|drums?|engineer(?:ing)?|'
  r'guitars?|keyboards?|lyrics?|mastering|mixing|music|orchestration|'
  r'percussion|piano|producer|production|programming|publishing|recording|'
  r'strings?|synthesi[sz]ers?|violas?|violins?|vocals?)\b|\bop-\d+\b',
  caseSensitive: false,
);

final RegExp _englishCreditRelationPattern = RegExp(
  r'\b(?:administered|arranged|composed|distributed|engineered|mastered|mixed|'
  r'orchestrated|produced|published|recorded|written)?\s*by$',
  caseSensitive: false,
);

final RegExp _courtesyRelationPattern = RegExp(
  r'\b(?:appears?\s+)?courtesy\s+of$',
  caseSensitive: false,
);

String _stripOuterBrackets(String text) {
  var value = text.trim();
  const pairs = <(String, String)>[
    ('(', ')'),
    ('（', '）'),
    ('[', ']'),
    ('【', '】'),
    ('{', '}'),
    ('「', '」'),
    ('『', '』'),
  ];
  for (var pass = 0; pass < 4; pass++) {
    var changed = false;
    for (final pair in pairs) {
      if (value.startsWith(pair.$1) && value.endsWith(pair.$2)) {
        value = value
            .substring(pair.$1.length, value.length - pair.$2.length)
            .trim();
        changed = true;
        break;
      }
    }
    if (!changed) break;
  }
  return value;
}

bool _isChineseCreditSequence(String text) {
  final normalized = text.replaceAll(RegExp(r'[\s/／&＆、·・]+'), '');
  if (normalized.isEmpty || normalized.length > 40) return false;
  if (!RegExp(r'^[\u3400-\u9fff]+$').hasMatch(normalized)) return false;

  var offset = 0;
  var isFirstSegment = true;
  while (offset < normalized.length) {
    String? matched;
    for (final segment in _structuredChineseCreditSegments) {
      if (normalized.startsWith(segment, offset)) {
        matched = segment;
        break;
      }
    }
    if (matched == null) return false;
    if (isFirstSegment && !_structuredChineseCreditBases.contains(matched)) {
      return false;
    }
    offset += matched.length;
    isFirstSegment = false;
  }
  return true;
}

bool _isStructuredChineseCreditLabel(String text) {
  if (_isChineseCreditSequence(text)) return true;
  for (final separator in RegExp(r'\s+').allMatches(text)) {
    final suffix = text.substring(separator.end).trim();
    if (_isChineseCreditSequence(suffix)) return true;
  }
  return false;
}

bool _isStructuredEnglishCreditLabel(String text) {
  final normalized = text.trim();
  if (normalized.isEmpty || normalized.length > 180) return false;
  if (_courtesyRelationPattern.hasMatch(normalized)) return true;
  return _englishCreditRolePattern.hasMatch(normalized) &&
      _englishCreditRelationPattern.hasMatch(normalized);
}

/// 只识别能够独立确认的歌词元数据，含糊格式交给首尾上下文处理。
bool isLyricMetadataText(String text) {
  final cleaned = _stripOuterBrackets(
    text.replaceAll(RegExp(r'<[^>]*>'), '').trim(),
  );
  if (cleaned.isEmpty) return false;

  if (_creditByPattern.hasMatch(cleaned) ||
      _compoundCreditLabelPattern.hasMatch(cleaned) ||
      _rightsPattern.hasMatch(cleaned)) {
    return true;
  }

  final separator = RegExp(r'[:：]').firstMatch(cleaned);
  if (separator != null) {
    final label = cleaned.substring(0, separator.start).trim();
    if (_isStructuredChineseCreditLabel(label) ||
        _isStructuredEnglishCreditLabel(label)) {
      return true;
    }
  }

  final normalized = cleaned.toLowerCase();
  for (final label in _metadataLabels) {
    if (!normalized.startsWith(label)) continue;
    final remainder = normalized.substring(label.length).trimLeft();
    if (remainder.startsWith(':') || remainder.startsWith('：')) return true;
    if (label.endsWith(' by') && remainder.isNotEmpty) return true;
  }
  return false;
}
