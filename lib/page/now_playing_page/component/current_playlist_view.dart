import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/component/danger_confirm_dialog.dart';
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

  void _toNowPlaying({required bool animate}) {
    if (!scrollController.hasClients) return;
    final target = playbackService.playlistIndex * 64.0;
    final maxScroll = scrollController.position.maxScrollExtent;
    final offset = target.clamp(0.0, maxScroll);
    if ((scrollController.offset - offset).abs() < 1.0) return;
    if (!animate) {
      scrollController.jumpTo(offset);
      return;
    }
    scrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _scheduleToNowPlaying({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isReordering) return;
      _toNowPlaying(animate: animate);
    });
  }

  void _onNowPlayingChanged() {
    if (mounted) setState(() {});
    _scheduleToNowPlaying();
  }

  void _onPlaylistChanged() {
    _scheduleToNowPlaying(animate: false);
  }

  @override
  void initState() {
    super.initState();
    scrollController = ScrollController(
      initialScrollOffset: playbackService.playlistIndex * 64.0,
    );
    playbackService.nowPlayingNotifier.addListener(_onNowPlayingChanged);
    playbackService.playlistNotifier.addListener(_onPlaylistChanged);
    _scheduleToNowPlaying(animate: false);
  }

  @override
  void activate() {
    super.activate();
    _scheduleToNowPlaying(animate: false);
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
                    final canReorder = hasEnoughItemsToReorder(playlist.length);
                    return IconButton(
                      tooltip: canReorder
                          ? _isReordering
                              ? '完成排序'
                              : '排序'
                          : '至少两首歌曲才能排序',
                      icon: Icon(
                        _isReordering ? Symbols.check : Symbols.reorder,
                      ),
                      style: IconButton.styleFrom(
                        foregroundColor: _isReordering
                            ? scheme.onTertiaryContainer
                            : scheme.onSecondaryContainer,
                        disabledForegroundColor:
                            scheme.onSecondaryContainer.withValues(alpha: 0.38),
                        backgroundColor:
                            _isReordering ? scheme.tertiaryContainer : null,
                      ),
                      onPressed: canReorder
                          ? () => setState(() => _isReordering = !_isReordering)
                          : null,
                    );
                  },
                ),
                // 清除队列按钮
                ValueListenableBuilder<List<Audio>>(
                  valueListenable: playbackService.playlistNotifier,
                  builder: (context, playlist, _) {
                    if (playlist.isEmpty) return const SizedBox.shrink();
                    return IconButton(
                      tooltip: _isReordering ? '完成排序后再清空队列' : '清空播放队列',
                      icon: const Icon(Symbols.clear_all),
                      style: IconButton.styleFrom(
                        foregroundColor: scheme.error,
                        disabledForegroundColor:
                            scheme.onSecondaryContainer.withValues(alpha: 0.38),
                      ),
                      onPressed: _isReordering
                          ? null
                          : () => _confirmClearQueue(context),
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
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(32.0),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 280),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Symbols.queue_music,
                                  color: scheme.onSecondaryContainer
                                      .withValues(alpha: 0.62),
                                  size: 32,
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  '播放队列还是空的',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: scheme.onSecondaryContainer,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '选择歌曲后，它们会出现在这里。',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: scheme.onSecondaryContainer
                                        .withValues(alpha: 0.62),
                                  ),
                                ),
                              ],
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
                        final audio = playlist[index];
                        return _PlaylistViewItem(
                          index: index,
                          audio: audio,
                          isNowPlaying:
                              playbackService.nowPlaying?.path == audio.path,
                          hasNowPlaying: playbackService.nowPlaying != null,
                          currentIndex: playbackService.playlistIndex,
                        );
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
      buildDefaultDragHandles: false,
      itemCount: playlist.length,
      onReorderItem: (oldIndex, newIndex) {
        playbackService.reorderPlaylist(oldIndex, newIndex);
      },
      proxyDecorator: (child, index, animation) => Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        child: child,
      ),
      itemBuilder: (context, i) {
        final audio = playlist[i];
        final isNowPlaying = playbackService.nowPlaying?.path == audio.path;
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

  Future<void> _confirmClearQueue(BuildContext context) async {
    final confirmed = await showDangerConfirmDialog(
      context: context,
      title: '清空播放队列？',
      message: '只会清空当前播放队列，不会删除本地音乐文件。',
      confirmLabel: '清空队列',
    );
    if (!confirmed || !mounted) return;
    playbackService.clearQueue();
    setState(() => _isReordering = false);
  }

  @override
  void dispose() {
    playbackService.nowPlayingNotifier.removeListener(_onNowPlayingChanged);
    playbackService.playlistNotifier.removeListener(_onPlaylistChanged);
    scrollController.dispose();
    super.dispose();
  }
}

class _PlaylistViewItem extends StatelessWidget {
  const _PlaylistViewItem({
    required this.index,
    required this.audio,
    required this.isNowPlaying,
    required this.hasNowPlaying,
    required this.currentIndex,
  });

  final int index;
  final Audio audio;
  final bool isNowPlaying;
  final bool hasNowPlaying;
  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    final playbackService = PlayService.instance.playbackService;
    final scheme = Theme.of(context).colorScheme;
    final canActivate = canActivateQueueItem(
      hasNowPlaying: hasNowPlaying,
      currentIndex: currentIndex,
      targetIndex: index,
    );

    return InkWell(
      borderRadius: BorderRadius.circular(8.0),
      onTap:
          canActivate ? () => playbackService.playIndexOfPlaylist(index) : null,
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
                    color: isNowPlaying ? scheme.primary : scheme.onSurface,
                    fontSize: 14,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        audio.title,
                        style: TextStyle(
                          fontWeight: isNowPlaying
                              ? FontWeight.w600
                              : FontWeight.normal,
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
