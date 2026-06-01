import 'package:pure_music/lyric/lyric.dart';
import 'package:xml/xml.dart';

class Ttml extends Lyric {
  Ttml(super.lines, [super.source = LyricFormat.local, super.rawText]);

  static Ttml? fromTtmlText(String ttml, {String? separator}) {
    try {
      final document = XmlDocument.parse(_preformatTtml(ttml));
      final root = document.rootElement;

      final agentAlignment = _parseAgentAlignment(root);
      final translations = _parseTimedTextMap(root, 'translation');
      final transliterations = _parseTransliterations(root);

      final body = root.findAllElements('body').firstOrNull;
      if (body == null) return null;

      final lines = <TtmlLine>[];
      for (final div in body.findAllElements('div')) {
        for (final p in div.findAllElements('p')) {
          final line = _parseParagraph(
            p,
            separator,
            agentAlignment: agentAlignment,
            translations: translations,
            transliterations: transliterations,
          );
          if (line != null) lines.add(line);
        }
      }

      if (lines.isEmpty) return null;

      lines.sort((a, b) => a.start.compareTo(b.start));

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        final nextStart = i < lines.length - 1 ? lines[i + 1].start : null;
        final lineLen = nextStart == null
            ? const Duration(seconds: 5)
            : (nextStart - line.start);
        line.length = lineLen.isNegative ? Duration.zero : lineLen;

        _fillWordDurations(line.words, line.start, line.length, nextStart);

        if (line.bgWords.isNotEmpty) {
          _fillWordDurations(line.bgWords, line.bgStart ?? line.start, line.length, nextStart);
        }
      }

      return Ttml(lines);
    } catch (e) {
      return null;
    }
  }

  static String _preformatTtml(String ttml) {
    return ttml
        .replaceAll('&nbsp;', '&#160;')
        .replaceAll('</span><span', '</span> <span')
        .replaceAll(',</span><span', ',</span> <span');
  }

  static String _decodeEntities(String text) {
    return text
        .replaceAll('&apos;', "'")
        .replaceAll('&quot;', '"')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'");
  }

  static String _cleanText(String text) {
    return _decodeEntities(text)
        .replaceAll(RegExp(r'[ \t\r\n]+'), ' ')
        .trim();
  }

  static bool _isMusicSymbolOnly(String text) {
    final content = text.trim();
    if (content.isEmpty) return true;
    return content.runes.every((c) {
      final char = String.fromCharCode(c);
      return char == ' ' || char == '\u00A0' ||
          '♪♫♬♩♭♯♮☆★·.。…'.contains(char);
    });
  }

  static String _attr(XmlElement element, String name) {
    final direct = element.getAttribute(name);
    if (direct != null) return direct;
    final localName = name.contains(':') ? name.split(':').last : name;
    for (final attr in element.attributes) {
      if (attr.name.local == localName) return attr.value;
    }
    return '';
  }

  static bool _hasRole(XmlElement element, String role) {
    final r = _attr(element, 'role');
    if (r.isEmpty) return false;
    if (r == role) return true;
    return r.split(RegExp(r'\s+')).any((s) => s == role);
  }

  static Map<String, String> _parseAgentAlignment(XmlElement root) {
    final agents = root.descendantElements
        .where((e) => e.name.local == 'agent')
        .map((e) => _attr(e, 'id').ifBlank(() => _attr(e, 'xml:id')))
        .where((id) => id.isNotEmpty)
        .toList();
    final result = <String, String>{};
    for (int i = 0; i < agents.length; i++) {
      result[agents[i]] = i == 1 ? 'v2' : 'v1';
    }
    return result;
  }

  static Map<String, String> _parseTimedTextMap(XmlElement root, String tag) {
    final result = <String, String>{};
    for (final container in root.descendantElements.where((e) => e.name.local == tag)) {
      for (final textElem in container.childElements.where((e) => e.name.local == 'text')) {
        final key = _attr(textElem, 'for');
        if (key.isEmpty) continue;
        final value = _cleanText(textElem.innerText);
        if (value.isNotEmpty) result[key] = value;
      }
    }
    return result;
  }

  static Map<String, _TtmlPronunciation> _parseTransliterations(XmlElement root) {
    final result = <String, _TtmlPronunciation>{};
    for (final container in root.descendantElements
        .where((e) => e.name.local == 'transliteration')) {
      for (final textElem in container.childElements.where((e) => e.name.local == 'text')) {
        final key = _attr(textElem, 'for');
        if (key.isEmpty) continue;
        final words = <SyncLyricWord>[];
        for (final span in textElem.childElements.where((e) => e.name.local == 'span')) {
          final value = _removeBgParentheses(
            _decodeEntities(span.innerText).replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim(),
          );
          if (value.isEmpty) continue;
          final start = _parseTime(_attr(span, 'begin'));
          final end = _parseTime(_attr(span, 'end'));
          if (start != null) {
            words.add(SyncLyricWord(
              start,
              end != null ? end - start : Duration.zero,
              value,
            ));
          }
        }
        final plainText = _removeBgParentheses(
          _decodeEntities(textElem.innerText).replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim(),
        );
        if (plainText.isNotEmpty || words.isNotEmpty) {
          result[key] = _TtmlPronunciation(text: plainText, words: words);
        }
      }
    }
    return result;
  }

  static TtmlLine? _parseParagraph(
    XmlElement p,
    String? separator, {
    required Map<String, String> agentAlignment,
    required Map<String, String> translations,
    required Map<String, _TtmlPronunciation> transliterations,
  }) {
    final begin = _parseTime(_attr(p, 'begin'));
    if (begin == null) return null;
    final end = _parseTime(_attr(p, 'end'));
    final key = _attr(p, 'key').ifBlank(() => _attr(p, 'itunes:key'));
    final agent = _attr(p, 'agent').ifBlank(() => _attr(p, 'ttm:agent'));
    final resolvedAgent = agentAlignment[agent] ?? agent;

    final children = p.childElements.toList();
    if (children.isEmpty) {
      final text = _cleanText(p.innerText);
      if (text.isEmpty || _isMusicSymbolOnly(text)) return null;
      final parts = separator != null ? text.split(separator) : [text];
      final wordContent = parts.first.trim();
      final translation = parts.length > 1 ? parts.sublist(1).join(separator ?? '').trim() : null;

      final line = TtmlLine(
        begin,
        end != null ? end - begin : Duration.zero,
        [SyncLyricWord(Duration.zero, Duration.zero, wordContent)],
        translation?.isNotEmpty == true ? translation : null,
      );
      if (resolvedAgent.isNotEmpty) line.agent = resolvedAgent;
      return line;
    }

    final mainSpans = <XmlElement>[];
    final translationSpans = <XmlElement>[];
    XmlElement? bgSpan;
    final romanSpans = <XmlElement>[];

    for (final child in children) {
      if (_hasRole(child, 'x-translation') && !_hasRole(child, 'x-bg')) {
        translationSpans.add(child);
      } else if (_hasRole(child, 'x-bg')) {
        bgSpan = child;
      } else if (_hasRole(child, 'x-roman')) {
        romanSpans.add(child);
      } else {
        mainSpans.add(child);
      }
    }

    final words = <SyncLyricWord>[];
    final text = _collectMainText(mainSpans, words, end);

    final inlineTranslation = translationSpans
        .map((s) => _cleanText(s.innerText))
        .where((t) => t.isNotEmpty && !_isMusicSymbolOnly(t))
        .join(separator ?? '');
    final String? lineTranslation = translations[key] != null
        ? _cleanText(translations[key]!)
        : null;

    final romanText = romanSpans
        .map((s) => _cleanText(s.innerText))
        .where((t) => t.isNotEmpty && !_isMusicSymbolOnly(t))
        .join(' ');

    final transf = transliterations[key];
    String? pronunciation;
    if (romanText.isNotEmpty) {
      pronunciation = romanText;
    } else if (transf != null && transf.text.replaceAll(RegExp(r'[()（）]'), '').trim().isNotEmpty) {
      pronunciation = _removeBgParentheses(transf.text);
    } else if (transf != null && transf.words.isNotEmpty) {
      pronunciation = transf.words.map((w) => w.content).join();
    }
    if (pronunciation != null && pronunciation.isEmpty) pronunciation = null;

    String? translation =
        inlineTranslation.isNotEmpty ? inlineTranslation : lineTranslation;
    if (translation != null && translation.isEmpty) translation = null;

    if (text.isEmpty && bgSpan == null && translation == null && pronunciation == null) {
      return null;
    }

    final line = TtmlLine(
      begin,
      end != null ? end - begin : Duration.zero,
      words,
      translation,
    );
    line.romanLyric = pronunciation;
    if (resolvedAgent.isNotEmpty) line.agent = resolvedAgent;

    if (bgSpan != null) {
      _parseBackground(bgSpan, line, end, translations[key]);
    }

    return line;
  }

  static String _collectMainText(
    List<XmlElement> elements,
    List<SyncLyricWord> words,
    Duration? fallbackEnd,
  ) {
    final buffer = StringBuffer();
    for (final element in elements) {
      _collectMainTextFromElement(element, words, buffer, fallbackEnd);
    }
    return _cleanText(buffer.toString());
  }

  static void _collectMainTextFromElement(
    XmlElement element,
    List<SyncLyricWord> words,
    StringBuffer buffer,
    Duration? fallbackEnd,
  ) {
    final children = element.children.toList();
    for (final child in children) {
      if (child is XmlText) {
        buffer.write(_decodeEntities(child.value));
      } else if (child is XmlElement) {
        final begin = _parseTime(_attr(child, 'begin'));
        if (begin != null) {
          final inner = StringBuffer();
          _collectRawText(child, inner);
          final nested = _cleanText(inner.toString());
          if (nested.isNotEmpty) {
            words.add(SyncLyricWord(
              begin,
              (_parseTime(_attr(child, 'end')) ?? fallbackEnd ?? begin + _estimateDuration(nested)) - begin,
              nested,
            ));
          }
          buffer.write(nested);
        } else {
          _collectMainTextFromElement(child, words, buffer, fallbackEnd);
        }
      }
    }
  }

  static void _collectRawText(XmlElement element, StringBuffer buffer) {
    for (final child in element.children) {
      if (child is XmlText) {
        buffer.write(_decodeEntities(child.value));
      } else if (child is XmlElement) {
        _collectRawText(child, buffer);
      }
    }
  }

  static void _parseBackground(
    XmlElement bgSpan,
    TtmlLine line,
    Duration? fallbackEnd,
    String? fallbackTranslation,
  ) {
    final bgWords = <SyncLyricWord>[];
    final bgText = _collectMainText([bgSpan], bgWords, fallbackEnd);

    final translationChildren = bgSpan.childElements
        .where((e) => _hasRole(e, 'x-translation'))
        .toList();
    var bgTranslation = translationChildren
        .map((e) => _cleanText(e.innerText))
        .where((t) => t.isNotEmpty)
        .join('');
    if (bgTranslation.isEmpty) bgTranslation = fallbackTranslation ?? '';
    if (bgTranslation.isEmpty) bgTranslation = '';

    final cleanedBgText = _removeBgParentheses(bgText);
    final cleanedBgWords = bgWords
        .map((w) => SyncLyricWord(w.start, w.length, _removeBgParentheses(w.content)))
        .where((w) => w.content.isNotEmpty)
        .toList();

    line.bgStart = _parseTime(_attr(bgSpan, 'begin'));
    line.bgEnd = _parseTime(_attr(bgSpan, 'end')) ?? fallbackEnd;
    line.bgText = cleanedBgText.isNotEmpty ? cleanedBgText : null;
    line.bgWords = cleanedBgWords;
    line.bgTranslation = bgTranslation.isNotEmpty ? bgTranslation : null;
  }

  static void _fillWordDurations(
    List<SyncLyricWord> words,
    Duration lineStart,
    Duration lineLength,
    Duration? nextLineStart,
  ) {
    if (words.isEmpty) return;
    for (int j = 0; j < words.length; j++) {
      final curr = words[j];
      final nextWordStart = j < words.length - 1 ? words[j + 1].start : null;
      final end = nextWordStart ?? (lineStart + lineLength);
      final d = end - curr.start;
      curr.length = d.isNegative
          ? Duration.zero
          : (d < const Duration(milliseconds: 50)
              ? const Duration(milliseconds: 50)
              : d);
    }
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

  static Duration _estimateDuration(String text) {
    final len = text.replaceAll(RegExp(r'\s+'), '').length;
    return Duration(milliseconds: (len * 150).clamp(180, 2200));
  }

  static String _removeBgParentheses(String text) {
    return text.replaceAll(RegExp(r'[()（）]'), '').trim();
  }
}

class TtmlLine extends SyncLyricLine {
  TtmlLine(super.start, super.length, super.words, [super.translation]);
}

class TtmlWord extends SyncLyricWord {
  TtmlWord(super.start, super.length, super.content);
}

class _TtmlPronunciation {
  final String text;
  final List<SyncLyricWord> words;
  const _TtmlPronunciation({required this.text, required this.words});
}

extension on String {
  String ifBlank(String Function() orElse) {
    return isNotEmpty ? this : orElse();
  }
}