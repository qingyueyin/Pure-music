import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/library/audio_library.dart';

void main() {
  setUp(() {
    AudioLibrary.instance.dispose();
    AppPreference.instance.audiosPagePref = PagePreference(
      0,
      SortOrder.ascending,
      ContentView.list,
    );
    AppPreference.instance.artistsPagePref = PagePreference(
      0,
      SortOrder.ascending,
      ContentView.table,
    );
    AppPreference.instance.albumsPagePref = PagePreference(
      0,
      SortOrder.ascending,
      ContentView.table,
    );
  });

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
      disc: 1,
    );
    final album = Album(name: 'Album')..works.add(audio);
    library.folders = [
      AudioFolder([audio], r'C:\Music', 1, 1),
    ];
    library.albumCollection = {'Album': album};

    library.updateAudioTags(
      audio,
      title: 'New title',
      artist: 'Artist',
      album: 'Album',
      track: 5,
      disc: 2,
    );

    expect(library.albumCollection['Album'], same(album));
    expect(album.works.single.title, 'New title');
    expect(album.works.single.track, 5);
    expect(album.works.single.disc, 2);
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
      disc: 1,
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
      disc: 2,
    );
    library.replaceFolders([
      AudioFolder([refreshedAudio], r'C:\Music', 2, 2),
    ]);

    expect(library.folders.single, same(currentFolder));
    expect(library.audioByPath(currentAudio.path), same(currentAudio));
    expect(currentAudio.title, 'Refreshed title');
    expect(currentAudio.track, 5);
    expect(currentAudio.disc, 2);
    expect(library.albumCollection['Album'], same(currentAlbum));
    expect(currentAlbum.works.single, same(currentAudio));
  });

  test('collection build keeps artist and album relationships unchanged', () {
    final library = AudioLibrary.instance;
    final first = Audio(
      'First',
      'Singer / Shared',
      'Album',
      'Album Artist / Shared',
      1,
      60,
      320,
      44100,
      r'C:\Music\first.mp3',
      1,
      1,
      'test',
    );
    final second = Audio(
      'Second',
      'Guest',
      'Album',
      null,
      2,
      60,
      320,
      44100,
      r'C:\Music\second.mp3',
      1,
      1,
      'test',
    );

    library.replaceFolders([
      AudioFolder([first, second], r'C:\Music', 1, 1),
    ]);

    expect(library.audioCollection, [first, second]);
    expect(library.artistCollection['Shared']!.works, [first]);
    expect(library.artistCollection['Singer']!.works, [first]);
    expect(library.artistCollection['Album Artist']!.works, [first]);
    expect(library.artistCollection['Guest']!.works, [second]);
    expect(library.albumCollection['Album']!.artistsMap.keys, [
      'Album Artist',
      'Shared',
    ]);
  });

  test('artist changes rebuild collection relationships', () {
    final library = AudioLibrary.instance;
    final currentAudio = Audio(
      'Title',
      'Old Artist',
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
    library.replaceFolders([
      AudioFolder([currentAudio], r'C:\Music', 1, 1),
    ]);

    library.replaceFolders([
      AudioFolder(
        [
          Audio(
            'Title',
            'New Artist',
            'Album',
            null,
            1,
            60,
            320,
            44100,
            r'C:\Music\song.mp3',
            2,
            1,
            'test',
          ),
        ],
        r'C:\Music',
        2,
        2,
      ),
    ]);

    expect(library.audioByPath(currentAudio.path), same(currentAudio));
    expect(library.artistCollection.containsKey('Old Artist'), isFalse);
    expect(
      library.artistCollection['New Artist']!.works.single,
      same(currentAudio),
    );
  });

  test('albums without album artists retain all track artists', () {
    final library = AudioLibrary.instance;
    final first = Audio(
      'First',
      'First Artist',
      'Album',
      null,
      1,
      60,
      320,
      44100,
      r'C:\Music\first.mp3',
      1,
      1,
      'test',
    );
    final second = Audio(
      'Second',
      'Second Artist',
      'Album',
      null,
      2,
      60,
      320,
      44100,
      r'C:\Music\second.mp3',
      1,
      1,
      'test',
    );

    library.replaceFolders([
      AudioFolder([first, second], r'C:\Music', 1, 1),
    ]);

    expect(library.albumCollection['Album']!.artistsMap.keys, [
      'First Artist',
      'Second Artist',
    ]);
  });

  test('album artists replace earlier track artist fallback', () {
    final library = AudioLibrary.instance;
    final first = Audio(
      'First',
      'First Artist',
      'Album',
      null,
      1,
      60,
      320,
      44100,
      r'C:\Music\first.mp3',
      1,
      1,
      'test',
    );
    final second = Audio(
      'Second',
      'Second Artist',
      'Album',
      'Album Artist',
      2,
      60,
      320,
      44100,
      r'C:\Music\second.mp3',
      1,
      1,
      'test',
    );

    library.replaceFolders([
      AudioFolder([first, second], r'C:\Music', 1, 1),
    ]);

    expect(library.albumCollection['Album']!.artistsMap.keys, ['Album Artist']);
  });

  test('preferred page snapshots preserve sorting and path indexes', () async {
    final library = AudioLibrary.instance;
    final track10 = Audio(
      'Track 10',
      'Artist 10',
      'Album 10',
      null,
      10,
      60,
      320,
      44100,
      r'C:\Music\track10.mp3',
      10,
      10,
      'test',
    );
    final track2 = Audio(
      'Track 2',
      'Artist 2',
      'Album 2',
      null,
      2,
      60,
      320,
      44100,
      r'C:\Music\track2.mp3',
      2,
      2,
      'test',
    );
    library.replaceFolders([
      AudioFolder([track10, track2], r'C:\Music', 1, 1),
    ]);

    await library.preparePreferredPageSnapshots();

    final audios = library.preparedAudiosPage!;
    expect(audios.items, [track2, track10]);
    expect(library.audiosPageIndexForPath(track2.path), 0);
    expect(library.audiosPageIndexForPath(track10.path), 1);
    expect(library.preparedArtistsPage!.items.map((artist) => artist.name), [
      'Artist 2',
      'Artist 10',
    ]);
    expect(library.preparedAlbumsPage!.items.map((album) => album.name), [
      'Album 2',
      'Album 10',
    ]);

    AppPreference.instance.audiosPagePref.sortOrder = SortOrder.decending;
    expect(library.preparedAudiosPage, isNull);
  });

  test(
    'page snapshots keep the preference captured when work starts',
    () async {
      final library = AudioLibrary.instance;
      final track10 = Audio(
        'Track 10',
        'Artist',
        'Album',
        null,
        10,
        60,
        320,
        44100,
        r'C:\Music\track10.mp3',
        10,
        10,
        'test',
      );
      final track2 = Audio(
        'Track 2',
        'Artist',
        'Album',
        null,
        2,
        60,
        320,
        44100,
        r'C:\Music\track2.mp3',
        2,
        2,
        'test',
      );
      library.replaceFolders([
        AudioFolder([track10, track2], r'C:\Music', 1, 1),
      ]);

      final preparation = library.preparePreferredAudioPageSnapshot();
      AppPreference.instance.audiosPagePref.sortOrder = SortOrder.decending;
      await preparation;

      expect(library.preparedAudiosPage, isNull);
    },
  );

  test('concurrent audio page preparation reuses the same work', () async {
    final library = AudioLibrary.instance;
    library.replaceFolders([
      AudioFolder(
        [
          Audio(
            'Track',
            'Artist',
            'Album',
            null,
            1,
            60,
            320,
            44100,
            r'C:\Music\track.mp3',
            1,
            1,
            'test',
          ),
        ],
        r'C:\Music',
        1,
        1,
      ),
    ]);

    final first = library.preparePreferredAudioPageSnapshot();
    final second = library.preparePreferredAudioPageSnapshot();

    expect(identical(first, second), isTrue);
    await first;
  });
}
