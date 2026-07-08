import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/component/artist_tile.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/page/uni_detail_page.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class AlbumDetailPage extends StatelessWidget {
  const AlbumDetailPage({super.key, required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final secondaryContent = List<Audio>.from(album.works);
    final multiSelectController = MultiSelectController<Audio>();

    final canSortSongs = hasEnoughItemsToSort(secondaryContent.length);

    return UniDetailPage<Album, Audio, Artist>(
      pref: AppPreference.instance.albumDetailPagePref,
      primaryContent: album,
      primaryPic: album.cover,
      backgroundPic: album.works.isEmpty
          ? Future<ImageProvider?>.value(null)
          : album.works.first.cover,
      picShape: PicShape.rrect,
      title: album.name,
      subtitle: '${album.works.length} 首作品',
      secondaryContent: secondaryContent,
      secondaryContentBuilder: (context, audio, i, multiSelectController, _) =>
          AudioTile(
        leading: Text(audio.track < 10 ? '0${audio.track}' : '${audio.track}'),
        audioIndex: i,
        playlist: secondaryContent,
        multiSelectController: multiSelectController,
      ),
      tertiaryContentTitle: '艺术家',
      tertiaryContent: album.artistsMap.values.toList(),
      tertiaryContentBuilder:
          (context, artist, i, multiSelectController, view) => ArtistTile(
        artist: artist,
        view: view,
      ),
      enableShufflePlay: secondaryContent.isNotEmpty,
      enableSortMethod: canSortSongs,
      enableSortOrder: canSortSongs,
      enableSecondaryContentViewSwitch: secondaryContent.isNotEmpty,
      enableTabs: true,
      secondaryContentTitle: '歌曲',
      tertiaryTabIcon: Symbols.artist,
      bodyOverride: secondaryContent.isEmpty ? const _EmptyAlbumBody() : null,
      multiSelectController: multiSelectController,
      multiSelectViewActions: [
        AddAllToPlaylist(multiSelectController: multiSelectController),
        MultiSelectSelectOrClearAll(
          multiSelectController: multiSelectController,
          contentList: secondaryContent,
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
          icon: Symbols.art_track,
          name: '音轨',
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.track.compareTo(b.track));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.track.compareTo(a.track));
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

class _EmptyAlbumBody extends StatelessWidget {
  const _EmptyAlbumBody();

  @override
  Widget build(BuildContext context) {
    return const QuietEmptyState(
      icon: Symbols.album,
      title: '这个专辑还没有歌曲',
      message: '等扫描或索引更新后，这里会显示可播放内容。',
    );
  }
}
