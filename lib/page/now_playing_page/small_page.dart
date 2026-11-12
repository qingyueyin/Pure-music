part of 'page.dart';

class _NowPlayingSmallPage extends StatefulWidget {
  const _NowPlayingSmallPage({required this.cursorHidden});

  final ValueListenable<bool> cursorHidden;

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
  IconData viewSwitchIcon(NowPlayingViewMode viewMode) {
    return switch (viewMode) {
      NowPlayingViewMode.onlyMain => Symbols.music_note,
      NowPlayingViewMode.withLyric => Symbols.lyrics,
      NowPlayingViewMode.withPlaylist => Symbols.queue_music,
    };
  }

  String viewSwitchTooltip(NowPlayingViewMode viewMode) {
    return switch (viewMode) {
      NowPlayingViewMode.onlyMain => '封面',
      NowPlayingViewMode.withLyric => '歌词',
      NowPlayingViewMode.withPlaylist => '播放列表',
    };
  }

  void changeView(NowPlayingViewMode viewMode) {
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
    setState(() => views = desView);
    nowPlayingViewMode.value = viewMode;
    AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode = viewMode;
    unawaited(AppPreference.instance.save());
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          Expanded(child: _centerRow()),
          const SizedBox(height: 4.0),
          const _NowPlayingSmallControlZone(),
        ],
      ),
    );
  }

  Widget _centerRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PortraitViewSwitch(
          cursorHidden: widget.cursorHidden,
          onTap: () => changeView(views[0]),
          icon: viewSwitchIcon(views[0]),
          tooltip: viewSwitchTooltip(views[0]),
        ),
        Expanded(child: _centerView()),
        _PortraitViewSwitch(
          cursorHidden: widget.cursorHidden,
          onTap: () => changeView(views[2]),
          icon: viewSwitchIcon(views[2]),
          tooltip: viewSwitchTooltip(views[2]),
        ),
      ],
    );
  }

  Widget _centerView() {
    return AnimatedSwitcher(
      duration: MotionDuration.base,
      switchInCurve: MotionCurve.standard,
      switchOutCurve: MotionCurve.standard,
      child: switch (views[1]) {
        NowPlayingViewMode.onlyMain => const RepaintBoundary(
          child: Center(child: _NowPlayingInfo(usePortraitCoverSize: true)),
        ),
        NowPlayingViewMode.withLyric => RepaintBoundary(
          child: Padding(
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
        ),
        NowPlayingViewMode.withPlaylist => const CurrentPlaylistView(),
      },
    );
  }
}

class _PortraitViewSwitch extends StatelessWidget {
  const _PortraitViewSwitch({
    required this.cursorHidden,
    required this.onTap,
    required this.icon,
    required this.tooltip,
  });

  final ValueListenable<bool> cursorHidden;
  final VoidCallback onTap;
  final IconData icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.rebuildNotifier,
      builder: (context, _) => ValueListenableBuilder<bool>(
        valueListenable: cursorHidden,
        builder: (context, hidden, _) => _switch(hidden),
      ),
    );
  }

  Widget _switch(bool hidden) {
    return NowPlayingSmallViewSwitch(
      onTap: onTap,
      icon: icon,
      tooltip: tooltip,
      topInset: nowPlayingTopChromeHeight,
      revealed: nowPlayingSmallViewSwitchRevealed(
        alwaysShowControls: AppSettings.instance.alwaysShowNowPlayingControls,
        cursorHidden: hidden,
      ),
    );
  }


}

/// 竖屏底部控制区：进度条 + 主控排常驻；次要功能排悬停展开，离开后收回高度
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
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      hitTestBehavior: HitTestBehavior.translucent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: RepaintBoundary(
              child: _NowPlayingSlider(
                mode:
                    MediaQuery.of(context).orientation == Orientation.portrait
                    ? NowPlayingMode.portrait
                    : NowPlayingMode.landscape,
              ),
            ),
          ),
          const SizedBox(height: 4.0),
          const _NowPlayingSmallMainControls(),
          _secondaryChrome(),
        ],
      ),
    );
  }

  Widget _secondaryChrome() {
    final controlColor = playerChromeForeground(
      context,
      enabled: AppSettings.instance.useMaterialYouForControls,
    );
    return ListenableBuilder(
      listenable: AppSettings.rebuildNotifier,
      builder: (context, _) {
        final visible =
            AppSettings.instance.alwaysShowNowPlayingControls || _isHovering;
        return NowPlayingCollapsibleChrome(
          visible: visible,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8.0, 4.0, 8.0, 0),
            child: _secondaryButtons(controlColor),
          ),
        );
      },
    );
  }


  Widget _secondaryButtons(Color controlColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        const _DesktopLyricSwitch(),
        const NowPlayingPitchControl(),
        const _ExclusiveModeSwitch(),
        _eqButton(controlColor),
        const _NowPlayingMoreAction(),
      ],
    );
  }

  Widget _eqButton(Color controlColor) {
    return IconButton(
      tooltip: '均衡器',
      onPressed: () {
        showDialog<void>(
          context: context,
          builder: (context) => const EqualizerDialog(),
        );
      },
      icon: const Icon(Symbols.graphic_eq),
      color: controlColor,
    );
  }

}

/// 竖屏主控排：播放模式 + 上一曲 / 播放 / 下一曲 + 音量，常驻显示
class _NowPlayingSmallMainControls extends StatelessWidget {
  const _NowPlayingSmallMainControls();

  @override
  Widget build(BuildContext context) {
    final playbackService = PlayService.instance.playbackService;
    final controlColor = playerChromeForeground(
      context,
      enabled: AppSettings.instance.useMaterialYouForControls,
    );
    return ListenableBuilder(
      listenable: playbackService.nowPlayingNotifier,
      builder: (context, _) => _controlsRow(playbackService, controlColor),
    );
  }

  Widget _controlsRow(PlaybackService playbackService, Color controlColor) {
    final hasNowPlaying = playbackService.nowPlaying != null;
    final disabledColor = controlColor.withValues(alpha: 0.38);
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
        _playPauseButton(playbackService, controlColor, disabledColor),
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
    Color controlColor,
    Color disabledColor,
  ) {
    final hasNowPlaying = playbackService.nowPlaying != null;
    return ValueListenableBuilder<PlayerState>(
      valueListenable: playbackService.playerStateNotifier,
      builder: (context, playerState, _) {
        final isPlaying = playerState == PlayerState.playing;
        final isCompleted = playerState == PlayerState.completed;
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
