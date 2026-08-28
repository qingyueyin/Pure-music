import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/component/artist_tile.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/page/uni_detail_page.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

int _discNumber(Audio audio) {
  final disc = audio.disc;
  return disc != null && disc > 0 ? disc : 1;
}

String _trackNumber(Audio audio, {bool includeDisc = false}) {
  final track = audio.track < 10 ? '0${audio.track}' : '${audio.track}';
  return includeDisc ? '${_discNumber(audio)}-$track' : track;
}

int _compareWithinDisc(
  Audio first,
  Audio second,
  int Function(Audio first, Audio second) compare,
) {
  final disc = _discNumber(first).compareTo(_discNumber(second));
  return disc != 0 ? disc : compare(first, second);
}

class AlbumDetailPage extends StatelessWidget {
  const AlbumDetailPage({super.key, required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final secondaryContent = List<Audio>.from(album.works);
    final multiSelectController = MultiSelectController<Audio>();
    final discNumbers = secondaryContent
        .map(_discNumber)
        .where((disc) => disc > 0)
        .toSet();
    final showDiscSections =
        discNumbers.length > 1 || discNumbers.any((disc) => disc > 1);

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
      secondaryContentBuilder:
          (context, audio, i, multiSelectController, view) => AudioTile(
            leading: Text(
              _trackNumber(
                audio,
                includeDisc: showDiscSections && view == ContentView.table,
              ),
            ),
            audioIndex: i,
            playlist: secondaryContent,
            multiSelectController: multiSelectController,
          ),
      secondaryContentSectionBuilder: showDiscSections
          ? (context, audio, i) {
              final disc = _discNumber(audio);
              if (i > 0 && _discNumber(secondaryContent[i - 1]) == disc) {
                return null;
              }
              return _DiscSectionHeader(disc: disc);
            }
          : null,
      tertiaryContentTitle: '艺术家',
      tertiaryContent: album.artistsMap.values.toList(),
      tertiaryContentBuilder:
          (context, artist, i, multiSelectController, view) =>
              ArtistTile(artist: artist, view: view),
      enableShufflePlay: secondaryContent.isNotEmpty,
      enablePlayAll: secondaryContent.isNotEmpty,
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
          alphabetValueOf: (audio) => audio.title,
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort(
                  (a, b) => _compareWithinDisc(
                    a,
                    b,
                    (first, second) =>
                        first.title.naturalCompareTo(second.title),
                  ),
                );
                break;
              case SortOrder.decending:
                list.sort(
                  (a, b) => _compareWithinDisc(
                    b,
                    a,
                    (first, second) =>
                        first.title.naturalCompareTo(second.title),
                  ),
                );
                break;
            }
          },
        ),
        SortMethodDesc(
          icon: Symbols.artist,
          name: '艺术家',
          alphabetValueOf: (audio) => audio.artist,
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort(
                  (a, b) => _compareWithinDisc(
                    a,
                    b,
                    (first, second) =>
                        first.artist.naturalCompareTo(second.artist),
                  ),
                );
                break;
              case SortOrder.decending:
                list.sort(
                  (a, b) => _compareWithinDisc(
                    b,
                    a,
                    (first, second) =>
                        first.artist.naturalCompareTo(second.artist),
                  ),
                );
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
                list.sort(
                  (a, b) => _compareWithinDisc(
                    a,
                    b,
                    (first, second) => first.track.compareTo(second.track),
                  ),
                );
                break;
              case SortOrder.decending:
                list.sort(
                  (a, b) => _compareWithinDisc(
                    b,
                    a,
                    (first, second) => first.track.compareTo(second.track),
                  ),
                );
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
                list.sort(
                  (a, b) => _compareWithinDisc(
                    a,
                    b,
                    (first, second) => first.created.compareTo(second.created),
                  ),
                );
                break;
              case SortOrder.decending:
                list.sort(
                  (a, b) => _compareWithinDisc(
                    b,
                    a,
                    (first, second) => first.created.compareTo(second.created),
                  ),
                );
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
                list.sort(
                  (a, b) => _compareWithinDisc(
                    a,
                    b,
                    (first, second) =>
                        first.modified.compareTo(second.modified),
                  ),
                );
                break;
              case SortOrder.decending:
                list.sort(
                  (a, b) => _compareWithinDisc(
                    b,
                    a,
                    (first, second) =>
                        first.modified.compareTo(second.modified),
                  ),
                );
                break;
            }
          },
        ),
      ],
    );
  }
}

class _DiscSectionHeader extends StatelessWidget {
  const _DiscSectionHeader({required this.disc});

  final int disc;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Row(
          children: [
            Icon(Symbols.album, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(
              '唱片 $disc',
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: AppType.body,
                fontWeight: AppType.weightSemibold,
              ),
            ),
          ],
        ),
      ),
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
