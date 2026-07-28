import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';

import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/playlist_cover_picker.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/native/folder_picker_windows.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
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
  final Set<Playlist> _deletingPlaylists = <Playlist>{};
  final Set<Playlist> _exportingPlaylists = <Playlist>{};
  bool _isImportingPlaylist = false;
  bool _isImportingFolder = false;
  bool _isDeletingSelected = false;

  void newPlaylist(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _NewPlaylistDialog(
        existingNames: playlists.map((p) => p.name).toSet(),
      ),
    );
    if (name == null) return;
    if (!mounted) return;
    final playlist = Playlist(name, []);
    setState(() {
      playlists.add(playlist);
    });
    final saved = await savePlaylists();
    if (!saved) {
      playlists.remove(playlist);
      if (!mounted) return;
      setState(() {});
      showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
    } else if (mounted) {
      showTextOnSnackBar('已创建歌单', variant: ToastVariant.success);
    }
  }

  void editPlaylist(
    BuildContext context,
    Playlist playlist,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _EditPlaylistDialog(
        currentName: playlist.name,
        existingNames: playlists
            .map((p) => p.name)
            .where((n) => n != playlist.name)
            .toSet(),
      ),
    );
    if (name == null) return;
    if (!mounted) return;
    final oldName = playlist.name;
    setState(() {
      playlist.name = name;
    });
    final saved = await savePlaylists();
    if (!saved) {
      playlist.name = oldName;
      if (!mounted) return;
      setState(() {});
      showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
    } else if (mounted) {
      showTextOnSnackBar('已重命名歌单', variant: ToastVariant.success);
    }
  }

  Future<void> importPlaylist() async {
    if (_isImportingPlaylist) return;
    setState(() => _isImportingPlaylist = true);
    try {
      final pl = await importPlaylistFromFile();
      if (pl == null) return;
      if (!mounted) return;
      if (hasEquivalentPlaylistName(
        existingNames: playlists.map((p) => p.name),
        targetName: pl.name,
      )) {
        showTextOnSnackBar('歌单已存在');
        return;
      }
      setState(() {
        playlists.add(pl);
      });
      final saved = await savePlaylists();
      if (!saved) {
        playlists.remove(pl);
        if (!mounted) return;
        setState(() {});
        showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
        return;
      }
      if (!mounted) return;
      showTextOnSnackBar('已导入歌单', variant: ToastVariant.success);
    } catch (err) {
      if (!mounted) return;
      showTextOnSnackBar('导入歌单失败', variant: ToastVariant.error);
    } finally {
      if (mounted) {
        setState(() => _isImportingPlaylist = false);
      }
    }
  }

  Future<void> importFolderAsPlaylist() async {
    if (_isImportingFolder) return;
    setState(() => _isImportingFolder = true);
    try {
      final paths = pickMultipleDirectories(title: '选择歌单文件夹');
      if (paths.isEmpty) return;
      if (!mounted) return;

      final folderPath = paths.first;
      final dir = Directory(folderPath);
      if (!dir.existsSync()) {
        showTextOnSnackBar('文件夹不存在', variant: ToastVariant.error);
        return;
      }

      final audioFiles = <String>[];
      final audioExtensions = <String>{
        'mp3', 'flac', 'wav', 'ogg', 'ape', 'm4a', 'wma', 'opus', 'aiff', 'aac',
      };

      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
          if (audioExtensions.contains(ext)) {
            audioFiles.add(entity.path);
          }
        }
      }

      if (audioFiles.isEmpty) {
        showTextOnSnackBar('文件夹中没有找到音乐文件');
        return;
      }

      final resolved = <String>[];
      final collection = AudioLibrary.instance.audioCollection;
      for (final raw in audioFiles) {
        if (collection.any((a) => a.path == raw)) {
          resolved.add(raw);
          continue;
        }
        final matchedPath = findImportedPlaylistLibraryPath(
          rawPath: raw,
          libraryPaths: collection.map((a) => a.path),
        );
        if (matchedPath != null) resolved.add(matchedPath);
      }

      if (resolved.isEmpty) {
        showTextOnSnackBar('文件夹中的音乐不在曲库中');
        return;
      }

      final folderName = p.basename(folderPath);
      final pl = Playlist(folderName, resolved);
      if (hasEquivalentPlaylistName(
        existingNames: playlists.map((p) => p.name),
        targetName: pl.name,
      )) {
        showTextOnSnackBar('歌单已存在');
        return;
      }

      setState(() => playlists.add(pl));
      final saved = await savePlaylists();
      if (!saved) {
        playlists.remove(pl);
        if (!mounted) return;
        setState(() {});
        showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
        return;
      }
      if (!mounted) return;
      showTextOnSnackBar('已导入歌单', variant: ToastVariant.success);
    } catch (err) {
      if (!mounted) return;
      showTextOnSnackBar('导入文件夹歌单失败', variant: ToastVariant.error);
    } finally {
      if (mounted) {
        setState(() => _isImportingFolder = false);
      }
    }
  }

  bool _isExportingPlaylist(Playlist playlist) {
    return _exportingPlaylists.contains(playlist);
  }

  Future<void> _exportPlaylist(Playlist playlist) async {
    if (_isExportingPlaylist(playlist) || _isDeletingPlaylist(playlist)) return;
    setState(() => _exportingPlaylists.add(playlist));
    try {
      final exported = await exportPlaylistToFile(playlist);
      if (!mounted || !exported) return;
      showTextOnSnackBar('已导出歌单', variant: ToastVariant.success);
    } catch (err) {
      if (!mounted) return;
      showTextOnSnackBar('导出歌单失败', variant: ToastVariant.error);
    } finally {
      if (mounted) {
        setState(() => _exportingPlaylists.remove(playlist));
      }
    }
  }

  Future<bool> _confirmDeletePlaylist(Playlist playlist) {
    return _confirmDeletePlaylists([playlist]);
  }

  Future<bool> _confirmDeletePlaylists(List<Playlist> playlists) async {
    final count = playlists.length;
    final songCount = playlists.fold<int>(
      0,
      (total, playlist) => total + playlist.paths.length,
    );
    final title = count == 1 ? '删除歌单？' : '删除选中歌单？';
    final message = count == 1
        ? '将删除歌单“${playlists.first.name}”，不会删除本地音乐文件。'
        : '将删除 $count 个歌单，共涉及 $songCount 首歌曲，不会删除本地音乐文件。';

    return showDangerConfirmDialog(
      context: context,
      title: title,
      message: message,
      confirmLabel: '删除',
    );
  }

  bool _isDeletingPlaylist(Playlist playlist) {
    return _deletingPlaylists.contains(playlist);
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    if (_isDeletingPlaylist(playlist)) return;
    final confirmed = await _confirmDeletePlaylist(playlist);
    if (!confirmed || !mounted) return;

    setState(() {
      _deletingPlaylists.add(playlist);
      playlists.remove(playlist);
    });
    try {
      final saved = await savePlaylists();
      if (!saved) {
        playlists.add(playlist);
        if (!mounted) return;
        setState(() {});
        showTextOnSnackBar('删除歌单失败', variant: ToastVariant.error);
      } else if (mounted) {
        showTextOnSnackBar('已删除歌单', variant: ToastVariant.success);
      }
    } finally {
      if (mounted) {
        setState(() => _deletingPlaylists.remove(playlist));
      }
    }
  }

  Future<void> _deleteSelectedPlaylists() async {
    if (_isDeletingSelected || multiSelectController.selected.isEmpty) return;
    final selected = List<Playlist>.from(multiSelectController.selected);
    final indexed = selected
        .map((playlist) => MapEntry(playlists.indexOf(playlist), playlist))
        .where((entry) => entry.key >= 0)
        .toList();
    final confirmed = await _confirmDeletePlaylists(selected);
    if (!confirmed || !mounted) return;

    setState(() {
      _isDeletingSelected = true;
      _deletingPlaylists.addAll(selected);
      playlists.removeWhere(selected.contains);
    });
    try {
      final saved = await savePlaylists();
      if (!mounted) return;
      if (saved) {
        multiSelectController.useMultiSelectView(false);
        multiSelectController.clear();
        showTextOnSnackBar('已删除', variant: ToastVariant.success);
      } else {
        for (final entry in indexed.reversed) {
          final index = entry.key.clamp(0, playlists.length).toInt();
          playlists.insert(index, entry.value);
        }
        setState(() {});
        showTextOnSnackBar('删除歌单失败', variant: ToastVariant.error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDeletingSelected = false;
          _deletingPlaylists.removeAll(selected);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final menuStyle = appMenuStyle;
    final menuItemStyle = appMenuItemStyle;
    final canSortPlaylists = hasEnoughItemsToSort(playlists.length);
    final canSwitchContentView = canShowContentViewSwitch(playlists.length);

    return UniPage<Playlist>(
      pref: AppPreference.instance.playlistsPagePref,
      title: '歌单',
      subtitle: '${playlists.length} 个歌单',
      contentList: playlists,
      contentBuilder: (context, item, i, multiSelectController, _) {
        final playlist = playlists[i];
        final isSelected =
            multiSelectController?.selected.contains(playlist) == true;
        final isMultiSelectView =
            multiSelectController?.enableMultiSelectView == true;
        final isDeleting = _isDeletingPlaylist(playlist);
        final isExporting = _isExportingPlaylist(playlist);
        final isBusy = isDeleting || isExporting;
        return MenuTheme(
          data: MenuThemeData(style: menuStyle),
          child: MenuAnchor(
            consumeOutsideTap: true,
            style: menuStyle,
            menuChildren: [
              MenuItemButton(
                style: menuItemStyle,
                onPressed: isBusy
                    ? null
                    : () => context.push(
                          app_paths.PLAYLIST_DETAIL_PAGE,
                          extra: playlist,
                        ),
                leadingIcon: const Icon(Symbols.open_in_new),
                child: const Text('打开'),
              ),
              MenuItemButton(
                style: menuItemStyle,
                onPressed:
                    isBusy ? null : () => editPlaylist(context, playlist),
                leadingIcon: const Icon(Symbols.edit),
                child: const Text('编辑'),
              ),
              MenuItemButton(
                style: menuItemStyle,
                onPressed: isBusy
                    ? null
                    : () async {
                        await showCoverPicker(context, playlist);
                        if (mounted) setState(() {});
                      },
                leadingIcon: const Icon(Symbols.brush),
                child: const Text('更换封面'),
              ),
              MenuItemButton(
                style: menuItemStyle,
                onPressed: isBusy ? null : () => _deletePlaylist(playlist),
                leadingIcon: isDeleting
                    ? const SizedBox(
                        width: 18.0,
                        height: 18.0,
                        child: CircularProgressIndicator(strokeWidth: 2.0),
                      )
                    : Icon(Symbols.delete, color: scheme.error),
                child: Text(isDeleting ? '删除中' : '删除'),
              ),
              MenuItemButton(
                style: menuItemStyle,
                onPressed: isBusy ? null : () => _exportPlaylist(playlist),
                leadingIcon: isExporting
                    ? const SizedBox(
                        width: 18.0,
                        height: 18.0,
                        child: CircularProgressIndicator(strokeWidth: 2.0),
                      )
                    : const Icon(Symbols.file_export),
                child: Text(isExporting ? '导出中' : '导出'),
              ),
              if (multiSelectController != null)
                MenuItemButton(
                  style: menuItemStyle,
                  onPressed: isBusy
                      ? null
                      : () {
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
                borderRadius: AppRadius.smCircular,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: AppRadius.smCircular,
                  onTap: isBusy
                      ? null
                      : () {
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
                  onLongPress: isBusy
                      ? null
                      : () {
                          if (multiSelectController == null) return;
                          if (isMultiSelectView) return;
                          multiSelectController.useMultiSelectView(true);
                          multiSelectController.select(playlist);
                        },
                  onSecondaryTapDown: (details) {
                    if (isBusy || isMultiSelectView) return;
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
                              style: const TextStyle(fontSize: AppType.subtitle),
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
                          onChanged: isBusy
                              ? null
                              : (v) {
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
                          onPressed: isBusy
                              ? null
                              : () => editPlaylist(context, playlist),
                          icon: const Icon(Symbols.edit),
                        ),
                        const SizedBox(width: 8.0),
                        IconButton(
                          tooltip: '删除',
                          onPressed:
                              isBusy ? null : () => _deletePlaylist(playlist),
                          color: scheme.error,
                          icon: isDeleting
                              ? const SizedBox(
                                  width: 20.0,
                                  height: 20.0,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.0,
                                  ),
                                )
                              : const Icon(Symbols.delete),
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
      primaryAction: MenuAnchor(
        style: appMenuStyle,
        menuChildren: [
          MenuItemButton(
            style: const ButtonStyle(
              padding: WidgetStatePropertyAll(EdgeInsets.all(12)),
            ),
            leadingIcon: const Icon(Symbols.add),
            onPressed: () => newPlaylist(context),
            child: const Text('新建歌单'),
          ),
          MenuItemButton(
            style: const ButtonStyle(
              padding: WidgetStatePropertyAll(EdgeInsets.all(12)),
            ),
            leadingIcon: _isImportingFolder
                ? const SizedBox(
                    width: 18.0,
                    height: 18.0,
                    child: CircularProgressIndicator(strokeWidth: 2.0),
                  )
                : const Icon(Symbols.folder_open),
            onPressed: _isImportingFolder ? null : () => importFolderAsPlaylist(),
            child: Text(_isImportingFolder ? '导入中' : '导入文件夹歌单'),
          ),
          MenuItemButton(
            style: const ButtonStyle(
              padding: WidgetStatePropertyAll(EdgeInsets.all(12)),
            ),
            leadingIcon: _isImportingPlaylist
                ? const SizedBox(
                    width: 18.0,
                    height: 18.0,
                    child: CircularProgressIndicator(strokeWidth: 2.0),
                  )
                : const Icon(Symbols.file_open),
            onPressed: _isImportingPlaylist ? null : () => importPlaylist(),
            child: Text(_isImportingPlaylist ? '导入中' : '导入歌单列表'),
          ),
        ],
        builder: (context, menuController, _) {
          return FilledButton.tonal(
            onPressed: () {
              if (menuController.isOpen) {
                menuController.close();
              } else {
                menuController.open();
              }
            },
            style: ButtonStyle(
              fixedSize: const WidgetStatePropertyAll(Size.fromHeight(40)),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 16),
              ),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Symbols.queue_music, size: 20),
                const SizedBox(width: 4.0),
                const Text('管理歌单'),
                const SizedBox(width: 4.0),
                    AnimatedRotation(
                      duration: const Duration(milliseconds: 200),
                  turns: menuController.isOpen ? 0.5 : 0.0,
                  child: const Icon(Symbols.arrow_drop_down, size: 20),
                ),
              ],
            ),
          );
        },
      ),
      enableShufflePlay: false,
      enableSortMethod: canSortPlaylists,
      enableSortOrder: canSortPlaylists,
      enableContentViewSwitch: canSwitchContentView,
      multiSelectController: multiSelectController,
      multiSelectViewActions: [
        ListenableBuilder(
          listenable: multiSelectController,
          builder: (context, _) => IconButton.filled(
            tooltip: '删除选中歌单',
            onPressed:
                multiSelectController.selected.isEmpty || _isDeletingSelected
                    ? null
                    : _deleteSelectedPlaylists,
            style: ButtonStyle(
              backgroundColor: WidgetStatePropertyAll(scheme.error),
              foregroundColor: WidgetStatePropertyAll(scheme.onError),
            ),
            icon: _isDeletingSelected
                ? const SizedBox(
                    width: 20.0,
                    height: 20.0,
                    child: CircularProgressIndicator(strokeWidth: 2.0),
                  )
                : const Icon(Symbols.delete),
          ),
        ),
        MultiSelectSelectOrClearAll(
          multiSelectController: multiSelectController,
          contentList: playlists,
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
                list.sort((a, b) => a.paths.length.compareTo(b.paths.length));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.paths.length.compareTo(a.paths.length));
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

  String get _trimmedName => _editingController.text.trim();

  bool get _canSubmit {
    final name = _trimmedName;
    return name.isNotEmpty &&
        !hasEquivalentPlaylistName(
          existingNames: widget.existingNames,
          targetName: name,
        );
  }

  void _onNameChanged(String value) {
    final name = value.trim();
    setState(() {
      _errorText = name.isNotEmpty &&
              hasEquivalentPlaylistName(
                existingNames: widget.existingNames,
                targetName: name,
              )
          ? '该名称已存在'
          : null;
    });
  }

  void _submit() {
    final name = _trimmedName;
    if (name.isEmpty) {
      setState(() => _errorText = '请输入歌单名称');
      return;
    }
    if (hasEquivalentPlaylistName(
      existingNames: widget.existingNames,
      targetName: name,
    )) {
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
    final width = (MediaQuery.sizeOf(context).width - 48.0)
        .clamp(280.0, 360.0)
        .toDouble();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.mdCircular,
      ),
      child: SizedBox(
        width: width,
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
                    fontSize: AppType.sectionTitle,
                    fontWeight: AppType.weightBold,
                  ),
                ),
              ),
              Focus(
                onFocusChange: HotkeysHelper.onFocusChanges,
                child: TextField(
                  autofocus: true,
                  controller: _editingController,
                  onChanged: _onNameChanged,
                  onSubmitted: (value) => _submit(),
                  decoration: InputDecoration(
                    labelText: '歌单名称',
                    border: const OutlineInputBorder(),
                    errorText: _errorText,
                  ),
                ),
              ),
              const SizedBox(height: 16.0),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8.0,
                overflowSpacing: 8.0,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: _canSubmit ? _submit : null,
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

  String get _trimmedName => _editingController.text.trim();

  bool get _canSubmit {
    final name = _trimmedName;
    return name.isNotEmpty &&
        name != widget.currentName &&
        !hasEquivalentPlaylistName(
          existingNames: widget.existingNames,
          targetName: name,
        );
  }

  void _onNameChanged(String value) {
    final name = value.trim();
    setState(() {
      _errorText = name.isNotEmpty &&
              hasEquivalentPlaylistName(
                existingNames: widget.existingNames,
                targetName: name,
              )
          ? '该名称已存在'
          : null;
    });
  }

  void _submit() {
    final name = _trimmedName;
    if (name.isEmpty) {
      setState(() => _errorText = '请输入歌单名称');
      return;
    }
    if (hasEquivalentPlaylistName(
      existingNames: widget.existingNames,
      targetName: name,
    )) {
      setState(() => _errorText = '该名称已存在');
      return;
    }
    if (name == widget.currentName) return;
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
    final width = (MediaQuery.sizeOf(context).width - 48.0)
        .clamp(280.0, 360.0)
        .toDouble();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.mdCircular,
      ),
      child: SizedBox(
        width: width,
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
                    fontSize: AppType.sectionTitle,
                    fontWeight: AppType.weightBold,
                  ),
                ),
              ),
              Focus(
                onFocusChange: HotkeysHelper.onFocusChanges,
                child: TextField(
                  autofocus: true,
                  controller: _editingController,
                  onChanged: _onNameChanged,
                  onSubmitted: (value) => _submit(),
                  decoration: InputDecoration(
                    labelText: '新歌单名称',
                    border: const OutlineInputBorder(),
                    errorText: _errorText,
                  ),
                ),
              ),
              const SizedBox(height: 16.0),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8.0,
                overflowSpacing: 8.0,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: _canSubmit ? _submit : null,
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
  ImageProvider? _cached;
  bool _isHovered = false;
  bool _isPickingCover = false;
  int _loadToken = 0;

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
    final token = ++_loadToken;
    final custom = await widget.playlist.resolveCoverProvider(size: 48);
    if (!mounted || token != _loadToken) return;
    if (custom != null) {
      setState(() => _cached = custom);
      return;
    }
    final firstAudio = widget.playlist.firstAudio;
    if (firstAudio == null) return;
    final bytes =
        firstAudio.smallCoverBytes ?? await firstAudio.loadSmallCoverBytes();
    if (!mounted || token != _loadToken) return;
    if (bytes != null) {
      setState(() => _cached = MemoryImage(bytes));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final overlayColor = scheme.onSurface.withValues(alpha: 0.25);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: _isPickingCover
            ? null
            : () async {
                setState(() => _isPickingCover = true);
                try {
                  await showCoverPicker(context, widget.playlist);
                  _load();
                } finally {
                  if (mounted) {
                    setState(() => _isPickingCover = false);
                  }
                }
              },
        child: Stack(
          children: [
            _cached != null
                ? ClipRRect(
                    borderRadius: AppRadius.smCircular,
                    child: RepaintBoundary(
                      child: Image(
                        key: ValueKey(_cached),
                        image: _cached!,
                        width: 48.0,
                        height: 48.0,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => _placeholder(context),
                      ),
                    ),
                  )
                : _placeholder(context),
            if (_isHovered || _isPickingCover)
              Container(
                width: 48.0,
                height: 48.0,
                decoration: BoxDecoration(
                  color: overlayColor,
                  borderRadius: AppRadius.smCircular,
                ),
                child: _isPickingCover
                    ? Center(
                        child: SizedBox(
                          width: 20.0,
                          height: 20.0,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.0,
                            color: scheme.onSurface,
                          ),
                        ),
                      )
                    : Icon(Symbols.brush, size: 20, color: scheme.onSurface),
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
        borderRadius: AppRadius.smCircular,
      ),
      child: Icon(Symbols.queue_music, color: scheme.onSurface.withAlpha(100)),
    );
  }
}
