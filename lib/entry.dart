import 'dart:async';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/component/app_shell.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/page/album_detail_page.dart';
import 'package:pure_music/page/albums_page.dart';
import 'package:pure_music/page/artist_detail_page.dart';
import 'package:pure_music/page/artists_page.dart';
import 'package:pure_music/page/audio_detail_page.dart';
import 'package:pure_music/page/audios_page.dart';
import 'package:pure_music/page/concert_page.dart';
import 'package:pure_music/page/folder_detail_page.dart';
import 'package:pure_music/page/folders_page.dart';
import 'package:pure_music/page/now_playing_page/now_playing_open_transition.dart';
import 'package:pure_music/page/now_playing_page/page.dart';
import 'package:pure_music/page/playlist_detail_page.dart';
import 'package:pure_music/page/playlists_page.dart';
import 'package:pure_music/page/remote_page.dart';
import 'package:pure_music/page/settings_page/check_update.dart';
import 'package:pure_music/page/settings_page/create_issue.dart';
import 'package:pure_music/page/stats_page/page.dart';
import 'package:pure_music/page/hidden_songs_page.dart';
import 'package:pure_music/page/settings_page/page.dart';
import 'package:pure_music/page/settings_page/settings_tabs.dart';
import 'package:pure_music/page/updating_page.dart';
import 'package:pure_music/page/welcoming_page.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/taskbar_thumbnail_service.dart';
import 'package:pure_music/component/app_scroll_behavior.dart';
import 'package:pure_music/core/app_fonts.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:pure_music/core/mouse_back_exit.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/route_visibility.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/core/update_download_monitor.dart';
import 'package:pure_music/core/update_installer.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_render_gate.dart';
import 'package:pure_music/core/memory_monitor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

/// 统一页面跳转过渡：iOS 风格——新页从右滑入覆盖，旧页向左视差滑动并淡化淡出。
///
/// 新页全程不透明（只位移），旧页被推向左侧 1/3 的同时淡出，
/// 由此形成清晰的层级推进，且不会出现"旧页没消失、新页重合"。
class SlideTransitionPage<T> extends CustomTransitionPage<T> {
  const SlideTransitionPage({
    required super.child,
    super.name,
    super.arguments,
    super.restorationId,
    super.key,
    super.maintainState = false,
    super.transitionDuration = const Duration(milliseconds: 420),
    super.reverseTransitionDuration = const Duration(milliseconds: 420),
  }) : super(transitionsBuilder: _transitionsBuilder);

  /// 内容切换过渡开关关闭时，页面立即跳转（无动画）。
  static bool _contentTransitionEnabled() =>
      AppSettings.instance.enableContentTransitionMotion;

