part of 'page.dart';

class _NowPlayingImmersivePage extends StatelessWidget {
  const _NowPlayingImmersivePage();

  @override
  Widget build(BuildContext context) {
    return ResponsiveBuilder2(
      builder: (context, screenType) {
        switch (screenType) {
          case ScreenType.small:
            return const _ImmersivePortraitLayout();
          case ScreenType.medium:
          case ScreenType.large:
            return const _ImmersiveLandscapeLayout();
        }
      },
    );
  }
}

/// 竖屏沉浸模式：封面 + 歌名歌手 (顶) + 歌词 (下)
class _ImmersivePortraitLayout extends StatelessWidget {
  const _ImmersivePortraitLayout();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24.0, 32.0, 16.0, 16.0),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SizedBox(
                    width: 80.0,
                    height: 80.0,
                    child: _ImmersiveCoverThumbnail(),
                  ),
                  const SizedBox(width: 12.0),
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _ImmersiveTitleText(),
                          const SizedBox(height: 2),
                          _ImmersiveArtistText(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ShaderMask(
                  shaderCallback: (Rect bounds) {
                    return const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black,       
                        Colors.black,       
                        Colors.transparent,
                      ],
                      stops: [0.0, 0.05, 0.95, 1.0],
                    ).createShader(bounds);
                  },
                  blendMode: BlendMode.dstIn,
                  child: VerticalLyricView(
                    showControls: false,
                    enableSeekOnTap: true,
                    centerVertically: false,
                    enableEdgeSpacer: false,
                    currentLineAlignment: 0.3,
                  ),
                ),
              ),
            ],
          ),
        ),
        const _ImmersiveHelpOverlay(),
      ],
    );
  }
}

class _ImmersiveHelpOverlay extends StatefulWidget {
  const _ImmersiveHelpOverlay();

  @override
  State<_ImmersiveHelpOverlay> createState() => _ImmersiveHelpOverlayState();
}

class _ImmersiveHelpOverlayState extends State<_ImmersiveHelpOverlay> {
  bool _visible = false;
  Timer? _timer;

