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
    return ListenableBuilder(
      listenable:
          PlayService.instance.playbackService.nowPlayingNotifier,
      builder: (context, _) {
        final playbackService = PlayService.instance.playbackService;
        final nowPlaying = playbackService.nowPlaying;
        final scheme = Theme.of(context).colorScheme;

        final album = nowPlaying == null
            ? null
            : AudioLibrary.instance.albumCollection[nowPlaying.album];

        final dynamicColor = _resolveDynamicColor(album, scheme);
        if (album != null && dynamicColor == scheme.surfaceContainerLow) {
          AlbumColorCache.instance.getAlbumColor(album).ignore();
        }

        return ResponsiveBuilder(
          builder: (context, screenType) {
            switch (screenType) {
              case ScreenType.small:
                return _AppShell_Small(
                  navigationShell: navigationShell,
                  backgroundColor: dynamicColor,
                );
              case ScreenType.medium:
              case ScreenType.large:
                return _AppShell_Large(
                  navigationShell: navigationShell,
                  backgroundColor: dynamicColor,
                );
            }
          },
        );
      },
    );
  }

  static Color _resolveDynamicColor(Album? album, ColorScheme scheme) {
    if (album == null) return scheme.surfaceContainerLow;
    final cached = AlbumColorCache.instance.getAlbumColorSync(album);
    if (cached == null) return scheme.surfaceContainerLow;
    return Color.alphaBlend(
        cached.primary.withAlpha(20), scheme.surfaceContainerLow);
  }
}

class _AppShell_Small extends StatelessWidget {
  const _AppShell_Small({
    required this.navigationShell,
    required this.backgroundColor,
  });

  final StatefulNavigationShell navigationShell;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final drawerWidth = (size.width * 0.78).clamp(240.0, 288.0);
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: const PreferredSize(
        preferredSize: Size.fromHeight(48.0),
        child: TitleBar(),
      ),
      drawer: SizedBox(
          width: drawerWidth,
          child: SideNav(navigationShell: navigationShell)),
      body: Stack(children: [navigationShell, const MiniNowPlaying()]),
    );
  }
}

class _AppShell_Large extends StatelessWidget {
  const _AppShell_Large({
    required this.navigationShell,
    required this.backgroundColor,
  });

  final StatefulNavigationShell navigationShell;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: const PreferredSize(
        preferredSize: Size.fromHeight(48.0),
        child: TitleBar(),
      ),
      body: Row(
        children: [
          ClipRect(child: SideNav(navigationShell: navigationShell)),
          Expanded(
            child: Stack(
              children: [
                navigationShell,
                const MiniNowPlaying(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
