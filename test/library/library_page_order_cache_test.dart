import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/library_page_order_cache.dart';

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
    AppPreference.instance.excludedFolderPaths = [];
  });

  test(
    'binary page order cache round trips and rejects context changes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pure_music_page_order_cache_test_',
      );
      try {
        final source = File(
          '${directory.path}${Platform.pathSeparator}index.json',
        );
        final cache = '${directory.path}${Platform.pathSeparator}orders.bin';
        await source.writeAsString('source');
        final signature = await LibraryPageOrderCache.sourceSignature(
          source.path,
        );
        final orders = LibraryPageOrders(
          sourceSignature: signature!,
          context: 'context-a',
          audios: PageOrderSnapshot(
            sortMethod: 0,
            sortOrderIndex: 0,
            indexes: Uint32List.fromList([1, 0]),
          ),
          artists: PageOrderSnapshot(
            sortMethod: 0,
            sortOrderIndex: 0,
            indexes: Uint32List.fromList([0]),
          ),
          albums: PageOrderSnapshot(
            sortMethod: 0,
            sortOrderIndex: 0,
            indexes: Uint32List.fromList([0]),
          ),
        );

        await LibraryPageOrderCache.write(cachePath: cache, orders: orders);
        await LibraryPageOrderCache.write(cachePath: cache, orders: orders);
        final restored = await LibraryPageOrderCache.read(
          cachePath: cache,
          sourceSignature: signature,
          context: 'context-a',
          audioCount: 2,
          artistCount: 1,
          albumCount: 1,
        );

        expect(restored, isNotNull);
        expect(restored!.audios.indexes, [1, 0]);
        expect(
          await LibraryPageOrderCache.read(
            cachePath: cache,
            sourceSignature: signature,
            context: 'context-b',
            audioCount: 2,
            artistCount: 1,
            albumCount: 1,
          ),
          isNull,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'audio library restores cached orders and re-sorts changed preferences',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pure_music_page_order_integration_test_',
      );
      try {
        final source = File(
          '${directory.path}${Platform.pathSeparator}index.json',
        );
        final cache = '${directory.path}${Platform.pathSeparator}orders.bin';
        await source.writeAsString('stable-library');

        _installLibrary();
        expect(
          await AudioLibrary.instance.preparePreferredPageSnapshotsUsingCache(
            sourcePath: source.path,
            cachePath: cache,
          ),
          isFalse,
        );
        await AudioLibrary.instance.waitForPreferredPageOrderCacheWrite();
        expect(
          AudioLibrary.instance.preparedAudiosPage!.items.map((e) => e.title),
          ['Track 2', 'Track 10'],
        );
        final signature = await LibraryPageOrderCache.sourceSignature(
          source.path,
        );
        final currentContext = json.encode({
          'appVersion': AppSettings.version,
          'artistSplitPattern': AppSettings.instance.artistSplitPattern,
          'excludedFolders': <String>[],
        });
        final previousVersionContext = json.encode({
          'appVersion': '${AppSettings.version}-previous',
          'artistSplitPattern': AppSettings.instance.artistSplitPattern,
          'excludedFolders': <String>[],
        });
        expect(
          await LibraryPageOrderCache.read(
            cachePath: cache,
            sourceSignature: signature!,
            context: currentContext,
            audioCount: 2,
            artistCount: 2,
            albumCount: 2,
          ),
          isNotNull,
        );
        expect(
          await LibraryPageOrderCache.read(
            cachePath: cache,
            sourceSignature: signature,
            context: previousVersionContext,
            audioCount: 2,
            artistCount: 2,
            albumCount: 2,
          ),
          isNull,
        );

        AudioLibrary.instance.dispose();
        _installLibrary();
        expect(
          await AudioLibrary.instance.preparePreferredPageSnapshotsUsingCache(
            sourcePath: source.path,
            cachePath: cache,
          ),
          isTrue,
        );

        AppPreference.instance.audiosPagePref.sortOrder = SortOrder.decending;
        AudioLibrary.instance.dispose();
        _installLibrary();
        expect(
          await AudioLibrary.instance.preparePreferredPageSnapshotsUsingCache(
            sourcePath: source.path,
            cachePath: cache,
          ),
          isFalse,
        );
        await AudioLibrary.instance.waitForPreferredPageOrderCacheWrite();
        expect(
          AudioLibrary.instance.preparedAudiosPage!.items.map((e) => e.title),
          ['Track 10', 'Track 2'],
        );
      } finally {
        await AudioLibrary.instance.waitForPreferredPageOrderCacheWrite();
        await directory.delete(recursive: true);
      }
    },
  );
}

void _installLibrary() {
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
  AudioLibrary.instance.replaceFolders([
    AudioFolder([track10, track2], r'C:\Music', 1, 1),
  ]);
}
