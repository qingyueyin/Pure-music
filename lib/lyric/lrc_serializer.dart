import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_tag_word_format.dart';

String serializeLyricToLrc(
  Lyric lyric, {
  required LyricTagWordFormat wordFormat,
}) {
  final output = _extractLrcMetadata(lyric.rawText);
  for (final line in lyric.lines) {
    if (line is LrcLine) {
      if (line.isMetadata || line.content.trim().isEmpty) continue;
      output.add('${_lrcTime(line.start)}${line.content}');
      _appendSupplementalLines(output, line);
      continue;
    }
    if (line is SyncLyricLine) {
      final words =
          line.words.where((word) => word.content.isNotEmpty).toList();
      if (words.isEmpty) continue;
      final buffer = StringBuffer();
      if (wordFormat == LyricTagWordFormat.enhanced) {
        buffer.write(_lrcTime(line.start));
      }
      for (final word in words) {
        buffer.write(
          _lrcTime(
            word.start,
            enhanced: wordFormat == LyricTagWordFormat.enhanced,
          ),
        );
        buffer.write(word.content);
      }
      output.add(buffer.toString());
      _appendSupplementalLines(
        output,
        line,
        timestamp: wordFormat == LyricTagWordFormat.wordByWord
            ? words.first.start
            : line.start,
      );
      continue;
    }
    if (line is UnsyncLyricLine && line.content.trim().isNotEmpty) {
      output.add('${_lrcTime(line.start)}${line.content}');
      _appendSupplementalLines(output, line);
    }
  }
  return output.join('\n');
}

void _appendSupplementalLines(
  List<String> output,
  LyricLine line, {
  Duration? timestamp,
}) {
  final timeTag = _lrcTime(timestamp ?? line.start);
  final translation = line.translation?.trim();
  if (translation != null && translation.isNotEmpty) {
    output.add('$timeTag$translation');
  }
  final romanization = line.romanLyric?.trim();
  if (romanization != null && romanization.isNotEmpty) {
    output.add('$timeTag$romanization');
  }
}

List<String> _extractLrcMetadata(String? rawText) {
  if (rawText == null || rawText.isEmpty) return [];
  final metadataPattern = RegExp(
    r'^\[(ar|ti|al|by|au|re|ve|length|language):[^\]\r\n]*\]$',
    caseSensitive: false,
  );
  final result = <String>[];
  for (final rawLine in rawText.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (metadataPattern.hasMatch(line) && !result.contains(line)) {
      result.add(line);
    }
  }
  return result;
}

String _lrcTime(Duration duration, {bool enhanced = false}) {
  final totalMs = duration.inMilliseconds < 0 ? 0 : duration.inMilliseconds;
  final minutes = totalMs ~/ 60000;
  final seconds = (totalMs % 60000) ~/ 1000;
  final milliseconds = totalMs % 1000;
  final time = '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}.'
      '${milliseconds.toString().padLeft(3, '0')}';
  return enhanced ? '<$time>' : '[$time]';
}
