import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/page/uni_detail_page.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;

class FolderDetailPage extends StatefulWidget {
  final AudioFolder folder;
  const FolderDetailPage({super.key, required this.folder});

  @override
  State<FolderDetailPage> createState() => _FolderDetailPageState();
}

class _FolderDetailPageState extends State<FolderDetailPage> {
  final multiSelectController = MultiSelectController<Audio>();
  late final List<Audio> _contentList;
  late final Future<ImageProvider?> _primaryPicFuture;
  late final Future<ImageProvider?> _backgroundPicFuture;

  Future<ImageProvider?> _loadPrimaryPic() {
    return widget.folder.audios.firstOrNull?.mediumCover ??
        Future<ImageProvider?>.value(null);
  }

  Future<ImageProvider?> _loadBackgroundPic() {
    return widget.folder.audios.isEmpty
        ? Future<ImageProvider?>.value(null)
        : widget.folder.audios.first.cover;
  }

  @override
  void initState() {
    super.initState();
    _contentList = List<Audio>.from(widget.folder.audios);
    _primaryPicFuture = _loadPrimaryPic();
    _backgroundPicFuture = _loadBackgroundPic();
  }

  @override
  Widget build(BuildContext context) {
    final canSortSongs = hasEnoughItemsToSort(_contentList.length);
    final canPlaySongs = canShowPlayAllAction(_contentList.length);
    final canSwitchContentView = canShowContentViewSwitch(_contentList.length);

    return UniDetailPage<AudioFolder, Audio, Object>(
      pref: AppPreference.instance.folderDetailPagePref,
      primaryContent: widget.folder,
      primaryPic: _primaryPicFuture,
      backgroundPic: _backgroundPicFuture,
      picShape: PicShape.rrect,
      title: p.basename(widget.folder.path),
      subtitle: '${_contentList.length} 首乐曲',
      secondaryContent: _contentList,
      secondaryContentBuilder: (context, item, i, msc, _) => AudioTile(
        audioIndex: i,
        playlist: _contentList,
        multiSelectController: msc,
      ),
      enableShufflePlay: canPlaySongs,
      enableSortMethod: canSortSongs,
      enableSortOrder: canSortSongs,
      enableSecondaryContentViewSwitch: canSwitchContentView,
      bodyOverride:
          _contentList.isEmpty ? const _EmptyFolderBody() : null,
      multiSelectController: multiSelectController,
      multiSelectViewActions: [
        AddAllToPlaylist(multiSelectController: multiSelectController),
        MultiSelectSelectOrClearAll(
          multiSelectController: multiSelectController,
          contentList: _contentList,
        ),
        MultiSelectExit(multiSelectController: multiSelectController),
      ],
      sortMethods: [
        SortMethodDesc(
          icon: Symbols.title,
          name: '标题',
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.title.naturalCompareTo(b.title));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.title.naturalCompareTo(a.title));
                break;
            }
          },
        ),
        SortMethodDesc(
          icon: Symbols.artist,
          name: '艺术家',
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.artist.naturalCompareTo(b.artist));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.artist.naturalCompareTo(a.artist));
                break;
            }
          },
        ),
        SortMethodDesc(
          icon: Symbols.album,
          name: '专辑',
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.album.naturalCompareTo(b.album));
                break;
              case SortOrder.decending:
                list.sort((a, b) => b.album.naturalCompareTo(a.album));
                break;
            }
          },
        ),
        SortMethodDesc(
          icon: Symbols.add,
          name: '创建时间',
          method: (list, order) {
            switch (order) {
              case SortOrder.ascending:
                list.sort((a, b) => a.created.compareTo(b.created));
                break;
 
             case SortOrder.decending:
                list.sort((a, b) => b.created.compareTo(a.created));
                break;
            }
          },
        ),
        SortMethodDesc(
          icon: Symbols.edit,
          name: '修改时间',
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
      ],
    );
  }
}

class _EmptyFolderBody extends StatelessWidget {
  const _EmptyFolderBody();

  @override
  Widget build(BuildContext context) {
    return const QuietEmptyState(
      icon: Symbols.folder,
      title: '这个文件夹还没有歌曲',
      message: '等扫描或索引更新后，这里会显示可播放内容。',
    );
  }
}