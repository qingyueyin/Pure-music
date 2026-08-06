// ignore_for_file: camel_case_types

import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/preference.dart';
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
            return _AppShell_Small(
              navigationShell: navigationShell,
            );
          case ScreenType.medium:
          case ScreenType.large:
            return _AppShell_Large(
              navigationShell: navigationShell,
            );
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
      cached.primary.withAlpha(20), scheme.surfaceContainerLow);
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
    PlayService.instance.playbackService.nowPlayingNotifier
        .addListener(_onNowPlayingChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _backgroundColor = _resolveDynamicColor(Theme.of(context).colorScheme);
  }

  @override
  void dispose() {
    PlayService.instance.playbackService.nowPlayingNotifier
        .removeListener(_onNowPlayingChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: const PreferredSize(
        preferredSize: Size.fromHeight(48.0),
        child: TitleBar(),
      ),
      drawer: SizedBox(
          width: SideNav.expandedWidth,
          child: SideNav(navigationShell: widget.navigationShell)),
      body: Stack(
        children: [widget.navigationShell, const MiniNowPlaying()],
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
    PlayService.instance.playbackService.nowPlayingNotifier
        .addListener(_onNowPlayingChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _backgroundColor = _resolveDynamicColor(Theme.of(context).colorScheme);
  }

  @override
  void dispose() {
    PlayService.instance.playbackService.nowPlayingNotifier
        .removeListener(_onNowPlayingChanged);
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
    return Scaffold(
      backgroundColor: _backgroundColor,
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
                final offset =
                    _sidebarAnimating ? progress * sidebarTravel : 0.0;
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
    );
  }
}
