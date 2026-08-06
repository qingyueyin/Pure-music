// ignore_for_file: camel_case_types

import 'package:pure_music/core/cache.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/component/mini_now_playing.dart';
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
    final size = MediaQuery.sizeOf(context);
    final drawerWidth = (size.width * 0.78).clamp(240.0, 288.0);
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: const PreferredSize(
        preferredSize: Size.fromHeight(48.0),
        child: TitleBar(),
      ),
      drawer: SizedBox(
          width: drawerWidth,
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
      body: Row(
        children: [
          ClipRect(child: SideNav(navigationShell: widget.navigationShell)),
          Expanded(
            child: Stack(
              children: [
                widget.navigationShell,
                const MiniNowPlaying(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
