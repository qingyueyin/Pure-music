import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/page/playlist_cover_picker.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'dart:typed_data';

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
      builder: (context) => _NewPlaylistDialog(
        existingNames: PLAYLISTS.map((p) => p.name).toSet(),
      ),
    );
    if (name == null) return;
    setState(() {
      PLAYLISTS.add(Playlist(name, []));
    });
    await savePlaylists();
  }

  void editPlaylist(
    BuildContext context,
    Playlist playlist,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _EditPlaylistDialog(
        currentName: playlist.name,
        existingNames: PLAYLISTS
            .map((p) => p.name)
            .where((n) => n != playlist.name)
            .toSet(),
      ),
    );
    if (name == null) return;
    setState(() {
      playlist.name = name;
    });
    await savePlaylists();
  }

  Future<void> importPlaylist() async {
    final pl = await importPlaylistFromFile();
    if (pl == null) return;
    if (!mounted) return;
    if (PLAYLISTS.any((p) => p.name == pl.name)) {
      showTextOnSnackBar('歌单"${pl.name}"已存在');
      return;
    }
    setState(() {
      PLAYLISTS.add(pl);
    });
    await savePlaylists();
    if (!mounted) return;
    showTextOnSnackBar('成功导入歌单"${pl.name}"（${pl.paths.length}首）');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final menuStyle = appMenuStyle;
    final menuItemStyle = appMenuItemStyle;

    return UniPage<Playlist>(
      pref: AppPreference.instance.playlistsPagePref,
      title: '歌单',
      subtitle: '${PLAYLISTS.length} 个歌单',
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
                child: const Text('打开'),
              ),
              MenuItemButton(
                style: menuItemStyle,
                onPressed: () => editPlaylist(context, playlist),
                leadingIcon: const Icon(Symbols.edit),
                child: const Text('编辑'),
              ),
              MenuItemButton(
                style: menuItemStyle,
                onPressed: () async {
                  await showCoverPicker(context, playlist);
                  setState(() {});
                },
                leadingIcon: const Icon(Symbols.brush),
                child: const Text('更换封面'),
              ),
              MenuItemButton(
                style: menuItemStyle,
                onPressed: () async {
                  setState(() {
                    PLAYLISTS.remove(playlist);
                  });
                  await savePlaylists();
                },
                leadingIcon: Icon(Symbols.delete, color: scheme.error),
                child: const Text('删除'),
              ),
              MenuItemButton(
                style: menuItemStyle,
                onPressed: () => exportPlaylistToFile(playlist),
                leadingIcon: const Icon(Symbols.file_export),
                child: const Text('导出'),
              ),
              if (multiSelectController != null)
                MenuItemButton(
                  style: menuItemStyle,
                  onPressed: () {
                    multiSelectController.useMultiSelectView(true);
                    multiSelectController.select(playlist);
                  },
                  leadingIcon: const Icon(Symbols.select),
                  child: const Text('多选'),
                ),
            ],
            builder: (context, controller, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                color:
                    isSelected ? scheme.secondaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(8.0),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8.0),
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
                  onSecondaryTapDown: (details) {
                    if (isMultiSelectView) return;
                    controller.open(
                      position: details.localPosition.translate(0, -240),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Row(children: [
                      _PlaylistCover(playlist: playlist),
                      const SizedBox(width: 16.0),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              playlist.name,
                              softWrap: false,
                              maxLines: 1,
                              style: const TextStyle(fontSize: 16),
                            ),
                            const SizedBox(height: 4.0),
                            Text(
                              '${playlist.paths.length}首乐曲',
                              softWrap: false,
                              maxLines: 1,
                              style: TextStyle(
                                color: scheme.onSurface.withAlpha(153),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isMultiSelectView)
                        Checkbox(
                          value: isSelected,
                          onChanged: (v) {
                            if (v == true) {
                              multiSelectController?.select(playlist);
                            } else {
                              multiSelectController?.unselect(playlist);
                            }
                          },
                        )
                      else ...[
                        IconButton(
                          tooltip: '编辑',
                          onPressed: () =>
                              editPlaylist(context, playlist),
                          icon: const Icon(Symbols.edit),
                        ),
                        const SizedBox(width: 8.0),
                        IconButton(
                          tooltip: '删除',
                          onPressed: () async {
                            setState(() {
                              PLAYLISTS.remove(playlist);
                            });
                            await savePlaylists();
                          },
                          color: scheme.error,
                          icon: const Icon(Symbols.delete),
                        ),
                      ],
                    ]),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      primaryAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.icon(
            onPressed: () => newPlaylist(context),
            icon: const Icon(Symbols.add),
            label: const Text('新建歌单'),
            style: const ButtonStyle(
              fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
            ),
          ),
          const SizedBox(width: 4),
          MenuAnchor(
            style: MenuStyle(
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
            ),
            menuChildren: [
              MenuItemButton(
                style: menuItemStyle,
                onPressed: () => importPlaylist(),
                leadingIcon: const Icon(Symbols.file_open),
                child: const Text('导入歌单'),
              ),
            ],
            builder: (context, controller, _) => SizedBox(
              height: 40,
              child: FilledButton.tonal(
                onPressed: () => controller.isOpen
                    ? controller.close()
                    : controller.open(),
                style: ButtonStyle(
                  padding:
                      const WidgetStatePropertyAll(EdgeInsets.zero),
                  minimumSize:
                      const WidgetStatePropertyAll(Size(32, 40)),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(20)),
                  ),
                ),
                child: AnimatedRotation(
                  turns: controller.isOpen ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 150),
                  child:
                      const Icon(Symbols.arrow_drop_down, size: 24),
                ),
              ),
            ),
          ),
        ],
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
            tooltip: '删除选中歌单',
            onPressed: multiSelectController.selected.isEmpty
                ? null
                : () async {
                    setState(() {
                      PLAYLISTS.removeWhere(
                        (p) => multiSelectController.selected.contains(p),
                      );
                    });
                    await savePlaylists();
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
          name: '名称',
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
          name: '歌曲数量',
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

class _NewPlaylistDialog extends StatefulWidget {
  final Set<String> existingNames;
  const _NewPlaylistDialog({required this.existingNames});

  @override
  State<_NewPlaylistDialog> createState() => _NewPlaylistDialogState();
}

class _NewPlaylistDialogState extends State<_NewPlaylistDialog> {
  late final _editingController = TextEditingController();
  String? _errorText;

  void _submit() {
    final name = _editingController.text.trim();
    if (name.isEmpty || widget.existingNames.contains(name)) {
      setState(() => _errorText = '该名称已存在');
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  void dispose() {
    _editingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
                  '新建歌单',
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
                  controller: _editingController,
                  onChanged: (_) {
                    if (_errorText != null) setState(() => _errorText = null);
                  },
                  onSubmitted: (value) => _submit(),
                  decoration: InputDecoration(
                    labelText: '歌单名称',
                    border: const OutlineInputBorder(),
                    errorText: _errorText,
                  ),
                ),
              ),
              const SizedBox(height: 16.0),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8.0),
                  TextButton(
                    onPressed: _submit,
                    child: const Text('创建'),
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

class _EditPlaylistDialog extends StatefulWidget {
  final String currentName;
  final Set<String> existingNames;
  const _EditPlaylistDialog({
    required this.currentName,
    required this.existingNames,
  });

  @override
  State<_EditPlaylistDialog> createState() => _EditPlaylistDialogState();
}

class _EditPlaylistDialogState extends State<_EditPlaylistDialog> {
  late final _editingController =
      TextEditingController(text: widget.currentName);
  String? _errorText;

  void _submit() {
    final name = _editingController.text.trim();
    if (name.isEmpty || widget.existingNames.contains(name)) {
      setState(() => _errorText = '该名称已存在');
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  void dispose() {
    _editingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
                  '修改歌单',
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
                  controller: _editingController,
                  onChanged: (_) {
                    if (_errorText != null) setState(() => _errorText = null);
                  },
                  onSubmitted: (value) => _submit(),
                  decoration: InputDecoration(
                    labelText: '新歌单名称',
                    border: const OutlineInputBorder(),
                    errorText: _errorText,
                  ),
                ),
              ),
              const SizedBox(height: 16.0),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8.0),
                  TextButton(
                    onPressed: _submit,
                    child: const Text('确认'),
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

class _PlaylistCover extends StatefulWidget {
  final Playlist playlist;
  const _PlaylistCover({required this.playlist});

  @override
  State<_PlaylistCover> createState() => _PlaylistCoverState();
}

class _PlaylistCoverState extends State<_PlaylistCover> {
  Uint8List? _cached;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_PlaylistCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlist != widget.playlist ||
        oldWidget.playlist.coverSource != widget.playlist.coverSource) {
      _cached = null;
      _load();
    }
  }

  Future<void> _load() async {
    final custom = await widget.playlist.resolveCoverBytes();
    if (custom != null) {
      if (mounted) setState(() => _cached = custom);
      return;
    }
    final audios = widget.playlist.audios;
    if (audios.isEmpty) return;
    final bytes = await audios.first.loadSmallCoverBytes();
    if (mounted && bytes != null) {
      setState(() => _cached = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final overlayColor = (brightness == Brightness.light
            ? Colors.black
            : Colors.white)
        .withValues(alpha: 0.25);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: () async {
          await showCoverPicker(context, widget.playlist);
          _load();
        },
        child: Stack(
          children: [
            _cached != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8.0),
                    child: Image.memory(
                      _cached!,
                      width: 48.0,
                      height: 48.0,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => _placeholder(context),
                    ),
                  )
                : _placeholder(context),
            if (_isHovered)
              Container(
                width: 48.0,
                height: 48.0,
                decoration: BoxDecoration(
                  color: overlayColor,
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: const Icon(Symbols.brush, size: 20, color: Colors.white),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 48.0,
      height: 48.0,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: Icon(Symbols.queue_music, color: scheme.onSurface.withAlpha(100)),
    );
  }
}
