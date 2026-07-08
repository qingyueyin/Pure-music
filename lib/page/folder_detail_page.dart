import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class FolderDetailPage extends StatefulWidget {
  final AudioFolder folder;
  const FolderDetailPage({super.key, required this.folder});

  @override
  State<FolderDetailPage> createState() => _FolderDetailPageState();
}

class _FolderDetailPageState extends State<FolderDetailPage> {
  late final MultiSelectController<Audio> _multiSelectController;
  late final List<Audio> _contentList;

  @override
  void initState() {
    super.initState();
    _multiSelectController = MultiSelectController<Audio>();
    _contentList = List<Audio>.from(widget.folder.audios);
  }

  @override
  Widget build(BuildContext context) {
    final canSortSongs = hasEnoughItemsToSort(_contentList.length);
    final canPlaySongs = canShowPlayAllAction(_contentList.length);
    final canSwitchContentView = canShowContentViewSwitch(_contentList.length);
    return UniPage<Audio>(
      pref: AppPreference.instance.folderDetailPagePref,
      title: widget.folder.path,
      subtitle: '${_contentList.length} 首乐曲',
      contentList: _contentList,
      contentBuilder: (context, item, i, multiSelectController, _) => AudioTile(
        audioIndex: i,
        playlist: _contentList,
        multiSelectController: multiSelectController,
      ),
      enableShufflePlay: canPlaySongs,
      enableSortMethod: canSortSongs,
      enableSortOrder: canSortSongs,
      enableContentViewSwitch: canSwitchContentView,
      multiSelectController: _multiSelectController,
      multiSelectViewActions: [
        AddAllToPlaylist(multiSelectController: _multiSelectController),
        MultiSelectSelectOrClearAll(
          multiSelectController: _multiSelectController,
          contentList: _contentList,
        ),
        MultiSelectExit(multiSelectController: _multiSelectController),
      ],
      sortMethods: [
        SortMethodDesc(
          icon: Symbols.title,
          name: '标题',
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
          name: '艺术家',
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
          name: '专辑',
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
          name: '创建时间',
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
          name: '修改时间',
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
