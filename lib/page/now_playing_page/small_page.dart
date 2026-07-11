part of 'page.dart';

class _NowPlayingSmallPage extends StatefulWidget {
  const _NowPlayingSmallPage();

  @override
  State<_NowPlayingSmallPage> createState() => _NowPlayingSmallPageState();
}

class _NowPlayingSmallPageState extends State<_NowPlayingSmallPage> {
  static const viewOnlyMain = [
    NowPlayingViewMode.withPlaylist,
    NowPlayingViewMode.onlyMain,
    NowPlayingViewMode.withLyric,
  ];
  static const viewWithLyric = [
    NowPlayingViewMode.onlyMain,
    NowPlayingViewMode.withLyric,
    NowPlayingViewMode.withPlaylist,
  ];
  static const viewWithPlaylist = [
    NowPlayingViewMode.withLyric,
    NowPlayingViewMode.withPlaylist,
    NowPlayingViewMode.onlyMain,
  ];
  late var views =
      switch (AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode) {
    NowPlayingViewMode.onlyMain => viewOnlyMain,
    NowPlayingViewMode.withLyric => viewWithLyric,
    NowPlayingViewMode.withPlaylist => viewWithPlaylist,
  };
  NowPlayingViewMode? _savingViewMode;

  IconData viewSwitchIcon(NowPlayingViewMode viewMode) {
    return switch (viewMode) {
      NowPlayingViewMode.onlyMain => Symbols.music_note,
      NowPlayingViewMode.withLyric => Symbols.lyrics,
      NowPlayingViewMode.withPlaylist => Symbols.queue_music,
    };
  }

  Future<void> changeView(NowPlayingViewMode viewMode) async {
    if (_savingViewMode != null) return;

    late final List<NowPlayingViewMode> desView;
    switch (viewMode) {
      case NowPlayingViewMode.onlyMain:
        desView = viewOnlyMain;
        break;
      case NowPlayingViewMode.withLyric:
        desView = viewWithLyric;
        break;
      case NowPlayingViewMode.withPlaylist:
        desView = viewWithPlaylist;
        break;
    }
    setState(() {
      views = desView;
      _savingViewMode = viewMode;
    });
    nowPlayingViewMode.value = viewMode;
    AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode = viewMode;
    try {
      await AppPreference.instance.save();
    } finally {
      if (mounted) {
        setState(() => _savingViewMode = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _NowPlayingSmallViewSwitch(
                  onTap: () => changeView(views[0]),
                  icon: viewSwitchIcon(views[0]),
                  busy: _savingViewMode == views[0],
                  enabled: _savingViewMode == null,
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: MotionDuration.base,
                    switchInCurve: MotionCurve.standard,
                    switchOutCurve: MotionCurve.standard,
                    child: switch (views[1]) {
                      NowPlayingViewMode.onlyMain =>
                        const Center(child: _NowPlayingInfo()),
                      NowPlayingViewMode.withLyric => Padding(
                          // 负 padding 抵消歌词行内部 12px 水平 padding，让歌词贴近切换按钮
                          padding: const EdgeInsets.symmetric(horizontal: -12.0),
                          child: ClipRRect(
                            borderRadius: AppRadius.mdCircular,
                            child: const VerticalLyricView(
                              showControls: true,
                              centerVertically: false,
                              enableEdgeSpacer: true,
                              currentLineAlignment: 0.3,
                            ),
                          ),
                        ),
                      NowPlayingViewMode.withPlaylist =>
                        const CurrentPlaylistView(),
                    },
                  ),
                ),
                _NowPlayingSmallViewSwitch(
                  onTap: () => changeView(views[2]),
                  icon: viewSwitchIcon(views[2]),
                  busy: _savingViewMode == views[2],
                  enabled: _savingViewMode == null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4.0),
          const _NowPlayingSmallControlZone(),
        ],
      ),
    );
  }
}

/// 竖屏底部控制区：进度条 + 主控排常驻，次要功能排随鼠标离开淡出
class _NowPlayingSmallControlZone extends StatefulWidget {
  const _NowPlayingSmallControlZone();

  @override
  State<_NowPlayingSmallControlZone> createState() =>
      _NowPlayingSmallControlZoneState();
}

