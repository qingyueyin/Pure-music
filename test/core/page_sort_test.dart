import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/page_sort.dart';
import 'package:pure_music/core/utils.dart';

void main() {
  test('background natural sort matches synchronous order', () async {
    final source = ['track 10', 'track 2', 'track 1'];
    final expected = List<String>.from(source);
    sortNaturallyBy(expected, (value) => value);

    final sorted = await sortPageNaturallyInBackground(
      source,
      (value) => value,
      descending: false,
    );

    expect(sorted, expected);
  });

  test('background locale sort preserves locale comparison', () async {
    final source = ['beta', 'alpha', 'gamma'];
    final expected = List<String>.from(source)
      ..sort((a, b) => b.localeCompareTo(a));

    final sorted = await sortPageByLocaleInBackground(
      source,
      (value) => value,
      descending: true,
    );

    expect(sorted, expected);
  });

  test('background integer sort supports descending order', () async {
    final source = [3, 1, 4, 2];
    final sorted = await sortPageByIntegerInBackground(
      source,
      (value) => value,
      descending: true,
    );

    expect(sorted, [4, 3, 2, 1]);
  });

  test('background sort stops before isolate work when superseded', () async {
    var current = true;
    final sorted = await sortPageByIntegerInBackground(
      [3, 1, 4, 2],
      (value) {
        current = false;
        return value;
      },
      descending: true,
      control: PageSortControl(isCurrent: () => current, batchSize: () => 1),
    );

    expect(sorted, isNull);
  });
}
