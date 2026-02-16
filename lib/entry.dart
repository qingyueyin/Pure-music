import 'dart:io';

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/union_search_result.dart';
import 'package:pure_music/component/app_shell.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/page/album_detail_page.dart';
import 'package:pure_music/page/albums_page.dart';
import 'package:pure_music/page/artist_detail_page.dart';
import 'package:pure_music/page/artists_page.dart';
import 'package:pure_music/page/audio_detail_page.dart';
import 'package:pure_music/page/audios_page.dart';
import 'package:pure_music/page/folder_detail_page.dart';
import 'package:pure_music/page/folders_page.dart';
import 'package:pure_music/page/now_playing_page/page.dart';
import 'package:pure_music/page/playlist_detail_page.dart';
import 'package:pure_music/page/playlists_page.dart';
import 'package:pure_music/page/search_page/search_page.dart';
import 'package:pure_music/page/search_page/search_result_page.dart';
import 'package:pure_music/page/settings_page/create_issue.dart';
import 'package:pure_music/page/settings_page/page.dart';
import 'package:pure_music/page/updating_page.dart';
import 'package:pure_music/page/welcoming_page.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/component/app_scroll_behavior.dart';
import 'package:pure_music/theme_provider.dart';
import 'package:pure_music/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:pure_music/app_paths.dart' as app_paths;

class SlideTransitionPage<T> extends CustomTransitionPage<T> {
  const SlideTransitionPage({
    required super.child,
    super.name,
    super.arguments,
    super.restorationId,
    super.key,
  }) : super(
          transitionsBuilder: _transitionsBuilder,
          transitionDuration: MotionDuration.fast,
          reverseTransitionDuration: MotionDuration.fast,
        );

  static Widget _transitionsBuilder(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: MotionCurve.standard,
      reverseCurve: MotionCurve.standard,
    );
    final fade = curved;
    final slide = Tween(
      begin: const Offset(0.03, 0.0),
      end: Offset.zero,
    ).animate(curved);
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(
        position: slide,
        child: child,
      ),
    );
  }
}

class DetailTransitionPage<T> extends CustomTransitionPage<T> {
  const DetailTransitionPage({
    required super.child,
    super.name,
    super.arguments,
    super.restorationId,
    super.key,
  }) : super(
          transitionsBuilder: _transitionsBuilder,
          transitionDuration: const Duration(milliseconds: 420),
          reverseTransitionDuration: const Duration(milliseconds: 420),
        );

  static Widget _transitionsBuilder(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final fade = CurvedAnimation(parent: animation, curve: Curves.easeInOutCubic);
    final slide = Tween(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.fastOutSlowIn));
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(position: slide, child: child),
    );
  }
}

class Entry extends StatefulWidget {
  const Entry({super.key, required this.welcome});
  final bool welcome;

  @override
  State<Entry> createState() => _EntryState();
}

