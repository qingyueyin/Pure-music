import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lyric_loader.dart';

void main() {
  group('embedded lyric format detection', () {
    test('detects VTT with or without a BOM', () {
      expect(isVttLyricText('WEBVTT\n'), isTrue);
      expect(isVttLyricText('\uFEFFWEBVTT\n'), isTrue);
    });

    test('does not classify other lyric formats as VTT', () {
      expect(isVttLyricText('[00:00.000] LRC'), isFalse);
      expect(isVttLyricText('<tt></tt>'), isFalse);
    });
  });
}
