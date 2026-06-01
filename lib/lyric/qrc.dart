import 'package:pure_music/lyric/lyric.dart';
import 'dart:math';

class Qrc extends Lyric {
  Qrc(super.lines, [super.source = LyricFormat.local, super.rawText]);

  /// 判断是否为元数据行（作曲、作词、编曲、和声、混音等）
  /// 支持中文、英文、日文、韩文等多种语言的元数据标签
  static bool _isMetadataLine(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return true;
    
    // 多语言元数据标签
    final metadataPatterns = [
      // 中文
      '作曲', '作词', '编曲', '和声', '混音', '母带',
      '演唱', '歌手', '原唱', '翻唱', '录音', '监制',
      '制作', '统筹', '企划', '宣发', '吉他', '贝斯',
      '鼓', '键盘', '弦乐', '管乐', '打击乐',
      // 英文
      'Composer', 'Lyricist', 'Arranger', 'Producer',
      'Vocal', 'Singer', 'Mixing', 'Mastering',
      'Recorded', 'Written', 'Composed', 'Arranged',
      'Guitar', 'Bass', 'Drums', 'Keyboard', 'Strings',
      'Horn', 'Percussion', 'Background', 'Backing',
      'feat.', 'ft.', 'featuring',
      // 日文
      '作曲', '作詞', '編曲', '歌', 'コーラス',
      'ギター', 'ベース', 'ドラム', 'ピアノ',
      'ミックス', 'マスタリング', 'プロデュース',
      // 韩文
      '작곡', '작사', '편곡', '노래', '코러스',
      '믹싱', '마스터링', '프로듀스',
      // 法文
      'Compositeur', 'Parolier', 'Arrangeur',
      'Chant', 'Mixage', 'Mastering',
      // 德文
      'Komponist', 'Texter', 'Arrangeur',
      'Gesang', 'Mischung', 'Mastering',
      // 西班牙文
      'Compositor', 'Letrista', 'Arreglista',
      'Voz', 'Mezcla', 'Masterización',
      // 通用缩写和符号
      'by', 'prod.', 'arr.', 'mix.', 'mast.',
    ];
    
    for (final pattern in metadataPatterns) {
      if (trimmed.startsWith(pattern)) return true;
    }
    
    // 匹配常见的元数据格式： "角色: 名字" 或 "角色 - 名字"
    final metadataRegex = RegExp(
      r'^(作曲|作词|编曲|Composer|Lyricist|Arranger|Producer|作曲|作詞|編曲|작곡|작사|편곡)\s*[:：\-–—]',
      caseSensitive: false,
    );
    if (metadataRegex.hasMatch(trimmed)) return true;
    
    return false;
  }

  static Qrc fromQrcText(String qrc, [String? transRawStr]) {
    final List<QrcLine> lines = [];
    final splited = qrc.split('\n');

    int? offsetInMilliseconds;
    final offsetPattern = RegExp(r'\[\s*offset\s*:\s*([+-]?\d+)\s*\]');
    for (final line in splited) {
      final matched = offsetPattern.firstMatch(line);
      if (matched == null) continue;
      offsetInMilliseconds = int.tryParse(matched.group(1) ?? '');
      break;
    }
    final offset = offsetInMilliseconds ?? 0;

    for (final item in splited) {
      final qrcLine = QrcLine.fromLine(item, null, offset);

      if (qrcLine == null) continue;

      // 过滤主歌词中的元数据行（作曲、作词等）
      final lineContent = qrcLine.words.map((w) => w.content).join();
      if (lineContent.isNotEmpty && _isMetadataLine(lineContent)) {
        continue;
      }

      lines.add(qrcLine);
    }

    if (transRawStr != null) {
      final splitedTrans = transRawStr.split('\n');
      // 解析翻译行并提取时间戳
      final List<_TransLine> transEntries = [];
      for (var transLine in splitedTrans) {
        final bracketStart = transLine.indexOf('[');
        final bracketEnd = transLine.indexOf(']');
        if (bracketStart == -1 || bracketEnd == -1 || bracketEnd <= bracketStart) continue;

        final timeStr = transLine.substring(bracketStart + 1, bracketEnd);
        final parts = timeStr.split(':');
        if (parts.length >= 2) {
          final mins = int.tryParse(parts[0]) ?? 0;
          final secs = double.tryParse(parts[1]) ?? 0.0;
          final transTimeMs = (mins * 60000 + (secs * 1000).round());
          final t = transLine.replaceAll(RegExp(r'\[\d{2}:\d{2}\.\d{2,}\]'), '').trim();
          if (t.isNotEmpty && !_isMetadataLine(t)) {
            transEntries.add(_TransLine(Duration(milliseconds: transTimeMs), t));
          }
        }
      }

      // 贪心最近匹配：每个翻译行找最近的原文行（误差 ≤ 5s）
      const maxDriftMs = 5000;
      int lastMatchedIdx = -1;

      for (final te in transEntries) {
        int bestIdx = -1;
        int bestDiff = maxDriftMs + 1;

        for (int i = lastMatchedIdx + 1; i < lines.length; i++) {
          if (lines[i].words.isEmpty) continue;
          final diff = (lines[i].start.inMilliseconds - te.start.inMilliseconds).abs();

          if (diff < bestDiff) {
            bestDiff = diff;
            bestIdx = i;
          } else if (diff > bestDiff) {
            break; // 时间戳递增，越过最优解后停止
          }
        }

        if (bestIdx != -1 && bestDiff <= maxDriftMs) {
          lines[bestIdx].translation = te.text;
          lastMatchedIdx = bestIdx;
        }
      }
    }

    // 添加空白
    final List<QrcLine> fommatedLines = [];
    final firstLine = lines.firstOrNull;
    if (firstLine != null && firstLine.start > const Duration(seconds: 5)) {
      fommatedLines.add(QrcLine(Duration.zero, firstLine.start, []));
    }
    for (int i = 0; i < lines.length - 1; ++i) {
      fommatedLines.add(lines[i]);
      final transitionStart = lines[i].start + lines[i].length;
      final transitionLength = lines[i + 1].start - transitionStart;
      if (transitionLength > const Duration(seconds: 5)) {
        fommatedLines.add(QrcLine(transitionStart, transitionLength, []));
      }
    }
    final lastLine = lines.lastOrNull;
    if (lastLine != null) {
      fommatedLines.add(lastLine);
    }

    return Qrc(fommatedLines);
  }

