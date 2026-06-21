import 'package:flutter/foundation.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:xml/xml.dart';

class Ttml extends Lyric {
  Ttml(super.lines, [super.source = LyricFormat.local, super.rawText, super.isDuet]);

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

      final isDuet = lines.any((l) => l.agent == 'v1') && lines.any((l) => l.agent == 'v2');

      lines.sort((a, b) => a.start.compareTo(b.start));

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        final nextStart = i < lines.length - 1 ? lines[i + 1].start : null;

        // 统一使用 nextLine.start - line.start 作为 length，与 LRC 行为一致
        // 这样可以避免 TTML end 时间不准确导致的行间间隔或重叠问题
        if (nextStart != null) {
          final lineLen = nextStart - line.start;
          line.length = lineLen.isNegative ? Duration.zero : lineLen;
        } else if (line.length <= Duration.zero) {
          // 最后一行且没有 end 时间，默认 5 秒
          line.length = const Duration(seconds: 5);
        }

        _fillWordDurations(line.words, line.start, line.length, nextStart);

        if (line.bgWords.isNotEmpty) {
          _fillWordDurations(line.bgWords, line.bgStart ?? line.start, line.length, nextStart);
        }
      }

      return Ttml(lines, LyricFormat.local, ttml, isDuet);
    } catch (e, stack) {
      if (kDebugMode) {
        print('TTML parse failed: $e\n$stack');
      }
      return null;
    }
  }

  static String _preformatTtml(String ttml) {
    return ttml.replaceAll('&nbsp;', '&#160;');
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
    var decoded = _decodeEntities(text);
    // 先把普通空白（含 XML 格式化产生的换行）序列替换为一个空格
    decoded = decoded.replaceAll(RegExp(r'[ \t\r\n]+'), ' ');
    // 把 <br/> 占位符换回真正的换行
    decoded = decoded.replaceAll('\u0001', '\n');
    return decoded.trim();
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

    final children = p.children.toList();
    if (children.isEmpty ||
        children.every((c) => c is XmlText && _cleanText(c.value).isEmpty)) {
      final text = _cleanText(p.innerText);
      final duration = end != null ? end - begin : Duration.zero;

      // 长时间空白段落保留为间奏/过渡行
      if (text.isEmpty || _isMusicSymbolOnly(text)) {
        if (duration >= const Duration(seconds: 3)) {
          final line = TtmlLine(
            begin,
            duration,
            const [],
            null,
          );
          if (resolvedAgent.isNotEmpty) line.agent = resolvedAgent;
          return line;
        }
        return null;
      }

      final parts = separator != null ? text.split(separator) : [text];
      final wordContent = parts.first.trim();
      final translation = parts.length > 1 ? parts.sublist(1).join(separator ?? '').trim() : null;

      final line = TtmlLine(
        begin,
        duration,
        [SyncLyricWord(Duration.zero, Duration.zero, wordContent)],
        translation?.isNotEmpty == true ? translation : null,
      );
      if (resolvedAgent.isNotEmpty) line.agent = resolvedAgent;
      return line;
    }

    final mainNodes = <XmlNode>[];
    final translationSpans = <XmlElement>[];
    XmlElement? bgSpan;
    final romanSpans = <XmlElement>[];

    for (final child in children) {
      if (child is XmlElement) {
        if (_hasRole(child, 'x-translation') && !_hasRole(child, 'x-bg')) {
          translationSpans.add(child);
        } else if (_hasRole(child, 'x-bg')) {
          bgSpan = child;
        } else if (_hasRole(child, 'x-roman')) {
          romanSpans.add(child);
        } else {
          mainNodes.add(child);
        }
      } else if (child is XmlText) {
        // 保留 span 之间的空格、标点等文本节点
        mainNodes.add(child);
      }
    }

    final words = <SyncLyricWord>[];
    final text = _collectMainText(mainNodes, words, end, parentBegin: begin);

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

    final duration = end != null ? end - begin : Duration.zero;
    if (text.isEmpty && bgSpan == null && translation == null && pronunciation == null) {
      // 非空子元素但最终无歌词内容（如仅时间标签的段落），保留为间奏行
      if (duration >= const Duration(seconds: 3)) {
        final line = TtmlLine(
          begin,
          duration,
          const [],
          null,
        );
        if (resolvedAgent.isNotEmpty) line.agent = resolvedAgent;
        return line;
      }
      return null;
    }

    final line = TtmlLine(
      begin,
      duration,
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
    List<XmlNode> nodes,
    List<SyncLyricWord> words,
    Duration? fallbackEnd, {
    Duration parentBegin = Duration.zero,
  }) {
    final buffer = StringBuffer();
    for (int i = 0; i < nodes.length; i++) {
      final separator = _wordSeparatorAfter(nodes, i);
      _collectMainTextFromNode(
        nodes[i],
        words,
        buffer,
        fallbackEnd,
        parentBegin,
        separator,
      );
    }
    return _cleanText(buffer.toString());
  }

  /// 判断当前节点后是否需要加一个词间隔空格。
  /// 仅当相邻的下一个节点是空白文本节点，且该空白节点之后还有非空内容时才返回空格。
  static String _wordSeparatorAfter(List<XmlNode> nodes, int index) {
    if (index + 1 >= nodes.length) return '';
    final next = nodes[index + 1];
    if (next is! XmlText) return '';
    if (!RegExp(r'^[ \t\r\n]+$').hasMatch(next.value)) return '';

    for (int i = index + 2; i < nodes.length; i++) {
      final node = nodes[i];
      if (node is XmlElement) {
        if (node.name.local == 'br') return '';
        return ' ';
      }
      if (node is XmlText && !RegExp(r'^[ \t\r\n]*$').hasMatch(node.value)) {
        return ' ';
      }
    }
    return '';
  }

  static void _collectMainTextFromNode(
    XmlNode node,
    List<SyncLyricWord> words,
    StringBuffer buffer,
    Duration? fallbackEnd,
    Duration parentBegin,
    String trailingSpace,
  ) {
    if (node is XmlText) {
      buffer.write(_decodeEntities(node.value));
      return;
    }

    if (node is! XmlElement) return;
    final element = node;

    // <br/> 用占位符标记，最后 _cleanText 会换回真正的换行
    if (element.name.local == 'br') {
      if (words.isNotEmpty) {
        final last = words.last;
        words[words.length - 1] = SyncLyricWord(
          last.start,
          last.length,
          '${last.content}\n',
        );
      }
      buffer.write('\u0001');
      return;
    }

    // 先检查当前元素自己是否有 begin 属性（例如顶层 <span>）
    final rawBegin = _attr(element, 'begin');
    final parsedBegin = _parseTime(rawBegin);
    if (parsedBegin != null) {
      final actualBegin = _isOffsetTime(rawBegin)
          ? parentBegin + parsedBegin
          : parsedBegin;

      final inner = StringBuffer();
      _collectRawText(element, inner);
      final text = _cleanText(inner.toString());
      final wordText = text + trailingSpace;
      if (wordText.isNotEmpty) {
        final parsedEnd = _parseTime(_attr(element, 'end'));
        final actualEnd = parsedEnd != null && _isOffsetTime(_attr(element, 'end'))
            ? parentBegin + parsedEnd
            : parsedEnd;
        words.add(SyncLyricWord(
          actualBegin,
          (actualEnd ?? fallbackEnd ?? actualBegin + _estimateDuration(text)) - actualBegin,
          wordText,
        ));
      }
      buffer.write(wordText);
      return; // 已处理，不再遍历子元素
    }

    // 如果当前元素没有 begin，则遍历其子元素
    final children = element.children.toList();
    for (int i = 0; i < children.length; i++) {
      final childTrailing = _wordSeparatorAfter(children, i);
      _collectMainTextFromNode(
        children[i],
        words,
        buffer,
        fallbackEnd,
        parentBegin,
        childTrailing,
      );
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
    final bgBegin = _parseTime(_attr(bgSpan, 'begin')) ?? Duration.zero;
    final bgText = _collectMainText(
      [bgSpan],
      bgWords,
      fallbackEnd,
      parentBegin: bgBegin,
    );

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

    // 时:分:秒 或 分:秒（绝对时间）
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

    // 毫秒：500ms
    final msMatch = RegExp(r'^(\d+(?:\.\d+)?)ms$').firstMatch(time);
    if (msMatch != null) {
      final ms = double.tryParse(msMatch.group(1)!) ?? 0;
      return Duration(milliseconds: ms.round());
    }

    // 秒：1.5s
    final sMatch = RegExp(r'^(\d+(?:\.\d+)?)s$').firstMatch(time);
    if (sMatch != null) {
      final seconds = double.tryParse(sMatch.group(1)!) ?? 0;
      return Duration(milliseconds: (seconds * 1000).round());
    }

    // 帧：f1200（默认 30fps）
    final fMatch = RegExp(r'^(\d+)f$').firstMatch(time);
    if (fMatch != null) {
      final frames = int.tryParse(fMatch.group(1)!) ?? 0;
      const fps = 30;
      return Duration(milliseconds: (frames / fps * 1000).round());
    }

    // 纯数字秒
    final seconds = double.tryParse(time);
    if (seconds != null) {
      return Duration(milliseconds: (seconds * 1000).round());
    }

    return null;
  }

  /// 判断 TTML 时间是否为 offset 形式（需要叠加父元素开始时间）
  static bool _isOffsetTime(String time) {
    return RegExp(r'^\d+(?:\.\d+)?[msf]$').hasMatch(time.trim());
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