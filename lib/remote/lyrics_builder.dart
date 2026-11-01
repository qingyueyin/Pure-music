/// 把 OpenSubsonic 的结构化歌词（`getLyricsBySongId`）转成 LRC 文本。
///
/// Navidrome 扫描音频时会把内嵌歌词抽进库，返回的格式是：
/// ```
/// { "lang": "eng",
///   "line": [ { "start": 0, "end": 883, "value": "…",
///               "cue": [ { "start": 14, "end": 29, "value": "Waku! " } ] } ] }
/// ```
/// `line.start` 是行时间，`cue.start` 是逐字时间。拼成增强 LRC
/// （`[00:16.15]<00:16.15>Waku<00:16.44>!`）后，现有的歌词解析器
/// 会识别成 `format=enhanced`，逐字高亮直接可用。
library;

typedef SubsonicLyric = ({String text, bool hasTiming, bool hasCues});

/// 把 OpenSubsonic 的 `structuredLyrics` 单个块转成增强 LRC。
///
/// 逐字信息在块的 `cueLine[]` 里（`index` 指向 `line[]` 的下标）——
/// **只有请求带 `enhanced=true` 时服务器才会返回**；部分实现把 `cue`
/// 内联在 `line[]` 上，这里两种都认。
///
/// 返回 null 表示这个块里没有可用文本。
SubsonicLyric? buildLyricTextFromStructuredBlock(Object? block) {
  if (block is! Map) return null;
  final lines = _asList(block['line']);
  if (lines.isEmpty) return null;
  return _buildSubsonicLines(lines, _cueIndexFor(block));
}

/// 兼容旧调用：只有 line 列表、没有 cueLine 的写法。
SubsonicLyric? buildLyricTextFromSubsonic(List<Object?> lines) =>
    _buildSubsonicLines(lines, const <int, List<Object?>>{});

Map<int, List<Object?>> _cueIndexFor(Object? block) {
  if (block is! Map) return const {};
  final entries = _asList(block['cueLine']);
  if (entries.isEmpty) return const {};
  final byIndex = <int, List<Object?>>{};
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    if (entry is! Map) continue;
    final cues = _asList(entry['cue']);
    if (cues.isEmpty) continue;
    byIndex[_intOf(entry['index']) ?? i] = cues;
  }
  return byIndex;
}

SubsonicLyric? _buildSubsonicLines(
  List<Object?> lines,
  Map<int, List<Object?>> cuesByIndex,
) {
  final buffer = StringBuffer();
  var hasTiming = false;
  var hasCues = false;
  for (var index = 0; index < lines.length; index++) {
    final raw = lines[index];
    if (raw is! Map) continue;
    final value = raw['value']?.toString().trim() ?? '';
    if (value.isEmpty) continue;
    final start = _intOf(raw['start']);
    if (start != null) hasTiming = true;

    final cues = cuesByIndex[index] ?? _asList(raw['cue']);
    // 逐字词的拼写必须能还原整行，否则宁可退回行级：少字比错位更难查。
    if (cues.isNotEmpty && _cuesMatchLine(cues, value)) {
      hasCues = true;
      if (start != null) buffer.write(_lrcStamp(start));
      for (final cue in cues) {
        if (cue is! Map) continue;
        final word = cue['value']?.toString() ?? '';
        if (word.isEmpty) continue;
        final cueStart = _intOf(cue['start']);
        if (cueStart != null) buffer.write('<${_lrcStamp(cueStart, brackets: false)}>');
        buffer.write(word);
      }
      buffer.writeln();
      continue;
    }

    if (start != null) buffer.write(_lrcStamp(start));
    buffer.writeln(value);
  }
  final text = buffer.toString().trim();
  if (text.isEmpty) return null;
  return (text: text, hasTiming: hasTiming, hasCues: hasCues);
}

bool _cuesMatchLine(List<Object?> cues, String line) {
  final joined = StringBuffer();
  for (final cue in cues) {
    if (cue is! Map) continue;
    joined.write(cue['value']?.toString() ?? '');
  }
  String squeeze(String value) => value.replaceAll(RegExp(r'\s+'), '');
  return squeeze(joined.toString()) == squeeze(line);
}

List<Object?> _asList(Object? value) {
  if (value is List) return value;
  if (value is Map) return <Object?>[value];
  return const <Object?>[];
}

/// 把 Jellyfin 的歌词结构转成 LRC。
///
/// 返回形如 `{"Lyrics":[{"Text":"…","Start":0,"Cues":[{"Position":0,
/// "EndPosition":1,"Start":600000}]}]}`，其中 `Start` 是 100ns tick，
/// `Cues` 的 Position/EndPosition 是 Text 里的字符下标 —— 正好能拼成逐字标签。
SubsonicLyric? buildLyricTextFromJellyfin(Object? rawLines) {
  if (rawLines is! List) return null;
  final buffer = StringBuffer();
  var hasTiming = false;
  var hasCues = false;
  for (final raw in rawLines) {
    if (raw is! Map) continue;
    final text = raw['Text']?.toString() ?? '';
    if (text.trim().isEmpty) continue;
    final lineStart = _ticksToMs(raw['Start']);
    final cues = raw['Cues'];
    final cueList = cues is List ? cues : const <Object?>[];
    if (lineStart != null && lineStart > 0) hasTiming = true;
    if (cueList.isEmpty) {
      if (lineStart != null && lineStart > 0) {
        buffer.write(_lrcStamp(lineStart));
      }
      buffer.writeln(text.trim());
      continue;
    }
    buffer.write(lineStart == null || lineStart <= 0 ? '' : _lrcStamp(lineStart));
    for (final cue in cueList) {
      if (cue is! Map) continue;
      final start = _ticksToMs(cue['Start']);
      final from = _intOf(cue['Position']);
      final to = _intOf(cue['EndPosition']);
      if (from == null || to == null || from < 0 || to > text.length) continue;
      if (from >= to) continue;
      if (start != null) {
        hasTiming = true;
        hasCues = true;
        buffer.write('<${_lrcStamp(start, brackets: false)}>');
      }
      buffer.write(text.substring(from, to));
    }
    buffer.writeln();
  }
  final lyric = buffer.toString().trim();
  if (lyric.isEmpty) return null;
  return (text: lyric, hasTiming: hasTiming, hasCues: hasCues);
}

/// Jellyfin 的时间单位是 100ns tick。
int? _ticksToMs(Object? value) {
  final ticks = _intOf(value);
  return ticks == null ? null : ticks ~/ 10000;
}

int? _intOf(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '');
}

/// `[03:12.34]`；`brackets: false` 时给逐字标签用（`03:12.34`）。
String _lrcStamp(int milliseconds, {bool brackets = true}) {
  final total = milliseconds < 0 ? 0 : milliseconds;
  final minutes = total ~/ 60000;
  final seconds = (total % 60000) ~/ 1000;
  final centis = (total % 1000) ~/ 10;
  final stamp =
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}.'
      '${centis.toString().padLeft(2, '0')}';
  return brackets ? '[$stamp]' : stamp;
}
