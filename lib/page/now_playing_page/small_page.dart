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
    });
    nowPlayingViewMode.value = viewMode;
    AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode = viewMode;
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
                          padding: const EdgeInsets.symmetric(horizontal: 0),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16.0),
                            child: VerticalLyricView(
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
                ),
              ],
            ),
          ),
          const SizedBox(height: 4.0),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: _NowPlayingSlider(),
          ),
          const SizedBox(height: 4.0),
          const _NowPlayingMainControls(),
          const SizedBox(height: 4.0),
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
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
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
                hoverColor: scheme.onSecondaryContainer.withValues(alpha: 0.02),
                highlightColor: scheme.onSecondaryContainer.withValues(alpha: 0.04),
                splashColor: Colors.transparent,
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
