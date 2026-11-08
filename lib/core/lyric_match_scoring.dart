const double lyricMatchMinimumScore = 75.0;

final class LyricMatchScore {
  const LyricMatchScore({
    required this.score,
    required this.titleSimilarity,
    required this.artistSimilarity,
    required this.albumSimilarity,
    required this.durationMultiplier,
    required this.titleMatched,
    required this.identityMatched,
  });

  final double score;
  final double titleSimilarity;
  final double artistSimilarity;
  final double albumSimilarity;
  final double durationMultiplier;
  final bool titleMatched;
  final bool identityMatched;

  bool get isReliable =>
      titleMatched && identityMatched && score >= lyricMatchMinimumScore;
}

LyricMatchScore scoreLyricMatch({
  required String title,
  required String artist,
  String? album,
  required String candidateTitle,
  required String candidateArtist,
  String? candidateAlbum,
  int? audioDurationSeconds,
  int? candidateDurationSeconds,
}) {
  final titleSimilarity = _similarity(title, candidateTitle);
  final artistSimilarity = _similarity(artist, candidateArtist);
  final albumSimilarity = _similarity(album ?? '', candidateAlbum ?? '');
  final durationMultiplier = _durationMultiplier(
    audioDurationSeconds,
    candidateDurationSeconds,
  );
  final titleMatched = titleSimilarity >= 0.65;
  final identityMatched = artistSimilarity >= 0.5 || albumSimilarity >= 0.65;
  var weightedScore = titleSimilarity * 45.0;
  var availableWeight = 45.0;
  if (normalizeLyricMatchText(artist).isNotEmpty &&
      normalizeLyricMatchText(candidateArtist).isNotEmpty) {
    weightedScore += artistSimilarity * 35.0;
    availableWeight += 35.0;
  }
  if (normalizeLyricMatchText(album ?? '').isNotEmpty &&
      normalizeLyricMatchText(candidateAlbum ?? '').isNotEmpty) {
    weightedScore += albumSimilarity * 20.0;
    availableWeight += 20.0;
  }
  final baseScore = weightedScore / availableWeight * 100.0;
  final score = (baseScore * durationMultiplier).clamp(0.0, 100.0);

  return LyricMatchScore(
    score: score,
    titleSimilarity: titleSimilarity,
    artistSimilarity: artistSimilarity,
    albumSimilarity: albumSimilarity,
    durationMultiplier: durationMultiplier,
    titleMatched: titleMatched,
    identityMatched: identityMatched,
  );
}

double _durationMultiplier(int? expected, int? actual) {
  if (expected == null || actual == null || expected <= 0 || actual <= 0) {
    return 1.0;
  }
  final difference = (expected - actual).abs();
  if (difference <= 1) return 1.0;
  if (difference <= 3) return 0.95;
  if (difference <= 5) return 0.75;
  if (difference <= 10) return 0.35;
  return 0.1;
}

double _similarity(String left, String right) {
  final a = normalizeLyricMatchText(left);
  final b = normalizeLyricMatchText(right);
  if (a.isEmpty || b.isEmpty) return 0.0;
  if (a == b) return 1.0;

  final aRunes = a.runes.toList(growable: false);
  final bRunes = b.runes.toList(growable: false);
  if (aRunes.length < 2 || bRunes.length < 2) return 0.0;

  final remaining = <String, int>{};
  for (var i = 0; i < aRunes.length - 1; i++) {
    final gram = String.fromCharCodes(aRunes, i, i + 2);
    remaining[gram] = (remaining[gram] ?? 0) + 1;
  }
  var overlap = 0;
  for (var i = 0; i < bRunes.length - 1; i++) {
    final gram = String.fromCharCodes(bRunes, i, i + 2);
    final count = remaining[gram] ?? 0;
    if (count == 0) continue;
    overlap += 1;
    remaining[gram] = count - 1;
  }
  return 2 * overlap / (aRunes.length + bRunes.length - 2);
}

String normalizeLyricMatchText(String value) {
  var normalized = value
      .toLowerCase()
      .replaceAll(RegExp(r'\([^)]*\)|\[[^]]*\]|（[^）]*）|【[^】]*】'), ' ')
      .replaceAll(
        RegExp(
          r'\b(?:feat(?:uring)?|ft|with)\.?\s+[^,;|]+',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(
        RegExp(
          r'\b(?:acoustic|live|remix|explicit|deluxe|edit|version|mix|radio|single|demo|bonus|instrumental|karaoke|cover|remaster(?:ed|ing)?)\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '')
      .trim();

  // Traditional/simplified pairs that commonly occur in online metadata.
  const replacements = <String, String>{
    '臺': '台',
    '體': '体',
    '樂': '乐',
    '國': '国',
    '學': '学',
    '會': '会',
    '現': '现',
    '場': '场',
    '聲': '声',
    '與': '与',
    '後': '后',
    '來': '来',
    '為': '为',
    '風': '风',
    '夢': '梦',
    '愛': '爱',
  };
  for (final entry in replacements.entries) {
    normalized = normalized.replaceAll(entry.key, entry.value);
  }
  return normalized;
}

double lyricMatchDurationMultiplier(int? expected, int? actual) =>
    _durationMultiplier(expected, actual);

double lyricMatchSimilarity(String left, String right) =>
    _similarity(left, right);
