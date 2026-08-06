part of 'page.dart';

class _NowPlayingLargePage extends StatelessWidget {
  const _NowPlayingLargePage();

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final scheme = Theme.of(context).colorScheme;
    final playbackService = PlayService.instance.playbackService;
    final controlColor = useMonet ? scheme.primary : scheme.onSurface;
    final disabledColor = controlColor.withValues(alpha: 0.38);
    const spacer = SizedBox(width: 8.0);
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24.0, 8.0, 24.0, 8.0),
            child: LayoutBuilder(builder: (context, constraints) {
              final immersiveViewportHeight =
                  MediaQuery.sizeOf(context).height - 16.0;
              final currentLineAlignment =
                  (immersiveViewportHeight * 0.45 / constraints.maxHeight)
                      .clamp(0.0, 1.0)
                      .toDouble();
              // 封面尺寸按整个窗口高度计算，与横屏沉浸模式一致
              final coverSize = _responsiveNowPlayingCoverSize(
                maxWidth: constraints.maxWidth / 2,
                maxHeight: immersiveViewportHeight,
              );
              return Row(
                children: [
                  // 左侧：封面+ 歌曲信息 (50%) - 封面垂直居中于整个窗口
                  Expanded(
                    child: Transform.translate(
                      offset: const Offset(
                        0,
                        _normalLandscapeBottomAreaHeight / 2,
                      ),
                      child: Center(
                        child: _NowPlayingInfo(coverSizeOverride: coverSize),
                      ),
                    ),
                  ),
                  // 右侧：歌词区域(50%)
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
                          _ => Padding(
                              padding: const EdgeInsets.only(right: 8.0),
                              child: VerticalLyricView(
                                enableEdgeSpacer: true,
                                currentLineAlignment: currentLineAlignment,
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
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _NowPlayingSlider(
              mode: MediaQuery.of(context).orientation == Orientation.portrait
                  ? NowPlayingMode.portrait
                  : NowPlayingMode.landscape,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _DesktopLyricSwitch(),
                        spacer,
                        const _ExclusiveModeSwitch(),
                        spacer,
                        IconButton(
                          tooltip: '均衡器',
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (context) => const EqualizerDialog(),
                            );
                          },
                          icon: const Icon(Symbols.graphic_eq),
                          color: useMonet
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurface,
                        ),
                      ],
                    ),
                  ),
                  _AutoHidingControlBar(
                    child: ListenableBuilder(
                      listenable: playbackService.nowPlayingNotifier,
                      builder: (context, _) {
                        final hasNowPlaying =
                            playbackService.nowPlaying != null;

                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const _NowPlayingPlaybackModeSwitch(),
                            spacer,
                            IconButton(
                              tooltip: hasNowPlaying ? '上一曲' : '暂无正在播放',
                              onPressed: hasNowPlaying
                                  ? playbackService.lastAudio
                                  : null,
                              icon: const Icon(
                                Symbols.skip_previous,
                                fill: 1.0,
                              ),
                              iconSize: 28,
                              color: controlColor,
                              disabledColor: disabledColor,
                            ),
                            spacer,
                            StreamBuilder(
                              stream: playbackService.playerStateStream,
                              initialData: playbackService.playerState,
                              builder: (context, snapshot) {
                                final state = snapshot.data!;
                                final isPlaying = state == PlayerState.playing;
                                final isCompleted =
                                    state == PlayerState.completed;

                                return IconButton(
                                  tooltip: hasNowPlaying
                                      ? (isPlaying ? '暂停' : '播放')
                                      : '暂无正在播放',
                                  onPressed: hasNowPlaying
                                      ? () {
                                          if (isPlaying) {
                                            playbackService.pause();
                                          } else if (isCompleted) {
                                            playbackService.playAgain();
                                          } else {
                                            playbackService.start();
                                          }
                                        }
                                      : null,
                                  icon: Icon(
                                    isPlaying
                                        ? Symbols.pause
                                        : Symbols.play_arrow,
                                    fill: 1.0,
                                  ),
                                  iconSize: 36,
                                  color: controlColor,
                                  disabledColor: disabledColor,
                                );
                              },
                            ),
                            spacer,
                            IconButton(
                              tooltip: hasNowPlaying ? '下一曲' : '暂无正在播放',
                              onPressed: hasNowPlaying
                                  ? playbackService.nextAudio
                                  : null,
                              icon: const Icon(
                                Symbols.skip_next,
                                fill: 1.0,
                              ),
                              iconSize: 28,
                              color: controlColor,
                              disabledColor: disabledColor,
                            ),
                            spacer,
                            const _NowPlayingLargeViewSwitch(),
                          ],
                        );
                      },
                    ),
                  ),
                  const Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _NowPlayingVolDspSlider(),
                        spacer,
                        NowPlayingPitchControl(),
                        spacer,
                        _NowPlayingMoreAction(),
                      ],
                    ),
                  )
                ],
              ),
            ),
          ],
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
          borderRadius: AppRadius.mdCircular,
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
class _NowPlayingLargeViewSwitch extends StatefulWidget {
  const _NowPlayingLargeViewSwitch();

  @override
  State<_NowPlayingLargeViewSwitch> createState() =>
      _NowPlayingLargeViewSwitchState();
}

class _NowPlayingLargeViewSwitchState
    extends State<_NowPlayingLargeViewSwitch> {
  Future<void> _changeView(NowPlayingViewMode currentViewMode) async {
    final nextViewMode = currentViewMode == NowPlayingViewMode.onlyMain ||
            currentViewMode == NowPlayingViewMode.withLyric
        ? NowPlayingViewMode.withPlaylist
        : NowPlayingViewMode.withLyric;

    nowPlayingViewMode.value = nextViewMode;
    AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode = nextViewMode;
    await AppPreference.instance.save();
  }

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final scheme = Theme.of(context).colorScheme;
    final color = useMonet ? scheme.primary : scheme.onSurface;
    final disabledColor = color.withValues(alpha: 0.38);

    return ValueListenableBuilder(
      valueListenable: nowPlayingViewMode,
      builder: (context, value, _) => IconButton(
        tooltip: switch (value) {
          NowPlayingViewMode.withPlaylist => '歌词',
          _ => '播放列表',
        },
        onPressed: () => _changeView(value),
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
        color: color,
        disabledColor: disabledColor,
      ),
    );
  }
}
