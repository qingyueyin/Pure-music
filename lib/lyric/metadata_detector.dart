import 'package:pure_music/lyric/exclude_data.dart';

final List<String> _metadataLabels =
    defaultExcludeKeywords
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
  '音乐设计',
  '执行制作',
  '后期制作',
  '后期协力',
  '制作协力',
  '人声编辑',
  '人声录制',
  '改编',
  '伴唱',
  '合音',
  '女声',
  '男声',
  '童声',
  '缩混',
  '出品人',
  '乐队队长',
  '编外制作',
  '客串',
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
  '公司',
  '部门',
  '厂牌',
  '机构',
  '中心',
  '棚',
  '师',
  '手',
  '及',
  '与',
  '和',
  '兼',
  '改编',
  '编配',
  '队长',
  '总监',
  '监督',
  '独奏',
  '字体',
  '次中音',
  '中音',
  '高音',
}.toList()..sort((a, b) => b.length.compareTo(a.length));

final List<String> _prefixedChineseCreditSuffixes = <String>[
  '混音师',
  '录音师',
  '母带师',
  '制作人',
  '工程师',
  '混音',
  '录音',
  '母带',
  '编曲',
  '作词',
  '作曲',
  '监制',
  '和声',
  '和音',
  '伴唱',
  '合音',
  '合声',
  '编配',
  '演奏',
  '独奏',
  '吉他',
  '贝斯',
  '钢琴',
  '键盘',
  '录音室',
  '录音棚',
  '工作室',
  '乐团',
  '指导',
  '统筹',
  '设计',
  '助理',
  '宣推',
  '营销',
  '编辑',
  '公司',
  '乐器',
  '合作伙伴',
  '萨克斯风',
  '编成',
  '协办',
  '监督',
]..sort((a, b) => b.length.compareTo(a.length));

final RegExp _creditByPattern = RegExp(
  r'^(?:(?:additional|background|assistant)\s+)?'
  r'(?:vocals?|arranged|arranger|composed|distributed|lyrics?|mastered|mixed|'
  r'produced(?:\s+and\s+mixed)?|published|recorded|recording|'
  r'engineered(?:\s+for\s+mix)?|assisted|all\s+instruments|'
  r'words and music|written)\s*by\b',
  caseSensitive: false,
);

final RegExp _compoundCreditLabelPattern = RegExp(
  r'^(?:'
  r'(?:人声|配唱|弦乐|吉他|鼓|贝斯|键盘|和声|和音)?(?:录音|混音|母带)'
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
  r'(?:QQ音乐|\bTME\b|©|着作权|著作权|版权|copyright|all rights reserved|used by permission)',
  caseSensitive: false,
);

final RegExp _lrcInlineTagPattern = RegExp(
  r'^(?:ti|ar|al|by|offset|length|tool|au|re|ve|la|id|hash|sign|qq|total|'
  r'language|kana)\s*[:：]',
  caseSensitive: false,
);

final RegExp _disclaimerPattern = RegExp(
  r'(?:翻译水平有限|授权.{0,16}(?:网易云音乐|网易云|QQ音乐|酷狗音乐|酷我音乐)|\bTME\b|'
  r'原创翻译|转载需标注|以下歌词翻译|歌词翻译由|'
  r'(?:本人|个人)(?:解说|自序|注释|解读)\s*[:：])',
  caseSensitive: false,
);

final RegExp _englishCreditRolePattern = RegExp(
  r'\b(?:arrangement|bass|cello|choir|drum programming|drums?|engineer(?:ing)?|'
  r'guitars?|keyboards?|lyrics?|mastering|mixing|music|orchestration|'
  r'percussion|piano|producer|production|programming|publishing|recording|'
  r'strings?|synth(?:esi[sz]ers?)?|trombone|trumpet|sax(?:ophone)?s?|flute|'
  r'clarinet|violas?|violins?|vocals?|glockenspiel|whistling|talkbox)\b|'
  r'\bop-\d+\b',
  caseSensitive: false,
);

final RegExp _englishCreditRelationPattern = RegExp(
  r'\b(?:administered|arranged|composed|distributed|engineered|mastered|mixed|'
  r'orchestrated|produced|published|recorded|written|assisted)?\s*(?:by|at)$',
  caseSensitive: false,
);

final RegExp _courtesyRelationPattern = RegExp(
  r'\b(?:appears?\s+)?courtesy\s+of$',
  caseSensitive: false,
);

