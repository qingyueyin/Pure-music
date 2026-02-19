import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/component/album_tile.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class AlbumsPage extends StatelessWidget {
  const AlbumsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final contentList = AudioLibrary.instance.albumCollection.values.toList();
    final multiSelectController = MultiSelectController<Album>();
    return UniPage<Album>(
      pref: AppPreference.instance.albumsPagePref,
      title: "专辑",
      subtitle: "${contentList.length} 张专辑",
      primaryAction: FilledButton.icon(
        onPressed: () async {
          int done = 0;
          int total = contentList.isEmpty ? 1 : contentList.length;
          bool running = true;
          bool started = false;
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (context) => StatefulBuilder(
              builder: (context, setState) {
                if (!started) {
                  started = true;
                  AlbumColorCache.instance
                      .recomputeAllAlbums(
                        contentList,
                        onProgress: (d, t) {
                          setState(() {
                            done = d;
                            total = t <= 0 ? 1 : t;
                          });
                        },
                      )
                      .then((_) => AlbumColorCache.instance.flush())
                      .whenComplete(() {
                    if (context.mounted) {
                      setState(() {
                        running = false;
                      });
                    }
                  }).ignore();
                }

                return AlertDialog(
                  title: const Text("优化专辑页"),
                  content: SizedBox(
                    width: 360,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(value: done / total),
                        const SizedBox(height: 12),
                        Text("$done / $total"),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: running ? null : () => Navigator.pop(context),
                      child: const Text("关闭"),
                    ),
                  ],
                );
              },
            ),
          );
        },
        icon: const Icon(Symbols.palette),
        label: const Text("优化专辑页"),
        style: const ButtonStyle(
          fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
        ),
      ),
      contentList: contentList,
      contentBuilder: (context, item, i, multiSelectController, view) => AlbumTile(
        album: item,
        multiSelectController: multiSelectController,
        view: view,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180,
          childAspectRatio: 0.75,
          mainAxisSpacing: 24.0,
          crossAxisSpacing: 24.0,
        ),
      enableShufflePlay: false,
      enableSortMethod: true,
      enableSortOrder: true,
      enableContentViewSwitch: true,
      multiSelectController: multiSelectController,
      multiSelectViewActions: [
        MultiSelectPlaySelectedAudios(
          multiSelectController: multiSelectController,
          toAudios: (selected) =>
              selected.expand((album) => album.works).toList(),
        ),
        AddSelectedAudiosToPlaylist(
          multiSelectController: multiSelectController,
          toAudios: (selected) =>
              selected.expand((album) => album.works).toList(),
        ),
        MultiSelectSelectOrClearAll(
          multiSelectController: multiSelectController,
          contentList: contentList,
        ),
        MultiSelectExit(multiSelectController: multiSelectController),
      ],
      sortMethods: [
        SortMethodDesc(
          icon: Symbols.title,
          name: "标题",
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
          name: "作品数量",
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.works.length.compareTo(b.works.length));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.works.length.compareTo(a.works.length));
                break;
            }
          },
        ),
      ],
    );
  }
}
