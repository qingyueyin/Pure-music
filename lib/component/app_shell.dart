// ignore_for_file: camel_case_types

import 'dart:io';
import 'dart:ui';

import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/component/mini_now_playing.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/component/side_nav.dart';
import 'package:pure_music/component/title_bar.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return ResponsiveBuilder(
      builder: (context, screenType) {
        switch (screenType) {
          case ScreenType.small:
            return _AppShell_Small(navigationShell: navigationShell);
          case ScreenType.medium:
          case ScreenType.large:
            return _AppShell_Large(navigationShell: navigationShell);
        }
      },
    );
  }
}

Color _resolveDynamicColor(ColorScheme scheme) {
  final playbackService = PlayService.instance.playbackService;
  final nowPlaying = playbackService.nowPlaying;
  final album = nowPlaying == null
      ? null
      : AudioLibrary.instance.albumCollection[nowPlaying.album];
  if (album == null) return scheme.surfaceContainerLow;
  final cached = AlbumColorCache.instance.getAlbumColorSync(album);
  if (cached == null) {
    AlbumColorCache.instance.getAlbumColor(album).ignore();
    return scheme.surfaceContainerLow;
  }
  return Color.alphaBlend(
    cached.primary.withAlpha(20),
    scheme.surfaceContainerLow,
  );
}

final Map<String, double> _backgroundLuminanceCache = {};

Future<double> _resolveBackgroundLuminance(String path) async {
  final cached = _backgroundLuminanceCache[path];
  if (cached != null) return cached;
  try {
    final bytes = await File(path).readAsBytes();
    final codec = await instantiateImageCodec(bytes, targetWidth: 64);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ImageByteFormat.rawRgba);
    image.dispose();
    if (data == null) return 0.5;
    final pixels = data.buffer.asUint8List();
    var sum = 0.0;
    for (var i = 0; i < pixels.length; i += 4) {
      final r = pixels[i] / 255;
      final g = pixels[i + 1] / 255;
      final b = pixels[i + 2] / 255;
      sum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }
    final luminance = sum / (pixels.length / 4);
    _backgroundLuminanceCache[path] = luminance;
    return luminance;
  } catch (_) {
    _backgroundLuminanceCache[path] = 0.5;
    return 0.5;
  }
}

class _AppBackground extends StatefulWidget {
  const _AppBackground({
    required this.fallbackColor,
    required this.imagePath,
    required this.child,
  });

  final Color fallbackColor;
  final String? imagePath;
  final Widget child;

  @override
  State<_AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<_AppBackground> {
  double _imageLuminance = 0.5;

  @override
  void initState() {
    super.initState();
    _resolveLuminance();
  }

  @override
  void didUpdateWidget(_AppBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _resolveLuminance();
    }
  }

  Future<void> _resolveLuminance() async {
    final imagePath = widget.imagePath;
    if (imagePath == null) {
      setState(() => _imageLuminance = 0.5);
      return;
    }
    final luminance = await _resolveBackgroundLuminance(imagePath);
    if (!mounted || imagePath != widget.imagePath) return;
    setState(() => _imageLuminance = luminance);
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final imagePath = widget.imagePath;
    final blur = settings.appBackgroundImageBlur;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final maskColor = isDark ? Colors.black : Colors.white;
    final maskAlpha = isDark
        ? 0.25 + 0.2 * _imageLuminance
        : 0.25 + 0.2 * (1 - _imageLuminance);
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: widget.fallbackColor),
        if (imagePath != null) ...[
          Opacity(
            opacity: settings.appBackgroundImageOpacity,
            child: blur > 0
                ? _blurredBackground(context, imagePath, blur)
                : _backgroundImage(imagePath),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            color: maskColor.withValues(alpha: maskAlpha),
          ),
        ],
        widget.child,
      ],
    );
  }

  Widget _blurredBackground(BuildContext context, String imagePath, double blur) {
    const downsample = 4;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    return ImageFiltered(
      imageFilter: ImageFilter.blur(
        sigmaX: blur / downsample,
        sigmaY: blur / downsample,
      ),
      child: Image.file(
        File(imagePath),
        fit: BoxFit.cover,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
        cacheWidth: (viewportWidth / downsample).round(),
      ),
    );
  }

  Widget _backgroundImage(String imagePath) => Image.file(
        File(imagePath),
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
}

