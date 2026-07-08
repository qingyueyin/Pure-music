import 'package:pure_music/lyric/lyric.dart';

bool lyricHasTranslation(Lyric? lyric) {
  if (lyric == null) return false;
  return lyric.lines.any(
    (line) => line.translation?.trim().isNotEmpty == true,
  );
}

bool canSelectLyricSource({
  required bool? isCurrentLocal,
  required bool targetLocal,
}) =>
    isCurrentLocal == null || isCurrentLocal != targetLocal;
