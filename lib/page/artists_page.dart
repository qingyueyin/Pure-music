import 'dart:async';

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/component/artist_tile.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/page_sort.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class ArtistsPage extends StatefulWidget {
  const ArtistsPage({super.key});

  @override
  State<ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends State<ArtistsPage> {
  final MultiSelectController<Artist> _multiSelectController =
      MultiSelectController<Artist>();
  int _contentVersion = -1;
  List<Artist> _contentList = [];
  bool _contentIsPrepared = false;
  Future<void>? _preparation;
  bool _preparationFailed = false;

  void _prepareContentInBackground() {
    if (_preparation != null) return;
    if (AudioLibrary.instance.preparedArtistsPage != null) {
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
          logger.e('艺术家页面后台准备失败', error: error, stackTrace: trace);
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

  List<Artist> _resolveContentList(int version) {
    if (_contentVersion == version) return _contentList;
    _contentVersion = version;
    final library = AudioLibrary.instance;
    final prepared = library.preparedArtistsPage;
    _contentIsPrepared = prepared != null;
    _contentList =
        prepared?.items ?? List<Artist>.from(library.artistCollection.values);
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
      valueListenable: AudioLibrary.artistPageVersion,
      builder: (context, version, _) {
        final library = AudioLibrary.instance;
        if (!_preparationFailed &&
            library.preparedArtistsPage == null &&
            library.artistCollection.length >= 4096) {
          return LibraryPagePreparing(
            title: '艺术家',
            subtitle: '${library.artistCollection.length} 位艺术家',
          );
        }
        final contentList = _resolveContentList(version);
        final canSortItems = hasEnoughItemsToSort(contentList.length);
        return UniPage<Artist>(
          pref: AppPreference.instance.artistsPagePref,
          title: '艺术家',
          subtitle: '${contentList.length} 位艺术家',
          contentList: contentList,
          contentRevision: version,
          contentIsPrepared: _contentIsPrepared,
          contentBuilder: (_, item, _, multiSelectController, view) =>
              ArtistTile(
                artist: item,
                multiSelectController: _multiSelectController,
                view: view,
              ),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 300,
            mainAxisExtent: 72,
            mainAxisSpacing: 8.0,
            crossAxisSpacing: 8.0,
          ),
          enableShufflePlay: false,
          enableSortMethod: canSortItems,
          enableSortOrder: canSortItems,
          enableContentViewSwitch: false,
          multiSelectController: _multiSelectController,
          multiSelectViewActions: [
            MultiSelectPlaySelectedAudios(
              multiSelectController: _multiSelectController,
              toAudios: (selected) =>
                  selected.expand((artist) => artist.works).toList(),
            ),
            AddSelectedAudiosToPlaylist(
              multiSelectController: _multiSelectController,
              toAudios: (selected) =>
                  selected.expand((artist) => artist.works).toList(),
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
              name: '名称',
              method: (list, order) {
                switch (order) {
                  case SortOrder.ascending:
                    sortNaturallyBy(list, (artist) => artist.name);
                    break;
                  case SortOrder.decending:
                    sortNaturallyBy(
                      list,
                      (artist) => artist.name,
                      descending: true,
                    );
                    break;
                }
              },
              backgroundMethod: (list, order, control) =>
                  sortPageNaturallyInBackground(
                    list,
                    (artist) => artist.name,
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
                    (artist) => artist.works.length,
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
