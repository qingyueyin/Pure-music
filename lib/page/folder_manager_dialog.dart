import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/component/build_index_state_view.dart';
import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/native/folder_picker_windows.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;

Future<void> showFolderManagerDialog(BuildContext context) async {
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => const FolderManagerDialog(),
  );
}

class FolderManagerDialog extends StatefulWidget {
  const FolderManagerDialog({super.key});

  @override
  State<FolderManagerDialog> createState() => _FolderManagerDialogState();
}

class _FolderManagerDialogState extends State<FolderManagerDialog> {
  List<AudioFolder> folders = [];

  final applicationSupportDirectory = getAppDataDir();

  bool editing = true;
  bool building = false;
  bool _isPickingFolder = false;

  Widget? _buildView;

  @override
  void initState() {
    super.initState();
    folders = AudioLibrary.aggregatedRootFolders();
  }

  List<String> _folderPathKeys(Iterable<AudioFolder> folders) {
    return folderPathKeys(folders.map((f) => f.path));
  }

  void _appendUniqueFolders(Iterable<String> paths) {
    final existing = {
      for (final folder in folders) pendingFolderKey(folder.path): folder,
    };
    final next = appendUniquePendingFolders(
      current: folders.map((folder) => folder.path),
      incoming: paths,
    );
    folders = next
        .map(
          (path) =>
              existing[pendingFolderKey(path)] ?? AudioFolder([], path, 0, 0),
        )
        .toList();
  }

  bool get _hasFolderChanges {
    final current = _folderPathKeys(folders);
    final original = folderPathKeys(AppPreference.instance.userFolders);
    if (current.length != original.length) return true;
    for (var i = 0; i < current.length; i++) {
      if (current[i] != original[i]) return true;
    }
    return false;
  }

  bool _folderPathsOverlap(String first, String second) {
    final firstKey = pendingFolderKey(first);
    final secondKey = pendingFolderKey(second);
    if (firstKey.isEmpty || secondKey.isEmpty) return false;
    return firstKey == secondKey ||
        firstKey.startsWith('$secondKey/') ||
        secondKey.startsWith('$firstKey/');
  }

  List<_ManagedFolderGroup> _managedFolderGroups() {
    final foldersByParent = <String, List<AudioFolder>>{};
    final parentPaths = <String, String>{};
    for (final folder in folders) {
      final parentPath = p.windows.dirname(folder.path);
      final parentKey = pendingFolderKey(parentPath);
      if (parentKey.isEmpty || parentKey == pendingFolderKey(folder.path)) {
        continue;
      }
      parentPaths.putIfAbsent(parentKey, () => parentPath);
      foldersByParent.putIfAbsent(parentKey, () => []).add(folder);
    }

    final groupedParents = <String>{};
    final result = <_ManagedFolderGroup>[];
    for (final folder in folders) {
      final parentPath = p.windows.dirname(folder.path);
      final parentKey = pendingFolderKey(parentPath);
      final siblings = foldersByParent[parentKey];
      if (siblings != null && siblings.length > 1) {
        if (!groupedParents.add(parentKey)) continue;
        final rootPath = parentPaths[parentKey]!;
        result.add(
          _ManagedFolderGroup(
            path: rootPath,
            sourceFolders: siblings,
            tree: _buildFolderTree(rootPath, siblings),
          ),
        );
        continue;
      }
      result.add(
        _ManagedFolderGroup(
          path: folder.path,
          sourceFolders: [folder],
          tree: _buildFolderTree(folder.path, [folder]),
        ),
      );
    }
    return result;
  }