  static Widget _transitionsBuilder(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    if (!_contentTransitionEnabled()) {
      return _reducedMotionPageTransition(animation, child);
    }
    return _contentSlidePageTransition(
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }

  static Widget _reducedMotionPageTransition(
    Animation<double> animation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: MotionCurve.standard,
      reverseCurve: MotionCurve.standard,
    );
    final slide = Tween<Offset>(
      begin: const Offset(0.03, 0.0),
      end: Offset.zero,
    ).animate(curved);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(position: slide, child: child),
    );
  }

  static Widget _contentSlidePageTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final textDirection = Directionality.of(context);
    final slides = _contentSlideAnimations(animation, secondaryAnimation);
    return AnimatedBuilder(
      animation: secondaryAnimation,
      child: child,
      builder: (context, child) {
        return IgnorePointer(
          ignoring: secondaryAnimation.value > 0.001,
          child: FadeTransition(
            opacity: slides.secondaryFade,
            child: SlideTransition(
              position: slides.secondaryPosition,
              textDirection: textDirection,
              transformHitTests: false,
              child: SlideTransition(
                position: slides.primaryPosition,
                textDirection: textDirection,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }

  static ({
    Animation<Offset> primaryPosition,
    Animation<Offset> secondaryPosition,
    Animation<double> secondaryFade,
  })
  _contentSlideAnimations(
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final primaryCurve = CurvedAnimation(
      parent: animation,
      curve: Curves.fastEaseInToSlowEaseOut,
      reverseCurve: Curves.fastEaseInToSlowEaseOut.flipped,
    );
    final secondaryCurve = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.linearToEaseOut,
      reverseCurve: Curves.easeInToLinear,
    );
    return (
      primaryPosition: Tween<Offset>(
        begin: const Offset(1.0, 0.0),
        end: Offset.zero,
      ).animate(primaryCurve),
      secondaryPosition: Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-1.0 / 3.0, 0.0),
      ).animate(secondaryCurve),
      secondaryFade: Tween<double>(
        begin: 1.0,
        end: 0.0,
      ).animate(secondaryCurve),
    );
  }
}

/// 根据"内容切换过渡"开关构造页面：关闭时恢复旧版短过渡。
Page<T> _slidePage<T>({
  required LocalKey? key,
  required Widget child,
  bool maintainState = false,
}) {
  final enabled = AppSettings.instance.enableContentTransitionMotion;
  return SlideTransitionPage<T>(
    key: key,
    maintainState: maintainState,
    child: child,
    transitionDuration: enabled
        ? const Duration(milliseconds: 420)
        : MotionDuration.fast,
    reverseTransitionDuration: enabled
        ? const Duration(milliseconds: 420)
        : MotionDuration.fast,
  );
}

GoRoute _detailRoute<T>({
  required String fallback,
  required Widget Function(T extra) builder,
  String path = 'detail',
}) {
  return GoRoute(
    path: path,
    redirect: (context, state) => _redirectUnlessExtra<T>(state, fallback),
    pageBuilder: (context, state) =>
        _slidePage(key: state.pageKey, child: builder(state.extra as T)),
  );
}

StatefulShellBranch _maintainedBranch({
  required String path,
  required Widget child,
  List<RouteBase> routes = const [],
}) {
  return StatefulShellBranch(
    routes: [
      GoRoute(
        path: path,
        pageBuilder: (context, state) =>
            _slidePage(key: state.pageKey, maintainState: true, child: child),
        routes: routes,
      ),
    ],
  );
}

StatefulShellBranch _builderBranch({
  required String path,
  required Widget child,
}) {
  return StatefulShellBranch(
    routes: [GoRoute(path: path, builder: (context, state) => child)],
  );
}

Page<void> _audiosPage(GoRouterState state) {
  final extra = state.extra;
  final page = extra is Audio
      ? AudiosPage(locateTo: extra)
      : const AudiosPage();
  return _slidePage(key: state.pageKey, maintainState: true, child: page);
}

String? _redirectUnlessExtra<T>(GoRouterState state, String fallback) {
  return state.extra is T ? null : fallback;
}

Page<void> _folderDetailPage(GoRouterState state) {
  final folder = state.extra as AudioFolder?;
  if (folder == null) {
    return NoTransitionPage(
      key: state.pageKey,
      child: FolderDetailPage(folder: AudioFolder([], '', 0, 0)),
    );
  }
  return _slidePage(
    key: state.pageKey,
    child: FolderDetailPage(folder: folder),
  );
}

Page<void> _playlistDetailPage(GoRouterState state) {
  final playlist = state.extra as Playlist?;
  if (playlist == null) {
    return NoTransitionPage(
      key: state.pageKey,
      child: PlaylistDetailPage(playlist: Playlist('', [])),
    );
  }
  return _slidePage(
    key: state.pageKey,
    child: PlaylistDetailPage(playlist: playlist),
  );
}

class Entry extends StatefulWidget {
  const Entry({super.key, required this.welcome});
  final bool welcome;

  @override
  State<Entry> createState() => _EntryState();
}

class _EntryState extends State<Entry>
    with WindowListener, WidgetsBindingObserver {
  final ValueNotifier<bool> _windowResizing = ValueNotifier(false);
  Timer? _resizeIdleTimer;
  Timer? _geometrySaveTimer;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    AppSettings.backgroundNotifier.addListener(_applyWindowTransparent);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      AudioEchoLogRecorder.instance.start(
        full: Platform.environment['CP_ECHO_RECORD'] == '1',
      );
      // 任务栏缩略图自定义封面（主窗口已创建完成）
      TaskbarThumbnailService.instance.init();
      // 预编译播放页背景 shader，避免首次进入时卡顿。
      NowPlayingPage.precacheBackgrounds();
      // 启动后延迟检查更新
      unawaited(_settleCachedUpdateDownload());
      _autoCheckUpdate();
    });
  }

  @override
  void dispose() {
    _resizeIdleTimer?.cancel();
    _geometrySaveTimer?.cancel();
    _windowResizing.dispose();
    AppSettings.backgroundNotifier.removeListener(_applyWindowTransparent);
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  void _applyWindowTransparent() {
    final settings = AppSettings.instance;
    if (settings.appWindowTransparent) {
      windowManager.setBackgroundColor(Colors.transparent);
      return;
    }
    windowManager.setBackgroundColor(Color(_windowBackgroundArgb(settings)));
  }

  int _windowBackgroundArgb(AppSettings settings) {
    if (settings.appBackgroundImagePath != null) return 0xFF000000;
    return ThemeProvider.instance.currScheme.surfaceContainerLow.toARGB32();
  }

  @override
  void didHaveMemoryPressure() {
    _onLowMemory();
  }

  @override
  void didChangePlatformBrightness() {
    ThemeProvider.instance.handlePlatformBrightnessChanged();
  }

  @override
  void onWindowMinimize() {
    WindowRenderGate.instance.setWindowMinimized(true);
    MemoryMonitorService.instance.trimWindowMinimized();
    PlayService.existingPlaybackService?.startSmtcKeepAlive();
  }

  @override
  void onWindowRestore() {
    // 等这次系统回调返回后再生效。回调里立刻画，会和还没恢复的窗口表面死锁。
    Timer.run(() {
      WindowRenderGate.instance.setWindowMinimized(false);
      PlayService.existingPlaybackService?.stopSmtcKeepAlive();
    });
  }

  @override
  void onWindowResize() {
    if (!_windowResizing.value) {
      _windowResizing.value = true;
    }
    _resizeIdleTimer?.cancel();
    _resizeIdleTimer = Timer(
      const Duration(milliseconds: 160),
      _finishWindowResize,
    );
  }

  @override
  void onWindowResized() {
    _finishWindowResize();
    _scheduleGeometrySave();
  }

  @override
  void onWindowMoved() {
    _scheduleGeometrySave();
  }

  void _finishWindowResize() {
    _resizeIdleTimer?.cancel();
    _resizeIdleTimer = null;
    if (_windowResizing.value) {
      _windowResizing.value = false;
    }
  }

  void _scheduleGeometrySave() {
    _geometrySaveTimer?.cancel();
    _geometrySaveTimer = Timer(const Duration(milliseconds: 160), () {
      _geometrySaveTimer = null;
      unawaited(AppSettings.instance.saveSettings());
    });
  }

  @override
  void onWindowFocus() {
    ThemeProvider.instance.refreshConfiguredSeedIfNeeded();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    if (event.buttons == kBackMouseButton) {
      _handleMouseBack();
    }
  }

  Future<void> _handleMouseBack() async {
    if (MultiSelectController.consumeBack()) return;

    final routerContext = routerKey.currentContext;
    if (routerContext == null) return;
    final router = GoRouter.of(routerContext);
    if (MouseBackExit.consumeRoute(router.state.uri.path)) return;
    if (MouseBackExit.consume()) return;

    if (ImmersiveModeController.instance.enabled) {
      await ImmersiveModeController.instance.exit();
      final startIndex = AppPreference.instance.startPage.clamp(
        0,
        app_paths.START_PAGES.length - 1,
      );
      router.go(app_paths.START_PAGES[startIndex]);
      return;
    }

    final navigator = Navigator.maybeOf(routerContext);
    if (navigator?.canPop() == true) {
      navigator?.pop();
    } else if (routerKey.currentContext?.canPop() == true) {
      routerKey.currentContext?.pop();
    }
  }

  Future<void> _settleCachedUpdateDownload() async {
    try {
      await cleanupCachedUpdateDownload();
      await UpdateDownloadMonitor.instance.restoreReadyNotice();
    } catch (error, trace) {
      log.app.warn(
        'legacy',
        '[UpdateInstaller] cleanup failed',
        error: error,
        stackTrace: trace,
      );
    }
  }

  /// 启动后延迟检查更新（1 小时节流）
  Future<void> _autoCheckUpdate() async {
    if (!AppPreference.instance.autoCheckUpdate) return;
    await Future<void>.delayed(const Duration(seconds: 5));
    if (!mounted) return;
    final hadSavedChannel =
        UpdateChannel.parse(AppPreference.instance.updateChannel) != null;
    final overlayContext = routerKey.currentState?.overlay?.context;
    if (overlayContext == null || !overlayContext.mounted) return;
    final channel = await ensureUpdateChannel(overlayContext);
    if (!mounted || !overlayContext.mounted || channel == null) return;
    if (_shouldSkipAutoUpdateCheck(hadSavedChannel)) return;
    final update = await _checkNewestUpdate(channel);
    if (!mounted || !overlayContext.mounted || update == null) return;
    await _notifyNewestUpdate(overlayContext, update, channel);
  }

  bool _shouldSkipAutoUpdateCheck(bool hadSavedChannel) {
    final lastRaw = AppPreference.instance.lastUpdateCheckTime;
    final last = lastRaw == null ? null : DateTime.tryParse(lastRaw);
    final now = DateTime.now().toUtc();
    return hadSavedChannel &&
        last != null &&
        now.isBefore(last.toUtc().add(const Duration(hours: 1)));
  }

  Future<UpdateInfo?> _checkNewestUpdate(UpdateChannel channel) async {
    UpdateInfo? newest;
    try {
      newest = await UpdateChecker.checkForUpdate(channel: channel);
    } catch (err, trace) {
      log.app.warn(
        'legacy',
        '[UpdateChecker] automatic check failed',
        error: err,
        stackTrace: trace,
      );
    } finally {
      AppPreference.instance.lastUpdateCheckTime = DateTime.now()
          .toUtc()
          .toIso8601String();
      await AppPreference.instance.save();
    }
    return newest;
  }

  Future<void> _notifyNewestUpdate(
    BuildContext overlayContext,
    UpdateInfo update,
    UpdateChannel channel,
  ) async {
    if (!UpdateChecker.shouldNotify(update.tagName)) return;
    AppPreference.instance.lastSeenUpdateTag = update.tagName;
    await AppPreference.instance.save();
    if (!mounted || !overlayContext.mounted) return;
    unawaited(
      showDialog<void>(
        context: overlayContext,
        builder: (context) => NewestUpdateView(info: update, channel: channel),
      ),
    );
  }

  void _onLowMemory() {
    // 只丢久未访问的封面字节，不清曲库、歌词和图片缓存。
    AudioLibrary.instance.evictStaleCoverBytes();
  }

  ThemeData fromSchemeAndFontFamily({
    required ColorScheme colorScheme,
    String? fontFamily,
  }) {
    final bool isDark = colorScheme.brightness == Brightness.dark;

    // For surfaces that use primary color in light themes and surface color in dark
    final Color primarySurfaceColor = isDark
        ? colorScheme.surface
        : colorScheme.primary;
    final Color onPrimarySurfaceColor = isDark
        ? colorScheme.onSurface
        : colorScheme.onPrimary;

    final defaultTextTheme = isDark
        ? Typography.material2021().white
        : Typography.material2021().black;
    final familyFallback = appFontFamilyFallback(fontFamily);
    final textTheme = defaultTextTheme.apply(
      fontFamily: fontFamily,
      fontFamilyFallback: familyFallback,
    );

    return ThemeData(
      fontFamily: fontFamily,
      fontFamilyFallback: familyFallback,
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
      cardTheme: CardThemeData(
        color: colorScheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
        clipBehavior: Clip.antiAlias,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHighest,
        labelStyle: textTheme.bodySmall?.copyWith(color: colorScheme.onSurface),
        side: BorderSide(color: colorScheme.outline),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.lg,
            vertical: Spacing.sm,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          side: BorderSide(color: colorScheme.outline),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.lg,
            vertical: Spacing.sm,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.sm,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: colorScheme.onSurfaceVariant,
          visualDensity: VisualDensity.compact,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm,
        ),
        border: OutlineInputBorder(
          borderRadius: AppRadius.smCircular,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.smCircular,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.smCircular,
          borderSide: BorderSide(color: colorScheme.primary),
        ),
        labelStyle: textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(AppRadius.md),
            topRight: Radius.circular(AppRadius.md),
          ),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        indicatorColor: onPrimarySurfaceColor,
        labelColor: onPrimarySurfaceColor,
        unselectedLabelColor: colorScheme.onSurfaceVariant,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.surfaceContainerHighest,
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withAlpha(
          (255 * Alpha.hover).round(),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
          ),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return colorScheme.primaryContainer;
            }
            return colorScheme.surfaceContainerHighest;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return colorScheme.onPrimaryContainer;
            }
            return colorScheme.onSurfaceVariant;
          }),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.onPrimaryContainer;
          }
          return colorScheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primaryContainer;
          }
          return colorScheme.surfaceContainerHighest;
        }),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: colorScheme.surfaceContainerHighest,
      ),
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
            builder: (context, child) => _windowTickerGate(child),
            theme: fromSchemeAndFontFamily(
              fontFamily: theme.fontFamily,
              colorScheme: theme.lightScheme,
            ),
            darkTheme: fromSchemeAndFontFamily(
              fontFamily: theme.fontFamily,
              colorScheme: theme.darkScheme,
            ),
            themeAnimationDuration: Duration.zero,
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

  Widget _windowTickerGate(Widget? child) {
    return ValueListenableBuilder<bool>(
      valueListenable: WindowRenderGate.instance.trayHidden,
      child: child,
      builder: (context, trayHidden, child) {
        return ValueListenableBuilder<bool>(
          valueListenable: _windowResizing,
          child: child,
          builder: (context, resizing, child) => ValueListenableBuilder<bool>(
            valueListenable: WindowRenderGate.instance.framesEnabled,
            child: child,
            builder: (context, windowFramesEnabled, child) {
              // 托盘隐藏时只停动画，界面树继续挂着。
              return TickerMode(
                enabled: !trayHidden && !resizing && windowFramesEnabled,
                child: child ?? const SizedBox.shrink(),
              );
            },
          ),
        );
      },
    );
  }

  late final GoRouter config = GoRouter(
    navigatorKey: routerKey,
    initialLocation: widget.welcome
        ? app_paths.WELCOMING_PAGE
        : app_paths.UPDATING_DIALOG,
    observers: [routeVisibilityObserver],
    routes: [
      StatefulShellRoute(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        navigatorContainerBuilder: (context, navigationShell, children) =>
            DirectionalTabView(
              index: navigationShell.currentIndex,
              children: children,
            ),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: app_paths.AUDIOS_PAGE,
                pageBuilder: (context, state) => _audiosPage(state),
                routes: [
                  _detailRoute<Audio>(
                    fallback: app_paths.AUDIOS_PAGE,
                    builder: (audio) => AudioDetailPage(audio: audio),
                  ),
                ],
              ),
            ],
          ),
          _maintainedBranch(
            path: app_paths.ARTISTS_PAGE,
            child: const ArtistsPage(),
            routes: [
              _detailRoute<Artist>(
                fallback: app_paths.ARTISTS_PAGE,
                builder: (artist) => ArtistDetailPage(artist: artist),
              ),
            ],
          ),
          _maintainedBranch(
            path: app_paths.ALBUMS_PAGE,
            child: const AlbumsPage(),
            routes: [
              _detailRoute<Album>(
                fallback: app_paths.ALBUMS_PAGE,
                builder: (album) => AlbumDetailPage(album: album),
              ),
            ],
          ),
          _maintainedBranch(
            path: app_paths.FOLDERS_PAGE,
            child: const FoldersPage(),
            routes: [
              GoRoute(
                path: 'detail',
                pageBuilder: (context, state) => _folderDetailPage(state),
              ),
            ],
          ),
          _maintainedBranch(
            path: app_paths.REMOTE_PAGE,
            child: const RemotePage(),
          ),
          _maintainedBranch(
            path: app_paths.PLAYLISTS_PAGE,
            child: const PlaylistsPage(),
            routes: [
              GoRoute(
                path: 'detail',
                pageBuilder: (context, state) => _playlistDetailPage(state),
              ),
            ],
          ),
          _builderBranch(
            path: app_paths.CONCERT_PAGE,
            child: const ConcertPage(),
          ),
          _maintainedBranch(
            path: app_paths.STATS_PAGE,
            child: const StatsPage(),
            routes: [
              _detailRoute<Artist>(
                path: 'artist',
                fallback: app_paths.STATS_PAGE,
                builder: (artist) => ArtistDetailPage(artist: artist),
              ),
              _detailRoute<Album>(
                path: 'album',
                fallback: app_paths.STATS_PAGE,
                builder: (album) => AlbumDetailPage(album: album),
              ),
            ],
          ),
          _maintainedBranch(
            path: app_paths.SETTINGS_PAGE,
            child: const SettingsPage(),
            routes: [
              GoRoute(
                path: 'hidden-songs',
                pageBuilder: (context, state) => _slidePage(
                  key: state.pageKey,
                  child: const HiddenSongsPage(),
                ),
              ),
              GoRoute(
                path: 'issue',
                pageBuilder: (context, state) => _slidePage(
                  key: state.pageKey,
                  child: const SettingsIssuePage(),
                ),
              ),
              GoRoute(
                path: 'group/:id',
                pageBuilder: (context, state) => _slidePage(
                  key: state.pageKey,
                  child: SettingsGroupPage(
                    groupId: state.pathParameters['id']!,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),

      /// now playing page
      GoRoute(
        path: app_paths.NOW_PLAYING_PAGE,
        pageBuilder: (context, state) {
          final motionEnabled =
              AppSettings.instance.enableContentTransitionMotion &&
              !MediaQuery.disableAnimationsOf(context);
          final openMotion =
              motionEnabled && AppSettings.instance.enableNowPlayingOpenMotion;
          if (!openMotion) {
            return CustomTransitionPage(
              key: state.pageKey,
              maintainState: false,
              transitionDuration: motionEnabled
                  ? MotionDuration.medium
                  : Duration.zero,
              reverseTransitionDuration: motionEnabled
                  ? MotionDuration.medium
                  : Duration.zero,
              transitionsBuilder: (context, animation, _, child) {
                if (!motionEnabled) return child;
                final curved = CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                );
                final slide = Tween<Offset>(
                  begin: const Offset(0.0, 0.06),
                  end: Offset.zero,
                ).animate(curved);
                final fade = Tween<double>(
                  begin: 0.0,
                  end: 1.0,
                ).animate(curved);
                return FadeTransition(
                  opacity: fade,
                  child: SlideTransition(position: slide, child: child),
                );
              },
              child: const NowPlayingPage(),
            );
          }
          return CustomTransitionPage(
            key: state.pageKey,
            maintainState: false,
            transitionDuration: MotionDuration.medium,
            reverseTransitionDuration: MotionDuration.medium,
            transitionsBuilder: (context, animation, _, child) {
              return NowPlayingOpenTransition(
                animation: animation,
                motionEnabled: true,
                child: child,
              );
            },
            child: const NowPlayingPage(),
          );
        },
      ),

      /// welcoming page
      GoRoute(
        path: app_paths.WELCOMING_PAGE,
        pageBuilder: (context, state) =>
            _slidePage(key: state.pageKey, child: const WelcomingPage()),
      ),

      /// updating dialog
      GoRoute(
        path: app_paths.UPDATING_DIALOG,
        pageBuilder: (context, state) =>
            _slidePage(key: state.pageKey, child: const UpdatingPage()),
      ),
    ],
  );

  final supportedLocales = const [
    Locale.fromSubtags(languageCode: 'zh'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hans',
      countryCode: 'CN',
    ),
    Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
      countryCode: 'TW',
    ),
    Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
      countryCode: 'HK',
    ),
    Locale('en', 'US'),
  ];
}
