import 'dart:async';
import 'dart:typed_data';

import 'package:pure_music/component/rectangle_progress_indicator.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/library/audio_library.dart';
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
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600.0),
            child: SizedBox(
              height: 64.0,
              width: double.infinity,
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
  int _precacheToken = 0;

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
          color: _hovered
              ? scheme.onSecondaryContainer.withValues(alpha: 0.06)
              : null,
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
              if (nowPlaying != null &&
                  !playbackService.nowPlayingChangedRecently) {
                _precacheToken += 1;
                final token = _precacheToken;
                final config = createLocalImageConfiguration(context);
                Future<void> precacheProvider(ImageProvider provider) {
                  final completer = Completer<void>();
                  final stream = provider.resolve(config);
                  late final ImageStreamListener listener;
                  listener = ImageStreamListener(
                    (_, __) {
                      stream.removeListener(listener);
                      if (!completer.isCompleted) completer.complete();
                    },
                    onError: (_, __) {
                      stream.removeListener(listener);
                      if (!completer.isCompleted) completer.complete();
                    },
                  );
                  stream.addListener(listener);
                  return completer.future;
                }

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  () async {
                    final image = await nowPlaying.mediumCover;
                    if (!mounted) return;
                    if (token != _precacheToken) return;
                    if (image == null) return;
                    await precacheProvider(image);
                  }();
                });
              }
              context.push(app_paths.NOW_PLAYING_PAGE);
            },
            borderRadius: BorderRadius.circular(8.0),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: ListenableBuilder(
                listenable:
                    PlayService.instance.playbackService.nowPlayingNotifier,
                builder: (context, _) {
                  final playbackService = PlayService.instance.playbackService;
                  final nowPlaying = playbackService.nowPlaying;
                  final heroEnabled =
                      !playbackService.nowPlayingChangedRecently;
                  final placeholder = Icon(
                    Symbols.queue_music,
                    size: 48.0,
                    color: scheme.onSecondaryContainer,
                  );

                  return LayoutBuilder(builder: (context, constraints) {
                    final dense = constraints.maxWidth <= 520;
                    final hideControls = !_controlsVisible;
                    final hasNowPlaying = nowPlaying != null;
                    final controls = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!dense)
                          IconButton(
                            tooltip: hasNowPlaying ? '上一曲' : '暂无正在播放',
                            onPressed: hasNowPlaying
                                ? playbackService.lastAudio
                                : null,
                            icon: const Icon(
                              Symbols.skip_previous,
                              fill: 1.0,
                              weight: 400.0,
                            ),
                            color: scheme.onSecondaryContainer,
                          ),
                        _MiniPlayPauseButton(
                          dense: dense,
                          onSecondaryContainer: scheme.onSecondaryContainer,
                          enabled: hasNowPlaying,
                        ),
                        if (!dense)
                          IconButton(
                            tooltip: hasNowPlaying ? '下一曲' : '暂无正在播放',
                            onPressed: hasNowPlaying
                                ? playbackService.nextAudio
                                : null,
                            icon: const Icon(
                              Symbols.skip_next,
                              fill: 1.0,
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
                                    child: _MiniCoverWidget(audio: nowPlaying),
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
                                    : 'Pure Music',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: scheme.onSecondaryContainer),
                              ),
                              Text(
                                nowPlaying != null
                                    ? '${nowPlaying.artist} - ${nowPlaying.album}'
                                    : '享受音乐',
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
    required this.enabled,
  });

  final bool dense;
  final Color onSecondaryContainer;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final playbackService = PlayService.instance.playbackService;
    return _AnimatedPlayPauseIconButton(
      dense: dense,
      color: onSecondaryContainer,
      enabled: enabled,
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
    required this.enabled,
    required this.onPlay,
    required this.onPause,
    required this.onReplay,
    required this.playerStateStream,
    required this.initialState,
  });

  final bool dense;
  final Color color;
  final bool enabled;
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
  StreamSubscription<PlayerState>? _playerStateSub;

  @override
  void initState() {
    super.initState();
    if (_state == PlayerState.playing) {
      _controller.value = 1.0;
    } else {
      _controller.value = 0.0;
    }
    _bindPlayerStateStream();
  }

  void _bindPlayerStateStream() {
    _playerStateSub?.cancel();
    _playerStateSub = widget.playerStateStream.listen(_syncPlayerState);
  }

  void _syncPlayerState(PlayerState nextState) {
    if (!mounted || nextState == _state) return;
    setState(() {
      _state = nextState;
    });
    _controller.animateTo(
      nextState == PlayerState.playing ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 240),
      curve: const Cubic(0.2, 0.0, 0.0, 1.0),
    );
  }

  @override
  void didUpdateWidget(covariant _AnimatedPlayPauseIconButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playerStateStream != widget.playerStateStream) {
      _bindPlayerStateStream();
    }
    if (oldWidget.initialState != widget.initialState &&
        widget.initialState != _state) {
      _syncPlayerState(widget.initialState);
    }
  }

  @override
  void dispose() {
    _playerStateSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying = _state == PlayerState.playing;
    VoidCallback? onPressed;
    if (widget.enabled) {
      if (_state == PlayerState.playing) {
        onPressed = widget.onPause;
      } else if (_state == PlayerState.completed) {
        onPressed = widget.onReplay;
      } else {
        onPressed = widget.onPlay;
      }
    }
    final iconColor =
        widget.enabled ? widget.color : widget.color.withValues(alpha: 0.38);

    final icon = AnimatedIcon(
      icon: AnimatedIcons.play_pause,
      progress: _controller,
      color: iconColor,
      size: widget.dense ? 24.0 : 28.0,
    );

    return IconButton(
      tooltip: widget.enabled ? (isPlaying ? '暂停' : '播放') : '暂无正在播放',
      onPressed: onPressed,
      icon: icon,
      color: iconColor,
    );
  }
}

