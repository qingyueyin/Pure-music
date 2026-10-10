import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/services/concert_session.dart';
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

  double _songScrollOffset(int songIndex) {
    final session = ConcertSession.instance;
    if (!session.isActive) return songIndex * kConcertSongExtent;
    return concertSongScrollOffset(songIndex, session.sections);
  }

  void _toNowPlaying({required bool animate}) {
    if (!scrollController.hasClients) return;
    final target = _songScrollOffset(playbackService.playlistIndex);
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
      initialScrollOffset: _songScrollOffset(playbackService.playlistIndex),
    );
    playbackService.nowPlayingNotifier.addListener(_onNowPlayingChanged);
    playbackService.playlistNotifier.addListener(_onPlaylistChanged);
    ConcertSession.instance.addListener(_onNowPlayingChanged);
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
          _header(scheme),
          Expanded(child: _playlistBody(scheme)),
        ],
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    final session = ConcertSession.instance;
    final act = session.actAt(playbackService.playlistIndex);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8.0, 8.0, 4.0, 8.0),
      child: Row(
        children: [
          Text(
            session.isActive ? '此次的演出单' : '播放列表',
            style: TextStyle(
              color: scheme.onSecondaryContainer,
              fontSize: AppType.hero,
              fontWeight: AppType.weightBold,
            ),
          ),
          if (session.isActive && act != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$act · ${playbackService.playlistIndex + 1}/${session.length}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.primary,
                  fontSize: AppType.caption,
                  fontWeight: AppType.weightSemibold,
                ),
              ),
            ),
          ],
          const Spacer(),
          _reorderButton(scheme),
          _clearButton(scheme),
        ],
      ),
    );
  }

  Widget _reorderButton(ColorScheme scheme) {
    return ValueListenableBuilder<List<Audio>>(
      valueListenable: playbackService.playlistNotifier,
      builder: (context, playlist, _) {
        if (playlist.isEmpty) return const SizedBox.shrink();
        final canReorder = hasEnoughItemsToReorder(playlist.length);
        return IconButton(
          tooltip: canReorder ? (_isReordering ? '完成排序' : '排序') : '至少两首歌曲才能排序',
          icon: Icon(_isReordering ? Symbols.check : Symbols.reorder),
          style: IconButton.styleFrom(
            foregroundColor: _isReordering
                ? scheme.onTertiaryContainer
                : scheme.onSecondaryContainer,
            disabledForegroundColor: scheme.onSecondaryContainer.withValues(
              alpha: 0.38,
            ),
            backgroundColor: _isReordering ? scheme.tertiaryContainer : null,
          ),
          onPressed: canReorder
              ? () => setState(() => _isReordering = !_isReordering)
              : null,
        );
      },
    );
  }

  Widget _clearButton(ColorScheme scheme) {
    return ValueListenableBuilder<List<Audio>>(
      valueListenable: playbackService.playlistNotifier,
      builder: (context, playlist, _) {
        if (playlist.isEmpty) return const SizedBox.shrink();
        return IconButton(
          tooltip: _isReordering ? '完成排序后再清空队列' : '清空播放队列',
          icon: const Icon(Symbols.clear_all),
          style: IconButton.styleFrom(
            foregroundColor: scheme.error,
            disabledForegroundColor: scheme.onSecondaryContainer.withValues(
              alpha: 0.38,
            ),
          ),
          onPressed: _isReordering ? null : () => _confirmClearQueue(context),
        );
      },
    );
  }

  Widget _playlistBody(ColorScheme scheme) {
    return ListenableBuilder(
      listenable: playbackService.shuffle,
      builder: (context, _) {
        return ValueListenableBuilder<List<Audio>>(
          valueListenable: playbackService.playlistNotifier,
          builder: (context, playlist, _) {
            if (playlist.isEmpty) return _emptyQueue(scheme);
            if (_isReordering) return _buildReorderList(playlist, scheme);
            return _playlistList(playlist, scheme);
          },
        );
      },
    );
  }

  Widget _playlistList(List<Audio> playlist, ColorScheme scheme) {
    final session = ConcertSession.instance;
    final showActs = session.isActive && session.sections.isNotEmpty;
    final layout = showActs
        ? concertQueueLayout(playlist.length, session.sections)
        : [for (var index = 0; index < playlist.length; index++) index];
    return ListView.builder(
      controller: scrollController,
      itemCount: layout.length,
      itemExtent: showActs ? null : kConcertSongExtent,
      itemExtentBuilder: showActs
          ? (index, _) =>
                layout[index] < 0 ? kConcertActHeaderExtent : kConcertSongExtent
          : null,
      itemBuilder: (context, index) {
        final value = layout[index];
        if (value < 0) {
          final section = session.sections[-value - 1];
          return _QueueActHeader(name: section.name, count: section.count);
        }
        final audio = playlist[value];
        return _PlaylistViewItem(
          index: value,
          audio: audio,
          isNowPlaying: playbackService.nowPlaying?.path == audio.path,
          hasNowPlaying: playbackService.nowPlaying != null,
          currentIndex: playbackService.playlistIndex,
        );
      },
    );
  }

  Widget _emptyQueue(ColorScheme scheme) {
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
                color: scheme.onSecondaryContainer.withValues(alpha: 0.62),
                size: 32,
              ),
              const SizedBox(height: 14),
              Text(
                '播放队列还是空的',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onSecondaryContainer,
                  fontSize: AppType.subtitle,
                  fontWeight: AppType.weightBold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '选择歌曲后，它们会出现在这里。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onSecondaryContainer.withValues(alpha: 0.62),
                ),
              ),
            ],
          ),
        ),
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
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final t = MediaQuery.disableAnimationsOf(context)
                ? 1.0
                : MotionCurve.entrance.transform(animation.value);
            return Transform.rotate(
              angle: 0.105 * t,
              child: Transform.scale(
                scale: 1.0 + 0.03 * t,
                child: Material(
                  elevation: 4 * t,
                  borderRadius: AppRadius.smCircular,
                  child: child,
                ),
              ),
            );
          },
          child: child,
        );
      },
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
    ConcertSession.instance.removeListener(_onNowPlayingChanged);
    scrollController.dispose();
    super.dispose();
  }
}

