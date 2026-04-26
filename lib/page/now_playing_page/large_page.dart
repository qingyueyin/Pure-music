part of 'page.dart';

class _NowPlayingLargePage extends StatelessWidget {
  const _NowPlayingLargePage();

  @override
  Widget build(BuildContext context) {
    const spacer = SizedBox(width: 8.0);
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24.0, 8.0, 24.0, 0),
            child: LayoutBuilder(builder: (context, constraints) {
              return Row(
                children: [
                  // 左侧：封面 + 歌曲信息 (50%)
                  Expanded(
                    child: Center(child: _NowPlayingInfo()),
                  ),
                  // 右侧：歌词区域 (50%)
                  Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: nowPlayingViewMode,
                      builder: (context, value, _) => AnimatedSwitcher(
                        duration: MotionDuration.base,
                        switchInCurve: MotionCurve.standard,
                        switchOutCurve: MotionCurve.standard,
                        child: switch (value) {
                          NowPlayingViewMode.withPlaylist =>
                            const CurrentPlaylistView(),
                          _ => Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                child: VerticalLyricView(
                                  enableEdgeSpacer: true,
                                  currentLineAlignment: 0.45,
                                ),
                              ),
                            ),
                        },
                      ),
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
        const SizedBox(height: 8.0),
        const _NowPlayingSlider(),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _DesktopLyricSwitch(),
                    spacer,
                    _ExclusiveModeSwitch(),
                    spacer,
                    IconButton(
                      tooltip: "均衡器",
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) => const EqualizerDialog(),
                        );
                      },
                      icon: const Icon(Symbols.graphic_eq),
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ],
                ),
              ),
              _AutoHidingControlBar(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _NowPlayingPlaybackModeSwitch(),
                    spacer,
                    IconButton(
                      tooltip: "上一曲",
                      onPressed: PlayService.instance.playbackService.lastAudio,
                      icon: const Icon(
                        Symbols.skip_previous,
                        fill: 1.0,
                      ),
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    spacer,
                    StreamBuilder(
                      stream: PlayService
                          .instance.playbackService.playerStateStream,
                      initialData:
                          PlayService.instance.playbackService.playerState,
                      builder: (context, snapshot) {
                        final state = snapshot.data!;
                        final isPlaying = state == PlayerState.playing;
                        final isCompleted = state == PlayerState.completed;
                        
                        return IconButton(
                          tooltip: isPlaying ? "暂停" : "播放",
                          onPressed: () {
                            final service = PlayService.instance.playbackService;
                            if (isPlaying) {
                              service.pause();
                            } else if (isCompleted) {
                              service.playAgain();
                            } else {
                              service.start();
                            }
                          },
                          icon: Icon(
                            isPlaying ? Symbols.pause : Symbols.play_arrow,
                            fill: 1.0,
                          ),
                          color: Theme.of(context).colorScheme.onSurface,
                        );
                      },
                    ),
                    spacer,
                    IconButton(
                      tooltip: "下一曲",
                      onPressed: PlayService.instance.playbackService.nextAudio,
                      icon: const Icon(
                        Symbols.skip_next,
                        fill: 1.0,
                      ),
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    spacer,
                    const _NowPlayingLargeViewSwitch(),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _NowPlayingVolDspSlider(),
                    spacer,
                    const NowPlayingPitchControl(),
                    spacer,
                    _NowPlayingMoreAction(),
                  ],
                ),
              )
            ],
          ),
        ),
      ],
    );
  }
}

class _AutoHidingControlBar extends StatefulWidget {
  final Widget child;
  const _AutoHidingControlBar({required this.child});

  @override
  State<_AutoHidingControlBar> createState() => _AutoHidingControlBarState();
}

class _AutoHidingControlBarState extends State<_AutoHidingControlBar> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      hitTestBehavior: HitTestBehavior.translucent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(32),
        ),
        child: AnimatedOpacity(
          duration: MotionDuration.base,
          curve: MotionCurve.standard,
          opacity: _isHovering ? 1.0 : 0.0,
          child: widget.child,
        ),
      ),
    );
  }
}

/// 切换视图：lyric / playlist
class _NowPlayingLargeViewSwitch extends StatelessWidget {
  const _NowPlayingLargeViewSwitch();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ValueListenableBuilder(
      valueListenable: nowPlayingViewMode,
      builder: (context, value, _) => IconButton(
        tooltip: switch (value) {
          NowPlayingViewMode.withPlaylist => "歌词",
          _ => "播放列表",
        },
        onPressed: () {
          if (value == NowPlayingViewMode.onlyMain ||
              value == NowPlayingViewMode.withLyric) {
            nowPlayingViewMode.value = NowPlayingViewMode.withPlaylist;
            AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode =
                NowPlayingViewMode.withPlaylist;
          } else {
            nowPlayingViewMode.value = NowPlayingViewMode.withLyric;
            AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode =
                NowPlayingViewMode.withLyric;
          }
        },
        icon: switch (value) {
          NowPlayingViewMode.withPlaylist => const Icon(
            Symbols.lyrics,
            fill: 1.0,
          ),
          _ => const Icon(
            Symbols.queue_music,
            fill: 1.0,
          ),
        },
        color: scheme.onSurface,
      ),
    );
  }
}