class _MiniTimeText extends StatefulWidget {
  const _MiniTimeText({required this.color});

  final Color color;

  @override
  State<_MiniTimeText> createState() => _MiniTimeTextState();
}

class _MiniTimeTextState extends State<_MiniTimeText> {
  final playbackService = PlayService.instance.playbackService;
  Timer? _positionTimer;
  final Stopwatch _clock = Stopwatch()..start();
  int _lastNativeSyncMs = 0;
  int _syncedPositionSeconds = 0;
  late int _positionSeconds;
  late int _lengthSeconds;
  static const _nativeSyncInterval = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _syncedPositionSeconds = playbackService.position.floor();
    _positionSeconds = _syncedPositionSeconds;
    _lengthSeconds = playbackService.length.floor();
    playbackService.playerStateNotifier.addListener(_syncTimer);
    playbackService.nowPlayingNotifier.addListener(_onNowPlayingChanged);
    _syncTimer();
  }

  void _syncTimer() {
    _syncNativePosition();
    final isPlaying =
        playbackService.playerStateNotifier.value == PlayerState.playing;
    if (!isPlaying) {
      _positionTimer?.cancel();
      _positionTimer = null;
      return;
    }
    _positionTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final elapsedSinceNative =
          _clock.elapsedMilliseconds - _lastNativeSyncMs;
      if (elapsedSinceNative >= _nativeSyncInterval.inMilliseconds) {
        _syncNativePosition();
      } else {
        _emitLocalPosition();
      }
    });
  }

  void _syncNativePosition() {
    _syncedPositionSeconds = playbackService.position.floor();
    _lastNativeSyncMs = _clock.elapsedMilliseconds;
    _emitLocalPosition(forceLength: true);
  }

  void _emitLocalPosition({bool forceLength = false}) {
    final isPlaying =
        playbackService.playerStateNotifier.value == PlayerState.playing;
    final elapsedSeconds = isPlaying
        ? ((_clock.elapsedMilliseconds - _lastNativeSyncMs) / 1000).floor()
        : 0;
    final nextLengthSeconds = playbackService.length.floor();
    final nextSeconds = nextLengthSeconds > 0
        ? (_syncedPositionSeconds + elapsedSeconds)
            .clamp(0, nextLengthSeconds)
            .toInt()
        : _syncedPositionSeconds + elapsedSeconds;
    if (nextSeconds == _positionSeconds &&
        (!forceLength || nextLengthSeconds == _lengthSeconds)) {
      return;
    }
    if (!mounted) {
      _positionSeconds = nextSeconds;
      _lengthSeconds = nextLengthSeconds;
      return;
    }
    setState(() {
      _positionSeconds = nextSeconds;
      _lengthSeconds = nextLengthSeconds;
    });
  }

  void _onNowPlayingChanged() {
    _syncNativePosition();
  }

  @override
  void dispose() {
    playbackService.playerStateNotifier.removeListener(_syncTimer);
    playbackService.nowPlayingNotifier.removeListener(_onNowPlayingChanged);
    _positionTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final posText = Duration(seconds: _positionSeconds)
        .toStringHMMSS()
        .replaceFirst(RegExp(r'^0:'), '');
    final lenText = Duration(seconds: _lengthSeconds)
        .toStringHMMSS()
        .replaceFirst(RegExp(r'^0:'), '');
    return Text(
      '$posText / $lenText',
      style: TextStyle(
        color: widget.color,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// 迷你封面组件：
/// 同步检查 Audio.smallCoverBytes，已缓存则用 Image.memory 直接渲染；
/// 未缓存则显示纯色占位 + 异步加载后写回 Audio 并 setState。
/// 不使用 FutureBuilder，避免鼠标 hover 时因 rebuild 导致的闪烁。
class _MiniCoverWidget extends StatefulWidget {
  final Audio audio;
  const _MiniCoverWidget({required this.audio});

  @override
  State<_MiniCoverWidget> createState() => _MiniCoverWidgetState();
}

class _MiniCoverWidgetState extends State<_MiniCoverWidget> {
  Uint8List? _cached;

  @override
  void initState() {
    super.initState();
    _cached = widget.audio.smallCoverBytes;
    if (_cached == null) {
      _load();
    }
  }

  @override
  void didUpdateWidget(_MiniCoverWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audio != widget.audio ||
        widget.audio.smallCoverBytes != _cached) {
      final bytes = widget.audio.smallCoverBytes;
      if (bytes != null && !identical(bytes, _cached)) {
        setState(() => _cached = bytes);
      } else if (bytes == null && _cached != null) {
        setState(() => _cached = null);
        _load();
      }
    }
  }

  Future<void> _load() async {
    final bytes = await widget.audio.loadSmallCoverBytes();
    if (mounted && bytes != null) {
      setState(() => _cached = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cached != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: Image.memory(
          _cached!,
          width: 48.0,
          height: 48.0,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _placeholder(context),
        ),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      width: 48.0,
      height: 48.0,
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8.0),
      ),
    );
  }
}
