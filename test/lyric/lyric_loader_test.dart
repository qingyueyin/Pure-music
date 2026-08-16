import 'dart:io';

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

  group('selected lyric file loading', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pure_music_lyric_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('loads the selected supported file directly', () async {
      final selected = File(
        '${tempDir.path}${Platform.pathSeparator}other.lrc',
      );
      await selected.writeAsString('[00:01.00]Selected lyric');

      final lyric = await loadLyricFromFile(selected.path);

      expect(lyric, isNotNull);
      expect(lyric!.lines, isNotEmpty);
    });

    test('does not fall back when the selected file is missing', () async {
      final lyric = await loadLyricFromFile(
        '${tempDir.path}${Platform.pathSeparator}missing.lrc',
      );

      expect(lyric, isNull);
    });

    test('rejects unsupported file extensions', () async {
      final selected = File(
        '${tempDir.path}${Platform.pathSeparator}lyric.txt',
      );
      await selected.writeAsString('[00:01.00]Selected lyric');

      final lyric = await loadLyricFromFile(selected.path);

      expect(lyric, isNull);
    });
  });
}
