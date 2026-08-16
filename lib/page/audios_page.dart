import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/page_sort.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class AudiosPage extends StatefulWidget {
  final Audio? locateTo;
  const AudiosPage({super.key, this.locateTo});

  @override
  State<AudiosPage> createState() => _AudiosPageState();
}

class _AudiosPageState extends State<AudiosPage> {
  final MultiSelectController<Audio> _multiSelectController =
      MultiSelectController<Audio>();
  int _contentVersion = -1;
  List<Audio> _contentList = [];
  bool _contentIsPrepared = false;

  List<Audio> _resolveContentList(int version) {
    if (_contentVersion == version) return _contentList;
    _contentVersion = version;
    final library = AudioLibrary.instance;
    final prepared = library.preparedAudiosPage;
    _contentIsPrepared = prepared != null;
    _contentList = prepared?.items ?? List<Audio>.from(library.audioCollection);
    _multiSelectController.selected.clear();
    _multiSelectController.enableMultiSelectView = false;
    return _contentList;
  }

  @override
  void dispose() {
    _multiSelectController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AudioLibrary.libraryVersion,
      builder: (context, version, _) {
        final contentList = _resolveContentList(version);
        final hasSongs = contentList.isNotEmpty;
        final canSortSongs = hasEnoughItemsToSort(contentList.length);
        return UniPage<Audio>(
          pref: AppPreference.instance.audiosPagePref,
          title: '音乐',
          subtitle: '${contentList.length} 首乐曲',
          contentList: contentList,
          contentRevision: version,
          contentIsPrepared: _contentIsPrepared,
          contentBuilder: (context, item, i, multiSelectController, _) =>
              AudioTile(
                audioIndex: i,
                playlist: contentList,
                focus: item == widget.locateTo,
                multiSelectController: _multiSelectController,
              ),
          enableShufflePlay: hasSongs,
          enableSortMethod: canSortSongs,
          enableSortOrder: canSortSongs,
          enableContentViewSwitch: hasSongs,
          enableStackedList: true,
          locateTo: widget.locateTo,
          multiSelectController: _multiSelectController,
          multiSelectViewActions: [
            AddAllToPlaylist(multiSelectController: _multiSelectController),
            MultiSelectSelectOrClearAll(
              multiSelectController: _multiSelectController,
              contentList: contentList,
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
                    sortNaturallyBy(list, (audio) => audio.title);
                    break;
                  case SortOrder.decending:
                    sortNaturallyBy(
                      list,
                      (audio) => audio.title,
                      descending: true,
                    );
                    break;
                }
              },
              backgroundMethod: (list, order, control) =>
                  sortPageNaturallyInBackground(
                    list,
                    (audio) => audio.title,
                    descending: order == SortOrder.decending,
                    control: control,
                  ),
            ),
            SortMethodDesc(
              icon: Symbols.artist,
              name: '艺术家',
              method: (list, order) {
                switch (order) {
                  case SortOrder.ascending:
                    sortNaturallyBy(
                      list,
                      (audio) => audio.artist,
                      reuseEqualKeys: true,
                    );
                    break;
                  case SortOrder.decending:
                    sortNaturallyBy(
                      list,
                      (audio) => audio.artist,
                      descending: true,
                      reuseEqualKeys: true,
                    );
                    break;
                }
              },
              backgroundMethod: (list, order, control) =>
                  sortPageNaturallyInBackground(
                    list,
                    (audio) => audio.artist,
                    descending: order == SortOrder.decending,
                    reuseEqualKeys: true,
                    control: control,
                  ),
            ),
            SortMethodDesc(
              icon: Symbols.album,
              name: '专辑',
              method: (list, order) {
                switch (order) {
                  case SortOrder.ascending:
                    sortNaturallyBy(
                      list,
                      (audio) => audio.album,
                      reuseEqualKeys: true,
                    );
                    break;
                  case SortOrder.decending:
                    sortNaturallyBy(
                      list,
                      (audio) => audio.album,
                      descending: true,
                      reuseEqualKeys: true,
                    );
                    break;
                }
              },
              backgroundMethod: (list, order, control) =>
                  sortPageNaturallyInBackground(
                    list,
                    (audio) => audio.album,
                    descending: order == SortOrder.decending,
                    reuseEqualKeys: true,
                    control: control,
                  ),
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
              backgroundMethod: (list, order, control) =>
                  sortPageByIntegerInBackground(
                    list,
                    (audio) => audio.created,
                    descending: order == SortOrder.decending,
                    control: control,
                  ),
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
              backgroundMethod: (list, order, control) =>
                  sortPageByIntegerInBackground(
                    list,
                    (audio) => audio.modified,
                    descending: order == SortOrder.decending,
                    control: control,
                  ),
            ),
          ],
        );
      },
    );
  }
}
