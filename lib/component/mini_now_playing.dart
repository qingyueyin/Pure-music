import 'dart:async';

import 'package:pure_music/component/rectangle_progress_indicator.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

class MiniNowPlaying extends StatelessWidget {
  const MiniNowPlaying({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ResponsiveBuilder(builder: (context, screenType) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            8.0,
            0,
            8.0,
            screenType == ScreenType.small ? 8.0 : 32.0,
          ),
          child: SizedBox(
            height: 64.0,
            width: 600.0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                boxShadow: kElevationToShadow[4],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LayoutBuilder(builder: (context, constraints) {
                  return RectangleProgressIndicator(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    child: const _NowPlayingForeground(),
                  );
                }),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _NowPlayingForeground extends StatefulWidget {
  const _NowPlayingForeground();

  @override
  State<_NowPlayingForeground> createState() => _NowPlayingForegroundState();
}

class _NowPlayingForegroundState extends State<_NowPlayingForeground> {
  bool _hovered = false;
  bool _controlsVisible = false;
  Timer? _controlsHideTimer;
  String? _lastPrecachedCoverPath;
  int _precacheToken = 0;

  void _maybePrecacheCover({
    required String path,
    required ImageProvider image,
  }) {
    if (_lastPrecachedCoverPath == path) return;
    _lastPrecachedCoverPath = path;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      precacheImage(image, context);
    });
  }

  void _setControlsVisible(bool visible) {
    if (_controlsVisible == visible) return;
    setState(() => _controlsVisible = visible);
  }

  void _scheduleHideControls() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      if (_hovered) return;
      _setControlsVisible(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return IconButtonTheme(
      data: IconButtonThemeData(
        style: ButtonStyle(
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return scheme.onSecondaryContainer.withValues(alpha: 0.04);
            }
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return scheme.onSecondaryContainer.withValues(alpha: 0.02);
            }
            return Colors.transparent;
          }),
        ),
      ),
      child: AnimatedContainer(
        duration: MotionDuration.fast,
        curve: MotionCurve.standard,
        decoration: BoxDecoration(
          color:
              _hovered ? scheme.onSecondaryContainer.withOpacity(0.06) : null,
          borderRadius: BorderRadius.circular(8.0),
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(8.0),
          child: InkWell(
            onHover: (v) {
              _controlsHideTimer?.cancel();
              setState(() => _hovered = v);
              if (v) {
                _setControlsVisible(true);
              } else {
                _scheduleHideControls();
              }
            },
            onTap: () {
              final playbackService = PlayService.instance.playbackService;
              final nowPlaying = playbackService.nowPlaying;
              if (nowPlaying != null && !playbackService.nowPlayingChangedRecently) {
                _precacheToken += 1;
                final token = _precacheToken;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  nowPlaying.mediumCover.then((image) {
                    if (!mounted) return;
                    if (token != _precacheToken) return;
                    if (image != null) precacheImage(image, context);
                  });
                });
              }
              context.push(app_paths.NOW_PLAYING_PAGE);
            },
            borderRadius: BorderRadius.circular(8.0),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: ListenableBuilder(
                listenable: PlayService.instance.playbackService,
                builder: (context, _) {
                  final playbackService = PlayService.instance.playbackService;
                  final nowPlaying = playbackService.nowPlaying;
                  final heroEnabled = !playbackService.nowPlayingChangedRecently;
                  final placeholder = Icon(
                    Symbols.broken_image,
                    size: 48.0,
                    color: scheme.onSecondaryContainer,
                  );

                  return LayoutBuilder(builder: (context, constraints) {
                    final dense = constraints.maxWidth <= 520;
                    final minimal = constraints.maxWidth <= 440;
                    final hideControls = !_controlsVisible;
                    final controls = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!dense)
                          IconButton(
                            tooltip: "上一曲",
                            onPressed: playbackService.lastAudio,
                            icon: const Icon(
                              Symbols.skip_previous,
                              fill: 0.0,
                              weight: 400.0,
                            ),
                            color: scheme.onSecondaryContainer,
                          ),
                        _MiniPlayPauseButton(
                          dense: dense,
                          onSecondaryContainer: scheme.onSecondaryContainer,
                        ),
                        if (!dense)
                          IconButton(
                            tooltip: "下一曲",
                            onPressed: playbackService.nextAudio,
                            icon: const Icon(
                              Symbols.skip_next,
                              fill: 0.0,
                              weight: 400.0,
                            ),
                            color: scheme.onSecondaryContainer,
                          ),
                        if (!dense) const SizedBox(width: 8.0),
                        if (!dense)
                          _MiniTimeText(color: scheme.onSecondaryContainer),
                      ],
                    );
                    return Row(
                      children: [
                        nowPlaying != null
                            ? Builder(builder: (context) {
                                final cover = ClipRRect(
                                  borderRadius: BorderRadius.circular(8.0),
                                  child: SizedBox(
                                    width: 48.0,
                                    height: 48.0,
                                    child: FutureBuilder(
                                      future: nowPlaying.cover,
                                      builder: (context, snapshot) =>
                                          switch (snapshot.connectionState) {
                                        ConnectionState.done => snapshot.data ==
                                                null
                                            ? Center(child: placeholder)
                                            : Builder(builder: (context) {
                                                _maybePrecacheCover(
                                                  path: nowPlaying.path,
                                                  image: snapshot.data!,
                                                );
                                                return Image(
                                                  image: snapshot.data!,
                                                  fit: BoxFit.cover,
                                                  gaplessPlayback: true,
                                                  filterQuality:
                                                      FilterQuality.medium,
                                                  errorBuilder: (_, __, ___) =>
                                                      Center(
                                                    child: placeholder,
                                                  ),
                                                );
                                              }),
                                        _ => const Center(
                                            child: SizedBox(
                                              width: 20,
                                              height: 20,
                                              child:
                                                  CircularProgressIndicator(),
                                            ),
                                          ),
                                      },
                                    ),
                                  ),
                                );
                                if (!heroEnabled) return cover;
                                return Hero(tag: nowPlaying.path, child: cover);
                              })
                            : SizedBox(
                                width: 48.0,
                                height: 48.0,
                                child: Center(child: placeholder),
                              ),
                        const SizedBox(width: 8.0),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                nowPlaying != null
                                    ? nowPlaying.title
                                    : "Pure Music",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: scheme.onSecondaryContainer),
                              ),
                              Text(
                                nowPlaying != null
                                    ? "${nowPlaying.artist} - ${nowPlaying.album}"
                                    : "享受音乐",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: scheme.onSecondaryContainer),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8.0),
                        IgnorePointer(
                          ignoring: hideControls,
                          child: AnimatedSlide(
                            duration: MotionDuration.fast,
                            curve: MotionCurve.standard,
                            offset: hideControls
                                ? const Offset(0.02, 0.0)
                                : Offset.zero,
                            child: AnimatedOpacity(
                              duration: MotionDuration.fast,
                              curve: MotionCurve.standard,
                              opacity: hideControls ? 0.0 : 1.0,
                              child: controls,
                            ),
                          ),
                        ),
                      ],
                    );
                  });
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controlsHideTimer?.cancel();
    super.dispose();
  }
}

