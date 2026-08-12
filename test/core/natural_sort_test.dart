import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/utils.dart';

void main() {
  test('natural comparison preserves numeric and leading-zero ordering', () {
    final values = ['Track 10', 'Track 02', 'Track 2', 'Track 1'];

    sortNaturallyBy(values, (value) => value);

    expect(values, ['Track 1', 'Track 2', 'Track 02', 'Track 10']);
  });

  test('natural comparison handles integers larger than machine words', () {
    final values = [
      'Track 99999999999999999999999999999999999999',
      'Track 100000000000000000000000000000000000000',
      'Track 2',
    ];

    sortNaturallyBy(values, (value) => value);

    expect(values, [
      'Track 2',
      'Track 99999999999999999999999999999999999999',
      'Track 100000000000000000000000000000000000000',
    ]);
  });

  test('prepared natural sort reuses keys and supports descending order', () {
    final values = ['歌曲 10', '歌曲 2', '歌曲 2'];

    sortNaturallyBy(values, (value) => value, descending: true);

    expect(values, ['歌曲 10', '歌曲 2', '歌曲 2']);
  });
}