class _EntryState extends State<Entry> with WindowListener, SingleTickerProviderStateMixin {
  late final AnimationController _restoreAnimController;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    
    _restoreAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
      value: 1.0, // Initially show content fully
    );

    _scaleAnimation = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _restoreAnimController, curve: Curves.easeOutQuart),
    );

    _opacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _restoreAnimController, curve: Curves.easeOut),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Platform.environment['CP_ECHO_RECORD'] == '1') {
        AudioEchoLogRecorder.instance.start();
      }
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _restoreAnimController.dispose();
    super.dispose();
  }

  @override
  void onWindowRestore() {
    // Play animation when restored from minimization
    _restoreAnimController.value = 0.0;
    _restoreAnimController.forward();
  }

  ThemeData fromSchemeAndFontFamily({
    required ColorScheme colorScheme,
    String? fontFamily,
  }) {
    final bool isDark = colorScheme.brightness == Brightness.dark;

    // For surfaces that use primary color in light themes and surface color in dark
    final Color primarySurfaceColor =
        isDark ? colorScheme.surface : colorScheme.primary;
    final Color onPrimarySurfaceColor =
        isDark ? colorScheme.onSurface : colorScheme.onPrimary;

    return ThemeData(
      fontFamily: fontFamily,
      colorScheme: colorScheme,
      brightness: colorScheme.brightness,
      primaryColor: primarySurfaceColor,
      canvasColor: colorScheme.surfaceContainer,
      scaffoldBackgroundColor: colorScheme.surfaceContainer,
      cardColor: colorScheme.surface,
      dividerColor: colorScheme.onSurface.withOpacity(0.12),
      applyElevationOverlayColor: isDark,
      useMaterial3: true,
      dialogTheme: DialogThemeData(backgroundColor: colorScheme.surface),
      tabBarTheme: TabBarThemeData(indicatorColor: onPrimarySurfaceColor),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: ThemeProvider.instance,
      builder: (context, _) {
        final theme = Provider.of<ThemeProvider>(context);
        return AnimatedBuilder(
          animation: _restoreAnimController,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: Opacity(
                opacity: _opacityAnimation.value,
                child: child,
              ),
            );
          },
          child: MaterialApp.router(
            scaffoldMessengerKey: SCAFFOLD_MESSAGER,
            debugShowCheckedModeBanner: false,
            scrollBehavior: const AppScrollBehavior(),
            theme: fromSchemeAndFontFamily(
              fontFamily: theme.fontFamily,
              colorScheme: theme.lightScheme,
            ),
            darkTheme: fromSchemeAndFontFamily(
              fontFamily: theme.fontFamily,
              colorScheme: theme.darkScheme,
            ),
            themeAnimationDuration: const Duration(milliseconds: 560),
            themeAnimationCurve: Curves.easeInOutCubic,
            themeMode: theme.themeMode,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: supportedLocales,
            routerConfig: config,
          ),
        );
      },
    );
  }

  late final GoRouter config = GoRouter(
    navigatorKey: ROUTER_KEY,
    initialLocation:
        widget.welcome ? app_paths.WELCOMING_PAGE : app_paths.UPDATING_DIALOG,
    routes: [
      ShellRoute(
        builder: (context, state, page) => AppShell(page: page),
        routes: [
          /// audios page
          GoRoute(
            path: app_paths.AUDIOS_PAGE,
            pageBuilder: (context, state) {
              if (state.extra != null) {
                return NoTransitionPage(
                  key: state.pageKey,
                  child: AudiosPage(locateTo: state.extra as Audio),
                );
              }
              return NoTransitionPage(key: state.pageKey, child: const AudiosPage());
            },
            routes: [
              GoRoute(
                path: "detail",
                pageBuilder: (context, state) => DetailTransitionPage(
                  key: state.pageKey,
                  child: AudioDetailPage(audio: state.extra as Audio),
                ),
              ),
            ],
          ),

          /// artists page
          GoRoute(
            path: app_paths.ARTISTS_PAGE,
            pageBuilder: (context, state) =>
                NoTransitionPage(key: state.pageKey, child: const ArtistsPage()),
            routes: [
              GoRoute(
                path: "detail",
                pageBuilder: (context, state) => SlideTransitionPage(
                  key: state.pageKey,
                  child: ArtistDetailPage(artist: state.extra as Artist),
                ),
              ),
            ],
          ),

          /// albums page
          GoRoute(
            path: app_paths.ALBUMS_PAGE,
            pageBuilder: (context, state) =>
                NoTransitionPage(key: state.pageKey, child: const AlbumsPage()),
            routes: [
              GoRoute(
                path: "detail",
                pageBuilder: (context, state) => SlideTransitionPage(
                  key: state.pageKey,
                  child: AlbumDetailPage(album: state.extra as Album),
                ),
              ),
            ],
          ),

          /// folders page
          GoRoute(
            path: app_paths.FOLDERS_PAGE,
            pageBuilder: (context, state) =>
                NoTransitionPage(key: state.pageKey, child: const FoldersPage()),
            routes: [
              /// folder detail page
              GoRoute(
                path: "detail",
                pageBuilder: (context, state) {
                  final folder = state.extra as AudioFolder;
                  return SlideTransitionPage(
                    key: state.pageKey,
                    child: FolderDetailPage(folder: folder),
                  );
                },
              ),
            ],
          ),

          /// playlists page
          GoRoute(
            path: app_paths.PLAYLISTS_PAGE,
            pageBuilder: (context, state) =>
                NoTransitionPage(key: state.pageKey, child: const PlaylistsPage()),
            routes: [
              GoRoute(
                path: "detail",
                pageBuilder: (context, state) {
                  final playlist = state.extra as Playlist;
                  return SlideTransitionPage(
                    key: state.pageKey,
                    child: PlaylistDetailPage(playlist: playlist),
                  );
                },
              ),
            ],
          ),

          /// search page
          GoRoute(
            path: app_paths.SEARCH_PAGE,
            pageBuilder: (context, state) =>
                NoTransitionPage(key: state.pageKey, child: const SearchPage()),
            routes: [
              GoRoute(
                path: "result",
                pageBuilder: (context, state) {
                  final extra = state.extra;
                  if (extra is UnionSearchResult) {
                    return SlideTransitionPage(
                      key: state.pageKey,
                      child: SearchResultPage(searchResult: extra),
                    );
                  }
                  return SlideTransitionPage(
                    key: state.pageKey,
                    child: const SearchPage(),
                  );
                },
              ),
            ],
          ),

          /// settings page
          GoRoute(
              path: app_paths.SETTINGS_PAGE,
              pageBuilder: (context, state) => NoTransitionPage(
                    key: state.pageKey,
                    child: const SettingsPage(),
                  ),
              routes: [
                GoRoute(
                  path: "issue",
                  pageBuilder: (context, state) => SlideTransitionPage(
                    key: state.pageKey,
                    child: const SettingsIssuePage(),
                  ),
                )
              ]),
        ],
      ),

      /// now playing page
      GoRoute(
        path: app_paths.NOW_PLAYING_PAGE,
        pageBuilder: (context, state) => CustomTransitionPage(
          key: state.pageKey,
          maintainState: false,
          transitionDuration: const Duration(milliseconds: 360),
          reverseTransitionDuration: const Duration(milliseconds: 360),
          transitionsBuilder: (context, animation, _, child) {
            final fade = CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
              reverseCurve: Curves.easeInOutCubic,
            );
            return FadeTransition(opacity: fade, child: child);
          },
          child: const NowPlayingPage(),
        ),
      ),

      /// welcoming page
      GoRoute(
        path: app_paths.WELCOMING_PAGE,
        pageBuilder: (context, state) =>
            SlideTransitionPage(key: state.pageKey, child: const WelcomingPage()),
      ),

      /// updating dialog
      GoRoute(
        path: app_paths.UPDATING_DIALOG,
        pageBuilder: (context, state) =>
            SlideTransitionPage(key: state.pageKey, child: const UpdatingPage()),
      ),
    ],
  );

  final supportedLocales = const [
    Locale.fromSubtags(languageCode: 'zh'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    Locale.fromSubtags(
        languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN'),
    Locale.fromSubtags(
        languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW'),
    Locale.fromSubtags(
        languageCode: 'zh', scriptCode: 'Hant', countryCode: 'HK'),
    Locale("en", "US"),
  ];
}
