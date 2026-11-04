part of 'page.dart';

class _NowPlayingLargePage extends StatelessWidget {
  const _NowPlayingLargePage({required this.cursorHidden});

  final ValueListenable<bool> cursorHidden;

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final controlColor = playerChromeForeground(context, enabled: useMonet);
    return Column(
      children: [
        Expanded(child: _stage()),
        _bottomArea(context, controlColor, useMonet),
      ],
    );
  }

  Widget _stage() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24.0, 8.0, 24.0, 8.0),
      child: LayoutBuilder(
        builder: (context, constraints) => _stageRow(context, constraints),
      ),
    );
  }


  Widget _stageRow(BuildContext context, BoxConstraints constraints) {
    final immersiveViewportHeight = MediaQuery.sizeOf(context).height - 16.0;
    final currentLineAlignment =
        (immersiveViewportHeight * 0.45 / constraints.maxHeight)
            .clamp(0.0, 1.0)
            .toDouble();
    final coverSize = _responsiveNowPlayingCoverSize(
      maxWidth: constraints.maxWidth / 2,
      maxHeight: immersiveViewportHeight,
    );
    return Row(
      children: [
        Expanded(
          child: RepaintBoundary(
            child: Transform.translate(
              offset: const Offset(0, _normalLandscapeBottomAreaHeight / 2),
              child: Center(
                child: _NowPlayingInfo(coverSizeOverride: coverSize),
              ),
            ),
          ),
        ),
        Expanded(child: _rightPane(currentLineAlignment)),
      ],
    );
  }

  Widget _rightPane(double currentLineAlignment) {
    return ValueListenableBuilder(
      valueListenable: nowPlayingViewMode,
      builder: (context, value, _) => AnimatedSwitcher(
        duration: MotionDuration.base,
        switchInCurve: MotionCurve.standard,
        switchOutCurve: MotionCurve.standard,
        child: switch (value) {
          NowPlayingViewMode.withPlaylist => const CurrentPlaylistView(),
          _ => RepaintBoundary(
            child: Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: PerfLayers.lyrics
                  ? VerticalLyricView(
                      enableEdgeSpacer: true,
                      currentLineAlignment: currentLineAlignment,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        },
      ),
    );
  }

  Widget _bottomArea(BuildContext context, Color controlColor, bool useMonet) {
    final playbackService = PlayService.instance.playbackService;
    final disabledColor = controlColor.withValues(alpha: 0.38);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RepaintBoundary(
          child: _NowPlayingSlider(
            mode: MediaQuery.of(context).orientation == Orientation.portrait
                ? NowPlayingMode.portrait
                : NowPlayingMode.landscape,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: _controlStack(context, playbackService, controlColor, useMonet, disabledColor),
        ),
      ],
    );
  }


  Widget _controlStack(
    BuildContext context,
    PlaybackService playbackService,
    Color controlColor,
    bool useMonet,
    Color disabledColor,
  ) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: _CursorIdleVisibility(
            cursorHidden: cursorHidden,
            child: _leftButtons(context, controlColor, useMonet),
          ),
        ),
        _AutoHidingControlBar(
          child: ListenableBuilder(
            listenable: playbackService.nowPlayingNotifier,
            builder: (context, _) =>
                _transport(playbackService, controlColor, disabledColor),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: _CursorIdleVisibility(
            cursorHidden: cursorHidden,
            child: _rightTools(),
          ),
        ),
      ],
    );
  }

  Widget _rightTools() {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _NowPlayingVolDspSlider(),
        SizedBox(width: 8.0),
        NowPlayingPitchControl(),
        SizedBox(width: 8.0),
        SetLyricSourceBtn(),
        SizedBox(width: 8.0),
        _NowPlayingMoreAction(showLyricSource: false),
      ],
    );
  }

  Widget _leftButtons(BuildContext context, Color controlColor, bool useMonet) {
    const spacer = SizedBox(width: 8.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '收起播放页',
          onPressed: () {
            if (context.canPop()) context.pop();
          },
          icon: const Icon(Symbols.keyboard_arrow_down),
          color: controlColor,
        ),
        spacer,
        const _DesktopLyricSwitch(),
        spacer,
        const _ExclusiveModeSwitch(),
        spacer,
        IconButton(
          tooltip: '均衡器',
          onPressed: () {
            showDialog<void>(
              context: context,
              builder: (context) => const EqualizerDialog(),
            );
          },
          icon: const Icon(Symbols.graphic_eq),
          color: playerChromeForeground(context, enabled: useMonet),
        ),
      ],
    );
  }

  Widget _transport(
    PlaybackService playbackService,
    Color controlColor,
    Color disabledColor,
  ) {
    const spacer = SizedBox(width: 8.0);
    final hasNowPlaying = playbackService.nowPlaying != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _NowPlayingPlaybackModeSwitch(),
        spacer,
        IconButton(
          tooltip: hasNowPlaying ? '上一曲' : '暂无正在播放',
          onPressed: hasNowPlaying ? playbackService.lastAudio : null,
          icon: const Icon(Symbols.skip_previous, fill: 1.0),
          iconSize: 28,
          color: controlColor,
          disabledColor: disabledColor,
        ),
        spacer,
        _playPauseButton(
          playbackService,
          hasNowPlaying,
          controlColor,
          disabledColor,
        ),
        spacer,
        IconButton(
          tooltip: hasNowPlaying ? '下一曲' : '暂无正在播放',
          onPressed: hasNowPlaying ? playbackService.nextAudio : null,
          icon: const Icon(Symbols.skip_next, fill: 1.0),
          iconSize: 28,
          color: controlColor,
          disabledColor: disabledColor,
        ),
        spacer,
        const _NowPlayingLargeViewSwitch(),
      ],
    );
  }


  void _togglePlay(
    PlaybackService playbackService,
    bool isPlaying,
    bool isCompleted,
  ) {
    if (isPlaying) {
      playbackService.pause();
    } else if (isCompleted) {
      playbackService.playAgain();
    } else {
      playbackService.start();
    }
  }

  Widget _playPauseButton(
    PlaybackService playbackService,
    bool hasNowPlaying,
    Color controlColor,
    Color disabledColor,
  ) {
    return ValueListenableBuilder<PlayerState>(
      valueListenable: playbackService.playerStateNotifier,
      builder: (context, state, _) {
        final isPlaying = state == PlayerState.playing;
        final isCompleted = state == PlayerState.completed;
        return IconButton(
          tooltip: hasNowPlaying ? (isPlaying ? '暂停' : '播放') : '暂无正在播放',
          onPressed: hasNowPlaying
              ? () => _togglePlay(playbackService, isPlaying, isCompleted)
              : null,
          icon: Icon(isPlaying ? Symbols.pause : Symbols.play_arrow, fill: 1.0),
          iconSize: 36,
          color: controlColor,
          disabledColor: disabledColor,
        );
      },
    );
  }
}

