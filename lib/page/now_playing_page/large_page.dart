part of 'page.dart';

class _NowPlayingPage_Large extends StatelessWidget {
  const _NowPlayingPage_Large();

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
                  const Expanded(child: Center(child: _NowPlayingInfo())),
                  Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: NOW_PLAYING_VIEW_MODE,
                      builder: (context, value, _) => AnimatedSwitcher(
                        duration: MotionDuration.base,
                        switchInCurve: MotionCurve.standard,
                        switchOutCurve: MotionCurve.standard,
                        child: switch (value) {
                          NowPlayingViewMode.withPlaylist =>
                            const CurrentPlaylistView(),
                          _ => Center(
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 820.0),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16.0),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      const Padding(
                                        padding: EdgeInsets.symmetric(
                                            horizontal: 8.0),
                                        child: VerticalLyricView(),
                                      ),
                                    ],
                                  ),
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
        const SizedBox(height: 12.0),
        const _NowPlayingSlider(),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 20),
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
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
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
                    _GlowingIconButton(
                      tooltip: "上一曲",
                      onPressed: PlayService.instance.playbackService.lastAudio,
                      iconData: Symbols.skip_previous,
                      size: 32,
                      glowColor: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.5),
                      iconColor:
                          Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                    spacer,
                    StreamBuilder(
                      stream: PlayService
                          .instance.playbackService.playerStateStream,
                      initialData:
                          PlayService.instance.playbackService.playerState,
                      builder: (context, snapshot) {
                        final state = snapshot.data!;
                        final service = PlayService.instance.playbackService;
                        return _MorphPlayPauseButton(
                          playerState: state,
                          onPlay: service.start,
                          onPause: service.pause,
                          onReplay: service.playAgain,
                          size: 32,
                          glowColor: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.5),
                          color: Theme.of(context)
                              .colorScheme
                              .onSecondaryContainer,
                          playerStateStream: service.playerStateStream,
                        );
                      },
                    ),
                    spacer,
                    _GlowingIconButton(
                      tooltip: "下一曲",
                      onPressed: PlayService.instance.playbackService.nextAudio,
                      iconData: Symbols.skip_next,
                      size: 32,
                      glowColor: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.5),
                      iconColor:
                          Theme.of(context).colorScheme.onSecondaryContainer,
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
      valueListenable: NOW_PLAYING_VIEW_MODE,
      builder: (context, value, _) => IconButton(
        tooltip: switch (value) {
          NowPlayingViewMode.withPlaylist => "歌词",
          _ => "播放列表",
        },
        onPressed: () {
          if (value == NowPlayingViewMode.onlyMain ||
              value == NowPlayingViewMode.withLyric) {
            NOW_PLAYING_VIEW_MODE.value = NowPlayingViewMode.withPlaylist;
            AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode =
                NowPlayingViewMode.withPlaylist;
          } else {
            NOW_PLAYING_VIEW_MODE.value = NowPlayingViewMode.withLyric;
            AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode =
                NowPlayingViewMode.withLyric;
          }
        },
        icon: switch (value) {
          NowPlayingViewMode.withPlaylist => const _MergedPlaylistIcon(),
          _ => const Icon(Symbols.queue_music),
        },
        color: scheme.onSecondaryContainer,
      ),
    );
  }
}

class _MergedPlaylistIcon extends StatelessWidget {
  const _MergedPlaylistIcon();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      size: const Size(24, 24),
      painter: _MergedPlaylistIconPainter(
        noteColor: scheme.primary,
        listColor: scheme.onSecondaryContainer,
      ),
    );
  }
}

class _MergedPlaylistIconPainter extends CustomPainter {
  final Color noteColor;
  final Color listColor;

  _MergedPlaylistIconPainter({
    required this.noteColor,
    required this.listColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round;

    // Drawing parameters
    const double barHeight = 3.0;
    const double startX = 11.0;
    const double endX = 22.0;
    const double headRadius = 3.5;

    // Y positions for the three bars (centered vertically approx)
    const double topY = 6.0;
    const double midY = 12.0;
    const double botY = 18.0;

    // 1. Draw List Lines (Right side)
    paint.color = listColor;

    // Top Bar
    canvas.drawRRect(
      RRect.fromLTRBR(
        startX,
        topY - barHeight / 2,
        endX,
        topY + barHeight / 2,
        const Radius.circular(barHeight / 2),
      ),
      paint,
    );

    // Mid Bar
    canvas.drawRRect(
      RRect.fromLTRBR(
        startX,
        midY - barHeight / 2,
        endX,
        midY + barHeight / 2,
        const Radius.circular(barHeight / 2),
      ),
      paint,
    );

    // Bot Bar
    canvas.drawRRect(
      RRect.fromLTRBR(
        startX,
        botY - barHeight / 2,
        endX,
        botY + barHeight / 2,
        const Radius.circular(barHeight / 2),
      ),
      paint,
    );

    // 2. Draw Music Note (Left side)
    paint.color = noteColor;

    // Note Head
    const headCenter = Offset(6.0, 18.0);
    canvas.drawCircle(headCenter, headRadius, paint);

    // Stem
    const double stemWidth = 2.5;
    final stemRect = RRect.fromLTRBR(
      headCenter.dx + headRadius - stemWidth,
      4.0, // Top of stem
      headCenter.dx + headRadius,
      18.0, // Bottom of stem (center of head)
      const Radius.circular(1.0),
    );
    canvas.drawRRect(stemRect, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
