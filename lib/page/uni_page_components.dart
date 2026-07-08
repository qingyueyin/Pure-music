import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'package:pure_music/component/motion.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class ShufflePlay<T> extends StatelessWidget {
  final List<T> contentList;
  const ShufflePlay({super.key, required this.contentList});

  @override
  Widget build(BuildContext context) {
    final enabled = contentList.isNotEmpty;

    return FilledButton.icon(
      onPressed: enabled
          ? () => PlayService.instance.playbackService.shuffleAndPlay(
                contentList as List<Audio>,
              )
          : null,
      icon: const Icon(Symbols.shuffle),
      label: const Text('随机播放'),
      style: const ButtonStyle(
        fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
      ),
    );
  }
}

class SortMethodComboBox<T> extends StatelessWidget {
  final List<T> contentList;
  final List<SortMethodDesc<T>> sortMethods;
  final SortMethodDesc<T> currSortMethod;
  final void Function(SortMethodDesc<T> sortMethod) setSortMethod;
  const SortMethodComboBox({
    super.key,
    required this.sortMethods,
    required this.contentList,
    required this.currSortMethod,
    required this.setSortMethod,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return MenuAnchor(
      style: appMenuStyle,
      menuChildren: List.generate(
        sortMethods.length,
        (i) {
          final sortMethod = sortMethods[i];
          final selected = identical(sortMethod, currSortMethod);
          return MenuItemButton(
            style: const ButtonStyle(
              padding: WidgetStatePropertyAll(EdgeInsets.all(12)),
            ),
            leadingIcon: Icon(sortMethod.icon),
            trailingIcon: selected ? const Icon(Symbols.check) : null,
            onPressed: selected ? null : () => setSortMethod(sortMethod),
            child: Text(sortMethod.name),
          );
        },
      ),
      builder: (context, menuController, _) {
        final borderRadius = BorderRadius.circular(20.0);

        return SizedBox(
          height: 40.0,
          child: Material(
            borderRadius: borderRadius,
            color: scheme.secondaryContainer,
            child: InkWell(
              hoverColor: scheme.onSecondaryContainer.withAlpha(20),
              borderRadius: borderRadius,
              onTap: () {
                if (menuController.isOpen) {
                  menuController.close();
                } else {
                  menuController.open();
                }
              },
              child: Padding(
                padding: const EdgeInsets.only(left: 16.0, right: 12.0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Symbols.sort,
                      size: 24,
                      color: scheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 4.0),
                    Text(
                      currSortMethod.name,
                      style: TextStyle(color: scheme.onSecondaryContainer),
                    ),
                    const SizedBox(width: 4.0),
                    AnimatedRotation(
                      duration: MotionDuration.fast,
                      curve: MotionCurve.standard,
                      turns: menuController.isOpen ? 0.5 : 0.0,
                      child: Icon(
                        Symbols.arrow_drop_down,
                        size: 24,
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class SortOrderSwitch<T> extends StatelessWidget {
  final SortOrder sortOrder;
  final void Function(SortOrder order) setSortOrder;
  const SortOrderSwitch(
      {super.key, required this.sortOrder, required this.setSortOrder});

  @override
  Widget build(BuildContext context) {
    var isAscending = sortOrder == SortOrder.ascending;
    return IconButton.filledTonal(
      tooltip: "切换排序顺序（${isAscending ? "升序" : "降序"}）",
      onPressed: () => setSortOrder(
        isAscending ? SortOrder.decending : SortOrder.ascending,
      ),
      icon: AnimatedSwitcher(
        duration: MotionDuration.fast,
        switchInCurve: MotionCurve.standard,
        switchOutCurve: MotionCurve.standard,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: animation, child: child),
        ),
        child: Icon(
          isAscending ? Symbols.arrow_upward : Symbols.arrow_downward,
          key: ValueKey(isAscending),
        ),
      ),
    );
  }
}

class ContentViewSwitch<T> extends StatelessWidget {
  final ContentView contentView;
  final void Function(ContentView contentView) setContentView;
  const ContentViewSwitch(
      {super.key, required this.contentView, required this.setContentView});

  @override
  Widget build(BuildContext context) {
    var isListView = contentView == ContentView.list;
    return IconButton.filledTonal(
      tooltip: "切换页面视图（${isListView ? "列表" : "表格"}）",
      onPressed: () => setContentView(
        isListView ? ContentView.table : ContentView.list,
      ),
      icon: AnimatedSwitcher(
        duration: MotionDuration.fast,
        switchInCurve: MotionCurve.standard,
        switchOutCurve: MotionCurve.standard,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: animation, child: child),
        ),
        child: Icon(
          isListView ? Symbols.list : Symbols.table,
          key: ValueKey(isListView),
        ),
      ),
    );
  }
}

List<Audio> _uniqueAudiosByPath(Iterable<Audio> audios) {
  final map = <String, Audio>{};
  for (final audio in audios) {
    map[audio.path] = audio;
  }
  return map.values.toList();
}

int _addMissingAudiosToPlaylist(Playlist playlist, Iterable<Audio> audios) {
  var addedCount = 0;
  for (final audio in _uniqueAudiosByPath(audios)) {
    if (!playlist.containsPath(audio.path)) {
      playlist.addPath(audio.path);
      addedCount++;
    }
  }
  return addedCount;
}

int _addableAudioCount(Playlist playlist, Iterable<Audio> audios) {
  var count = 0;
  for (final audio in _uniqueAudiosByPath(audios)) {
    if (!playlist.containsPath(audio.path)) count++;
  }
  return count;
}

class AddAllToPlaylist extends StatefulWidget {
  const AddAllToPlaylist({super.key, required this.multiSelectController});

  final MultiSelectController<Audio> multiSelectController;

  @override
  State<AddAllToPlaylist> createState() => _AddAllToPlaylistState();
}

class _AddAllToPlaylistState extends State<AddAllToPlaylist> {
  Playlist? _addingPlaylist;

  Future<void> _addToPlaylist(Playlist playlist) async {
    if (_addingPlaylist != null) return;

    final selected = _uniqueAudiosByPath(widget.multiSelectController.selected);
    if (selected.isEmpty) return;
    setState(() => _addingPlaylist = playlist);
    try {
      final oldPaths = List<String>.from(playlist.paths);
      final addedCount = _addMissingAudiosToPlaylist(playlist, selected);
      if (addedCount == 0) {
        if (!mounted) return;
        showTextOnSnackBar('选中歌曲已在歌单“${playlist.name}”中');
        return;
      }
      final saved = await savePlaylists();
      if (!mounted) return;
      if (!saved) {
        playlist.replacePaths(oldPaths);
        showTextOnSnackBar('保存歌单失败');
        return;
      }
      showTextOnSnackBar(
        '成功将$addedCount首添加到歌单“${playlist.name}”',
      );
    } finally {
      if (mounted) {
        setState(() => _addingPlaylist = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.multiSelectController,
      builder: (context, _) {
        final selectedAudios =
            _uniqueAudiosByPath(widget.multiSelectController.selected);
        final addableCounts = playlists
            .map((playlist) => _addableAudioCount(playlist, selectedAudios))
            .toList(growable: false);
        return MenuAnchor(
          style: appMenuStyle,
          menuChildren: List.generate(
            playlists.length,
            (i) {
              final playlist = playlists[i];
              final isAdding = identical(_addingPlaylist, playlist);
              final addableCount = addableCounts[i];
              final allAlreadyAdded =
                  selectedAudios.isNotEmpty && addableCount == 0;
              return MenuItemButton(
                style: const ButtonStyle(
                  padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 20),
                  ),
                ),
                onPressed: _addingPlaylist == null && addableCount > 0
                    ? () => _addToPlaylist(playlist)
                    : null,
                leadingIcon: isAdding
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        allAlreadyAdded ? Symbols.check : Symbols.queue_music,
                      ),
                child: Text(playlist.name),
              );
            },
          ),
          builder: (context, controller, _) {
            final enabled = canOpenAddToPlaylistMenu(
              hasSelectedAudios: selectedAudios.isNotEmpty,
              isAdding: _addingPlaylist != null,
              addableCounts: addableCounts,
            );
            final isAdding = _addingPlaylist != null;
            return FilledButton.icon(
              onPressed: enabled
                  ? () {
                      if (controller.isOpen) {
                        controller.close();
                      } else {
                        controller.open();
                      }
                    }
                  : null,
              icon: isAdding
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Symbols.add),
              label: Text(isAdding ? '添加中' : '添加到歌单'),
              style: const ButtonStyle(
                fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
              ),
            );
          },
        );
      },
    );
  }
}

class AddSelectedAudiosToPlaylist<T> extends StatefulWidget {
  const AddSelectedAudiosToPlaylist({
    super.key,
    required this.multiSelectController,
    required this.toAudios,
  });

  final MultiSelectController<T> multiSelectController;
  final List<Audio> Function(Set<T> selected) toAudios;

  @override
  State<AddSelectedAudiosToPlaylist<T>> createState() =>
      _AddSelectedAudiosToPlaylistState<T>();
}

class _AddSelectedAudiosToPlaylistState<T>
    extends State<AddSelectedAudiosToPlaylist<T>> {
  Playlist? _addingPlaylist;

  Future<void> _addToPlaylist(Playlist playlist) async {
    if (_addingPlaylist != null) return;

    final selectedAudios = _uniqueAudiosByPath(
        widget.toAudios(widget.multiSelectController.selected));
    if (selectedAudios.isEmpty) return;
    setState(() => _addingPlaylist = playlist);
    try {
      final oldPaths = List<String>.from(playlist.paths);
      final addedCount = _addMissingAudiosToPlaylist(playlist, selectedAudios);
      if (addedCount == 0) {
        if (!mounted) return;
        showTextOnSnackBar('选中歌曲已在歌单“${playlist.name}”中');
        return;
      }
      final saved = await savePlaylists();
      if (!mounted) return;
      if (!saved) {
        playlist.replacePaths(oldPaths);
        showTextOnSnackBar('保存歌单失败');
        return;
      }
      showTextOnSnackBar(
        '成功将$addedCount首添加到歌单“${playlist.name}”',
      );
    } finally {
      if (mounted) {
        setState(() => _addingPlaylist = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.multiSelectController,
      builder: (context, _) {
        final selectedAudios = _uniqueAudiosByPath(
          widget.toAudios(widget.multiSelectController.selected),
        );
        final addableCounts = playlists
            .map((playlist) => _addableAudioCount(playlist, selectedAudios))
            .toList(growable: false);
        return MenuAnchor(
          style: appMenuStyle,
          menuChildren: List.generate(
            playlists.length,
            (i) {
              final playlist = playlists[i];
              final isAdding = identical(_addingPlaylist, playlist);
              final addableCount = addableCounts[i];
              final allAlreadyAdded =
                  selectedAudios.isNotEmpty && addableCount == 0;
              return MenuItemButton(
                style: const ButtonStyle(
                  padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 20),
                  ),
                ),
                onPressed: _addingPlaylist == null && addableCount > 0
                    ? () => _addToPlaylist(playlist)
                    : null,
                leadingIcon: isAdding
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        allAlreadyAdded ? Symbols.check : Symbols.queue_music,
                      ),
                child: Text(playlist.name),
              );
            },
          ),
          builder: (context, controller, _) {
            final enabled = canOpenAddToPlaylistMenu(
              hasSelectedAudios: selectedAudios.isNotEmpty,
              isAdding: _addingPlaylist != null,
              addableCounts: addableCounts,
            );
            final isAdding = _addingPlaylist != null;
            return FilledButton.icon(
              onPressed: enabled
                  ? () {
                      if (controller.isOpen) {
                        controller.close();
                      } else {
                        controller.open();
                      }
                    }
                  : null,
              icon: isAdding
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Symbols.add),
              label: Text(isAdding ? '添加中' : '添加到歌单'),
              style: const ButtonStyle(
                fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
              ),
            );
          },
        );
      },
    );
  }
}

class MultiSelectPlaySelectedAudios<T> extends StatelessWidget {
  const MultiSelectPlaySelectedAudios({
    super.key,
    required this.multiSelectController,
    required this.toAudios,
    this.shuffle = false,
  });

  final MultiSelectController<T> multiSelectController;
  final List<Audio> Function(Set<T> selected) toAudios;
  final bool shuffle;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: multiSelectController,
      builder: (context, _) {
        final audios =
            _uniqueAudiosByPath(toAudios(multiSelectController.selected));
        return FilledButton.icon(
          onPressed: audios.isEmpty
              ? null
              : () {
                  if (shuffle) {
                    PlayService.instance.playbackService.shuffleAndPlay(audios);
                  } else {
                    PlayService.instance.playbackService.play(0, audios);
                  }

                  multiSelectController.useMultiSelectView(false);
                  multiSelectController.clear();
                },
          icon: Icon(shuffle ? Symbols.shuffle : Symbols.play_arrow),
          label: Text(shuffle ? '随机播放' : '播放'),
          style: const ButtonStyle(
            fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
          ),
        );
      },
    );
  }
}

class MultiSelectSelectOrClearAll<T> extends StatelessWidget {
  final MultiSelectController<T> multiSelectController;
  final List<T> contentList;

  const MultiSelectSelectOrClearAll(
      {super.key,
      required this.multiSelectController,
      required this.contentList});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: multiSelectController,
      builder: (context, _) {
        final allSelected = areAllContentItemsSelected(
          contentList: contentList,
          selectedItems: multiSelectController.selected,
        );
        return IconButton.filledTonal(
          tooltip: allSelected ? '取消全选' : '全选',
          onPressed: contentList.isEmpty
              ? null
              : () {
                  if (allSelected) {
                    multiSelectController.clear();
                  } else {
                    multiSelectController.selectAll(contentList);
                  }
                },
          icon: Icon(
            allSelected ? Symbols.deselect : Symbols.select_all,
          ),
        );
      },
    );
  }
}

class MultiSelectExit<T> extends StatelessWidget {
  final MultiSelectController<T> multiSelectController;

  const MultiSelectExit({super.key, required this.multiSelectController});

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: '退出多选视图',
      onPressed: () {
        multiSelectController.useMultiSelectView(false);
        multiSelectController.clear();
      },
      icon: const Icon(Symbols.cancel),
    );
  }
}
