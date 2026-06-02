import 'dart:convert';

import 'package:pure_music/lyric/lyric.dart';
import 'dart:math';

class Krc extends Lyric {
  Krc(super.lines, [super.source = LyricFormat.local, super.rawText]);

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
      // QQ音乐KRC常见缩写（词/曲不带"作"前缀）
      '词', '曲',
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
    // 包含单字缩写：词/曲（QQ音乐KRC常见）
    final metadataRegex = RegExp(
      r'^(作曲|作词|编曲|词|曲|Composer|Lyricist|Arranger|Producer|作曲|作詞|編曲|작곡|작사|편곡)\s*[:：\-–—]',
      caseSensitive: false,
    );
    if (metadataRegex.hasMatch(trimmed)) return true;
    
    return false;
  }

  static Krc fromKrcText(String krc) {
    final List<KrcLine> lines = [];
    String? languageFrame;

    final splited = krc.split('\n');

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
      if (languageFrame == null) {
        final bracketStart = item.indexOf('[');
        final bracketEnd = item.indexOf(']');
        if (bracketStart == -1 || bracketEnd == -1 || bracketEnd <= bracketStart) {
          continue;
        }
        final tag = item.substring(bracketStart + 1, bracketEnd);
        var splitedTag = tag.split(':');
        final tagName = splitedTag.firstOrNull;
        if (tagName?.contains('language') == true) {
          languageFrame = splitedTag[1];
        }
      }

      final krcLine = KrcLine.fromLine(item, null, offset);

      if (krcLine == null) continue;

      // 过滤主歌词中的元数据行（作曲、作词等）
      final lineContent = krcLine.words.map((w) => w.content).join();
      if (lineContent.isNotEmpty && _isMetadataLine(lineContent)) {
        continue;
      }

      lines.add(krcLine);
    }

    if (languageFrame != null) {
      final Map languageMap =
          json.decode(utf8.decode(base64.decode(languageFrame)));
      List<String> trans = [];
      List<String> romas = [];
      for (var item in languageMap['content']) {
        if (item['type'] == 1) {
          final List transContent = item['lyricContent'];
          for (List transLine in transContent) {
            final text = transLine.first;
            // 过滤元数据行（作曲、作词、编曲等）
            if (!_isMetadataLine(text)) {
              trans.add(text);
            }
          }
        } else if (item['type'] == 0) {
          // type=0 是注音（罗马音），使用 join 合并数组中的单个字符
          final List romaContent = item['lyricContent'];
          for (List romaLine in romaContent) {
            romas.add(romaLine.join());
          }
        }
      }

      // 关联翻译到歌词行，跳过空歌词行
      int transIt = 0;
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].words.isEmpty) continue;
        if (transIt < trans.length) {
          lines[i].translation = trans[transIt];
          transIt++;
        }
      }

      // 关联罗马音到歌词行，跳过空歌词行
      int romaIt = 0;
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].words.isEmpty) continue;
        if (romaIt < romas.length) {
          lines[i].romanLyric = romas[romaIt];
          romaIt++;
        }
      }
    }

    // 添加空白
    final List<KrcLine> fommatedLines = [];
    final firstLine = lines.firstOrNull;
    if (firstLine != null && firstLine.start > const Duration(seconds: 5)) {
      fommatedLines.add(KrcLine(Duration.zero, firstLine.start, []));
    }
    for (int i = 0; i < lines.length - 1; ++i) {
      fommatedLines.add(lines[i]);
      final transitionStart = lines[i].start + lines[i].length;
      final transitionLength = lines[i + 1].start - transitionStart;
      if (transitionLength > const Duration(seconds: 5)) {
        fommatedLines.add(KrcLine(transitionStart, transitionLength, []));
      }
    }
    final lastLine = lines.lastOrNull;
    if (lastLine != null) {
      fommatedLines.add(lastLine);
    }

    return Krc(fommatedLines);
  }

  @override
  String toString() {
    return (lines as List<SyncLyricLine>).toString();
  }
}

class KrcLine extends SyncLyricLine {
  KrcLine(super.start, super.length, super.words, [super.translation]);

  static KrcLine? fromLine(String line, [String? translation, int offset = 0]) {
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

    final splitedContent = splitedLine[1].split('<');
    final List<KrcWord> words = [];
    for (final item in splitedContent) {
      final qrcWord = KrcWord.fromWord(item, start, offset);

      if (qrcWord == null) continue;

      words.add(qrcWord);
    }

    return KrcLine(start, length, words, translation);
  }
}

class KrcWord extends SyncLyricWord {
  KrcWord(super.start, super.length, super.content);

  static KrcWord? fromWord(String word, Duration lineStart, [int offset = 0]) {
    final splitedWord = word.split('>');
    if (splitedWord.length != 2) return null;

    final splitedTime = splitedWord[0].split(',');

    if (splitedTime.length < 2) return null;

    final Duration start = Duration(
          milliseconds: max((int.tryParse(splitedTime[0]) ?? 0) - offset, 0),
        ) +
        lineStart;
    final Duration length = Duration(
      milliseconds: int.tryParse(splitedTime[1]) ?? 0,
    );

    final content = splitedWord[1];

    return KrcWord(start, length, content);
  }
}