  @override
  String toString() {
    return (lines as List<SyncLyricLine>).toString();
  }
}

class QrcLine extends SyncLyricLine {
  QrcLine(super.start, super.length, super.words, [super.translation]);

  static QrcLine? fromLine(String line, [String? translation, int offset = 0]) {
    final splitedLine = line.split(']');
    final from = splitedLine[0].indexOf('[') + 1;
    final splitedTime = splitedLine[0].substring(from).split(',');

    if (splitedTime.length != 2) return null;

    final Duration start = Duration(
      milliseconds: max((int.tryParse(splitedTime[0]) ?? 0) - offset, 0),
    );
    final Duration length = Duration(
      milliseconds: int.tryParse(splitedTime[1]) ?? 0,
    );

    final splitedContent = splitedLine[1].split(')');
    final List<QrcWord> words = _parseWords(splitedContent);

    return QrcLine(start, length, words, translation);
  }

  static List<QrcWord> _parseWords(List<String> contentParts) {
    final List<QrcWord> words = [];
    for (final item in contentParts) {
      final qrcWord = QrcWord.fromWord(item);
      if (qrcWord == null) continue;

      if (words.isNotEmpty && _shouldMergeWords(qrcWord, words.last)) {
        final last = words.last;
        final mergedEnd = last.start + last.length;
        if (mergedEnd >= qrcWord.start) {
          words[words.length - 1] = _mergeWords(last, qrcWord);
          continue;
        }
      }

      words.add(qrcWord);
    }
    return words;
  }

  static bool _shouldMergeWords(QrcWord curr, QrcWord last) {
    return curr.start == last.start ||
        (curr.length.inMilliseconds <= 60 && last.start > Duration.zero) ||
        (last.length.inMilliseconds <= 60 && last.start > Duration.zero);
  }

  static QrcWord _mergeWords(QrcWord last, QrcWord curr) {
    return QrcWord(
      last.start,
      Duration(milliseconds: last.length.inMilliseconds + curr.length.inMilliseconds),
      last.content + curr.content,
    );
  }
}

class QrcWord extends SyncLyricWord {
  QrcWord(super.start, super.length, super.content);

  static QrcWord? fromWord(String word) {
    final splitedWord = word.split('(');
    if (splitedWord.length != 2) return null;

    final splitedTime = splitedWord[1].split(',');

    if (splitedTime.length != 2) return null;

    // QRC 单词时间戳是绝对时间，不需要 +lineStartMs
    final Duration start = Duration(
      milliseconds: max(int.tryParse(splitedTime[0]) ?? 0, 0),
    );
    final Duration length = Duration(
      milliseconds: int.tryParse(splitedTime[1]) ?? 0,
    );

    final content = splitedWord[0];

    return QrcWord(start, length, content);
  }
}

class _TransLine {
  final Duration start;
  final String text;
  _TransLine(this.start, this.text);
}