  _ManagedFolderTreeNode _buildFolderTree(
    String rootPath,
    Iterable<AudioFolder> sourceFolders,
  ) {
    final rootKey = pendingFolderKey(rootPath);
    final root = _MutableManagedFolderTreeNode(rootPath);
    if (rootKey.isEmpty) return root.freeze();

    _MutableManagedFolderTreeNode? nodeForPath(String folderPath) {
      final folderKey = pendingFolderKey(folderPath);
      if (folderKey == rootKey) return root;
      if (!folderKey.startsWith('$rootKey/')) return null;

      final relativePath = p.windows.relative(folderPath, from: rootPath);
      final segments = p.windows
          .split(relativePath)
          .where((segment) => segment.isNotEmpty && segment != '.')
          .toList();
      if (segments.isEmpty || segments.first == '..') return null;

      var current = root;
      var currentPath = rootPath;
      for (var i = 0; i < segments.length; i++) {
        final segment = segments[i];
        currentPath = p.windows.join(currentPath, segment);
        current = current.children.putIfAbsent(
          segment.toLowerCase(),
          () => _MutableManagedFolderTreeNode(
            i == segments.length - 1 ? folderPath : currentPath,
          ),
        );
      }
      return current;
    }

    for (final folder in AudioLibrary.instance.folders) {
      nodeForPath(folder.path)?.directAudioCount += folder.audios.length;
    }
    for (final folder in sourceFolders) {
      final node = nodeForPath(folder.path);
      if (node == null) continue;
      node.sourceFolder = folder;
      node.pendingScan = !containsEquivalentFolderPath(
        paths: AppPreference.instance.userFolders,
        target: folder.path,
      );
    }

    return root.freeze();
  }