  void _bump() {
    _timer?.cancel();
    if (!_visible) {
      setState(() {
        _visible = true;
      });
    }
    _timer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() {
        _visible = false;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _showDialog() {
    showDialog<void>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final textStyle = TextStyle(color: scheme.onSurface);
        return AlertDialog(
          title: const Text("快捷键"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Space：播放/暂停", style: textStyle),
              const SizedBox(height: 8),
              Text("Ctrl + ←：上一曲", style: textStyle),
              const SizedBox(height: 8),
              Text("Ctrl + →：下一曲", style: textStyle),
              const SizedBox(height: 8),
              Text("Ctrl + ↑：音量 +", style: textStyle),
              const SizedBox(height: 8),
              Text("Ctrl + ↓：音量 -", style: textStyle),
              const SizedBox(height: 8),
              Text("F1：进入/退出沉浸模式", style: textStyle),
              const SizedBox(height: 8),
              Text("ESC：退出沉浸并回到主界面", style: textStyle),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("关闭"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: MouseRegion(
            onHover: (_) => _bump(),
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          right: 20,
          bottom: 120,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 200),
            curve: Curves.fastOutSlowIn,
            offset: _visible ? Offset.zero : const Offset(0.0, 0.2),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              curve: Curves.fastOutSlowIn,
              opacity: _visible ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !_visible,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Material(
                      color: scheme.secondaryContainer.withAlpha(235),
                      borderRadius: BorderRadius.circular(999),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12.0,
                          vertical: 10.0,
                        ),
                        child: Text(
                          "快捷键说明",
                          style: TextStyle(
                            color: scheme.onSecondaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Material(
                      color: scheme.secondaryContainer.withAlpha(235),
                      shape: const CircleBorder(),
                      child: IconButton(
                        onPressed: _showDialog,
                        icon: Icon(
                          Symbols.help_outline,
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 沉浸模式顶部封面缩略图
class _ImmersiveCoverThumbnail extends StatefulWidget {
  const _ImmersiveCoverThumbnail();

  @override
  State<_ImmersiveCoverThumbnail> createState() =>
      _ImmersiveCoverThumbnailState();
}

class _ImmersiveCoverThumbnailState extends State<_ImmersiveCoverThumbnail> {
  ImageProvider<Object>? _cover;
  String? _coverPath;
  final playbackService = PlayService.instance.playbackService;

  @override
  void initState() {
    super.initState();
    playbackService.nowPlayingNotifier.addListener(_onPlaybackChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onPlaybackChange();
    });
  }

  void _onPlaybackChange() {
    final nextAudio = playbackService.nowPlaying;
    if (nextAudio == null) {
      if (_coverPath != null) {
        setState(() {
          _cover = null;
          _coverPath = null;
        });
      }
      return;
    }

    if (nextAudio.path == _coverPath) return;

    nextAudio.mediumCover.then((image) {
      if (!mounted) return;
      if (playbackService.nowPlaying?.path != nextAudio.path) return;

      if (image != null) {
        precacheImage(image, context);
      }

      if (!mounted) return;
      setState(() {
        _cover = image;
        _coverPath = nextAudio.path;
      });
    });
  }

  @override
  void dispose() {
    playbackService.nowPlayingNotifier.removeListener(_onPlaybackChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final placeholder = Icon(
      Symbols.music_note,
      size: 80.0,
      color: scheme.onSecondaryContainer,
    );

    if (_cover == null) {
      return Center(child: placeholder);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(18.0),
      child: Image(
        image: _cover!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, __, ___) => Center(child: placeholder),
      ),
    );
  }
}

class _ImmersiveTitleText extends StatelessWidget {
  const _ImmersiveTitleText();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: PlayService.instance.playbackService.playerStateStream,
      initialData: PlayService.instance.playbackService.playerState,
      builder: (context, snapshot) {
        final nowPlaying = PlayService.instance.playbackService.nowPlaying;
        return Text(
          nowPlaying == null ? "Pure Music" : nowPlaying.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.bold,
            fontSize: 20,
            height: 1.2,
          ),
        );
      },
    );
  }
}

class _ImmersiveArtistText extends StatelessWidget {
  const _ImmersiveArtistText();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: PlayService.instance.playbackService.playerStateStream,
      initialData: PlayService.instance.playbackService.playerState,
      builder: (context, snapshot) {
        final nowPlaying = PlayService.instance.playbackService.nowPlaying;
        return Text(
          nowPlaying == null ? "Enjoy Music" : nowPlaying.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 14,
            height: 1.2,
          ),
        );
      },
    );
  }
}

/// 横屏沉浸模式：封面信息 (左) + 歌词 (右)
class _ImmersiveLandscapeLayout extends StatelessWidget {
  const _ImmersiveLandscapeLayout();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24.0, 32.0, 24.0, 32.0),
          child: Row(
            children: [
              // 左侧：封面 + 歌曲信息 (50%)
              Expanded(
                child: Align(
                  alignment: Alignment.center,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 452.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _NowPlayingInfo(),
                        SizedBox(height: 24.0),
                        _NowPlayingSlider(),
                      ],
                    ),
                  ),
                ),
              ),
              // 右侧：歌词区域 (50%)
              Expanded(
                child: ShaderMask(
                  shaderCallback: (Rect bounds) {
                    return const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black,
                        Colors.black,
                        Colors.transparent,
                      ],
                      stops: [0.0, 0.05, 0.95, 1.0],
                    ).createShader(bounds);
                  },
                  blendMode: BlendMode.dstIn,
                  child: VerticalLyricView(
                    showControls: false,
                    enableSeekOnTap: false,
                    centerVertically: false,
                    enableEdgeSpacer: false,
                    currentLineAlignment: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        const _ImmersiveHelpOverlay(),
      ],
    );
  }
}
