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
          padding: const EdgeInsets.fromLTRB(12.0, 32.0, 12.0, 16.0),
          child: Column(
            children: [
              const Padding(
                // 封面额外右移 24px，使封面左缘与歌词文字左缘对齐
                padding: EdgeInsets.only(left: 24.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 64.0,
                      height: 64.0,
                      child: _ImmersiveCoverThumbnail(),
                    ),
                    SizedBox(width: 12.0),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _ImmersiveTitleText(),
                          SizedBox(height: 2),
                          _ImmersiveArtistText(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
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
                  child: const VerticalLyricView(
                    showControls: false,
                    enableSeekOnTap: true,
                    centerVertically: false,
                    enableEdgeSpacer: true,
                    // 压缩顶部空间后，进一步降低对齐位置，使当前行更靠上
                    currentLineAlignment: 0.10,
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
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20.0,
            vertical: 24.0,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8.0),
          ),
          titlePadding: const EdgeInsets.fromLTRB(24.0, 20.0, 24.0, 8.0),
          contentPadding: const EdgeInsets.fromLTRB(24.0, 8.0, 24.0, 12.0),
          actionsPadding: const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 12.0),
          title: const Text('快捷键'),
          content: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320.0),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ImmersiveShortcutRow(
                    keys: 'Space',
                    label: '播放 / 暂停',
                  ),
                  _ImmersiveShortcutRow(
                    keys: 'Ctrl + ←',
                    label: '上一曲',
                  ),
                  _ImmersiveShortcutRow(
                    keys: 'Ctrl + →',
                    label: '下一曲',
                  ),
                  _ImmersiveShortcutRow(
                    keys: 'Ctrl + ↑',
                    label: '提高音量',
                  ),
                  _ImmersiveShortcutRow(
                    keys: 'Ctrl + ↓',
                    label: '降低音量',
                  ),
                  _ImmersiveShortcutRow(
                    keys: 'F1',
                    label: '进入 / 退出沉浸模式',
                  ),
                  _ImmersiveShortcutRow(
                    keys: 'ESC',
                    label: '退出沉浸并回到主界面',
                    isLast: true,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
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
                          '快捷键说明',
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

class _ImmersiveShortcutRow extends StatelessWidget {
  const _ImmersiveShortcutRow({
    required this.keys,
    required this.label,
    this.isLast = false,
  });

  final String keys;
  final String label;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0.0 : 6.0),
      child: Row(
        children: [
          SizedBox(
            width: 82.0,
            child: Text(
              keys,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontFamily: 'monospace',
                fontSize: 13.0,
              ),
            ),
          ),
          const SizedBox(width: 10.0),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: scheme.onSurface),
            ),
          ),
        ],
      ),
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
  bool _exiting = false;

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
    if (_exiting) return;

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
      if (!mounted || _exiting) return;
      if (playbackService.nowPlaying?.path != nextAudio.path) return;

      if (image != null) {
        precacheImage(image, context);
      }

      if (!mounted || _exiting) return;
      setState(() {
        _cover = image;
        _coverPath = nextAudio.path;
      });
    });
  }

  @override
  void dispose() {
    _exiting = true;
    playbackService.nowPlayingNotifier.removeListener(_onPlaybackChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final placeholder = Icon(
      Symbols.music_note,
      size: 64.0,
      color: scheme.onSecondaryContainer,
    );

    if (_cover == null) {
      return Center(child: placeholder);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12.0),
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
    final playbackService = PlayService.instance.playbackService;

    return ValueListenableBuilder<Audio?>(
      valueListenable: playbackService.nowPlayingNotifier,
      builder: (context, nowPlaying, _) {
        return Text(
          nowPlaying == null ? 'Pure Music' : nowPlaying.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.bold,
            fontSize: 16,
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
    final playbackService = PlayService.instance.playbackService;

    return ValueListenableBuilder<Audio?>(
      valueListenable: playbackService.nowPlayingNotifier,
      builder: (context, nowPlaying, _) {
        return Text(
          nowPlaying == null ? 'Enjoy Music' : nowPlaying.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
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
          padding: const EdgeInsets.fromLTRB(24.0, 8.0, 24.0, 8.0),
          child: Row(
            children: [
              // 左侧：封面 + 歌曲信息 (50%)
              Expanded(
                child: Align(
                  alignment: Alignment.center,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 452.0),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _NowPlayingInfo(),
                        SizedBox(height: 24.0),
                        _NowPlayingSlider(mode: NowPlayingMode.immersive),
                      ],
                    ),
                  ),
                ),
              ),
              // 右侧：歌词区域 (50%) - 与普通模式一致，无外层 ShaderMask
              const Expanded(
                child: ClipRect(
                  child: Stack(
                    children: [
                      Padding(
                        padding: EdgeInsets.only(right: 8.0),
                        child: VerticalLyricView(
                          showControls: false,
                          enableSeekOnTap: false,
                          centerVertically: true,
                          enableEdgeSpacer: true,
                          currentLineAlignment: 0.45,
                        ),
                      ),
                    ],
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
