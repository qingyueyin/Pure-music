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
  blurCover;

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
  slideLeft,
  slideRight,
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

enum NowPlayingMode {
  portrait,
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
