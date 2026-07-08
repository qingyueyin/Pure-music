import 'package:pure_music/core/preference.dart';
import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/page/playlist_cover_picker.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
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
  bool _isRemovingSelected = false;
  bool _isPickingCover = false;
  late Future<ImageProvider?> _primaryPicFuture;
  late Future<ImageProvider?> _backgroundPicFuture;
  String _searchQuery = '';

  Future<ImageProvider?> _loadPrimaryPic() async {
    final custom = await widget.playlist.resolveCoverProvider();
    if (custom != null) return custom;
    return widget.playlist.firstAudio?.mediumCover;
  }

  Future<ImageProvider?> _loadBackgroundPic() async {
    final custom = await widget.playlist.resolveCoverProvider(size: 600);
    if (custom != null) return custom;
    return widget.playlist.firstAudio?.cover;
  }

  void _refreshCoverFutures() {
    _primaryPicFuture = _loadPrimaryPic();
    _backgroundPicFuture = _loadBackgroundPic();
  }

  @override
  void initState() {
    super.initState();
    _refreshCoverFutures();
  }

  @override
  void didUpdateWidget(covariant PlaylistDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlist != widget.playlist) {
      _refreshCoverFutures();
      _searchQuery = '';
    }
  }

  Future<void> _changeCover() async {
    if (_isPickingCover) return;
    setState(() => _isPickingCover = true);
    try {
      await showCoverPicker(context, widget.playlist);
      if (!mounted) return;
      _refreshCoverFutures();
      setState(() {});
    } finally {
      if (mounted) setState(() => _isPickingCover = false);
    }
  }

  void _onSortChanged() {
    setState(() {
      _isReordering = false;
    });
  }

  Future<bool> _confirmRemoveSelectedAudios(List<Audio> audios) async {
    final count = audios.length;
    final message = count == 1
        ? '将从歌单“${widget.playlist.name}”移除选中歌曲，不会删除本地音乐文件。'
        : '将从歌单“${widget.playlist.name}”移除 $count 首歌曲，不会删除本地音乐文件。';

    return showDangerConfirmDialog(
      context: context,
      title: '从歌单移除歌曲？',
      message: message,
      confirmLabel: '移除',
    );
  }

  @override
  Widget build(BuildContext context) {
    final allAudios = widget.playlist.audios;
    final contentList = _searchQuery.isEmpty
        ? List<Audio>.from(allAudios)
        : allAudios.where((audio) {
            final q = _searchQuery.toLowerCase();
            return audio.title.toLowerCase().contains(q) ||
                audio.artist.toLowerCase().contains(q) ||
                audio.album.toLowerCase().contains(q);
          }).toList();
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
        icon: Symbols.add_circle,
        name: '添加时间',
        method: (list, order) {
          switch (order) {
            case SortOrder.ascending:
              list.sort((a, b) => widget.playlist
                  .addedAt(a.path)
                  .compareTo(widget.playlist.addedAt(b.path)));
              break;
            case SortOrder.decending:
              list.sort((a, b) => widget.playlist
                  .addedAt(b.path)
                  .compareTo(widget.playlist.addedAt(a.path)));
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
    final canSortSongs = hasEnoughItemsToSort(contentList.length);
    final canReorder =
        isCustomSort && hasEnoughItemsToReorder(contentList.length);

    return UniDetailPage<Playlist, Audio, Object>(
      pref: pref,
      primaryContent: widget.playlist,
      primaryPic: _primaryPicFuture,
      backgroundPic: _backgroundPicFuture,
      picShape: PicShape.rrect,
      title: widget.playlist.name,
      subtitle: _searchQuery.isEmpty
          ? '${allAudios.length} 首乐曲'
          : '${contentList.length} / ${allAudios.length} 首乐曲',
      secondaryContent: contentList,
      secondaryContentBuilder: (context, audio, i, msc, _) => AudioTile(
        audioIndex: i,
        playlist: contentList,
        multiSelectController: msc,
        onRemoveFromPlaylist: (removedAudio) async {
          final oldPaths = List<String>.from(widget.playlist.paths);
          setState(() {
            widget.playlist.removeByPath(removedAudio.path);
            _refreshCoverFutures();
          });
          final saved = await savePlaylists();
          if (!mounted) return;
          if (!saved) {
            setState(() {
              widget.playlist.replacePaths(oldPaths);
              _refreshCoverFutures();
            });
            showTextOnSnackBar('保存歌单失败');
            return;
          }
          showTextOnSnackBar('已从歌单移除');
        },
      ),
      enableShufflePlay: contentList.isNotEmpty,
      enableSortMethod: canSortSongs,
      enableSortOrder: canSortSongs,
      enableSecondaryContentViewSwitch: contentList.isNotEmpty,
      enableSearch: true,
      searchQuery: _searchQuery,
      onSearchChanged: (v) => setState(() => _searchQuery = v),
      multiSelectController: multiSelectController,
      multiSelectViewActions: [
        ListenableBuilder(
          listenable: multiSelectController,
          builder: (context, _) => IconButton.filled(
            tooltip: '移除选中歌曲',
            onPressed:
                multiSelectController.selected.isEmpty || _isRemovingSelected
                    ? null
                    : () async {
                        if (_isRemovingSelected) return;
                        final selected = List<Audio>.from(
                          multiSelectController.selected,
                        );
                        final confirmed = await _confirmRemoveSelectedAudios(
                          selected,
                        );
                        if (!confirmed || !mounted) return;
                        setState(() => _isRemovingSelected = true);
                        try {
                          final oldPaths = List<String>.from(
                            widget.playlist.paths,
                          );
                          setState(() {
                            for (final item in selected) {
                              widget.playlist.removeByPath(item.path);
                            }
                            _refreshCoverFutures();
                          });
                          final saved = await savePlaylists();
                          if (!mounted) return;
                          if (!saved) {
                            setState(() {
                              widget.playlist.replacePaths(oldPaths);
                              _refreshCoverFutures();
                            });
                            showTextOnSnackBar('保存歌单失败');
                            return;
                          }
                          showTextOnSnackBar(
                            '已从歌单移除 ${selected.length} 首',
                          );
                          multiSelectController.useMultiSelectView(false);
                          multiSelectController.clear();
                        } finally {
                          if (mounted) {
                            setState(() => _isRemovingSelected = false);
                          }
                        }
                      },
            style: ButtonStyle(
              backgroundColor: WidgetStatePropertyAll(scheme.error),
              foregroundColor: WidgetStatePropertyAll(scheme.onError),
            ),
            icon: _isRemovingSelected
                ? const SizedBox(
                    width: 20.0,
                    height: 20.0,
                    child: CircularProgressIndicator(strokeWidth: 2.0),
                  )
                : const Icon(Symbols.delete),
          ),
        ),
        if (!_isRemovingSelected)
          MultiSelectSelectOrClearAll(
            multiSelectController: multiSelectController,
            contentList: contentList,
          ),
        if (!_isRemovingSelected)
          MultiSelectExit(multiSelectController: multiSelectController),
      ],
      sortMethods: sortMethods,
      onSortMethodChanged: _onSortChanged,
      onPrimaryPicTap: _isPickingCover ? null : _changeCover,
      primaryPicBusy: _isPickingCover,
      bodyOverride: contentList.isEmpty
          ? const _EmptyPlaylistBody()
          : _isReordering && canReorder
              ? _buildReorderBody(contentList, scheme)
              : null,
      extraActions: canReorder
          ? [
              SizedBox(
                height: 40.0,
                child: Material(
                  borderRadius: BorderRadius.circular(12.0),
                  color: _isReordering
                      ? scheme.tertiaryContainer
                      : scheme.primaryContainer,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12.0),
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
        final oldPaths = List<String>.from(widget.playlist.paths);
        setState(() {
          final item = paths.removeAt(oldIndex);
          paths.insert(newIndex, item);
          widget.playlist.replacePaths(paths);
          _refreshCoverFutures();
        });
        savePlaylists().then((saved) {
          if (saved || !mounted) return;
          setState(() {
            widget.playlist.replacePaths(oldPaths);
            _refreshCoverFutures();
          });
          showTextOnSnackBar('保存歌单失败');
        });
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
                  child: Icon(Symbols.drag_indicator,
                      color: scheme.onSurfaceVariant),
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
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 13),
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

class _EmptyPlaylistBody extends StatelessWidget {
  const _EmptyPlaylistBody();

  @override
  Widget build(BuildContext context) {
    return const QuietEmptyState(
      icon: Symbols.playlist_add,
      title: '这个歌单还没有歌曲',
      message: '可以从歌曲菜单或搜索结果里把音乐加入歌单。',
    );
  }
}
