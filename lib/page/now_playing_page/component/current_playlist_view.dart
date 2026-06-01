import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class CurrentPlaylistView extends StatefulWidget {
  const CurrentPlaylistView({super.key});

  @override
  State<CurrentPlaylistView> createState() => _CurrentPlaylistViewState();
}

class _CurrentPlaylistViewState extends State<CurrentPlaylistView> {
  final playbackService = PlayService.instance.playbackService;
  late final ScrollController scrollController;
  bool _isReordering = false;

  void _toNowPlaying() {
    if (!scrollController.hasClients) return;
    final target = playbackService.playlistIndex * 64.0;
    final maxScroll = scrollController.position.maxScrollExtent;
    scrollController.animateTo(
      target.clamp(0.0, maxScroll),
      duration: const Duration(milliseconds: 300),
      curve: Curves.fastOutSlowIn,
    );
  }

  @override
  void initState() {
    super.initState();
    scrollController = ScrollController(
      initialScrollOffset: playbackService.playlistIndex * 64.0,
    );
    playbackService.nowPlayingNotifier.addListener(_toNowPlaying);
    playbackService.playlistNotifier.addListener(_toNowPlaying);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8.0, 8.0, 4.0, 8.0),
            child: Row(
              children: [
                Text(
                  '播放列表',
                  style: TextStyle(
                    color: scheme.onSecondaryContainer,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                // 排序模式切换按钮
                ValueListenableBuilder<List<Audio>>(
                  valueListenable: playbackService.playlistNotifier,
                  builder: (context, playlist, _) {
                    if (playlist.isEmpty) return const SizedBox.shrink();
                    return IconButton(
                      tooltip: _isReordering ? '完成排序' : '排序',
                      icon: Icon(
                        _isReordering ? Symbols.check : Symbols.reorder,
                      ),
                      style: ButtonStyle(
                        foregroundColor: WidgetStatePropertyAll(
                          _isReordering
                              ? scheme.onTertiaryContainer
                              : scheme.onSecondaryContainer,
                        ),
                      ),
                      onPressed: () =>
                          setState(() => _isReordering = !_isReordering),
                    );
                  },
                ),
                // 清除队列按钮
                ValueListenableBuilder<List<Audio>>(
                  valueListenable: playbackService.playlistNotifier,
                  builder: (context, playlist, _) {
                    if (playlist.isEmpty) return const SizedBox.shrink();
                    return IconButton(
                      tooltip: '清除队列',
                      icon: const Icon(Symbols.clear_all),
                      style: ButtonStyle(
                        foregroundColor: WidgetStatePropertyAll(
                          scheme.error,
                        ),
                      ),
                      onPressed: () => _confirmClearQueue(context),
                    );
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: playbackService.shuffle,
              builder: (context, _) {
                return ValueListenableBuilder<List<Audio>>(
                  valueListenable: playbackService.playlistNotifier,
                  builder: (context, playlist, _) {
                    if (playlist.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32.0),
                          child: Text(
                            '队列为空\n选择乐曲开始播放',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: scheme.onSecondaryContainer.withAlpha(128),
                              fontSize: 14,
                            ),
                          ),
                        ),
                      );
                    }

                    if (_isReordering) {
                      return _buildReorderList(playlist, scheme);
                    }

                    return ListView.builder(
                      controller: scrollController,
                      itemCount: playlist.length,
                      itemExtent: 64.0,
                      itemBuilder: (context, index) {
                        return _PlaylistViewItem(index: index);
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReorderList(List<Audio> playlist, ColorScheme scheme) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: 8.0),
      itemCount: playlist.length,
      onReorderItem: (oldIndex, newIndex) {
        final pb = playbackService;
        final currentList = List<Audio>.from(pb.playlist.value);
        final item = currentList.removeAt(oldIndex);
        currentList.insert(newIndex, item);
        pb.playlist.value = currentList;

        // 调整当前播放索引
        if (pb.playlistIndex == oldIndex) {
          // 当前播放歌曲被拖动，更新索引到新位置
          pb.playIndexOfPlaylist(newIndex);
        } else if (oldIndex < pb.playlistIndex &&
            newIndex >= pb.playlistIndex) {
          // 当前播放之前的歌曲被拖到之后，索引前移
          final newIdx = pb.playlistIndex - 1;
          pb.playIndexOfPlaylist(newIdx);
        } else if (oldIndex > pb.playlistIndex &&
            newIndex <= pb.playlistIndex) {
          // 当前播放之后的歌曲被拖到之前，索引后移
          final newIdx = pb.playlistIndex + 1;
          pb.playIndexOfPlaylist(newIdx);
        }
      },
      proxyDecorator: (child, index, animation) => Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        child: child,
      ),
      itemBuilder: (context, i) {
        final audio = playlist[i];
        final isNowPlaying =
            playbackService.nowPlaying?.path == audio.path;
        return _ReorderItem(
          key: ValueKey(audio.path),
          audio: audio,
          index: i,
          isNowPlaying: isNowPlaying,
          colorScheme: scheme,
        );
      },
    );
  }

  void _confirmClearQueue(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Text('清除播放队列'),
        content: const Text('确定要清空当前播放队列吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: ButtonStyle(
              backgroundColor: WidgetStatePropertyAll(scheme.error),
              foregroundColor: WidgetStatePropertyAll(scheme.onError),
            ),
            onPressed: () {
              playbackService.clearQueue();
              Navigator.of(context).pop();
            },
            child: const Text('清除'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    playbackService.nowPlayingNotifier.removeListener(_toNowPlaying);
    playbackService.playlistNotifier.removeListener(_toNowPlaying);
    scrollController.dispose();
    super.dispose();
  }
}

class _PlaylistViewItem extends StatelessWidget {
  const _PlaylistViewItem({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final playbackService = PlayService.instance.playbackService;
    final item = playbackService.playlist.value[index];
    final scheme = Theme.of(context).colorScheme;
    final isNowPlaying = playbackService.nowPlaying?.path == item.path;

    return InkWell(
      borderRadius: BorderRadius.circular(8.0),
      onTap: () {
        playbackService.playIndexOfPlaylist(index);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: Row(
          children: [
            Expanded(
              child: DefaultTextStyle(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isNowPlaying
                      ? scheme.primary
                      : scheme.onSecondaryContainer,
                  fontSize: 14,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: TextStyle(
                        fontWeight:
                            isNowPlaying ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${item.artist} - ${item.album}',
                      style: TextStyle(
                        fontSize: 12,
                        color: isNowPlaying
                            ? scheme.primary.withAlpha(179)
                            : scheme.onSecondaryContainer.withAlpha(179),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 移除按钮
            IconButton(
              tooltip: '从队列移除',
              icon: Icon(
                Symbols.remove_circle_outline,
                size: 20,
                color: scheme.onSecondaryContainer.withAlpha(153),
              ),
              visualDensity: VisualDensity.compact,
              onPressed: () {
                playbackService.removeFromQueue(index);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ReorderItem extends StatelessWidget {
  const _ReorderItem({
    super.key,
    required this.audio,
    required this.index,
    required this.isNowPlaying,
    required this.colorScheme,
  });

  final Audio audio;
  final int index;
  final bool isNowPlaying;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final scheme = colorScheme;
    return SizedBox(
      height: 64,
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Icon(
                    Symbols.drag_indicator,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 4.0),
              Expanded(
                child: DefaultTextStyle(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        isNowPlaying ? scheme.primary : scheme.onSurface,
                    fontSize: 14,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        audio.title,
                        style: TextStyle(
                          fontWeight:
                              isNowPlaying ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${audio.artist} - ${audio.album}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isNowPlaying
                              ? scheme.primary.withAlpha(179)
                              : scheme.onSurface.withAlpha(179),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
