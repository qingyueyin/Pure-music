import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/setting_action_state.dart';

void main() {
  test('normalizes legacy boolean and bounded integer values', () {
    expect(normalizedBoolSetting(' YES ', defaultValue: false), isTrue);
    expect(normalizedBoolSetting('off', defaultValue: true), isFalse);
    expect(normalizedBoolSetting('not-a-bool', defaultValue: true), isTrue);
    expect(
      normalizedBoundedIntSetting('12.0', defaultValue: 3, min: 0, max: 10),
      10,
    );
    expect(
      normalizedBoundedIntSetting('12.5', defaultValue: 3, min: 0, max: 10),
      3,
    );
  });

  test('rejects malformed colors and normalizes supported color syntax', () {
    expect(normalizedOptionalColorSetting('#12abEF'), 0xFF12ABEF);
    expect(normalizedOptionalColorSetting('Color(0x8012abEF)'), 0x8012ABEF);
    expect(normalizedOptionalColorSetting('0x100000000'), isNull);
    expect(normalizedOptionalColorSetting('not-a-color'), isNull);
  });

  test('deduplicates setting lists while preserving the first value', () {
    expect(uniqueTextListItems(['  /  ', '/', '', ' | ']), ['/', '|']);
    expect(normalizedArtistSeparators(null), defaultArtistSeparators);
    expect(normalizedArtistSeparators(['/', '/', ' | ']), ['/', '|']);
  });

  test('invalid enum indexes fall back instead of escaping the range', () {
    expect(normalizedEnumIndex('99', length: 3, defaultIndex: 1), 1);
    expect(normalizedEnumIndex(-1, length: 3), 0);
    expect(normalizedEnumIndex('1.0', length: 3), 1);
    expect(normalizedEnumIndex('1.5', length: 3), 0);
  });
}
