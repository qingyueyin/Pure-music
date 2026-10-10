/// 把标签里的艺术家字符串拆成多个名字。
/// 分隔符按字面匹配；白名单名字即使含分隔符也不拆。
class ArtistNameSplitter {
  ArtistNameSplitter._();

  /// 两边带空格才拆，默认不启用。
  static const featSeparators = [' feat. ', ' ft. ', ' featuring '];

  static final RegExp _neverMatches = RegExp('(?!x)x');

  static List<String> split(
    String raw, {
    required List<String> separators,
    List<String> noSplitNames = const [],
    Map<String, String> aliases = const {},
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const [];

    final aliasOf = normalizedArtistAliases(aliases);

    List<String> finish(List<String> parts) {
      final seen = <String>{};
      final result = <String>[];
      for (final part in parts) {
        final named = aliasOf[part] ?? part;
        if (seen.add(named)) result.add(named);
      }
      return result;
    }

    if (separators.isEmpty) return finish([trimmed]);

    final noSplitLower = <String>{};
    for (final name in noSplitNames) {
      final item = name.trim();
      if (item.isNotEmpty) noSplitLower.add(item.toLowerCase());
    }
    if (noSplitLower.contains(trimmed.toLowerCase())) {
      return finish([trimmed]);
    }

    final separatorRegex = anchoredAlternationRegex(separators);
    final protectedNames = <String>[];
    for (final name in noSplitNames) {
      final item = name.trim();
      if (item.isEmpty) continue;
      final lower = item.toLowerCase();
      final containsSeparator = separators.any(
        (separator) => lower.contains(separator.toLowerCase()),
      );
      if (containsSeparator) protectedNames.add(item);
    }
    final noSplitRegex = anchoredAlternationRegex(protectedNames);

    return finish(_scan(trimmed, separatorRegex, noSplitRegex));
  }

  /// 按长度从长到短、字面转义后组成正则；空列表匹配不到任何内容。
  static RegExp anchoredAlternationRegex(List<String> values) {
    final parts = <String>[];
    final seen = <String>{};
    final sorted = [...values]..sort((a, b) => b.length.compareTo(a.length));
    for (final value in sorted) {
      if (value.isEmpty || !seen.add(value)) continue;
      parts.add(RegExp.escape(value));
    }
    if (parts.isEmpty) return _neverMatches;
    return RegExp(parts.join('|'), caseSensitive: false);
  }

  static List<String> _scan(
    String raw,
    RegExp separatorRegex,
    RegExp noSplitRegex,
  ) {
    final artists = <String>[];
    final current = StringBuffer();
    var index = 0;
    while (index < raw.length) {
      final noSplitMatch = noSplitRegex.matchAsPrefix(raw, index);
      if (noSplitMatch != null) {
        current.write(noSplitMatch.group(0));
        index = noSplitMatch.end;
        continue;
      }
      final separatorMatch = separatorRegex.matchAsPrefix(raw, index);
      if (separatorMatch != null) {
        _flush(current, artists);
        index = separatorMatch.end;
        continue;
      }
      current.write(raw[index]);
      index++;
    }
    _flush(current, artists);
    return artists;
  }

  static void _flush(StringBuffer current, List<String> artists) {
    final value = current.toString().trim();
    current.clear();
    if (value.isNotEmpty) artists.add(value);
  }
}

Map<String, String> normalizedArtistAliases(Object? value) {
  if (value is! Map) return {};
  final result = <String, String>{};
  for (final entry in value.entries) {
    final key = entry.key.toString().trim();
    final alias = entry.value.toString().trim();
    if (key.isEmpty || alias.isEmpty || key == alias) continue;
    result.putIfAbsent(key, () => alias);
  }
  return result;
}