class _MiniPlayPauseButton extends StatelessWidget {
  const _MiniPlayPauseButton({
    required this.dense,
    required this.onSecondaryContainer,
  });

  final bool dense;
  final Color onSecondaryContainer;

  @override
  Widget build(BuildContext context) {
    final playbackService = PlayService.instance.playbackService;
    return _AnimatedPlayPauseIconButton(
      dense: dense,
      color: onSecondaryContainer,
      onPlay: playbackService.start,
      onPause: playbackService.pause,
      onReplay: playbackService.playAgain,
      playerStateStream: playbackService.playerStateStream,
      initialState: playbackService.playerState,
    );
  }
}

class _AnimatedPlayPauseIconButton extends StatefulWidget {
  const _AnimatedPlayPauseIconButton({
    required this.dense,
    required this.color,
    required this.onPlay,
    required this.onPause,
    required this.onReplay,
    required this.playerStateStream,
    required this.initialState,
  });

  final bool dense;
  final Color color;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onReplay;
  final Stream<PlayerState> playerStateStream;
  final PlayerState initialState;

  @override
  State<_AnimatedPlayPauseIconButton> createState() =>
      _AnimatedPlayPauseIconButtonState();
}

class _AnimatedPlayPauseIconButtonState
    extends State<_AnimatedPlayPauseIconButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 220));
  late PlayerState _state = widget.initialState;

  @override
  void initState() {
    super.initState();
    if (_state == PlayerState.playing) {
      _controller.value = 1.0;
    } else {
      _controller.value = 0.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: widget.playerStateStream,
      initialData: _state,
      builder: (context, snapshot) {
        _state = snapshot.data ?? _state;
        final isPlaying = _state == PlayerState.playing;
        _controller.animateTo(isPlaying ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 240),
            curve: const Cubic(0.2, 0.0, 0.0, 1.0));

        late VoidCallback onPressed;
        if (_state == PlayerState.playing) {
          onPressed = widget.onPause;
        } else if (_state == PlayerState.completed) {
          onPressed = widget.onReplay;
        } else {
          onPressed = widget.onPlay;
        }

        final icon = AnimatedIcon(
          icon: AnimatedIcons.play_pause,
          progress: _controller,
          color: widget.color,
          size: widget.dense ? 24.0 : 28.0,
        );

        return IconButton(
          tooltip: isPlaying ? "暂停" : "播放",
          onPressed: onPressed,
          icon: icon,
          color: widget.color,
        );
      },
    );
  }
}

class _MiniTimeText extends StatelessWidget {
  const _MiniTimeText({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final playbackService = PlayService.instance.playbackService;
    return StreamBuilder(
      stream: playbackService.positionStream,
      initialData: playbackService.position,
      builder: (context, snapshot) {
        final pos = snapshot.data!;
        final len = playbackService.length;
        final posText = Duration(milliseconds: (pos * 1000).toInt())
            .toStringHMMSS()
            .replaceFirst(RegExp(r'^0:'), '');
        final lenText = Duration(milliseconds: (len * 1000).toInt())
            .toStringHMMSS()
            .replaceFirst(RegExp(r'^0:'), '');
        return Text(
          "$posText / $lenText",
          style: TextStyle(
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
      },
    );
  }
}

class _MiniShuffleButton extends StatelessWidget {
  const _MiniShuffleButton({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final playbackService = PlayService.instance.playbackService;
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder(
      valueListenable: playbackService.shuffle,
      builder: (context, value, _) {
        final onPressed =
            enabled ? () => playbackService.useShuffle(!value) : null;
        return IconButton(
          tooltip: value ? "关闭随机" : "开启随机",
          onPressed: onPressed,
          icon: const Icon(Symbols.shuffle, fill: 0.0, weight: 400.0),
          color: value ? scheme.primary : scheme.onSecondaryContainer,
        );
      },
    );
  }
}
