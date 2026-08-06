import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/library/audio_library.dart';

void main() {
  tearDown(() {
    AppPreference.instance.userFolders = [];
    AudioLibrary.instance.folders = [];
  });

  test('folder manager aggregates scanned children under selected roots', () {
    final first = _audio(r'D:\Music\Album A\one.flac');
    final second = _audio(r'D:\Music\Album B\two.flac');
    AppPreference.instance.userFolders = [r'D:\Music'];
    AudioLibrary.instance.folders = [
      AudioFolder([first], r'D:\Music\Album A', 1, 1),
      AudioFolder([second], r'D:\Music\Album B', 1, 1),
    ];

    final roots = AudioLibrary.aggregatedRootFolders();

    expect(roots, hasLength(1));
    expect(roots.single.path, r'D:\Music');
    expect(roots.single.audios, [first, second]);
  });

  test('selected roots stay manageable when they contain no audio', () {
    AppPreference.instance.userFolders = [r'D:\Empty Music'];
    AudioLibrary.instance.folders = [];

    final roots = AudioLibrary.aggregatedRootFolders();

    expect(roots, hasLength(1));
    expect(roots.single.path, r'D:\Empty Music');
    expect(roots.single.audios, isEmpty);
  });
}

Audio _audio(String path) => Audio(
  'Title',
  'Artist',
  'Album',
  null,
  1,
  60,
  320,
  44100,
  path,
  1,
  1,
  'test',
);
