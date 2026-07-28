bool _matchesStoredEnumName(String stored, String name) {
  final normalized = stored.trim().toLowerCase();
  final separator = normalized.lastIndexOf('.');
  final storedName =
      separator < 0 ? normalized : normalized.substring(separator + 1);
  return storedName == name.toLowerCase();
}

enum SortOrder {
  ascending,
  decending;

  static SortOrder? fromString(String sortOrder) {
    for (var value in SortOrder.values) {
      if (_matchesStoredEnumName(sortOrder, value.name)) return value;
    }
    return null;
  }
}

enum ContentView {
  list,
  table;

  static ContentView? fromString(String contentView) {
    for (var value in ContentView.values) {
      if (_matchesStoredEnumName(contentView, value.name)) return value;
    }
    return null;
  }
}

enum NowPlayingViewMode {
  onlyMain,
  withLyric,
  withPlaylist;

  static NowPlayingViewMode? fromString(String nowPlayingViewMode) {
    for (var value in NowPlayingViewMode.values) {
      if (_matchesStoredEnumName(nowPlayingViewMode, value.name)) return value;
    }
    return null;
  }
}

enum NowPlayingBackgroundMode {
  meshGradient,
  blurCover,
  coverBlurTest;

  static NowPlayingBackgroundMode? fromString(String? backgroundMode) {
    if (backgroundMode == null) return null;
    if (_matchesStoredEnumName(backgroundMode, 'pureColor') ||
        _matchesStoredEnumName(backgroundMode, 'simpleFallback')) {
      return NowPlayingBackgroundMode.blurCover;
    }
    if (_matchesStoredEnumName(backgroundMode, 'fluidBlob') ||
        _matchesStoredEnumName(backgroundMode, 'hybrid')) {
      return NowPlayingBackgroundMode.blurCover;
    }
    for (var value in NowPlayingBackgroundMode.values) {
      if (_matchesStoredEnumName(backgroundMode, value.name)) return value;
    }
    return null;
  }
}

enum LyricTextAlign {
  left,
  center,
  right;

  static LyricTextAlign? fromString(String lyricTextAlign) {
    for (var value in LyricTextAlign.values) {
      if (_matchesStoredEnumName(lyricTextAlign, value.name)) return value;
    }
    return null;
  }
}

enum PlayMode {
  /// 顺序播放到播放列表结尾
  forward,

  /// 循环整个播放列表
  loop,

  /// 循环播放单曲
  singleLoop;

  static PlayMode? fromString(String playMode) {
    for (var value in PlayMode.values) {
      if (_matchesStoredEnumName(playMode, value.name)) return value;
    }
    return null;
  }
}

enum TopBarLyricAnimation {
  slideUp,
  slideDown,
  fade,
  absorb,
  flipX,
  flipY;

  static TopBarLyricAnimation? fromString(String name) {
    for (var value in TopBarLyricAnimation.values) {
      if (_matchesStoredEnumName(name, value.name)) return value;
    }
    return null;
  }
}

enum LyricLineTrack {
  original,
  romanization,
  translation;

  static LyricLineTrack? fromString(String name) {
    for (var value in LyricLineTrack.values) {
      if (_matchesStoredEnumName(name, value.name)) return value;
    }
    return null;
  }

  static List<LyricLineTrack> listFromStringList(List<String> names) {
    return names
        .map((e) => LyricLineTrack.fromString(e) ?? LyricLineTrack.original)
        .toList();
  }

  static List<String> stringListFromList(List<LyricLineTrack> tracks) {
    return tracks.map((e) => e.name).toList();
  }
}

const defaultLyricLineOrder = [
  LyricLineTrack.original,
  LyricLineTrack.romanization,
  LyricLineTrack.translation
];

List<LyricLineTrack> normalizedLyricLineOrder(List<LyricLineTrack> order) {
  final result = <LyricLineTrack>[];
  final seen = <LyricLineTrack>{};
  for (final t in [...order, ...defaultLyricLineOrder]) {
    if (seen.add(t)) result.add(t);
  }
  return result;
}

enum LyricLiftStyle {
  vertical,
  cosine;

  static LyricLiftStyle? fromString(String name) {
    for (var value in LyricLiftStyle.values) {
      if (_matchesStoredEnumName(name, value.name)) return value;
    }
    return null;
  }
}

enum LyricStaggerStyle {
  classic,
  salt;

  static LyricStaggerStyle? fromString(String name) {
    for (var value in LyricStaggerStyle.values) {
      if (_matchesStoredEnumName(name, value.name)) return value;
    }
    return null;
  }
}

enum RubyPosition {
  above,
  below,
  belowTranslation;

  static RubyPosition? fromString(String name) {
    for (var value in RubyPosition.values) {
      if (_matchesStoredEnumName(name, value.name)) return value;
    }
    return null;
  }

  String get displayName => switch (this) {
        RubyPosition.above => '在原文上',
        RubyPosition.below => '在原文下',
        RubyPosition.belowTranslation => '在翻译下',
      };

  List<LyricLineTrack> toLineOrder() => switch (this) {
        RubyPosition.above => [
            LyricLineTrack.romanization,
            LyricLineTrack.original,
            LyricLineTrack.translation,
          ],
        RubyPosition.below => [
            LyricLineTrack.original,
            LyricLineTrack.romanization,
            LyricLineTrack.translation,
          ],
        RubyPosition.belowTranslation => [
            LyricLineTrack.original,
            LyricLineTrack.translation,
            LyricLineTrack.romanization,
          ],
      };
}

enum NowPlayingMode {
  portrait,
  landscape,
  immersive;

  static NowPlayingMode? fromString(String name) {
    for (var value in NowPlayingMode.values) {
      if (_matchesStoredEnumName(name, value.name)) return value;
    }
    return null;
  }

  static NowPlayingMode? fromStoredValue(Object? value) {
    if (value is int && value >= 0 && value < NowPlayingMode.values.length) {
      return NowPlayingMode.values[value];
    }
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    final numeric = double.tryParse(text);
    if (numeric != null && numeric.isFinite) {
      final index = numeric.toInt();
      if (numeric == index &&
          index >= 0 &&
          index < NowPlayingMode.values.length) {
        return NowPlayingMode.values[index];
      }
    }
    return NowPlayingMode.fromString(text);
  }

  static Set<NowPlayingMode> fromList(List<dynamic>? list) {
    if (list == null) return {};
    return list
        .map(NowPlayingMode.fromStoredValue)
        .whereType<NowPlayingMode>()
        .toSet();
  }

  static List<String> toList(Set<NowPlayingMode> set) {
    return set.map((e) => e.name).toList();
  }
}
