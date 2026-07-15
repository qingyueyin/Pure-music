import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/page/folder_manager_dialog.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:path/path.dart' as p;

class FoldersPage extends StatefulWidget {
  const FoldersPage({super.key});

  @override
  State<FoldersPage> createState() => _FoldersPageState();
}

class _FoldersPageState extends State<FoldersPage> {
  bool _updating = false;

  Future<void> _refreshIndex() async {
    setState(() => _updating = true);
    try {
      final dir = await getAppDataDir();
      final stream = updateIndex(indexPath: dir.path);
      await for (final _ in stream) {}
      await Future.wait([
        AudioLibrary.initFromIndex(),
        readPlaylists(),
        readLyricSources(),
      ]);
      AlbumColorCache.instance
          .prewarmAlbums(AudioLibrary.instance.albumCollection.values)
          .ignore();
      if (mounted) {
        showTextOnSnackBar('已刷新');
      }
    } catch (e) {
      logger.e('refresh index failed: $e');
    }
    if (mounted) setState(() => _updating = false);
  }

  @override
  Widget build(BuildContext context) {
    final contentList = AudioLibrary.aggregatedRootFolders();
    return UniPage<AudioFolder>(
      pref: AppPreference.instance.foldersPagePref,
      title: '文件夹',
      subtitle: '${contentList.length} 个文件夹',
      contentList: contentList,
      primaryAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_updating)
            const SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            OutlinedButton.icon(
              onPressed: _refreshIndex,
              icon: const Icon(Symbols.refresh, size: 18),
              label: const Text('刷新'),
              style: const ButtonStyle(
                fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
              ),
            ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () async {
              await showFolderManagerDialog(context);
              setState(() {});
            },
            icon: const Icon(Symbols.folder),
            label: const Text('文件夹管理'),
            style: const ButtonStyle(
              fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
            ),
          ),
        ],
      ),
      contentBuilder: (context, item, i, multiSelectController, view) =>
          AudioFolderTile(audioFolder: item),
      enableShufflePlay: false,
      enableSortMethod: true,
      enableSortOrder: true,
      enableContentViewSwitch: true,
      sortMethods: [
        SortMethodDesc<AudioFolder>(
          icon: Symbols.title,
          name: '路径',
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.path.localeCompareTo(b.path));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.path.localeCompareTo(a.path));
                break;
            }
          },
        ),
        SortMethodDesc<AudioFolder>(
          icon: Symbols.edit,
          name: '修改日期',
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
        SortMethodDesc<AudioFolder>(
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

class AudioFolderTile extends StatelessWidget {
  final AudioFolder audioFolder;
  const AudioFolderTile({
    super.key,
    required this.audioFolder,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: InkWell(
        borderRadius: AppRadius.smCircular,
        onTap: () => context.push(
          app_paths.FOLDER_DETAIL_PAGE,
          extra: audioFolder,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
          child: Row(
            children: [
              Icon(Symbols.folder, color: scheme.onSurfaceVariant),
              const SizedBox(width: 16.0),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.basename(audioFolder.path),
                      softWrap: false,
                      maxLines: 1,
                      style: TextStyle(color: scheme.onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      p.dirname(audioFolder.path),
                      softWrap: false,
                      maxLines: 1,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: AppType.body,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${audioFolder.audios.length} 首',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
