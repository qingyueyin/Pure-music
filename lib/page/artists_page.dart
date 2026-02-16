import 'package:pure_music/app_preference.dart';
import 'package:pure_music/enums.dart';
import 'package:pure_music/component/artist_tile.dart';
import 'package:pure_music/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class ArtistsPage extends StatelessWidget {
  const ArtistsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final contentList = AudioLibrary.instance.artistCollection.values.toList();
    final multiSelectController = MultiSelectController<Artist>();
    return UniPage<Artist>(
      pref: AppPreference.instance.artistsPagePref,
      title: "艺术家",
      subtitle: "${contentList.length} 位艺术家",
      contentList: contentList,
      contentBuilder: (_, item, __, multiSelectController, view) => ArtistTile(
        artist: item,
        multiSelectController: multiSelectController,
        view: view,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 300,
          mainAxisExtent: 72,
          mainAxisSpacing: 8.0,
          crossAxisSpacing: 8.0,
        ),
      enableShufflePlay: false,
      enableSortMethod: true,
      enableSortOrder: true,
      enableContentViewSwitch: true,
      multiSelectController: multiSelectController,
      multiSelectViewActions: [
        MultiSelectPlaySelectedAudios(
          multiSelectController: multiSelectController,
          toAudios: (selected) =>
              selected.expand((artist) => artist.works).toList(),
        ),
        AddSelectedAudiosToPlaylist(
          multiSelectController: multiSelectController,
          toAudios: (selected) =>
              selected.expand((artist) => artist.works).toList(),
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
          name: "名称",
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
          name: "作品数量",
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.works.length.compareTo(b.works.length));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.works.length.compareTo(a.works.length));
                break;
            }
          },
        ),
      ],
    );
  }
}
