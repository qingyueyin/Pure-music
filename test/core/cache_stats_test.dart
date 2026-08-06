import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/cache.dart';

void main() {
  test('empty cover cache statistics can be logged', () {
    expect(CoverImageCache.instance.stats.hitRate, isNull);
    expect(CoverImageCache.instance.logStats, returnsNormally);
  });
}
