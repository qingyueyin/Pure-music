import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kBackMouseButton;
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
import 'package:pure_music/page/settings_page/check_update.dart';
import 'package:pure_music/page/settings_page/create_issue.dart';
import 'package:pure_music/page/settings_page/page.dart';
import 'package:pure_music/page/updating_page.dart';
import 'package:pure_music/page/welcoming_page.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/component/app_scroll_behavior.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/color_extraction.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:pure_music/core/memory_monitor.dart';
import 'package:pure_music/core/matcher.dart' hide logger;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/core/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

class SlideTransitionPage<T> extends CustomTransitionPage<T> {
  const SlideTransitionPage({
    required super.child,
    super.name,
    super.arguments,
    super.restorationId,
    super.key,
  }) : super(
          maintainState: false,
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
          maintainState: false,
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
    final fade =
        CurvedAnimation(parent: animation, curve: Curves.easeInOutCubic);
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

class _EntryState extends State<Entry>
    with WindowListener, WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Platform.environment['CP_ECHO_RECORD'] == '1') {
        AudioEchoLogRecorder.instance.start();
      }
      // 启动后延迟检查更新
      _autoCheckUpdate();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void didHaveMemoryPressure() {
    _onLowMemory();
  }

  @override
  void onWindowMinimize() {
    MemoryMonitorService.instance.trimAll();
    logger.i('[mem] window minimized - cleared invisible caches');
  }

  @override
  void onWindowFocus() {
    // Window focus handler
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    if (event.buttons == kBackMouseButton) {
      _handleMouseBack();
    }
  }

  Future<void> _handleMouseBack() async {
    final routerContext = routerKey.currentContext;
    if (routerContext == null) return;

    if (ImmersiveModeController.instance.enabled) {
      await ImmersiveModeController.instance.exit();
      final startIndex = AppPreference.instance.startPage
          .clamp(0, app_paths.START_PAGES.length - 1);
      GoRouter.of(routerContext).go(app_paths.START_PAGES[startIndex]);
      return;
    }

    final navigator = Navigator.maybeOf(routerContext);
    if (navigator?.canPop() == true) {
      navigator?.pop();
    } else if (routerKey.currentContext?.canPop() == true) {
      routerKey.currentContext?.pop();
    }
  }

  /// 启动后延迟检查更新
  Future<void> _autoCheckUpdate() async {
    if (!AppPreference.instance.autoCheckUpdate) return;

    // 延迟 5 秒，避免影响启动性能
    await Future.delayed(const Duration(seconds: 5));
    if (!mounted) return;

    final newest = await UpdateChecker.checkForUpdate();
    if (!mounted || newest == null) return;

    if (UpdateChecker.shouldNotify(newest.tagName)) {
      // 记录已提醒版本，避免反复弹窗
      AppPreference.instance.lastSeenUpdateTag = newest.tagName;
      AppPreference.instance.save();

      final ctx = routerKey.currentState?.overlay?.context;
      if (ctx == null || !ctx.mounted) return;
      showDialog(
        context: ctx,
        builder: (context) => NewestUpdateView(info: newest),
      );
    }
  }

  /// 内存不足时的统一清理入口
  void _onLowMemory() {
    CoverImageCache.instance.clear();
    ColorExtractionService().clear();
    AudioLibrary.instance.evictAllCoversExcept(
      PlayService.instance.playbackService.nowPlaying?.path,
      includeCollectionCovers: true,
    );
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    clearLyricCaches();
    logger.w('[mem] low memory - cleared all caches');
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

    // Material 3 的 Typography，确保 fontFamily 传播到各 text style
    // 这样 lyric widget 能通过 theme.textTheme.bodyMedium?.fontFamily 获取到
    // （Flutter 3.44.1 已移除 ThemeData.fontFamily getter，无法用 theme.fontFamily 回退）
    final defaultTextTheme = Typography.material2021().white;
    final textTheme = fontFamily != null
        ? defaultTextTheme.apply(fontFamily: fontFamily)
        : defaultTextTheme;

    return ThemeData(
      fontFamily: fontFamily,
      colorScheme: colorScheme,
      brightness: colorScheme.brightness,
      primaryColor: primarySurfaceColor,
      canvasColor: colorScheme.surfaceContainerLow,
      scaffoldBackgroundColor: colorScheme.surfaceContainerLow,
      cardColor: colorScheme.surface,
      dividerColor: colorScheme.onSurface.withAlpha(31),
      applyElevationOverlayColor: isDark,
      useMaterial3: true,
      textTheme: textTheme,
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
        return Listener(
          onPointerDown: _onPointerDown,
          child: MaterialApp.router(
            scaffoldMessengerKey: scaffoldMessengerKey,
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
    navigatorKey: routerKey,
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
                  child: AudiosPage(locateTo: state.extra as Audio?),
                );
              }
              return NoTransitionPage(
                  key: state.pageKey, child: const AudiosPage());
            },
            routes: [
              GoRoute(
                path: 'detail',
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
            pageBuilder: (context, state) => NoTransitionPage(
                key: state.pageKey, child: const ArtistsPage()),
            routes: [
              GoRoute(
                path: 'detail',
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
                path: 'detail',
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
            pageBuilder: (context, state) => NoTransitionPage(
                key: state.pageKey, child: const FoldersPage()),
            routes: [
              /// folder detail page
              GoRoute(
                path: 'detail',
                pageBuilder: (context, state) {
                  final folder = state.extra as AudioFolder?;
                  if (folder == null) {
                    return NoTransitionPage(
                        key: state.pageKey,
                        child: FolderDetailPage(
                            folder: AudioFolder([], '', 0, 0)));
                  }
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
            pageBuilder: (context, state) => NoTransitionPage(
                key: state.pageKey, child: const PlaylistsPage()),
            routes: [
              GoRoute(
                path: 'detail',
                pageBuilder: (context, state) {
                  final playlist = state.extra as Playlist?;
                  if (playlist == null) {
                    return NoTransitionPage(
                        key: state.pageKey,
                        child: PlaylistDetailPage(playlist: Playlist('', [])));
                  }
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
                path: 'result',
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
                  path: 'issue',
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
          transitionDuration: const Duration(milliseconds: 400),
          reverseTransitionDuration: const Duration(milliseconds: 400),
          transitionsBuilder: (context, animation, _, child) {
            return FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeInOutCubic,
                reverseCurve: Curves.easeInOutCubic,
              ),
              child: child,
            );
          },
          child: const NowPlayingPage(),
        ),
      ),

      /// welcoming page
      GoRoute(
        path: app_paths.WELCOMING_PAGE,
        pageBuilder: (context, state) => SlideTransitionPage(
          key: state.pageKey,
          child: const WelcomingPage(),
        ),
      ),

      /// updating dialog
      GoRoute(
        path: app_paths.UPDATING_DIALOG,
        pageBuilder: (context, state) => SlideTransitionPage(
          key: state.pageKey,
          child: const UpdatingPage(),
        ),
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
    Locale('en', 'US'),
  ];
}
