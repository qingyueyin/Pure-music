part of 'page.dart';

class _NowPlayingPage_Small extends StatefulWidget {
  const _NowPlayingPage_Small();

  @override
  State<_NowPlayingPage_Small> createState() => _NowPlayingPage_SmallState();
}

class _NowPlayingPage_SmallState extends State<_NowPlayingPage_Small> {
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
    setState(() {
      views = desView;
      if (viewMode != NowPlayingViewMode.withLyric) {
        _hideBottomPanel = false;
      }
    });
    NOW_PLAYING_VIEW_MODE.value = viewMode;
    AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode = viewMode;
  }

  bool _hideBottomPanel = false;

  @override
  Widget build(BuildContext context) {
    final showLyric = views[1] == NowPlayingViewMode.withLyric;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _NowPlayingSmallViewSwitch(
                  onTap: () => changeView(views[0]),
                  icon: viewSwitchIcon(views[0]),
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
                          padding: const EdgeInsets.symmetric(horizontal: 12.0),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16.0),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Padding(
                                  padding:
                                      EdgeInsets.symmetric(horizontal: 8.0),
                                  child: VerticalLyricView(
                                    showControls: !_hideBottomPanel,
                                    centerVertically: _hideBottomPanel,
                                  ),
                                ),
                                Positioned(
                                  top: 10,
                                  right: 10,
                                  child: IconButton.filledTonal(
                                    tooltip: _hideBottomPanel
                                        ? "显示控制栏"
                                        : "隐藏控制栏并扩展歌词",
                                    onPressed: () {
                                      setState(() {
                                        _hideBottomPanel = !_hideBottomPanel;
                                      });
                                    },
                                    icon: Icon(
                                      _hideBottomPanel
                                          ? Symbols.expand_content
                                          : Symbols.collapse_content,
                                    ),
                                  ),
                                ),
                              ],
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
                ),
              ],
            ),
          ),
          if (!_hideBottomPanel) ...[
            const SizedBox(height: 6.0),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: _NowPlayingSlider(),
            ),
            const SizedBox(height: 6.0),
            const _NowPlayingMainControls(),
            const SizedBox(height: 6.0),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                const _DesktopLyricSwitch(),
                const _NowPlayingPlaybackModeSwitch(),
                const NowPlayingPitchControl(),
                const _NowPlayingVolDspSlider(),
                const _ExclusiveModeSwitch(),
                IconButton(
                  tooltip: "均衡器",
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => const EqualizerDialog(),
                    );
                  },
                  icon: const Icon(Symbols.graphic_eq),
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
                const _NowPlayingMoreAction(),
              ],
            )
          ] else ...[
            if (!showLyric) const SizedBox(height: 6.0),
          ],
        ],
      ),
    );
  }
}

class _NowPlayingSmallViewSwitch extends StatefulWidget {
  const _NowPlayingSmallViewSwitch({required this.onTap, required this.icon});

  final void Function() onTap;
  final IconData icon;

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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: SizedBox(
        width: 32,
        child: Material(
          borderRadius: BorderRadius.circular(16.0),
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
                borderRadius: BorderRadius.circular(16.0),
                hoverColor: scheme.onSecondaryContainer.withOpacity(0.08),
                highlightColor: scheme.onSecondaryContainer.withOpacity(0.12),
                splashColor: scheme.onSecondaryContainer.withOpacity(0.12),
                onTap: widget.onTap,
                onHover: (hasEntered) {
                  setState(() {
                    visible = hasEntered;
                  });
                },
                child: Center(
                  child: Icon(
                    widget.icon,
                    color: scheme.onSecondaryContainer,
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
