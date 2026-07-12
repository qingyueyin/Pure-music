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
    final seen = folders.map((f) => pendingFolderKey(f.path)).toSet();
    for (final path in paths) {
      final key = pendingFolderKey(path);
      if (key.isEmpty || !seen.add(key)) continue;
      folders.add(AudioFolder([], path, 0, 0));
    }
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

  Future<bool> _confirmRemoveFolder(AudioFolder folder) async {
    final scheme = Theme.of(context).colorScheme;
    return showDangerConfirmDialog(
      context: context,
      title: '从曲库移除文件夹？',
      message: '不会删除本地音乐文件，只会从 Pure Music 的曲库扫描范围中移除。',
      confirmLabel: '移除',
      details: Text(
        folder.path,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: AppType.caption),
      ),
    );
  }

  void _startBuild() {
    building = true;
    _buildView = FutureBuilder(
      future: applicationSupportDirectory,
      builder: (context, snapshot) {
        if (snapshot.data == null) {
          return const Center(
            child: Text('Fail to get app data dir.'),
          );
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
                  .prewarmAlbums(
                    AudioLibrary.instance.albumCollection.values,
                  )
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

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.mdCircular,
      ),
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
                      '${folders.length} 个文件夹',
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
                              itemCount: folders.length,
                              itemBuilder: (context, i) => ListTile(
                                title: Text(
                                  folders[i].path,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${folders[i].audios.length} 首乐曲',
                                ),
                                trailing: TextButton.icon(
                                  style: TextButton.styleFrom(
                                    foregroundColor: scheme.error,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: building || _isPickingFolder
                                      ? null
                                      : () async {
                                          final folder = folders[i];
                                          final confirmed =
                                              await _confirmRemoveFolder(
                                            folder,
                                          );
                                          if (!confirmed || !context.mounted) {
                                            return;
                                          }
                                          setState(() {
                                            folders.remove(folder);
                                          });
                                        },
                                  icon: const Icon(
                                    Symbols.remove_circle,
                                    size: 18,
                                  ),
                                  label: const Text('移除'),
                                ),
                              ),
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
                  TextButton(
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
                                .where((f) => !containsEquivalentFolderPath(
                                      paths: original,
                                      target: f,
                                    ))
                                .toList();
                            final removed = original
                                .where((f) => !containsEquivalentFolderPath(
                                      paths: kept,
                                      target: f,
                                    ))
                                .toList();

                            final userFolderKeys = AppPreference
                                .instance.userFolders
                                .map(pendingFolderKey)
                                .toSet();
                            AppPreference.instance.userFolders.addAll(
                              added.where(
                                (f) => userFolderKeys.add(
                                  pendingFolderKey(f),
                                ),
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
                              (f) => containsEquivalentFolderPath(
                                paths: kept,
                                target: f,
                              ),
                            );
                            final excludedFolderKeys = AppPreference
                                .instance.excludedFolderPaths
                                .map(pendingFolderKey)
                                .toSet();
                            AppPreference.instance.excludedFolderPaths.addAll(
                              removed.where(
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
