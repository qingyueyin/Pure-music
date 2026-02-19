import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/enums.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

class PlaylistsPage extends StatefulWidget {
  const PlaylistsPage({super.key});

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  final multiSelectController = MultiSelectController<Playlist>();

  void newPlaylist(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _NewPlaylistDialog(),
    );
    if (name == null) return;
    setState(() {
      PLAYLISTS.add(Playlist(name, {}));
    });
  }

  void editPlaylist(
    BuildContext context,
    Playlist playlist,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _EditPlaylistDialog(),
    );
    if (name == null) return;
    setState(() {
      playlist.name = name;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final menuStyle = MenuStyle(
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
    final menuItemStyle = ButtonStyle(
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );

    return UniPage<Playlist>(
      pref: AppPreference.instance.playlistsPagePref,
      title: "歌单",
      subtitle: "${PLAYLISTS.length} 个歌单",
      contentList: PLAYLISTS,
      contentBuilder: (context, item, i, multiSelectController, _) {
        final playlist = PLAYLISTS[i];
        final isSelected =
            multiSelectController?.selected.contains(playlist) == true;
        final isMultiSelectView =
            multiSelectController?.enableMultiSelectView == true;
        return MenuTheme(
          data: MenuThemeData(style: menuStyle),
          child: MenuAnchor(
            consumeOutsideTap: true,
            style: menuStyle,
            menuChildren: [
              MenuItemButton(
                style: menuItemStyle,
                onPressed: () => context.push(
                  app_paths.PLAYLIST_DETAIL_PAGE,
                  extra: playlist,
                ),
                leadingIcon: const Icon(Symbols.open_in_new),
                child: const Text("打开"),
              ),
              MenuItemButton(
                style: menuItemStyle,
                onPressed: () => editPlaylist(context, playlist),
                leadingIcon: const Icon(Symbols.edit),
                child: const Text("编辑"),
              ),
              MenuItemButton(
                style: menuItemStyle,
                onPressed: () => setState(() {
                  PLAYLISTS.remove(playlist);
                }),
                leadingIcon: Icon(Symbols.delete, color: scheme.error),
                child: const Text("删除"),
              ),
              if (multiSelectController != null)
                MenuItemButton(
                  style: menuItemStyle,
                  onPressed: () {
                    multiSelectController.useMultiSelectView(true);
                    multiSelectController.select(playlist);
                  },
                  leadingIcon: const Icon(Symbols.select),
                  child: const Text("多选"),
                ),
            ],
            builder: (context, controller, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                color:
                    isSelected ? scheme.secondaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(8.0),
              ),
              child: ListTile(
                title: Text(
                  playlist.name,
                  softWrap: false,
                  maxLines: 1,
                ),
                subtitle: Text(
                  "${playlist.audios.length}首乐曲",
                  softWrap: false,
                  maxLines: 1,
                ),
                trailing: isMultiSelectView
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: "编辑",
                            onPressed: () => editPlaylist(context, playlist),
                            icon: const Icon(Symbols.edit),
                          ),
                          const SizedBox(width: 8.0),
                          IconButton(
                            tooltip: "删除",
                            onPressed: () => setState(() {
                              PLAYLISTS.remove(playlist);
                            }),
                            color: scheme.error,
                            icon: const Icon(Symbols.delete),
                          ),
                        ],
                      ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8.0),
                ),
                onTap: () {
                  if (controller.isOpen) {
                    controller.close();
                    return;
                  }
                  if (!isMultiSelectView) {
                    context.push(
                      app_paths.PLAYLIST_DETAIL_PAGE,
                      extra: playlist,
                    );
                    return;
                  }
                  if (isSelected) {
                    multiSelectController?.unselect(playlist);
                  } else {
                    multiSelectController?.select(playlist);
                  }
                },
                onLongPress: () {
                  if (multiSelectController == null) return;
                  if (isMultiSelectView) return;
                  multiSelectController.useMultiSelectView(true);
                  multiSelectController.select(playlist);
                },
              ),
            ),
          ),
        );
      },
      primaryAction: FilledButton.icon(
        onPressed: () => newPlaylist(context),
        icon: const Icon(Symbols.add),
        label: const Text("新建歌单"),
        style: const ButtonStyle(
          fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
        ),
      ),
      enableShufflePlay: false,
      enableSortMethod: true,
      enableSortOrder: true,
      enableContentViewSwitch: true,
      multiSelectController: multiSelectController,
      multiSelectViewActions: [
        ListenableBuilder(
          listenable: multiSelectController,
          builder: (context, _) => IconButton.filled(
            tooltip: "删除选中歌单",
            onPressed: multiSelectController.selected.isEmpty
                ? null
                : () {
                    setState(() {
                      PLAYLISTS.removeWhere(
                        (p) => multiSelectController.selected.contains(p),
                      );
                    });
                    multiSelectController.useMultiSelectView(false);
                    multiSelectController.clear();
                  },
            style: ButtonStyle(
              backgroundColor: WidgetStatePropertyAll(scheme.error),
              foregroundColor: WidgetStatePropertyAll(scheme.onError),
            ),
            icon: const Icon(Symbols.delete),
          ),
        ),
        MultiSelectSelectOrClearAll(
          multiSelectController: multiSelectController,
          contentList: PLAYLISTS,
        ),
        MultiSelectExit(multiSelectController: multiSelectController),
      ],
      sortMethods: [
        SortMethodDesc(
          icon: Symbols.title,
          name: "名称",
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.name.naturalCompareTo(b.name));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.name.naturalCompareTo(a.name));
                break;
            }
          },
        ),
        SortMethodDesc(
          icon: Symbols.music_note,
          name: "歌曲数量",
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.audios.length.compareTo(b.audios.length));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.audios.length.compareTo(a.audios.length));
                break;
            }
          },
        ),
      ],
    );
  }
}

class _NewPlaylistDialog extends StatelessWidget {
  const _NewPlaylistDialog();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final editingController = TextEditingController();

    return Dialog(
      insetPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: SizedBox(
        width: 350.0,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Text(
                  "新建歌单",
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 18.0,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Focus(
                onFocusChange: HotkeysHelper.onFocusChanges,
                child: TextField(
                  autofocus: true,
                  controller: editingController,
                  onSubmitted: (value) {
                    Navigator.pop(context, value);
                  },
                  decoration: const InputDecoration(
                    labelText: "歌单名称",
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 16.0),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text("取消"),
                  ),
                  const SizedBox(width: 8.0),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context, editingController.text);
                    },
                    child: const Text("创建"),
                  ),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}

class _EditPlaylistDialog extends StatelessWidget {
  const _EditPlaylistDialog();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final editingController = TextEditingController();

    return Dialog(
      insetPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: SizedBox(
        width: 350.0,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Text(
                  "修改歌单",
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 18.0,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Focus(
                onFocusChange: HotkeysHelper.onFocusChanges,
                child: TextField(
                  autofocus: true,
                  controller: editingController,
                  onSubmitted: (value) {
                    Navigator.pop(context, value);
                  },
                  decoration: const InputDecoration(
                    labelText: "新歌单名称",
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 16.0),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text("取消"),
                  ),
                  const SizedBox(width: 8.0),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context, editingController.text);
                    },
                    child: const Text("创建"),
                  ),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}
