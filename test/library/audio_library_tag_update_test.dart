import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';

void main() {
  test('tag updates keep existing album detail objects current', () {
    final library = AudioLibrary.instance;
    final audio = Audio(
      'Old title',
      'Artist',
      'Album',
      null,
      1,
      60,
      320,
      44100,
      r'C:\Music\song.mp3',
      1,
      1,
      'test',
    );
    final album = Album(name: 'Album')..works.add(audio);
    library.folders = [
      AudioFolder([audio], r'C:\Music', 1, 1)
    ];
    library.albumCollection = {'Album': album};

    library.updateAudioTags(
      audio,
      title: 'New title',
      artist: 'Artist',
      album: 'Album',
      track: 5,
    );

    expect(library.albumCollection['Album'], same(album));
    expect(album.works.single.title, 'New title');
    expect(album.works.single.track, 5);
  });

  test('library refresh updates objects already used by detail pages', () {
    final library = AudioLibrary.instance;
    final currentAudio = Audio(
      'Old title',
      'Artist',
      'Album',
      null,
      1,
      60,
      320,
      44100,
      r'C:\Music\song.mp3',
      1,
      1,
      'test',
    );
    final currentFolder = AudioFolder([currentAudio], r'C:\Music', 1, 1);
    final currentAlbum = Album(name: 'Album')..works.add(currentAudio);
    library.folders = [currentFolder];
    library.albumCollection = {'Album': currentAlbum};

    final refreshedAudio = Audio(
      'Refreshed title',
      'Artist',
      'Album',
      null,
      5,
      60,
      320,
      44100,
      r'C:\Music\song.mp3',
      2,
      1,
      'test',
    );
    library.replaceFolders([
      AudioFolder([refreshedAudio], r'C:\Music', 2, 2),
    ]);

    expect(library.folders.single, same(currentFolder));
    expect(library.audioByPath(currentAudio.path), same(currentAudio));
    expect(currentAudio.title, 'Refreshed title');
    expect(currentAudio.track, 5);
    expect(library.albumCollection['Album'], same(currentAlbum));
    expect(currentAlbum.works.single, same(currentAudio));
  });
}