class _AppShell_Small extends StatefulWidget {
  const _AppShell_Small({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<_AppShell_Small> createState() => _AppShell_SmallState();
}

class _AppShell_SmallState extends State<_AppShell_Small> {
  late Color _backgroundColor;
  late final VoidCallback _onNowPlayingChanged;

  @override
  void initState() {
    super.initState();
    _onNowPlayingChanged = () {
      final newColor = _resolveDynamicColor(Theme.of(context).colorScheme);
      if (newColor != _backgroundColor) {
        setState(() => _backgroundColor = newColor);
      }
    };
    PlayService.instance.playbackService.nowPlayingNotifier.addListener(
      _onNowPlayingChanged,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _backgroundColor = _resolveDynamicColor(Theme.of(context).colorScheme);
  }

  @override
  void dispose() {
    PlayService.instance.playbackService.nowPlayingNotifier.removeListener(
      _onNowPlayingChanged,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.backgroundNotifier,
      builder: (context, _) => _AppBackground(
        fallbackColor: _backgroundColor,
        imagePath: AppSettings.instance.appBackgroundImagePath,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: const PreferredSize(
            preferredSize: Size.fromHeight(48.0),
            child: TitleBar(),
          ),
          drawer: SizedBox(
            width: SideNav.expandedWidth,
            child: SideNav(navigationShell: widget.navigationShell),
          ),
          body: Stack(
            children: [widget.navigationShell, const MiniNowPlaying()],
          ),
        ),
      ),
    );
  }
}

class _AppShell_Large extends StatefulWidget {
  const _AppShell_Large({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<_AppShell_Large> createState() => _AppShell_LargeState();
}

class _AppShell_LargeState extends State<_AppShell_Large> {
  late Color _backgroundColor;
  late final VoidCallback _onNowPlayingChanged;
  late bool _sidebarExpanded;
  late bool _bodyUsesExpandedLayout;
  bool _sidebarAnimating = false;

  @override
  void initState() {
    super.initState();
    _sidebarExpanded = AppPreference.instance.sidebarExpanded;
    _bodyUsesExpandedLayout = _sidebarExpanded;
    _onNowPlayingChanged = () {
      final newColor = _resolveDynamicColor(Theme.of(context).colorScheme);
      if (newColor != _backgroundColor) {
        setState(() => _backgroundColor = newColor);
      }
    };
    PlayService.instance.playbackService.nowPlayingNotifier.addListener(
      _onNowPlayingChanged,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _backgroundColor = _resolveDynamicColor(Theme.of(context).colorScheme);
  }

  @override
  void dispose() {
    PlayService.instance.playbackService.nowPlayingNotifier.removeListener(
      _onNowPlayingChanged,
    );
    super.dispose();
  }

  void _handleSidebarExpandedChanged(bool expanded) {
    if (_sidebarExpanded == expanded) return;
    setState(() {
      _sidebarExpanded = expanded;
      _sidebarAnimating = true;
      if (!expanded) _bodyUsesExpandedLayout = false;
    });
  }

  void _handleSidebarAnimationEnd() {
    if (!_sidebarAnimating) return;
    setState(() {
      _sidebarAnimating = false;
      _bodyUsesExpandedLayout = _sidebarExpanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bodyLeft = _bodyUsesExpandedLayout
        ? SideNav.expandedWidth
        : SideNav.collapsedWidth;
    const sidebarTravel = SideNav.expandedWidth - SideNav.collapsedWidth;
    return ListenableBuilder(
      listenable: AppSettings.backgroundNotifier,
      builder: (context, _) => _AppBackground(
        fallbackColor: _backgroundColor,
        imagePath: AppSettings.instance.appBackgroundImagePath,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: const PreferredSize(
            preferredSize: Size.fromHeight(48.0),
            child: TitleBar(),
          ),
          body: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: bodyLeft,
                top: 0,
                right: 0,
                bottom: 0,
                child: TweenAnimationBuilder<double>(
                  duration: MotionDuration.base,
                  curve: MotionCurve.standard,
                  tween: Tween<double>(
                    begin: _sidebarExpanded ? 1.0 : 0.0,
                    end: _sidebarExpanded ? 1.0 : 0.0,
                  ),
                  onEnd: _handleSidebarAnimationEnd,
                  builder: (context, progress, child) {
                    final offset = _sidebarAnimating
                        ? progress * sidebarTravel
                        : 0.0;
                    return Transform.translate(
                      offset: Offset(offset, 0),
                      child: child,
                    );
                  },
                  child: RepaintBoundary(
                    child: Stack(
                      children: [
                        widget.navigationShell,
                        const MiniNowPlaying(),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: ClipRect(
                  child: SideNav(
                    navigationShell: widget.navigationShell,
                    onExpandedChanged: _handleSidebarExpandedChanged,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
