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
  simpleFallback;

  static NowPlayingBackgroundMode? fromString(String? backgroundMode) {
    if (backgroundMode == null) return null;
    if (backgroundMode == "shaderFallback") {
      return NowPlayingBackgroundMode.meshGradient;
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
