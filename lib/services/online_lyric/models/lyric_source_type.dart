/// 歌词来源类型枚举
enum LyricSourceType {
  qq('QQ'),
  kugou('酷狗'),
  ne('网易');

  final String displayName;
  const LyricSourceType(this.displayName);

  static LyricSourceType? fromString(String value) {
    for (final v in LyricSourceType.values) {
      if (v.name == value) return v;
    }
    return null;
  }
}