/// 左、右两组控件共用：跟顶部一样，光标空闲后隐藏，鼠标一动就出；「播放控件常驻」打开时保持显示。
class _CursorIdleVisibility extends StatelessWidget {
  const _CursorIdleVisibility({
    required this.cursorHidden,
    required this.child,
  });

  final ValueListenable<bool> cursorHidden;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: cursorHidden,
      builder: (context, hidden, _) => ListenableBuilder(
        listenable: AppSettings.rebuildNotifier,
        builder: (context, _) {
          final visible =
              AppSettings.instance.alwaysShowNowPlayingControls || !hidden;
          return AnimatedOpacity(
            duration: MotionDuration.xFast,
            curve: MotionCurve.standard,
            opacity: visible ? 1.0 : 0.0,
            child: IgnorePointer(ignoring: !visible, child: child),
          );
        },
      ),
    );
  }
}

/// 中间播放键：默认悬停才现，「播放键常驻」打开时保持显示。
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
        child: ListenableBuilder(
          listenable: AppSettings.rebuildNotifier,
          builder: (context, _) => AnimatedOpacity(
            duration: MotionDuration.base,
            curve: MotionCurve.standard,
            opacity:
                AppSettings.instance.alwaysShowNowPlayingTransport ||
                    _isHovering
                ? 1.0
                : 0.0,
            child: IgnorePointer(
              ignoring:
                  !AppSettings.instance.alwaysShowNowPlayingTransport &&
                  !_isHovering,
              child: widget.child,
            ),
          ),
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
    final nextViewMode =
        currentViewMode == NowPlayingViewMode.onlyMain ||
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
    final color = playerChromeForeground(context, enabled: useMonet);
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
          _ => const Icon(Symbols.queue_music, fill: 1.0),
        },
        color: color,
        disabledColor: disabledColor,
      ),
    );
  }
}
