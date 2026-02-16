// ignore_for_file: camel_case_types

import 'package:pure_music/album_color_cache.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/component/mini_now_playing.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/component/side_nav.dart';
import 'package:pure_music/component/title_bar.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.page});

  final Widget page;

  @override
  Widget build(BuildContext context) {
    final playbackService = PlayService.instance.playbackService;
    return ListenableBuilder(
      listenable: playbackService,
      builder: (context, _) {
        final nowPlaying = playbackService.nowPlaying;
        final scheme = Theme.of(context).colorScheme;

        final album = nowPlaying == null
            ? null
            : AudioLibrary.instance.albumCollection[nowPlaying.album];

        final albumColorFuture = album == null
            ? null
            : AlbumColorCache.instance.getAlbumColor(album);

        return FutureBuilder<AlbumColor?>(
          future: albumColorFuture,
          builder: (context, snapshot) {
            final dynamicColor = snapshot.data?.primary;
            final backgroundColor = dynamicColor != null
                ? Color.alphaBlend(
                    dynamicColor.withOpacity(0.08), scheme.surfaceContainer)
                : scheme.surfaceContainer;

            return ResponsiveBuilder(
              builder: (context, screenType) {
                switch (screenType) {
                  case ScreenType.small:
                    return _AppShell_Small(
                      page: page,
                      backgroundColor: backgroundColor,
                    );
                  case ScreenType.medium:
                  case ScreenType.large:
                    return _AppShell_Large(
                      page: page,
                      backgroundColor: backgroundColor,
                    );
                }
              },
            );
          },
        );
      },
    );
  }
}

class _AppShell_Small extends StatelessWidget {
  const _AppShell_Small({
    required this.page,
    required this.backgroundColor,
  });

  final Widget page;
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
      drawer: SizedBox(width: drawerWidth, child: const SideNav()),
      body: Stack(children: [page, const MiniNowPlaying()]),
    );
  }
}

class _AppShell_Large extends StatelessWidget {
  const _AppShell_Large({
    required this.page,
    required this.backgroundColor,
  });

  final Widget page;
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
          const SideNav(),
          Expanded(
            child: Stack(
              children: [
                page,
                const MiniNowPlaying(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
