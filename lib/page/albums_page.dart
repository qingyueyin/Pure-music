import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/component/album_tile.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class AlbumsPage extends StatelessWidget {
  const AlbumsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AudioLibrary.libraryVersion,
      builder: (context, _, _) {
        final contentList = AudioLibrary.instance.albumCollection.values
            .toList();
        final canSortItems = hasEnoughItemsToSort(contentList.length);
        final multiSelectController = MultiSelectController<Album>();
        return UniPage<Album>(
          pref: AppPreference.instance.albumsPagePref,
          title: '专辑',
          subtitle: '${contentList.length} 张专辑',
          contentList: contentList,
          contentBuilder: (context, item, i, multiSelectController, view) =>
              AlbumTile(
                album: item,
                multiSelectController: multiSelectController,
                view: view,
              ),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            childAspectRatio: 0.75,
            mainAxisSpacing: 24.0,
            crossAxisSpacing: 24.0,
          ),
          enableShufflePlay: false,
          enableSortMethod: canSortItems,
          enableSortOrder: canSortItems,
          enableContentViewSwitch: false,
          multiSelectController: multiSelectController,
          multiSelectViewActions: [
            MultiSelectPlaySelectedAudios(
              multiSelectController: multiSelectController,
              toAudios: (selected) =>
                  selected.expand((album) => album.works).toList(),
            ),
            AddSelectedAudiosToPlaylist(
              multiSelectController: multiSelectController,
              toAudios: (selected) =>
                  selected.expand((album) => album.works).toList(),
            ),
            MultiSelectSelectOrClearAll(
              multiSelectController: multiSelectController,
              contentList: contentList,
            ),
            MultiSelectExit(multiSelectController: multiSelectController),
          ],
          sortMethods: [
            SortMethodDesc(
              icon: Symbols.title,
              name: '标题',
              method: (list, order) {
                switch (order) {
                  case SortOrder.ascending:
                    list.sort((a, b) => a.name.naturalCompareTo(b.name));
                    break;
                  case SortOrder.decending:
                    list.sort((a, b) => b.name.naturalCompareTo(a.name));
                    break;
                }
              },
            ),
            SortMethodDesc(
              icon: Symbols.music_note,
              name: '作品数量',
              method: (list, order) {
                switch (order) {
                  case SortOrder.ascending:
                    list.sort(
                      (a, b) => a.works.length.compareTo(b.works.length),
                    );
                    break;
                  case SortOrder.decending:
                    list.sort(
                      (a, b) => b.works.length.compareTo(a.works.length),
                    );
                    break;
                }
              },
            ),
          ],
        );
      },
    );
  }
}
