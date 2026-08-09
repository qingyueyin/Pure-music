import 'package:flutter/foundation.dart';
import 'package:pure_music/lyric/lyric.dart';

class Vtt extends Lyric {
  Vtt(super.lines, [super.source = LyricFormat.local, super.rawText]);

  static Vtt? fromVttText(String vtt, {String? separator}) {
    try {
      var text = vtt;
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

      final rawLines = text.split('\n');
      final lines = <VttLine>[];
      var i = 0;

      while (i < rawLines.length) {
        final line = rawLines[i].trimRight();
        if (line.trim().isEmpty) {
          i++;
          continue;
        }

        // NOTE / STYLE / REGION 块与注释头：整块跳过
        if (line.startsWith('NOTE') ||
            line.startsWith('STYLE') ||
            line.startsWith('REGION')) {
          while (i < rawLines.length && rawLines[i].trim().isNotEmpty) i++;
          continue;
        }

        final timing = _cueTimingRe.firstMatch(line.trim());
        if (timing == null) {
          i++;
          continue;
        }

        final start = _parseCueTime(timing, startSide: true);
        if (start == null) {
          i++;
          continue;
        }
        final end = _parseCueTime(timing, startSide: false);

        // 收集 cue 正文（到空行或 EOF）
        i++;
        final cueParts = <String>[];
        while (i < rawLines.length && rawLines[i].trim().isNotEmpty) {
          cueParts.add(rawLines[i]);
          i++;
        }

        final cueText = _stripTagsAndEntities(cueParts.join(' '));
        if (cueText.isEmpty) continue;

        final parts = separator != null ? cueText.split(separator) : [cueText];
        final wordContent = parts.first.trim();
        if (wordContent.isEmpty) continue;
        final translation = parts.length > 1
            ? parts.sublist(1).join(separator!).trim()
            : null;

        // 行级：整行一个词
        final words = <SyncLyricWord>[
          SyncLyricWord(start, Duration.zero, wordContent),
        ];
        final length =
            (end != null && end > start) ? end - start : Duration.zero;
        lines.add(
          VttLine(
            start,
            length,
            words,
            translation?.isNotEmpty == true ? translation : null,
          ),
        );
      }

      if (lines.isEmpty) return null;

      lines.sort((a, b) => a.start.compareTo(b.start));

      // 行时长补全：<=0 用下一行起点差 / 5 秒
      for (var j = 0; j < lines.length; j++) {
        final line = lines[j];
        if (line.length <= Duration.zero) {
          final nextStart =
              j < lines.length - 1 ? lines[j + 1].start : null;
          if (nextStart != null) {
            final len = nextStart - line.start;
            line.length = len.isNegative ? Duration.zero : len;
          } else {
            line.length = const Duration(seconds: 5);
          }
        }
        if (line.words.isNotEmpty) {
          line.words.first.length = line.length <
                  const Duration(milliseconds: 50)
              ? const Duration(milliseconds: 50)
              : line.length;
        }
      }

      // 插入前奏 / 间奏空白行
      final result = <VttLine>[];
      final openingDuration = lines.first.start;
      if (openingDuration >= const Duration(seconds: 5)) {
        result.add(VttLine(Duration.zero, openingDuration, const []));
      }
      for (var j = 0; j < lines.length; j++) {
        result.add(lines[j]);
        if (j < lines.length - 1) {
          final nextStart = lines[j + 1].start;
          final gapStart = lines[j].start + lines[j].length;
          final gapDuration = nextStart - gapStart;
          if (gapDuration >= const Duration(seconds: 5)) {
            result.add(VttLine(gapStart, gapDuration, const []));
          }
        }
      }

      return Vtt(result, LyricFormat.local, vtt);
    } catch (e, stack) {
      if (kDebugMode) print('VTT parse failed: $e\n$stack');
      return null;
    }
  }

  // 毫秒必须 3 位，小时段可选（VTT 标准允许 MM:SS.mmm），尾部可带 cue settings
  static final RegExp _cueTimingRe = RegExp(
    r'^(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\.(\d{3})[ \t]+-->[ \t]+'
    r'(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\.(\d{3})(?:[ \t].*)?$',
  );

  static Duration? _parseCueTime(RegExpMatch m, {required bool startSide}) {
    final off = startSide ? 0 : 4;
    final h = int.tryParse(m.group(off + 1) ?? '') ?? 0;
    final mm = int.tryParse(m.group(off + 2) ?? '');
    final s = int.tryParse(m.group(off + 3) ?? '');
    final ms = int.tryParse(m.group(off + 4) ?? '');
    if (mm == null || s == null || ms == null) return null;
    if (s > 59) return null;
    return Duration(hours: h, minutes: mm, seconds: s, milliseconds: ms);
  }

  static String _decodeEntities(String text) {
    return text
        .replaceAll('&apos;', "'")
        .replaceAll('&quot;', '"')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&nbsp;', ' ');
  }

  static final RegExp _tagRe = RegExp(r'<[^>]*>');

  static String _stripTagsAndEntities(String text) {
    return _decodeEntities(text).replaceAll(_tagRe, '');
  }
}

class VttLine extends SyncLyricLine {
  VttLine(super.start, super.length, super.words, [super.translation]);
}
