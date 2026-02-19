import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({super.key, required this.playlist});

  final Playlist playlist;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  final multiSelectController = MultiSelectController<Audio>();

  @override
  Widget build(BuildContext context) {
    final contentList = widget.playlist.audios.values.toList();
    final scheme = Theme.of(context).colorScheme;

    return UniPage<Audio>(
      pref: AppPreference.instance.playlistDetailPagePref,
      title: widget.playlist.name,
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
        IconButton.filled(
          tooltip: "移除选中歌曲",
          onPressed: () {
            setState(() {
              for (var item in multiSelectController.selected) {
                widget.playlist.audios.remove(item.path);
              }
            });
            multiSelectController.useMultiSelectView(false);
          },
          style: ButtonStyle(
            backgroundColor: WidgetStatePropertyAll(scheme.error),
            foregroundColor: WidgetStatePropertyAll(scheme.onError),
          ),
          icon: const Icon(Symbols.delete),
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
