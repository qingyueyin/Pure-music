import 'package:pure_music/app_preference.dart';
import 'package:pure_music/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/enums.dart';
import 'package:pure_music/page/folder_manager_dialog.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:pure_music/app_paths.dart' as app_paths;

class FoldersPage extends StatelessWidget {
  const FoldersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final contentList = List<AudioFolder>.from(AudioLibrary.instance.folders);
    return UniPage<AudioFolder>(
      pref: AppPreference.instance.foldersPagePref,
      title: "文件夹",
      subtitle: "${contentList.length} 个文件夹",
      contentList: contentList,
      primaryAction: FilledButton.icon(
        onPressed: () => showFolderManagerDialog(context),
        icon: const Icon(Symbols.folder),
        label: const Text("文件夹管理"),
        style: const ButtonStyle(
          fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
        ),
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
          name: "路径",
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
          name: "修改日期",
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

class AudioFolderTile extends StatelessWidget {
  final AudioFolder audioFolder;
  const AudioFolderTile({
    super.key,
    required this.audioFolder,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: audioFolder.path,
      child: ListTile(
        title: Text(
          audioFolder.path,
          softWrap: false,
          maxLines: 1,
        ),
        subtitle: Text(
          "修改日期：${DateTime.fromMillisecondsSinceEpoch(audioFolder.modified * 1000).toString()}",
          softWrap: false,
          maxLines: 1,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8.0),
        ),
        onTap: () => context.push(
          app_paths.FOLDER_DETAIL_PAGE,
          extra: audioFolder,
        ),
      ),
    );
  }
}
