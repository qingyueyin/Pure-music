import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class FolderDetailPage extends StatelessWidget {
  final AudioFolder folder;
  const FolderDetailPage({super.key, required this.folder});

  @override
  Widget build(BuildContext context) {
    final contentList = List<Audio>.from(folder.audios);
    final multiSelectController = MultiSelectController<Audio>();
    return UniPage<Audio>(
      pref: AppPreference.instance.folderDetailPagePref,
      title: folder.path,
      subtitle: "${contentList.length} 首乐曲",
      contentList: contentList,
      contentBuilder: (context, item, i, multiSelectController, _) => AudioTile(
        audioIndex: i,
        playlist: contentList,
        multiSelectController: multiSelectController,
      ),
      enableShufflePlay: true,
      enableSortMethod: true,
      enableSortOrder: true,
      enableContentViewSwitch: true,
      multiSelectController: multiSelectController,
      multiSelectViewActions: [
        AddAllToPlaylist(multiSelectController: multiSelectController),
        MultiSelectSelectOrClearAll(
          multiSelectController: multiSelectController,
          contentList: contentList,
        ),
        MultiSelectExit(multiSelectController: multiSelectController),
      ],
      sortMethods: [
        SortMethodDesc(
          icon: Symbols.title,
          name: "标题",
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.title.naturalCompareTo(b.title));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.title.naturalCompareTo(a.title));
                break;
            }
          },
        ),
        SortMethodDesc(
          icon: Symbols.artist,
          name: "艺术家",
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.artist.naturalCompareTo(b.artist));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.artist.naturalCompareTo(a.artist));
                break;
            }
          },
        ),
        SortMethodDesc(
          icon: Symbols.album,
          name: "专辑",
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.album.naturalCompareTo(b.album));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.album.naturalCompareTo(a.album));
                break;
            }
          },
        ),
        SortMethodDesc(
          icon: Symbols.add,
          name: "创建时间",
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.created.compareTo(b.created));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.created.compareTo(a.created));
                break;
            }
          },
        ),
        SortMethodDesc(
          icon: Symbols.edit,
          name: "修改时间",
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.modified.compareTo(b.modified));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.modified.compareTo(a.modified));
                break;
            }
          },
        ),
      ],
    );
  }
}
