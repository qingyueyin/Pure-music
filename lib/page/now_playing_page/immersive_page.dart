part of 'page.dart';

class _NowPlayingImmersivePage extends StatelessWidget {
  const _NowPlayingImmersivePage();

  @override
  Widget build(BuildContext context) {
    return ResponsiveBuilder2(
      builder: (context, screenType) {
        if (_usesCompactNowPlayingLayout(context, screenType)) {
          return const _ImmersivePortraitLayout();
        }
        return const _ImmersiveLandscapeLayout();
      },
    );
  }
}

/// 竖屏沉浸：顶栏紧凑封面信息，歌词铺满剩余高度。
class _ImmersivePortraitLayout extends StatelessWidget {
  const _ImmersivePortraitLayout();

  // 竖屏紧凑顶栏：封面 72，左右约 10%，封面与文字约 5%；当前行贴 12%。
  static const _coverSize = 72.0;
  static const _lyricLineInset = 12.0;
  static const _currentLineAlignment = 0.12;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final sideInset = (width * 0.10).clamp(24.0, 64.0).toDouble();
        final headerGap = (width * 0.05).clamp(12.0, 24.0).toDouble();
        final outer = max(0.0, sideInset - _lyricLineInset);
        return Padding(
          padding: EdgeInsets.fromLTRB(outer, 20.0, outer, 8.0),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: _lyricLineInset,
                ),
                child: _header(headerGap),
              ),
              const SizedBox(height: 12),
              const Expanded(
                child: VerticalLyricView(
                  showControls: false,
                  enableSeekOnTap: true,
                  centerVertically: false,
                  enableEdgeSpacer: true,
                  currentLineAlignment: _currentLineAlignment,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(double gap) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(
          width: _coverSize,
          height: _coverSize,
          child: _ImmersiveCoverThumbnail(size: _coverSize),
        ),
        SizedBox(width: gap),
        const Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConcertActLabel(compact: true, textAlign: TextAlign.start),
              _ImmersiveTitleText(),
              SizedBox(height: 4),
              _ImmersiveArtistText(),
            ],
          ),
        ),
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
    showDialog<void>(context: context, builder: (context) => _shortcutDialog());
  }

  Widget _shortcutDialog() {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 20.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
      titlePadding: const EdgeInsets.fromLTRB(24.0, 20.0, 24.0, 8.0),
      contentPadding: const EdgeInsets.fromLTRB(24.0, 8.0, 24.0, 12.0),
      actionsPadding: const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 12.0),
      title: const Text('快捷键'),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _shortcutRows(),
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
  }

  List<Widget> _shortcutRows() {
    return [
      _ImmersiveShortcutRow(
        keys: HotkeysHelper.inAppLabel(HotkeyAction.playPause),
        label: '播放 / 暂停',
      ),
      _ImmersiveShortcutRow(
        keys: HotkeysHelper.inAppLabel(HotkeyAction.previous),
        label: '上一曲',
      ),
      _ImmersiveShortcutRow(
        keys: HotkeysHelper.inAppLabel(HotkeyAction.next),
        label: '下一曲',
      ),
      _ImmersiveShortcutRow(
        keys: HotkeysHelper.inAppLabel(HotkeyAction.volumeUp),
        label: '提高音量',
      ),
      _ImmersiveShortcutRow(
        keys: HotkeysHelper.inAppLabel(HotkeyAction.volumeDown),
        label: '降低音量',
      ),
      _ImmersiveShortcutRow(
        keys: HotkeysHelper.inAppLabel(HotkeyAction.shuffle),
        label: '随机播放',
      ),
      _ImmersiveShortcutRow(
        keys: HotkeysHelper.inAppLabel(HotkeyAction.desktopLyric),
        label: '桌面歌词',
      ),
      _ImmersiveShortcutRow(
        keys: HotkeysHelper.inAppLabel(HotkeyAction.sleepTimer),
        label: '睡眠定时',
      ),
      _ImmersiveShortcutRow(
        keys: HotkeysHelper.inAppLabel(HotkeyAction.immersive),
        label: '进入 / 退出沉浸模式',
      ),
      _ImmersiveShortcutRow(
        keys: HotkeysHelper.inAppLabel(HotkeyAction.fullscreen),
        label: '全屏 / 还原窗口',
      ),
      _ImmersiveShortcutRow(
        keys: HotkeysHelper.inAppLabel(HotkeyAction.escape),
        label: '退出沉浸并回到主界面',
        isLast: true,
      ),
    ];
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
                child: _helpChip(scheme),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _helpChip(ColorScheme scheme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 40,
          child: Material(
            color: scheme.secondaryContainer.withAlpha(235),
            borderRadius: AppRadius.smCircular,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: Center(
                child: Text(
                  '快捷键说明',
                  style: TextStyle(
                    color: scheme.onSecondaryContainer,
                    fontWeight: AppType.weightSemibold,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        IconButton.filledTonal(
          tooltip: '快捷键说明',
          onPressed: _showDialog,
          iconSize: 20,
          style: ButtonStyle(
            fixedSize: const WidgetStatePropertyAll(Size(40, 40)),
            padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            backgroundColor: WidgetStatePropertyAll(
              scheme.secondaryContainer.withAlpha(235),
            ),
            foregroundColor: WidgetStatePropertyAll(
              scheme.onSecondaryContainer,
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
            ),
          ),
          icon: const Icon(Symbols.help_outline),
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
                fontSize: AppType.body,
              ),
            ),
          ),
          const SizedBox(width: 10.0),
          Expanded(
            child: Text(label, style: TextStyle(color: scheme.onSurface)),
          ),
        ],
      ),
    );
  }
}

/// 沉浸模式顶部封面缩略图
class _ImmersiveCoverThumbnail extends StatefulWidget {
  const _ImmersiveCoverThumbnail({this.size = 72.0});

  final double size;

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
      size: widget.size,
      color: scheme.onSecondaryContainer,
    );

    final cover = _cover == null
        ? Center(child: placeholder)
        : ClipRRect(
            borderRadius: AppRadius.mdCircular,
            child: Image(
              image: _cover!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.high,
              errorBuilder: (_, _, _) => Center(child: placeholder),
            ),
          );
    return _PlaybackCoverScale(child: cover);
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
            fontWeight: AppType.weightBold,
            fontSize: AppType.pageTitle,
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
            fontSize: AppType.body,
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final infoMaxWidth = constraints.maxWidth / 2;
              // 封面尺寸按整个窗口高度计算，与普通横屏模式一致
              final coverSize = _responsiveNowPlayingCoverSize(
                maxWidth: infoMaxWidth,
                maxHeight: constraints.maxHeight,
              );
              final infoWidth = min(infoMaxWidth, coverSize + 32.0);
              // 封面垂直居中于整个窗口：整列中心在窗口中心，封面块位于其上方
              // 64/2 处，下移 32 让封面中心落在窗口中心（与普通横屏一致）。
              return Row(
                children: [
                  Expanded(child: _leftInfo(coverSize, infoWidth)),
                  Expanded(child: _rightLyrics()),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _leftInfo(double coverSize, double infoWidth) {
    return Transform.translate(
      offset: const Offset(0, _immersiveCoverBelowHeight / 2),
      child: Align(
        alignment: Alignment.center,
        child: SizedBox(
          width: infoWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _NowPlayingInfo(coverSizeOverride: coverSize),
              const SizedBox(height: 24.0),
              const _NowPlayingSlider(mode: NowPlayingMode.immersive),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rightLyrics() {
    return const ClipRect(
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
    );
  }
}
