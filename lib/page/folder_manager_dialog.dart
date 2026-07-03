import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/component/build_index_state_view.dart';
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
  List<AudioFolder> folders = List.from(AudioLibrary.instance.folders);

  final applicationSupportDirectory = getAppDataDir();

  bool editing = true;
  bool building = false;

  Widget? _buildView;

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

    return Dialog(
      insetPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: SizedBox(
        height: 450.0,
        width: 450.0,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Text(
                  '管理文件夹',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 18.0,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: editing
                      ? ListView.builder(
                          key: const ValueKey('folder_list'),
                          itemCount: folders.length,
                          itemBuilder: (context, i) => ListTile(
                            title: Text(folders[i].path, maxLines: 1),
                            subtitle: Text('${folders[i].audios.length} 首乐曲'),
                            trailing: IconButton(
                              tooltip: '移除',
                              color: scheme.error,
                              onPressed: () {
                                setState(() {
                                  folders.removeAt(i);
                                });
                              },
                              icon: const Icon(Symbols.delete),
                            ),
                          ),
                        )
                      : (_buildView ?? const SizedBox(key: ValueKey('empty'))),
                ),
              ),
              const SizedBox(height: 16.0),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: building
                        ? null
                        : () {
                            final paths = pickMultipleDirectories(
                              title: '选择文件夹',
                            );
                            if (paths.isEmpty) return;

                            setState(() {
                              for (final p in paths) {
                                final exists = folders.any(
                                    (f) => f.path.toLowerCase() == p.toLowerCase());
                                if (!exists) {
                                  folders.add(AudioFolder([], p, 0, 0));
                                }
                              }
                            });
                          },
                    child: const Text('添加'),
                  ),
                  const SizedBox(width: 8.0),
                  TextButton(
                    onPressed:
                        building ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8.0),
                  TextButton(
                    onPressed: building
                        ? null
                        : () {
                            final kept = folders.map((f) => f.path).toList();
                            final original = AudioLibrary
                                .instance.folders
                                .map((f) => f.path)
                                .toList();
                            final removed =
                                original.where((f) => !kept.contains(f)).toList();

                            AppPreference.instance.userFolders = kept;
                            AppPreference.instance.excludedFolderPaths
                                .removeWhere((f) => kept.contains(f));
                            AppPreference.instance.excludedFolderPaths
                                .addAll(removed);
                            AppPreference.instance.save();

                            _startBuild();
                          },
                    child: const Text('确定'),
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