const Set<String> _englishRoleTokens = {
  'vocal',
  'vocals',
  'guitar',
  'guitars',
  'piano',
  'drum',
  'drums',
  'bass',
  'cello',
  'viola',
  'violin',
  'string',
  'strings',
  'keyboard',
  'keyboards',
  'synth',
  'synthesizer',
  'synthesizers',
  'synthesiser',
  'synthesisers',
  'organ',
  'harmonica',
  'harp',
  'banjo',
  'mandolin',
  'ukulele',
  'trumpet',
  'trombone',
  'saxophone',
  'sax',
  'flute',
  'clarinet',
  'oboe',
  'horn',
  'brass',
  'percussion',
  'triangle',
  'snap',
  'snaps',
  'accordion',
  'fiddle',
  'producer',
  'engineer',
  'engineering',
  'director',
  'direction',
  'arrange',
  'arrangement',
  'instrumental',
  'mix',
  'rec',
  'programming',
  'program',
  'programme',
  'produce',
  'composer',
  'lyricist',
  'orchestration',
  'orchestra',
  'conga',
  'tambourine',
  'shaker',
  'whistle',
  'xylophone',
  'vibraphone',
  'mixing',
  'mastering',
  'producers',
  'engineers',
  'designer',
  'coordination',
  'assistance',
  'conducting',
  'keys',
  'whistling',
  'glockenspiel',
  'saxophones',
  'synths',
  'instruments',
  'leader',
  'steel',
  'conductor',
  'coordinator',
  'studios',
};

const Set<String> _englishRoleModifiers = {
  'additional',
  'assistant',
  'associate',
  'acoustic',
  'electric',
  'nylon',
  'steel',
  'slide',
  'lead',
  'rhythm',
  'bass',
  'background',
  'backing',
  'guest',
  'tack',
  'modular',
  'alto',
  'tenor',
  'soprano',
  'baritone',
  'finger',
  'other',
  'vocalo',
  'vocal',
  'sound',
  'brass',
  'string',
  'orchestra',
  'recording',
  'mixing',
  'mastering',
  'master',
  'rec',
  'mix',
  'executive',
  'upright',
  'pedal',
  'all',
  'visual',
  '1st',
  '2nd',
  '3rd',
  'first',
  'second',
  'tubular',
  'linn',
  'pulse',
};

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
  value = value.replaceFirst(RegExp(r'^[【\[「『《♪♫]+'), '').trim();
  return value;
}