class _NowPlayingSmallControlZoneState
    extends State<_NowPlayingSmallControlZone> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final controlColor = useMonet
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurface;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      hitTestBehavior: HitTestBehavior.translucent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _NowPlayingSlider(
              mode: MediaQuery.of(context).orientation == Orientation.portrait
                  ? NowPlayingMode.portrait
                  : NowPlayingMode.landscape,
            ),
          ),
          const SizedBox(height: 4.0),
          const _NowPlayingSmallMainControls(),
          const SizedBox(height: 4.0),
          AnimatedOpacity(
            duration: MotionDuration.base,
            curve: MotionCurve.standard,
            opacity: _isHovering ? 1.0 : 0.0,
            child: IgnorePointer(
              ignoring: !_isHovering,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    const _DesktopLyricSwitch(),
                    const NowPlayingPitchControl(),
                    const _ExclusiveModeSwitch(),
                    IconButton(
                      tooltip: '均衡器',
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) => const EqualizerDialog(),
                        );
                      },
                      icon: const Icon(Symbols.graphic_eq),
                      color: controlColor,
                    ),
                    const _NowPlayingMoreAction(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 竖屏主控排：播放模式 + 上一曲 / 播放 / 下一曲 + 音量，常驻显示
class _NowPlayingSmallMainControls extends StatelessWidget {
  const _NowPlayingSmallMainControls();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playbackService = PlayService.instance.playbackService;
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final controlColor = useMonet ? scheme.primary : scheme.onSurface;
    final disabledColor = controlColor.withValues(alpha: 0.38);

    return ListenableBuilder(
      listenable: playbackService.nowPlayingNotifier,
      builder: (context, _) {
        final hasNowPlaying = playbackService.nowPlaying != null;

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const _NowPlayingPlaybackModeSwitch(),
            const SizedBox(width: 16),
            IconButton(
              tooltip: hasNowPlaying ? '上一曲' : '暂无正在播放',
              onPressed: hasNowPlaying ? playbackService.lastAudio : null,
              icon: const Icon(Symbols.skip_previous, fill: 1.0),
              iconSize: 28,
              color: controlColor,
              disabledColor: disabledColor,
            ),
            const SizedBox(width: 16),
            StreamBuilder(
              stream: playbackService.playerStateStream,
              initialData: playbackService.playerState,
              builder: (context, snapshot) {
                final playerState = snapshot.data!;
                final isPlaying = playerState == PlayerState.playing;
                final isCompleted = playerState == PlayerState.completed;

                return IconButton(
                  tooltip: hasNowPlaying ? (isPlaying ? '暂停' : '播放') : '暂无正在播放',
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
                    isPlaying ? Symbols.pause : Symbols.play_arrow,
                    fill: 1.0,
                  ),
                  iconSize: 36,
                  color: controlColor,
                  disabledColor: disabledColor,
                );
              },
            ),
            const SizedBox(width: 16),
            IconButton(
              tooltip: hasNowPlaying ? '下一曲' : '暂无正在播放',
              onPressed: hasNowPlaying ? playbackService.nextAudio : null,
              icon: const Icon(Symbols.skip_next, fill: 1.0),
              iconSize: 28,
              color: controlColor,
              disabledColor: disabledColor,
            ),
            const SizedBox(width: 16),
            const _NowPlayingVolDspSlider(),
          ],
        );
      },
    );
  }
}

class _NowPlayingSmallViewSwitch extends StatefulWidget {
  const _NowPlayingSmallViewSwitch({
    required this.onTap,
    required this.icon,
    this.busy = false,
    this.enabled = true,
  });

  final void Function() onTap;
  final IconData icon;
  final bool busy;
  final bool enabled;

  @override
  State<_NowPlayingSmallViewSwitch> createState() =>
      _NowPlayingSmallViewSwitchState();
}

class _NowPlayingSmallViewSwitchState
    extends State<_NowPlayingSmallViewSwitch> {
  bool visible = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final useMonet = AppSettings.instance.useMaterialYouForControls;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: SizedBox(
        width: 32,
        child: Material(
          borderRadius: AppRadius.mdCircular,
          type: MaterialType.transparency,
          child: AnimatedOpacity(
            duration: MotionDuration.fast,
            curve: MotionCurve.standard,
            opacity: visible ? 1.0 : 0.0,
            child: AnimatedScale(
              duration: MotionDuration.fast,
              curve: MotionCurve.standard,
              scale: visible ? 1.0 : 0.94,
              child: InkWell(
                borderRadius: AppRadius.mdCircular,
                hoverColor: scheme.onSecondaryContainer.withValues(alpha: 0.02),
                highlightColor:
                    scheme.onSecondaryContainer.withValues(alpha: 0.04),
                splashColor: Colors.transparent,
                onTap: widget.enabled ? widget.onTap : null,
                onHover: (hasEntered) {
                  if (!widget.enabled) return;
                  setState(() {
                    visible = hasEntered;
                  });
                },
                child: Center(
                  child: widget.busy
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: useMonet ? scheme.primary : scheme.onSurface,
                          ),
                        )
                      : Icon(
                          widget.icon,
                          color: widget.enabled
                              ? (useMonet ? scheme.primary : scheme.onSurface)
                              : (useMonet ? scheme.primary : scheme.onSurface)
                                  .withValues(alpha: 0.38),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
