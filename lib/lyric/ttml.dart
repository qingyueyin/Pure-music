import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:xml/xml.dart';

class Ttml extends Lyric {
  final LrcSource source;
  Ttml(super.lines, this.source);

  static Ttml? fromTtmlText(String ttml, LrcSource source, {String? separator}) {
    try {
      final document = XmlDocument.parse(ttml);
      final body = document.findElements('body').firstOrNull;
      if (body == null) return null;

      final lines = <TtmlLine>[];
      final divs = body.findElements('div');

      for (final div in divs) {
        final paragraphs = div.findElements('p');
        for (final p in paragraphs) {
          final line = _parseParagraph(p, separator);
          if (line != null) {
            lines.add(line);
          }
        }
      }

      if (lines.isEmpty) return null;

      lines.sort((a, b) => a.start.compareTo(b.start));

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        final nextStart = i < lines.length - 1 ? lines[i + 1].start : null;
        if (line.length == Duration.zero) {
          final lineLen = nextStart == null
              ? const Duration(seconds: 5)
              : (nextStart - line.start);
          line.length = lineLen.isNegative ? Duration.zero : lineLen;
        }

        if (line.words.isEmpty) continue;
        final words = line.words.cast<TtmlWord>();
        for (int j = 0; j < words.length; j++) {
          final curr = words[j];
          final nextWordStart =
              j < words.length - 1 ? words[j + 1].start : null;
          final end = nextWordStart ?? (line.start + line.length);
          final d = end - curr.start;
          curr.length = d.isNegative
              ? Duration.zero
              : (d < const Duration(milliseconds: 50)
                  ? const Duration(milliseconds: 50)
                  : d);
        }
      }

      return Ttml(lines, source);
    } catch (e) {
      return null;
    }
  }

  static TtmlLine? _parseParagraph(XmlElement p, String? separator) {
    final beginAttr = p.getAttribute('begin');
    final endAttr = p.getAttribute('end');
    final durAttr = p.getAttribute('dur');

    if (beginAttr == null) return null;

    final begin = _parseTime(beginAttr);
    if (begin == null) return null;

    Duration? end;
    if (endAttr != null) {
      end = _parseTime(endAttr);
    }
    Duration? dur;
    if (durAttr != null) {
      dur = _parseTime(durAttr);
    }

    final length = end != null
        ? end - begin
        : dur ?? Duration.zero;

    final words = <TtmlWord>[];
    String? translation;

    final children = p.children;
    bool hasSpans = false;

    for (final child in children) {
      if (child is XmlElement && child.name.local == 'span') {
        hasSpans = true;
        final spanBegin = child.getAttribute('begin');
        final spanEnd = child.getAttribute('end');
        final spanDur = child.getAttribute('dur');
        final text = child.innerText;

        if (text.isEmpty) continue;

        if (spanBegin != null) {
          final wordBegin = _parseTime(spanBegin);
          if (wordBegin != null) {
            Duration? wordEnd;
            if (spanEnd != null) {
              wordEnd = _parseTime(spanEnd);
            }
            Duration? wordDur;
            if (spanDur != null) {
              wordDur = _parseTime(spanDur);
            }

            final wordLength = wordEnd != null
                ? wordEnd - wordBegin
                : wordDur ?? Duration.zero;

            words.add(TtmlWord(
              wordBegin,
              wordLength,
              text,
            ));
          }
        } else {
          final cleaned = text.trim();
          if (cleaned.isNotEmpty) {
            if (translation == null) {
              translation = cleaned;
            } else {
              translation = '$translation${separator ?? '┃'}$cleaned';
            }
          }
        }
      }
    }

    if (!hasSpans) {
      final text = p.innerText;
      if (text.isNotEmpty) {
        final parts = separator != null ? text.split(separator!) : [text];
        if (parts.isNotEmpty) {
          words.add(TtmlWord(begin, length, parts.first.trim()));
          if (parts.length > 1) {
            translation = parts.sublist(1).join(separator ?? '').trim();
          }
        }
      }
    }

    if (words.isEmpty) return null;

    return TtmlLine(begin, length, words, translation?.isEmpty == true ? null : translation);
  }

  static Duration? _parseTime(String time) {
    time = time.trim();
    if (time.isEmpty) return null;

    if (time.contains(':')) {
      final parts = time.split(':');
      if (parts.length == 3) {
        final hours = double.tryParse(parts[0]) ?? 0;
        final minutes = double.tryParse(parts[1]) ?? 0;
        final seconds = _parseSeconds(parts[2]);
        return Duration(
          milliseconds: ((hours * 3600 + minutes * 60 + seconds) * 1000).round(),
        );
      } else if (parts.length == 2) {
        final minutes = double.tryParse(parts[0]) ?? 0;
        final seconds = _parseSeconds(parts[1]);
        return Duration(
          milliseconds: ((minutes * 60 + seconds) * 1000).round(),
        );
      }
    }

    final seconds = double.tryParse(time);
    if (seconds != null) {
      return Duration(milliseconds: (seconds * 1000).round());
    }

    return null;
  }

  static double _parseSeconds(String s) {
    s = s.trim();
    if (s.contains('.')) {
      return double.tryParse(s) ?? 0.0;
    }
    return double.tryParse(s) ?? 0.0;
  }
}

class TtmlLine extends SyncLyricLine {
  TtmlLine(super.start, super.length, super.words, [super.translation]);
}

class TtmlWord extends SyncLyricWord {
  TtmlWord(super.start, super.length, super.content);
}
