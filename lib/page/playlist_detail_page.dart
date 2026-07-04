import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/page/playlist_cover_picker.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/page/uni_detail_page.dart';
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
  bool _isReordering = false;

  Future<ImageProvider?> get _primaryPic async {
    final custom = await widget.playlist.resolveCoverProvider();
    if (custom != null) return custom;
    if (widget.playlist.audios.isEmpty) return null;
    return widget.playlist.audios.first.mediumCover;
  }

  Future<ImageProvider?> get _backgroundPic async {
    if (widget.playlist.audios.isEmpty) return null;
    return widget.playlist.audios.first.cover;
  }

  Future<void> _changeCover() async {
    await showCoverPicker(context, widget.playlist);
    if (!mounted) return;
    setState(() {});
  }

  void _onSortChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final contentList = List<Audio>.from(widget.playlist.audios);
    final scheme = Theme.of(context).colorScheme;
    final pref = AppPreference.instance.playlistDetailPagePref;

    final List<SortMethodDesc<Audio>> sortMethods = [
      SortMethodDesc<Audio>(
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
      SortMethodDesc<Audio>(
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
      SortMethodDesc<Audio>(
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
      SortMethodDesc<Audio>(
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
      SortMethodDesc<Audio>(
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
      SortMethodDesc<Audio>(
        icon: Symbols.drag_indicator,
        name: '自定义',
        method: (list, order) {},
      ),
    ];

    final currMethodIndex = pref.sortMethod.clamp(0, sortMethods.length - 1);
    final isCustomSort = currMethodIndex == sortMethods.length - 1;

    return UniDetailPage<Playlist, Audio, Object>(
      pref: pref,
      primaryContent: widget.playlist,
      primaryPic: _primaryPic,
      backgroundPic: _backgroundPic,
      picShape: PicShape.rrect,
      title: widget.playlist.name,
      subtitle: '${contentList.length} 首乐曲',
      secondaryContent: contentList,
      secondaryContentBuilder: (context, audio, i, msc, _) =>
          AudioTile(
        audioIndex: i,
        playlist: contentList,
        multiSelectController: msc,
        onRemoveFromPlaylist: (removedAudio) {
          setState(() {
            widget.playlist.removeByPath(removedAudio.path);
          });
          savePlaylists();
          showTextOnSnackBar('已从歌单移除');
        },
      ),
      enableShufflePlay: true,
      enableSortMethod: true,
      enableSortOrder: true,
      enableSecondaryContentViewSwitch: true,
      multiSelectController: multiSelectController,
      multiSelectViewActions: [
        IconButton.filled(
          tooltip: '移除选中歌曲',
          onPressed: () async {
            setState(() {
              for (var item in multiSelectController.selected) {
                widget.playlist.removeByPath(item.path);
              }
            });
            await savePlaylists();
            if (!mounted) return;
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
      sortMethods: sortMethods,
      onSortMethodChanged: _onSortChanged,
      onPrimaryPicTap: _changeCover,
      bodyOverride: _isReordering
          ? _buildReorderBody(contentList, scheme)
          : null,
      extraActions: isCustomSort
          ? [
              SizedBox(
                height: 40.0,
                child: Material(
                  borderRadius: BorderRadius.circular(20.0),
                  color: _isReordering
                      ? scheme.tertiaryContainer
                      : scheme.primaryContainer,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20.0),
                    onTap: () => setState(() => _isReordering = !_isReordering),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isReordering ? Symbols.check : Symbols.reorder,
                            size: 24,
                            color: _isReordering
                                ? scheme.onTertiaryContainer
                                : scheme.onPrimaryContainer,
                          ),
                          const SizedBox(width: 4.0),
                          Text(
                            _isReordering ? '完成' : '排序',
                            style: TextStyle(
                              color: _isReordering
                                  ? scheme.onTertiaryContainer
                                  : scheme.onPrimaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ]
          : null,
    );
  }

  Widget _buildReorderBody(List<Audio> contentList, ColorScheme scheme) {
    final paths = List<String>.from(widget.playlist.paths);

    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: 80.0),
      buildDefaultDragHandles: false,
      itemCount: contentList.length,
      onReorderItem: (oldIndex, newIndex) {
        setState(() {
          final item = paths.removeAt(oldIndex);
          paths.insert(newIndex, item);
          widget.playlist.paths
            ..clear()
            ..addAll(paths);
        });
        savePlaylists();
      },
      proxyDecorator: (child, index, animation) => Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        child: child,
      ),
      itemBuilder: (context, i) {
        final audio = contentList[i];
        return _ReorderItem(
          key: ValueKey(audio.path),
          audio: audio,
          index: i,
          colorScheme: scheme,
        );
      },
    );
  }
}

class _ReorderItem extends StatelessWidget {
  const _ReorderItem({
    super.key,
    required this.audio,
    required this.index,
    required this.colorScheme,
  });

  final Audio audio;
  final int index;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final scheme = colorScheme;
    return SizedBox(
      height: 64,
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Icon(Symbols.drag_indicator, color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: 8.0),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      audio.title,
                      style: TextStyle(color: scheme.onSurface, fontSize: 16),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4.0),
                    Text(
                      '${audio.artist} - ${audio.album}',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