class _QueueActHeader extends StatelessWidget {
  const _QueueActHeader({required this.name, required this.count});

  final String name;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
      child: Row(
        children: [
          Text(
            name,
            style: TextStyle(
              fontSize: AppType.caption,
              fontWeight: AppType.weightSemibold,
              letterSpacing: 1.2,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count 首',
            style: TextStyle(
              fontSize: AppType.microlabel,
              color: scheme.onSecondaryContainer.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
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
      borderRadius: AppRadius.smCircular,
      onTap: canActivate
          ? () => playbackService.playIndexOfPlaylist(index)
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: Row(
          children: [
            Expanded(child: _titles(scheme)),
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

  Widget _titles(ColorScheme scheme) {
    return DefaultTextStyle(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: isNowPlaying ? scheme.primary : scheme.onSecondaryContainer,
        fontSize: AppType.body,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            audio.title,
            style: TextStyle(
              fontWeight: isNowPlaying
                  ? AppType.weightSemibold
                  : FontWeight.normal,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${audio.artist} - ${audio.album}',
            style: TextStyle(
              fontSize: AppType.caption,
              color: isNowPlaying
                  ? scheme.primary.withAlpha(179)
                  : scheme.onSecondaryContainer.withAlpha(179),
            ),
          ),
        ],
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

  Widget _dragHandle(ColorScheme scheme) {
    return ReorderableDragStartListener(
      index: index,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Icon(Symbols.drag_indicator, color: scheme.onSurfaceVariant),
      ),
    );
  }

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
              _dragHandle(scheme),
              const SizedBox(width: 4.0),
              Expanded(child: _titles(scheme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _titles(ColorScheme scheme) {
    return DefaultTextStyle(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: isNowPlaying ? scheme.primary : scheme.onSurface,
        fontSize: AppType.body,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            audio.title,
            style: TextStyle(
              fontWeight: isNowPlaying ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${audio.artist} - ${audio.album}',
            style: TextStyle(
              fontSize: AppType.caption,
              color: isNowPlaying
                  ? scheme.primary.withAlpha(179)
                  : scheme.onSurface.withAlpha(179),
            ),
          ),
        ],
      ),
    );
  }
}
