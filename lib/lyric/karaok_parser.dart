import 'package:pure_music/lyric/lyric.dart';

// ──────────────────────────────────────────────
// KaraOK 格式（YRC/QRC/KRC）解析器
// 使用正则逐字解析，比原有 split 方式更健壮
// ──────────────────────────────────────────────

/// KaraOK 行正则：[start_ms,duration_ms]content
final _karaOkLineRe = RegExp(r'\[(\d+),(\d+)](.*?)(\r?\n|$)');

/// YRC 单词正则：(start,dur,?)text
final _yrcWordRe = RegExp(r'\((\d+),(\d+),\d+\)[^(]*?((?:.(?!\(\d+,))*.)');

/// QRC 单词正则：text(start,dur)
final _qrcWordRe = RegExp(r'[^(]*?((?:.(?!\(\d+,))*.)\((\d+),(\d+)\)');

/// KRC 单词正则：`<start,dur,?>text`
final _krcWordRe = RegExp(r'<(\d+),(\d+),\d+>[^<]*?((?:.(?!<\d+,))*.)');

// ──────────────────────────────────────────────
// 内部模型
// ──────────────────────────────────────────────
class _Word {
  final int startMs;
  int durationMs;
  final String text;
  _Word(this.startMs, this.durationMs, this.text);
}

// ──────────────────────────────────────────────
// 单词解析配置
// ──────────────────────────────────────────────
class _WordConfig {
  final RegExp regex;
  final int startIdx, durIdx, textIdx;
  const _WordConfig(this.regex, this.startIdx, this.durIdx, this.textIdx);
}

_WordConfig? _configFor(String ext) => switch (ext) {
      '.yrc' => _WordConfig(_yrcWordRe, 1, 2, 3),
      '.qrc' => _WordConfig(_qrcWordRe, 2, 3, 1),
      '.krc' => _WordConfig(_krcWordRe, 1, 2, 3),
      _ => null,
    };

// 合并小单词
// ──────────────────────────────────────────────
bool _shouldMerge(_Word curr, _Word last) =>
    curr.startMs == last.startMs ||
    ((curr.durationMs <= 60 || last.durationMs <= 60) && last.startMs > 0);

_Word _merge(_Word last, _Word curr) => _Word(
      last.startMs,
      last.durationMs + curr.durationMs,
      last.text + curr.text,
    );

// ──────────────────────────────────────────────
// 单行单词解析
// ──────────────────────────────────────────────
List<_Word> _parseWords(
  String content,
  _WordConfig cfg,
  int lineStartMs,
  bool wordsAreAbsolute,
) {
  final words = <_Word>[];
  for (final m in cfg.regex.allMatches(content)) {
    final startMs = int.parse(m.group(cfg.startIdx)!);
    final durMs = int.parse(m.group(cfg.durIdx)!);
    final text = m.group(cfg.textIdx)!.replaceAll('\n', '');

    if (text.isEmpty) continue;

    final absStart = wordsAreAbsolute ? startMs : startMs + lineStartMs;
    final curr = _Word(absStart, durMs, text);

    if (words.isNotEmpty && _shouldMerge(curr, words.last)) {
      final last = words.last;
      if (last.startMs + last.durationMs >= curr.startMs) {
        words[words.length - 1] = _merge(last, curr);
        continue;
      }
    }
    words.add(curr);
  }
  return words;
}

// ──────────────────────────────────────────────
// 构建 Pure Music 的 SyncLyricLine
// ──────────────────────────────────────────────
SyncLyricLine _buildLine(
  Duration lineStart,
  Duration lineLength,
  List<_Word> words,
  String? translation,
) {
  final syncWords = words
      .map((w) => SyncLyricWord(
            Duration(milliseconds: w.startMs),
            Duration(milliseconds: w.durationMs),
            w.text,
          ))
      .toList();

  return SyncLyricLine(lineStart, lineLength, syncWords, translation);
}

// ──────────────────────────────────────────────
// 🎯 主入口：解析 KaraOK 格式文本 → Pure Music Lyric
// ──────────────────────────────────────────────

/// 解析 YRC/QRC/KRC 格式歌词文本，返回 Pure Music 的 Lyric 对象。
///
/// [ext] 扩展名（.yrc / .qrc / .krc）
/// [content] 已解密/解码的歌词文本
/// [transContent] 可选的翻译文本（QRC/YRC 配对的 .lrc）
Lyric? parseKaraokToPureLyric(
  String ext,
  String content, [
  String? transContent,
]) {
  final cfg = _configFor(ext);
  if (cfg == null) return null;

  final wordsAreAbsolute = ext != '.krc'; // YRC/QRC 绝对时间，KRC 相对时间

  final List<_LineData> lines = [];

  for (final m in _karaOkLineRe.allMatches(content)) {
    final startMs = int.parse(m.group(1)!);
    final durMs = int.parse(m.group(2)!);
    final lineContent = m.group(3)!;

    final words = _parseWords(lineContent, cfg, startMs, wordsAreAbsolute);
    lines.add(_LineData(
      start: Duration(milliseconds: startMs),
      length: Duration(milliseconds: durMs),
      words: words,
    ));
  }

  if (lines.isEmpty) return null;

  // 合并翻译
  final transLines = <_LineData>[];
  if (transContent != null && transContent.isNotEmpty) {
    for (final m in _karaOkLineRe.allMatches(transContent)) {
      transLines.add(_LineData(
        start: Duration(milliseconds: int.parse(m.group(1)!)),
        length: Duration.zero,
        words: [],
        rawText: m.group(3)?.trim(),
      ));
    }
  }

  // 构建最终的 SyncLyricLine 列表（两指针法匹配翻译）
  final resultLines = <SyncLyricLine>[];
  const toleranceMs = 300;
  int transIdx = 0;

  for (int i = 0; i < lines.length; i++) {
    final l = lines[i];

    String? translation;

    while (transIdx < transLines.length) {
      final t = transLines[transIdx];
      final diff = l.start.inMilliseconds - t.start.inMilliseconds;

      if (diff.abs() <= toleranceMs) {
        translation = t.rawText?.trim();
        if (translation == '//') translation = null;
        transIdx++;
        break;
      } else if (diff < 0) {
        break;
      } else {
        transIdx++;
      }
    }

    final line = _buildLine(l.start, l.length, l.words, translation);
    resultLines.add(line);
  }

  // 添加前奏空白行
  if (resultLines.isNotEmpty && resultLines.first.start > const Duration(seconds: 5)) {
    resultLines.insert(
      0,
      SyncLyricLine(Duration.zero, resultLines.first.start, []),
    );
  }

  // 添加间奏空白行
  for (int i = resultLines.length - 1; i >= 1; i--) {
    final curr = resultLines[i - 1];
    final next = resultLines[i];
    final gap = next.start - (curr.start + curr.length);
    if (gap > const Duration(seconds: 5)) {
      resultLines.insert(
        i,
        SyncLyricLine(curr.start + curr.length, gap, []),
      );
    }
  }

  // UI 只检查 is SyncLyricLine，统一用 Lyric 包装即可
  return Lyric(resultLines.cast<LyricLine>(), LyricFormat.local);
}

class _LineData {
  final Duration start;
  final Duration length;
  final List<_Word> words;
  final String? rawText;
  _LineData({
    required this.start,
    required this.length,
    required this.words,
    this.rawText,
  });
}
