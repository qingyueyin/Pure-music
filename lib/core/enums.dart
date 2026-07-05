enum SortOrder {
  ascending,
  decending;

  static SortOrder? fromString(String sortOrder) {
    for (var value in SortOrder.values) {
      if (value.name == sortOrder) return value;
    }
    return null;
  }
}

enum ContentView {
  list,
  table;

  static ContentView? fromString(String contentView) {
    for (var value in ContentView.values) {
      if (value.name == contentView) return value;
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
      if (value.name == nowPlayingViewMode) return value;
    }
    return null;
  }
}

enum NowPlayingBackgroundMode {
  meshGradient,
  blurCover;

  static NowPlayingBackgroundMode? fromString(String? backgroundMode) {
    if (backgroundMode == null) return null;
    if (backgroundMode == 'pureColor' || backgroundMode == 'simpleFallback') {
      return NowPlayingBackgroundMode.blurCover;
    }
    if (backgroundMode == 'fluidBlob' || backgroundMode == 'hybrid') {
      return NowPlayingBackgroundMode.blurCover;
    }
    for (var value in NowPlayingBackgroundMode.values) {
      if (value.name == backgroundMode) return value;
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
      if (value.name == lyricTextAlign) return value;
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
      if (value.name == playMode) return value;
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
      if (value.name == name) return value;
    }
    return null;
  }
}

enum NowPlayingMode {
  portrait,
  immersive;

  static NowPlayingMode? fromString(String name) {
    for (var value in NowPlayingMode.values) {
      if (value.name == name) return value;
    }
    return null;
  }

  static Set<NowPlayingMode> fromList(List<dynamic>? list) {
    if (list == null) return {};
    return list.map((e) => NowPlayingMode.fromString(e.toString())).whereType<NowPlayingMode>().toSet();
  }

  static List<String> toList(Set<NowPlayingMode> set) {
    return set.map((e) => e.name).toList();
  }
}
