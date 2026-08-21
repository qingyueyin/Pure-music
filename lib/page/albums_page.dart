import 'dart:async';

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/component/album_tile.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/page_sort.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class AlbumsPage extends StatefulWidget {
  const AlbumsPage({super.key});

  @override
  State<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends State<AlbumsPage> {
  final MultiSelectController<Album> _multiSelectController =
      MultiSelectController<Album>();
  int _contentVersion = -1;
  List<Album> _contentList = [];
  bool _contentIsPrepared = false;
  Future<void>? _preparation;
  bool _preparationFailed = false;

  void _prepareContentInBackground() {
    if (_preparation != null) return;
    if (AudioLibrary.instance.preparedAlbumsPage != null) {
      if (_contentVersion == -1) setState(() {});
      return;
    }
    final future = AudioLibrary.instance
        .preparePreferredSecondaryPageSnapshots();
    _preparation = future;
    unawaited(
      future.then<void>(
        (_) {
          if (!mounted || !identical(_preparation, future)) return;
          setState(() {
            _preparation = null;
            _contentVersion = -1;
          });
        },
        onError: (Object error, StackTrace trace) {
          logger.e('专辑页面后台准备失败', error: error, stackTrace: trace);
          if (!mounted || !identical(_preparation, future)) return;
          setState(() {
            _preparation = null;
            _preparationFailed = true;
            _contentVersion = -1;
          });
        },
      ),
    );
  }

  List<Album> _resolveContentList(int version) {
    if (_contentVersion == version) return _contentList;
    _contentVersion = version;
    final library = AudioLibrary.instance;
    final prepared = library.preparedAlbumsPage;
    _contentIsPrepared = prepared != null;
    _contentList =
        prepared?.items ?? List<Album>.from(library.albumCollection.values);
    _multiSelectController.selected.clear();
    _multiSelectController.enableMultiSelectView = false;
    return _contentList;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prepareContentInBackground();
    });
  }

  @override
  void dispose() {
    _multiSelectController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AudioLibrary.albumPageVersion,
      builder: (context, version, _) {
        final library = AudioLibrary.instance;
        if (!_preparationFailed &&
            library.preparedAlbumsPage == null &&
            library.albumCollection.length >= 4096) {
          return LibraryPagePreparing(
            title: '专辑',
            subtitle: '${library.albumCollection.length} 张专辑',
          );
        }
        final contentList = _resolveContentList(version);
        final canSortItems = hasEnoughItemsToSort(contentList.length);
        return UniPage<Album>(
          pref: AppPreference.instance.albumsPagePref,
          title: '专辑',
          subtitle: '${contentList.length} 张专辑',
          contentList: contentList,
          contentRevision: version,
          contentIsPrepared: _contentIsPrepared,
          contentBuilder: (context, item, i, multiSelectController, view) =>
              AlbumTile(
                album: item,
                multiSelectController: _multiSelectController,
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
          enableStackedEffect: false,
          multiSelectController: _multiSelectController,
          multiSelectViewActions: [
            MultiSelectPlaySelectedAudios(
              multiSelectController: _multiSelectController,
              toAudios: (selected) =>
                  selected.expand((album) => album.works).toList(),
            ),
            AddSelectedAudiosToPlaylist(
              multiSelectController: _multiSelectController,
              toAudios: (selected) =>
                  selected.expand((album) => album.works).toList(),
            ),
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
              alphabetValueOf: (album) => album.name,
              method: (list, order) {
                switch (order) {
                  case SortOrder.ascending:
                    sortNaturallyBy(list, (album) => album.name);
                    break;
                  case SortOrder.decending:
                    sortNaturallyBy(
                      list,
                      (album) => album.name,
                      descending: true,
                    );
                    break;
                }
              },
              backgroundMethod: (list, order, control) =>
                  sortPageNaturallyInBackground(
                    list,
                    (album) => album.name,
                    descending: order == SortOrder.decending,
                    control: control,
                  ),
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
              backgroundMethod: (list, order, control) =>
                  sortPageByIntegerInBackground(
                    list,
                    (album) => album.works.length,
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