  Future<bool> _confirmRemoveFolder(String folderPath) async {
    final scheme = Theme.of(context).colorScheme;
    return showDangerConfirmDialog(
      context: context,
      title: '从曲库移除文件夹？',
      message: '不会删除本地音乐文件，只会从 Pure Music 的曲库扫描范围中移除。',
      confirmLabel: '移除',
      details: Text(
        folderPath,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: AppType.caption,
        ),
      ),
    );
  }

  Future<void> _removeManagedFolders(
    String displayPath,
    Iterable<AudioFolder> sourceFolders,
  ) async {
    final confirmed = await _confirmRemoveFolder(displayPath);
    if (!confirmed || !mounted) return;
    final removedFolders = sourceFolders.toSet();
    setState(() {
      folders.removeWhere(removedFolders.contains);
    });
  }

  void _startBuild() {
    building = true;
    _buildView = FutureBuilder(
      future: applicationSupportDirectory,
      builder: (context, snapshot) {
        if (snapshot.data == null) {
          return const Center(child: Text('Fail to get app data dir.'));
        }
        return Center(
          child: BuildIndexStateView(
            key: const ValueKey('index_builder'),
            indexPath: snapshot.data!,
            folders: folders.map((f) => f.path).toList(),
            whenIndexBuilt: () async {
              await Future.wait([
                AudioLibrary.initFromIndex(),
                readPlaylists(),
                readLyricSources(),
              ]);
              AlbumColorCache.instance
                  .prewarmAlbums(AudioLibrary.instance.albumCollection.values)
                  .ignore();
              if (context.mounted) {
                Navigator.pop(context);
              }
            },
          ),
        );
      },
    );
    setState(() {
      editing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48.0).clamp(320.0, 520.0).toDouble();
    final height = (size.height - 96.0).clamp(320.0, 520.0).toDouble();
    final canApplyChanges = !building && !_isPickingFolder && _hasFolderChanges;
    final managedFolders = _managedFolderGroups();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      child: SizedBox(
        height: height,
        width: width,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '管理文件夹',
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: AppType.sectionTitle,
                        fontWeight: AppType.weightBold,
                      ),
                    ),
                    Text(
                      '${managedFolders.length} 个文件夹',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: AppType.caption,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: editing
                      ? folders.isEmpty
                            ? const _EmptyManagedFolderState()
                            : ListView.builder(
                                key: const ValueKey('folder_list'),
                                itemCount: managedFolders.length,
                                itemBuilder: (context, i) {
                                  final folder = managedFolders[i];
                                  return _ManagedFolderTile(
                                    key: ValueKey(
                                      folder.sourceFolders
                                          .map(
                                            (source) =>
                                                pendingFolderKey(source.path),
                                          )
                                          .join('|'),
                                    ),
                                    tree: folder.tree,
                                    onRemove: building || _isPickingFolder
                                        ? null
                                        : () => _removeManagedFolders(
                                            folder.path,
                                            folder.sourceFolders,
                                          ),
                                    onRemoveFolder: building || _isPickingFolder
                                        ? null
                                        : (source) => _removeManagedFolders(
                                            source.path,
                                            [source],
                                          ),
                                  );
                                },
                              )
                      : (_buildView ?? const SizedBox(key: ValueKey('empty'))),
                ),
              ),
              const SizedBox(height: 16.0),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8.0,
                overflowSpacing: 8.0,
                children: [
                  TextButton.icon(
                    onPressed: building || _isPickingFolder
                        ? null
                        : () async {
                            setState(() => _isPickingFolder = true);
                            await Future<void>.delayed(Duration.zero);

                            try {
                              final paths = pickMultipleDirectories(
                                title: '选择文件夹',
                              );
                              if (paths.isEmpty || !context.mounted) return;

                              setState(() {
                                _appendUniqueFolders(paths);
                              });
                            } finally {
                              if (context.mounted) {
                                setState(() => _isPickingFolder = false);
                              }
                            }
                          },
                    icon: _isPickingFolder
                        ? const SizedBox(
                            width: 18.0,
                            height: 18.0,
                            child: CircularProgressIndicator(strokeWidth: 2.0),
                          )
                        : const Icon(Symbols.create_new_folder),
                    label: Text(_isPickingFolder ? '选择中' : '添加'),
                  ),
                  TextButton(
                    onPressed: building || _isPickingFolder
                        ? null
                        : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: !canApplyChanges
                        ? null
                        : () async {
                            final kept = folders.map((f) => f.path).toList();
                            final original = List<String>.from(
                              AppPreference.instance.userFolders,
                            );
                            final oldUserFolders = List<String>.from(
                              AppPreference.instance.userFolders,
                            );
                            final oldExcludedFolderPaths = List<String>.from(
                              AppPreference.instance.excludedFolderPaths,
                            );

                            final added = kept
                                .where(
                                  (f) => !containsEquivalentFolderPath(
                                    paths: original,
                                    target: f,
                                  ),
                                )
                                .toList();
                            final removed = original
                                .where(
                                  (f) => !containsEquivalentFolderPath(
                                    paths: kept,
                                    target: f,
                                  ),
                                )
                                .toList();

                            final userFolderKeys = AppPreference
                                .instance
                                .userFolders
                                .map(pendingFolderKey)
                                .toSet();
                            AppPreference.instance.userFolders.addAll(
                              added.where(
                                (f) => userFolderKeys.add(pendingFolderKey(f)),
                              ),
                            );
                            AppPreference.instance.userFolders.removeWhere(
                              (f) => !containsEquivalentFolderPath(
                                paths: kept,
                                target: f,
                              ),
                            );
                            AppPreference.instance.excludedFolderPaths
                                .removeWhere(
                                  (excluded) => kept.any(
                                    (root) =>
                                        _folderPathsOverlap(excluded, root),
                                  ),
                                );
                            final excludedFolderKeys = AppPreference
                                .instance
                                .excludedFolderPaths
                                .map(pendingFolderKey)
                                .toSet();
                            AppPreference.instance.excludedFolderPaths.addAll(
                              removed
                                  .where(
                                    (removedPath) => !kept.any(
                                      (root) => _folderPathsOverlap(
                                        removedPath,
                                        root,
                                      ),
                                    ),
                                  )
                                  .where(
                                    (f) => excludedFolderKeys.add(
                                      pendingFolderKey(f),
                                    ),
                                  ),
                            );
                            final saved = await AppPreference.instance.save();
                            if (!saved) {
                              AppPreference.instance.userFolders =
                                  oldUserFolders;
                              AppPreference.instance.excludedFolderPaths =
                                  oldExcludedFolderPaths;
                              if (!context.mounted) return;
                              showTextOnSnackBar('保存文件夹设置失败');
                              return;
                            }

                            _startBuild();
                          },
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManagedFolderGroup {
  const _ManagedFolderGroup({
    required this.path,
    required this.sourceFolders,
    required this.tree,
  });

  final String path;
  final List<AudioFolder> sourceFolders;
  final _ManagedFolderTreeNode tree;
}

class _ManagedFolderTreeNode {
  const _ManagedFolderTreeNode({
    required this.path,
    required this.directAudioCount,
    required this.children,
    required this.sourceFolder,
    required this.pendingScan,
  });

  final String path;
  final int directAudioCount;
  final List<_ManagedFolderTreeNode> children;
  final AudioFolder? sourceFolder;
  final bool pendingScan;

  String get name => p.windows.basename(path);

  int get audioCount =>
      directAudioCount +
      children.fold(0, (total, child) => total + child.audioCount);

  int get displayAudioCount => pendingScan ? 0 : audioCount;

  int get pendingFolderCount =>
      (pendingScan ? 1 : 0) +
      children.fold(0, (total, child) => total + child.pendingFolderCount);
}

class _MutableManagedFolderTreeNode {
  _MutableManagedFolderTreeNode(this.path);

  final String path;
  int directAudioCount = 0;
  AudioFolder? sourceFolder;
  bool pendingScan = false;
  final Map<String, _MutableManagedFolderTreeNode> children = {};

  _ManagedFolderTreeNode freeze() {
    final frozenChildren =
        children.values.map((child) => child.freeze()).toList()..sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
    return _ManagedFolderTreeNode(
      path: path,
      directAudioCount: directAudioCount,
      children: frozenChildren,
      sourceFolder: sourceFolder,
      pendingScan: pendingScan,
    );
  }
}

class _ManagedFolderTile extends StatelessWidget {
  const _ManagedFolderTile({
    super.key,
    required this.tree,
    required this.onRemove,
    required this.onRemoveFolder,
  });

  final _ManagedFolderTreeNode tree;
  final VoidCallback? onRemove;
  final ValueChanged<AudioFolder>? onRemoveFolder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final removeButton = TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: scheme.error,
        visualDensity: VisualDensity.compact,
      ),
      onPressed: onRemove,
      icon: const Icon(Symbols.remove_circle, size: 18),
      label: const Text('移除'),
    );
    final title = Row(
      children: [
        Icon(Symbols.folder, size: 20, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(tree.path, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );

    if (tree.children.isEmpty) {
      return ListTile(
        title: title,
        subtitle: Text('${tree.displayAudioCount} 首乐曲'),
        trailing: removeButton,
      );
    }

    return ExpansionTile(
      initiallyExpanded: tree.pendingFolderCount > 0,
      controlAffinity: ListTileControlAffinity.leading,
      childrenPadding: const EdgeInsets.only(left: 20),
      title: title,
      subtitle: Text(
        '${tree.children.length} 个子文件夹 · ${tree.displayAudioCount} 首乐曲',
      ),
      trailing: removeButton,
      children: [
        for (final child in tree.children)
          _FolderTreeTile(node: child, onRemoveFolder: onRemoveFolder),
      ],
    );
  }
}

class _FolderTreeTile extends StatelessWidget {
  const _FolderTreeTile({required this.node, required this.onRemoveFolder});

  final _ManagedFolderTreeNode node;
  final ValueChanged<AudioFolder>? onRemoveFolder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sourceFolder = node.sourceFolder;
    final removeButton = sourceFolder == null
        ? null
        : IconButton(
            tooltip: '移除',
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(foregroundColor: scheme.error),
            onPressed: onRemoveFolder == null
                ? null
                : () => onRemoveFolder!(sourceFolder),
            icon: const Icon(Symbols.remove_circle, size: 18),
          );
    final title = Row(
      children: [
        Icon(Symbols.folder, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );

    if (node.children.isEmpty) {
      return ListTile(
        dense: true,
        title: title,
        subtitle: Text('${node.displayAudioCount} 首乐曲'),
        trailing: removeButton,
      );
    }

    return ExpansionTile(
      dense: true,
      initiallyExpanded: node.pendingFolderCount > 0,
      controlAffinity: ListTileControlAffinity.leading,
      childrenPadding: const EdgeInsets.only(left: 20),
      title: title,
      subtitle: Text(
        '${node.children.length} 个子文件夹 · ${node.displayAudioCount} 首乐曲',
      ),
      trailing: removeButton,
      children: [
        for (final child in node.children)
          _FolderTreeTile(node: child, onRemoveFolder: onRemoveFolder),
      ],
    );
  }
}

class _EmptyManagedFolderState extends StatelessWidget {
  const _EmptyManagedFolderState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 28.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.folder_open,
              size: 32.0,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12.0),
            Text(
              '暂时没有曲库文件夹',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: AppType.weightSemibold,
              ),
            ),
            const SizedBox(height: 4.0),
            Text(
              '添加文件夹后再重新构建曲库',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