String _normalizeCreditLabel(String text) {
  return text
      .replaceAll(RegExp(r'[（(][^）)]*[）)]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

final RegExp _preservedArtistLabelPattern = RegExp(
  r'^(?:艺术家|藝術家|artist)\s*[:：]\s*\S',
  caseSensitive: false,
);

bool isPreservedArtistMetadataText(String text) {
  final cleaned = _stripOuterBrackets(
    text.replaceAll(RegExp(r'<[^>]*>'), '').trim(),
  );
  return _preservedArtistLabelPattern.hasMatch(cleaned);
}

bool _isChineseCreditSequence(String text) {
  final normalized = text.replaceAll(RegExp(r'[\s/／&＆、·・＋+]+'), '');
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

bool _isPrefixedChineseCreditLabel(String text) {
  final normalized = text.replaceAll(RegExp(r'[\s/／&＆、·・＋+]+'), '');
  if (normalized.length < 3 || normalized.length > 24) return false;
  if (!RegExp(r'^[\u3400-\u9fff]+$').hasMatch(normalized)) return false;
  if (RegExp(r'[的了着过]').hasMatch(normalized)) return false;
  for (final suffix in _prefixedChineseCreditSuffixes) {
    if (normalized.endsWith(suffix) && normalized.length > suffix.length) {
      return true;
    }
  }
  return false;
}

bool _isChineseCreditListLabel(String text) {
  final parts = text
      .split(RegExp(r'[/\／、&＆]'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.length < 2) return false;
  var creditParts = 0;
  for (final part in parts) {
    if (_isChineseCreditSequence(part) || _isPrefixedChineseCreditLabel(part)) {
      creditParts++;
    } else if (RegExp(r'[的了着过我你他她]').hasMatch(part) ||
        !RegExp(r'^[\u3400-\u9fff]{1,8}$').hasMatch(part.replaceAll(' ', ''))) {
      return false;
    }
  }
  return creditParts >= 1;
}

bool _isStructuredChineseCreditLabel(String text) {
  if (_isChineseCreditSequence(text) ||
      _isPrefixedChineseCreditLabel(text) ||
      _isChineseCreditListLabel(text)) {
    return true;
  }
  for (final separator in RegExp(r'\s+').allMatches(text)) {
    final suffix = text.substring(separator.end).trim();
    if (_isChineseCreditSequence(suffix) ||
        _isPrefixedChineseCreditLabel(suffix)) {
      return true;
    }
  }
  return false;
}

bool _isEnglishRoleOnlyLabel(String text) {
  final normalized = text.trim().toLowerCase();
  if (normalized.isEmpty || normalized.length > 80) return false;
  final tokens = normalized
      .split(RegExp(r'[\s/&,+]+'))
      .where(
        (token) =>
            token.isNotEmpty &&
            token != '-' &&
            token != 'and' &&
            token != 'of' &&
            token != 'for' &&
            token != 'by' &&
            token != 'at',
      )
      .toList();
  if (tokens.isEmpty || tokens.length > 8) return false;
  var hasRole = false;
  for (final token in tokens) {
    if (RegExp(r'^op-\d+$').hasMatch(token)) {
      hasRole = true;
      continue;
    }
    if (_englishRoleTokens.contains(token)) {
      hasRole = true;
      continue;
    }
    if (_englishRoleModifiers.contains(token)) continue;
    return false;
  }
  return hasRole;
}

bool _isStructuredEnglishCreditLabel(String text) {
  final normalized = text.trim();
  if (normalized.isEmpty || normalized.length > 180) return false;
  if (_courtesyRelationPattern.hasMatch(normalized)) return true;
  if (_creditByPattern.hasMatch(normalized)) return true;
  if (_isEnglishRoleOnlyLabel(normalized)) return true;
  return _englishCreditRolePattern.hasMatch(normalized) &&
      _englishCreditRelationPattern.hasMatch(normalized);
}

const Set<String> _bilingualEnglishHeads = {
  'music',
  'production',
  'assistance',
  'coordination',
  'promotion',
  'designer',
  'rearrangement',
  'chorus',
  'bvox',
  'audio',
  'programmer',
  'authors',
  'director',
  'design',
  'arrangement',
  'studio',
  'ukelele',
  'ukulele',
  'original',
  'cover',
  'studios',
  'supervisor',
  'coordinator',
  'conductor',
};

bool _isEnglishCreditHead(String text) {
  final normalized = text.trim();
  if (normalized.isEmpty) return false;
  if (_isStructuredEnglishCreditLabel(normalized)) return true;
  final lower = normalized.toLowerCase();
  for (final label in _metadataLabels) {
    if (lower == label || lower.startsWith('$label ')) return true;
  }
  final tokens = lower
      .split(RegExp(r'[\s/&,+]+'))
      .where((token) => token.isNotEmpty && token != '-' && token != 'and')
      .toList();
  if (tokens.isEmpty || tokens.length > 6) return false;
  return tokens.every(
    (token) =>
        _englishRoleTokens.contains(token) ||
        _englishRoleModifiers.contains(token) ||
        _bilingualEnglishHeads.contains(token),
  );
}

bool _isCjkCreditAlias(String text) {
  final normalized = text.replaceAll(RegExp(r'\s+'), '');
  return normalized.isNotEmpty &&
      normalized.length <= 8 &&
      RegExp(r'^[\u3400-\u9fff]+$').hasMatch(normalized) &&
      !RegExp(r'[的了着过我你他她]').hasMatch(normalized);
}

bool _isBilingualCreditLabel(String text) {
  final cjkThenLatin = RegExp(
    r'^([\u3400-\u9fff]+(?:\s*[/／&＆、＋+]\s*[\u3400-\u9fff]+)*)\s*([A-Za-z].+)$',
  ).firstMatch(text);
  if (cjkThenLatin != null &&
      _isStructuredChineseCreditLabel(cjkThenLatin.group(1)!)) {
    return true;
  }
  final cjkIndex = text.indexOf(RegExp(r'[\u3400-\u9fff]'));
  if (cjkIndex <= 0) return false;
  final latin = text.substring(0, cjkIndex).trim();
  final cjk = text.substring(cjkIndex).trim();
  if (!RegExp(r"^[A-Za-z][A-Za-z0-9 .&+/'-]*$").hasMatch(latin)) {
    return false;
  }
  if (_isEnglishCreditHead(latin) &&
      (_isStructuredChineseCreditLabel(cjk) || _isCjkCreditAlias(cjk))) {
    return true;
  }
  return _isStructuredChineseCreditLabel(cjk) &&
      RegExp(r"^[A-Za-z][A-Za-z0-9+&./' -]{0,24}$").hasMatch(latin);
}

/// 只识别能够独立确认的歌词元数据，含糊格式交给首尾上下文处理。
bool isLyricMetadataText(String text) {
  final cleaned = _stripOuterBrackets(
    text.replaceAll(RegExp(r'<[^>]*>'), '').trim(),
  );
  if (cleaned.isEmpty) return false;
  if (_preservedArtistLabelPattern.hasMatch(cleaned)) return false;

  if (_creditByPattern.hasMatch(cleaned) ||
      _compoundCreditLabelPattern.hasMatch(cleaned) ||
      _rightsPattern.hasMatch(cleaned) ||
      _lrcInlineTagPattern.hasMatch(cleaned) ||
      _disclaimerPattern.hasMatch(cleaned)) {
    return true;
  }

  final separator = RegExp(r'[:：]').firstMatch(cleaned);
  if (separator != null) {
    final label = _normalizeCreditLabel(
      cleaned.substring(0, separator.start).trim(),
    );
    if (_isStructuredChineseCreditLabel(label) ||
        _isStructuredEnglishCreditLabel(label) ||
        _isBilingualCreditLabel(label)) {
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
