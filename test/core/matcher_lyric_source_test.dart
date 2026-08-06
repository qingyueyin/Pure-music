import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/matcher.dart';
import 'package:pure_music/lyric/lyric_source.dart';

void main() {
  test('keeps the AMLL TTML file when converting a search result', () {
    final result = SongSearchResult(
      ResultSource.amll,
      'Manchild',
      'Sabrina Carpenter',
      'Manchild',
      100,
      amllTtmlFile: '1749352311169-142093212-5ad2d962.ttml',
    );

    final source = result.toLyricSource();

    expect(source.source, LyricSourceType.amll);
    expect(
      source.amllTtmlFile,
      '1749352311169-142093212-5ad2d962.ttml',
    );
  });
}
