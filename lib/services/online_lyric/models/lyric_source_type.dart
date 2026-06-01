/// 歌词来源类型枚举
enum LyricSourceType {
  qq('QQ音乐'),
  kugou('酷狗'),
  ne('网易云');

  final String displayName;
  const LyricSourceType(this.displayName);

  static LyricSourceType? fromString(String value) {
    for (final v in LyricSourceType.values) {
      if (v.name == value) return v;
    }
    return null;
  }
}

/// 歌词源优先级配置
/// 默认顺序：QQ > 网易云 > 酷狗
class LyricSourcePriority {
  static const defaultOrder = [
    LyricSourceType.qq,
    LyricSourceType.ne,
    LyricSourceType.kugou,
  ];

  static List<LyricSourceType> load() => defaultOrder;

  static void save(List<LyricSourceType> order) {
    // TODO: persist to settings when lyricSourcePriority is added
  }
}
