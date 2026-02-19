// ignore_for_file: camel_case_types

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/component/hotkey_ui_feedback.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/side_nav.dart';
import 'package:pure_music/component/title_bar.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/page/now_playing_page/component/current_playlist_view.dart';
import 'package:pure_music/page/now_playing_page/component/equalizer_dialog.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_source_view.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_shader_background.dart';
import 'package:pure_music/page/now_playing_page/component/pitch_control.dart';
import 'package:pure_music/page/now_playing_page/component/vertical_lyric_view.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_service.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

part 'small_page.dart';
part 'large_page.dart';
part 'immersive_page.dart';

final NOW_PLAYING_VIEW_MODE = ValueNotifier(
  AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode,
);

class _MeshBackgroundPainter extends CustomPainter {
  final ColorScheme scheme;
  final Brightness brightness;
  final Animation<double> animation;

  _MeshBackgroundPainter({
    required this.scheme,
    required this.brightness,
    required Listenable repaint,
  })  : animation = repaint as Animation<double>,
        super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (!w.isFinite || !h.isFinite || w <= 1 || h <= 1) return;

    final t = animation.value * 6.283185307179586;
    final alphaBase = brightness == Brightness.dark ? 0.20 : 0.16;
    final blur = brightness == Brightness.dark ? 120.0 : 140.0;

    void circle({
      required Color color,
      required Offset center,
      required double radius,
      double alpha = 1.0,
    }) {
      final paint = Paint()
        ..color = color.withValues(alpha: (alphaBase * alpha).clamp(0.0, 1.0))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
      canvas.drawCircle(center, radius, paint);
    }

    circle(
      color: scheme.primary,
      center: Offset(
        w * (0.22 + 0.10 * sin(t * 0.9 + 0.2)),
        h * (0.25 + 0.10 * cos(t * 0.7 + 0.8)),
      ),
      radius: w * 0.45,
      alpha: 1.0,
    );
    circle(
      color: scheme.tertiary,
      center: Offset(
        w * (0.78 + 0.10 * cos(t * 0.8 + 1.6)),
        h * (0.20 + 0.12 * sin(t * 0.6 + 0.4)),
      ),
      radius: w * 0.40,
      alpha: 0.95,
    );
    circle(
      color: scheme.secondary,
      center: Offset(
        w * (0.62 + 0.14 * sin(t * 0.65 + 2.2)),
        h * (0.78 + 0.10 * cos(t * 0.55 + 1.1)),
      ),
      radius: w * 0.52,
      alpha: 0.85,
    );
    circle(
      color: scheme.primaryContainer,
      center: Offset(
        w * (0.30 + 0.10 * cos(t * 0.5 + 0.6)),
        h * (0.78 + 0.14 * sin(t * 0.7 + 2.8)),
      ),
      radius: w * 0.36,
      alpha: 0.70,
    );

    final overlay = Paint()
      ..color = (brightness == Brightness.dark
              ? Colors.black.withValues(alpha: 0.10)
              : Colors.white.withValues(alpha: 0.06))
          .withValues(alpha: 1.0);
    canvas.drawRect(Offset.zero & size, overlay);
  }

  @override
  bool shouldRepaint(covariant _MeshBackgroundPainter oldDelegate) {
    return oldDelegate.scheme != scheme || oldDelegate.brightness != brightness;
  }
}

class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key});

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage>
    with SingleTickerProviderStateMixin {
  final playbackService = PlayService.instance.playbackService;
  ImageProvider<Object>? nowPlayingCover;
  ImageProvider<Object>? nowPlayingBgCover;
  String? _nowPlayingCoverPath;
  Timer? _coverDebounceTimer;
  Timer? _cursorHideTimer;
  late final AnimationController _bgController;
  bool _cursorHidden = false;
  bool _lastImmersive = false;

  void _bumpCursor() {
    _cursorHideTimer?.cancel();
    if (_cursorHidden) {
      setState(() {
        _cursorHidden = false;
      });
    }
    _cursorHideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() {
        _cursorHidden = true;
      });
    });
  }

  void updateCover() {
    final path = playbackService.nowPlaying?.path;
    if (path == null) {
      if (_nowPlayingCoverPath != null || nowPlayingCover != null) {
        _coverDebounceTimer?.cancel();
        setState(() {
          _nowPlayingCoverPath = null;
          nowPlayingCover = null;
          nowPlayingBgCover = null;
        });
      }
      return;
    }

    if (path == _nowPlayingCoverPath) return;
    _nowPlayingCoverPath = path;

    _coverDebounceTimer?.cancel();
    _coverDebounceTimer = Timer(MotionDuration.base, () {
      playbackService.nowPlaying?.cover.then((cover) {
        if (!mounted) return;
        if (playbackService.nowPlaying?.path != path) return;
        if (cover != null) {
          precacheImage(cover, context);
        }
        if (nowPlayingCover == cover) return;
        setState(() {
          nowPlayingCover = cover;
          nowPlayingBgCover = cover == null
              ? null
              : ResizeImage(
                  cover,
                  width: 64,
                  height: 64,
                  allowUpscaling: true,
                );
        });
      });
    });
  }

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 22),
    )..repeat();
    playbackService.addListener(updateCover);
    updateCover();
    _bumpCursor();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      PlayService.instance.lyricService
          .findCurrLyricLineAt(playbackService.position);
    });
  }

  @override
  void dispose() {
    playbackService.removeListener(updateCover);
    _bgController.dispose();
    _coverDebounceTimer?.cancel();
    _cursorHideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    final drawerWidth = (size.width * 0.78).clamp(240.0, 288.0);

    return ListenableBuilder(
      listenable: ImmersiveModeController.instance,
      builder: (context, _) {
        final immersive = ImmersiveModeController.instance.enabled;
        if (immersive != _lastImmersive) {
          _lastImmersive = immersive;
        }
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 520),
          switchInCurve: Curves.easeInOutCubic,
          switchOutCurve: Curves.easeInOutCubic,
          layoutBuilder: (currentChild, previousChildren) {
            return Stack(
              fit: StackFit.expand,
              children: [
                ...previousChildren,
                if (currentChild != null) currentChild,
              ],
            );
          },
          transitionBuilder: (child, animation) {
            final fade = CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
            );
            final scale = Tween<double>(begin: 0.985, end: 1.0).animate(fade);
            return FadeTransition(
              opacity: fade,
              child: ScaleTransition(scale: scale, child: child),
            );
          },
          child: KeyedSubtree(
            key: ValueKey(immersive),
            child: Scaffold(
              appBar: null,
              backgroundColor: Colors.transparent,
              drawer: SizedBox(width: drawerWidth, child: const SideNav()),
              drawerEnableOpenDragGesture: !immersive,
              body: Listener(
                onPointerDown: (_) {
                  _bumpCursor();
                },
                onPointerMove: (_) {
                  _bumpCursor();
                },
                onPointerHover: (_) {
                  _bumpCursor();
                },
                child: Stack(
                  fit: StackFit.expand,
                  alignment: AlignmentDirectional.center,
                  children: [
                    RepaintBoundary(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ColoredBox(color: scheme.surface),
                          NowPlayingShaderBackground(
                            repaint: _bgController,
                            scheme: scheme,
                            brightness: brightness,
                            spectrumStream: playbackService.spectrumStream,
                            intensity: brightness == Brightness.dark ? 1.0 : 0.9,
                            fallback: RepaintBoundary(
                              child: CustomPaint(
                                painter: _MeshBackgroundPainter(
                                  scheme: scheme,
                                  brightness: brightness,
                                  repaint: _bgController,
                                ),
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 560),
                            switchInCurve: Curves.easeInOutCubic,
                            switchOutCurve: Curves.easeInOutCubic,
                            layoutBuilder: (currentChild, previousChildren) {
                              return Stack(
                                fit: StackFit.expand,
                                children: [
                                  ...previousChildren,
                                  if (currentChild != null) currentChild,
                                ],
                              );
                            },
                            transitionBuilder: (child, animation) {
                              final fade = CurvedAnimation(
                                parent: animation,
                                curve: Curves.easeInOutCubic,
                              );
                              return FadeTransition(opacity: fade, child: child);
                            },
                            child: nowPlayingCover == null
                                ? const SizedBox.expand(
                                    key: ValueKey("now-playing-bg-none"),
                                  )
                                : KeyedSubtree(
                                    key: ValueKey(_nowPlayingCoverPath),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Opacity(
                                          opacity: 0.24,
                                          child: ImageFiltered(
                                            imageFilter: ImageFilter.blur(
                                              sigmaX: 22,
                                              sigmaY: 22,
                                            ),
                                            child: Image(
                                              image: nowPlayingBgCover ?? nowPlayingCover!,
                                              fit: BoxFit.cover,
                                              filterQuality: FilterQuality.low,
                                              errorBuilder: (_, __, ___) =>
                                                  const SizedBox.shrink(),
                                            ),
                                          ),
                                        ),
                                        DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: switch (brightness) {
                                                Brightness.dark => [
                                                    Colors.black.withValues(
                                                        alpha: 0.44),
                                                    Colors.black.withValues(
                                                        alpha: 0.20),
                                                    Colors.black.withValues(
                                                        alpha: 0.44),
                                                  ],
                                                Brightness.light => [
                                                    Colors.black.withValues(
                                                        alpha: 0.34),
                                                    Colors.black.withValues(
                                                        alpha: 0.18),
                                                    Colors.black.withValues(
                                                        alpha: 0.34),
                                                  ],
                                              },
                                              stops: const [0.0, 0.6, 1.0],
                                            ),
                                          ),
                                          child: const SizedBox.expand(),
                                        ),
                                      ],
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                    IconButtonTheme(
                      data: IconButtonThemeData(
                        style: ButtonStyle(
                          backgroundColor: const WidgetStatePropertyAll(
                            Colors.transparent,
                          ),
                          overlayColor:
                              WidgetStateProperty.resolveWith((states) {
                            if (states.contains(WidgetState.pressed)) {
                              return scheme.onSecondaryContainer.withValues(
                                alpha: 0.04,
                              );
                            }
                            if (states.contains(WidgetState.hovered) ||
                                states.contains(WidgetState.focused)) {
                              return scheme.onSecondaryContainer.withValues(
                                alpha: 0.02,
                              );
                            }
                            return Colors.transparent;
                          }),
                        ),
                      ),
                      child: ChangeNotifierProvider.value(
                        value: PlayService.instance.playbackService,
                        builder: (context, _) => immersive
                            ? const _NowPlayingPage_Immersive()
                            : ResponsiveBuilder2(
                                builder: (context, screenType) {
                                  switch (screenType) {
                                    case ScreenType.small:
                                      return const _NowPlayingPage_Small();
                                    case ScreenType.medium:
                                    case ScreenType.large:
                                      return const _NowPlayingPage_Large();
                                  }
                                },
                              ),
                      ),
                    ),
                    if (immersive) const _ImmersiveHelpOverlay(),
                    if (!immersive)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 56.0,
                        child: SafeArea(
                          bottom: false,
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12.0),
                            child: Row(
                              children: [
                                ResponsiveBuilder2(
                                  builder: (context, screenType) {
                                    if (screenType != ScreenType.small) {
                                      return const SizedBox.shrink();
                                    }
                                    return Builder(
                                      builder: (context) => IconButton(
                                        tooltip: "侧边栏",
                                        onPressed: () {
                                          Scaffold.of(context).openDrawer();
                                        },
                                        icon: const Icon(Symbols.menu),
                                      ),
                                    );
                                  },
                                ),
                                const NavBackBtn(),
                                const Expanded(
                                  child: DragToMoveArea(
                                    child: SizedBox.expand(),
                                  ),
                                ),
                                const WindowControlls(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (_cursorHidden)
                      const Positioned.fill(
                        child: MouseRegion(
                          cursor: SystemMouseCursors.none,
                          child: SizedBox.expand(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ExclusiveModeSwitch extends StatelessWidget {
  const _ExclusiveModeSwitch();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: PlayService.instance.playbackService.wasapiExclusive,
      builder: (context, exclusive, _) => IconButton(
        tooltip: exclusive ? "独占模式：启用" : "独占模式",
        onPressed: () {
          PlayService.instance.playbackService.useExclusiveMode(!exclusive);
        },
        icon: Center(
          child: Text(
            exclusive ? "Excl" : "Shrd",
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}

class _NowPlayingMoreAction extends StatelessWidget {
  const _NowPlayingMoreAction();

  @override
  Widget build(BuildContext context) {
    final playbackService = context.watch<PlaybackService>();
    final nowPlaying = playbackService.nowPlaying;
    final scheme = Theme.of(context).colorScheme;
    final menuStyle = MenuStyle(
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
    final menuItemStyle = ButtonStyle(
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );

    if (nowPlaying == null) {
      return IconButton(
        tooltip: "更多",
        onPressed: null,
        icon: const Icon(Symbols.more_vert),
        color: scheme.onSecondaryContainer,
      );
    }

    return MenuTheme(
      data: MenuThemeData(style: menuStyle),
      child: MenuAnchor(
        style: menuStyle,
        menuChildren: [
          ...List.generate(
            nowPlaying.splitedArtists.length,
            (i) => MenuItemButton(
              style: menuItemStyle,
              onPressed: () {
                final Artist artist = AudioLibrary
                    .instance.artistCollection[nowPlaying.splitedArtists[i]]!;
                context.pushReplacement(
                  app_paths.ARTIST_DETAIL_PAGE,
                  extra: artist,
                );
              },
              leadingIcon: const Icon(Symbols.people),
              child: Text(nowPlaying.splitedArtists[i]),
            ),
          ),
          MenuItemButton(
            style: menuItemStyle,
            onPressed: () {
              final Album album =
                  AudioLibrary.instance.albumCollection[nowPlaying.album]!;
              context.pushReplacement(app_paths.ALBUM_DETAIL_PAGE,
                  extra: album);
            },
            leadingIcon: const Icon(Symbols.album),
            child: Text(nowPlaying.album),
          ),
          SubmenuButton(
            style: menuItemStyle,
            menuChildren: List.generate(
              PLAYLISTS.length,
              (i) => MenuItemButton(
                style: menuItemStyle,
                onPressed: () {
                  final added =
                      PLAYLISTS[i].audios.containsKey(nowPlaying.path);
                  if (added) {
                    showTextOnSnackBar("歌曲“${nowPlaying.title}”已存在");
                    return;
                  }
                  PLAYLISTS[i].audios[nowPlaying.path] = nowPlaying;
                  showTextOnSnackBar(
                    "成功将“${nowPlaying.title}”添加到歌单“${PLAYLISTS[i].name}”",
                  );
                },
                leadingIcon: const Icon(Symbols.queue_music),
                child: Text(PLAYLISTS[i].name),
              ),
            ),
            child: const Text("添加到歌单"),
          ),
          MenuItemButton(
            style: menuItemStyle,
            onPressed: () {
              showDialog<void>(
                context: context,
                builder: (context) => SetLyricSourceDialog(audio: nowPlaying),
              );
            },
            leadingIcon: const Icon(Symbols.lyrics),
            child: const Text("歌词来源"),
          ),
          MenuItemButton(
            style: menuItemStyle,
            onPressed: () {
              context.pushReplacement(app_paths.AUDIO_DETAIL_PAGE,
                  extra: nowPlaying);
            },
            leadingIcon: const Icon(Symbols.info),
            child: const Text("详细信息"),
          ),
        ],
        builder: (context, controller, _) => IconButton(
          tooltip: "更多",
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          icon: const Icon(Symbols.more_vert),
          color: scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _DesktopLyricSwitch extends StatelessWidget {
  const _DesktopLyricSwitch();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: PlayService.instance.desktopLyricService,
      builder: (context, _) {
        final desktopLyricService = PlayService.instance.desktopLyricService;
        return FutureBuilder(
          future: desktopLyricService.desktopLyric,
          builder: (context, snapshot) => IconButton(
            tooltip: snapshot.data != null ? "桌面歌词；启用" : "桌面歌词",
            onPressed: snapshot.data == null
                ? desktopLyricService.startDesktopLyric
                : desktopLyricService.isLocked
                    ? desktopLyricService.sendUnlockMessage
                    : desktopLyricService.killDesktopLyric,
            icon: snapshot.connectionState == ConnectionState.done
                ? Icon(
                    desktopLyricService.isLocked ? Symbols.lock : Symbols.toast,
                    fill: snapshot.data == null ? 0 : 1,
                  )
                : const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(),
                  ),
            color: scheme.onSecondaryContainer,
          ),
        );
      },
    );
  }
}

class _NowPlayingVolDspSlider extends StatefulWidget {
  const _NowPlayingVolDspSlider();

  @override
  State<_NowPlayingVolDspSlider> createState() =>
      _NowPlayingVolDspSliderState();
}

class _NowPlayingVolDspSliderState extends State<_NowPlayingVolDspSlider> {
  final playbackService = PlayService.instance.playbackService;
  final dragVolDsp = ValueNotifier(
    AppPreference.instance.playbackPref.volumeDsp,
  );
  final dragSystemVol = ValueNotifier(0.0);

  bool isDragging = false;
  bool isSystemDragging = false;
  bool _isMenuOpen = false;
  double _lastVolumeDsp = -1;
  Timer? _systemVolPollTimer;
  bool _systemVolPollBusy = false;
  Timer? _systemVolBoostTimer;
  int _systemVolReadFailures = 0;
  late final void Function(double) _systemVolListener;
  Timer? _indicatorTimer;
  Timer? _systemIndicatorTimer;
  bool _showCustomIndicator = false;
  bool _showSystemCustomIndicator = false;
  bool _isHovering = false;
  bool _isSystemHovering = false;
  MenuController? _menuController;
  Timer? _autoCloseTimer;
  int _lastVolumeHotkeySerial = 0;
  late final VoidCallback _hotkeyListener;

  void _scheduleAutoClose() {
    _autoCloseTimer?.cancel();
    _autoCloseTimer = Timer(const Duration(milliseconds: 950), () {
      if (!mounted) return;
      if (isDragging || isSystemDragging || _isHovering || _isSystemHovering) {
        _scheduleAutoClose();
        return;
      }
      _menuController?.close();
    });
  }

  Future<double?> _readSystemVol({required Duration timeout}) async {
    try {
      return await FlutterVolumeController.getVolume().timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  void _rebindSystemVolListener() {
    FlutterVolumeController.removeListener();
    FlutterVolumeController.addListener(_systemVolListener);
  }

  @override
  void initState() {
    super.initState();
    _hotkeyListener = () {
      if (!mounted) return;
      final event = HOTKEY_UI_FEEDBACK.lastEvent;
      if (event == null) return;
      if (event.action != HotkeyUiAction.volumeStep) return;
      if (event.serial == _lastVolumeHotkeySerial) return;
      _lastVolumeHotkeySerial = event.serial;

      if (_menuController?.isOpen != true) {
        _menuController?.open();
      }
      if (!isDragging) {
        dragVolDsp.value = playbackService.volumeDsp;
      }
      _triggerIndicator();
      _scheduleAutoClose();
    };
    HOTKEY_UI_FEEDBACK.addListener(_hotkeyListener);
    _lastVolumeDsp = playbackService.volumeDsp;
    playbackService.addListener(() {
      if (!mounted) return;
      final v = playbackService.volumeDsp;
      if ((v - _lastVolumeDsp).abs() <= 0.0001) return;
      _lastVolumeDsp = v;
      if (_isMenuOpen && !isDragging) {
        _triggerIndicator();
      }
    });
    _systemVolListener = (v) {
      if (mounted && !isSystemDragging) {
        dragSystemVol.value = v;
      }
    };
    FlutterVolumeController.addListener(_systemVolListener);
    _readSystemVol(timeout: const Duration(milliseconds: 600)).then((v) {
      if (!mounted) return;
      dragSystemVol.value = v ?? 0.5;
    });

    if (Platform.isWindows) {
      _systemVolPollTimer =
          Timer.periodic(const Duration(milliseconds: 250), (_) async {
        if (!mounted || isSystemDragging || _systemVolPollBusy) return;
        _systemVolPollBusy = true;
        try {
          final v = await _readSystemVol(timeout: const Duration(seconds: 1));
          if (!mounted || isSystemDragging) return;
          if (v == null) {
            _systemVolReadFailures += 1;
            if (_systemVolReadFailures >= 3) {
              _systemVolReadFailures = 0;
              _rebindSystemVolListener();
            }
            return;
          }
          _systemVolReadFailures = 0;
          final curr = dragSystemVol.value;
          if ((v - curr).abs() > 0.005) {
            dragSystemVol.value = v;
          }
        } finally {
          _systemVolPollBusy = false;
        }
      });
    }
  }

  void _triggerIndicator() {
    setState(() => _showCustomIndicator = true);
    _indicatorTimer?.cancel();
    _indicatorTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() => _showCustomIndicator = false);
      }
    });
  }

  void _triggerSystemIndicator() {
    setState(() => _showSystemCustomIndicator = true);
    _systemIndicatorTimer?.cancel();
    _systemIndicatorTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() => _showSystemCustomIndicator = false);
      }
    });
  }

  @override
  void dispose() {
    FlutterVolumeController.removeListener();
    _systemVolPollTimer?.cancel();
    _systemVolBoostTimer?.cancel();
    _indicatorTimer?.cancel();
    _systemIndicatorTimer?.cancel();
    _autoCloseTimer?.cancel();
    HOTKEY_UI_FEEDBACK.removeListener(_hotkeyListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return MenuAnchor(
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      onOpen: () {
        _isMenuOpen = true;
        if (!isDragging) {
          dragVolDsp.value = playbackService.volumeDsp;
        }
        int ticks = 0;
        _systemVolBoostTimer?.cancel();
        _systemVolBoostTimer =
            Timer.periodic(const Duration(milliseconds: 120), (_) async {
          if (!mounted || isSystemDragging) return;
          if (ticks++ > 25) {
            _systemVolBoostTimer?.cancel();
            return;
          }
          final v =
              await _readSystemVol(timeout: const Duration(milliseconds: 500));
          if (v != null && (v - dragSystemVol.value).abs() > 0.003) {
            dragSystemVol.value = v;
          }
        });
      },
      onClose: () {
        _isMenuOpen = false;
        _systemVolBoostTimer?.cancel();
      },
      menuChildren: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
          child: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // System Volume Slider
                Padding(
                  padding: const EdgeInsets.fromLTRB(16.0, 4.0, 16.0, 8.0),
                  child: Text(
                    "系统音量",
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 12,
                    ),
                  ),
                ),
                SliderTheme(
                  data: const SliderThemeData(
                    showValueIndicator: ShowValueIndicator.never,
                  ),
                  child: ValueListenableBuilder(
                    valueListenable: dragSystemVol,
                    builder: (context, systemVolValue, _) {
                      return LayoutBuilder(
                        builder: (context, constraints) {
                          const double padding = 24.0;
                          final double trackWidth =
                              constraints.maxWidth - (padding * 2);
                          const double min = 0.0;
                          const double max = 1.0;
                          final double percent =
                              (systemVolValue - min) / (max - min);
                          final double leftOffset =
                              padding + (trackWidth * percent);

                          return MouseRegion(
                            onEnter: (_) =>
                                setState(() => _isSystemHovering = true),
                            onExit: (_) =>
                                setState(() => _isSystemHovering = false),
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.centerLeft,
                              children: [
                                Slider(
                                  thumbColor: scheme.secondary,
                                  activeColor: scheme.secondary,
                                  inactiveColor: scheme.outline,
                                  min: min,
                                  max: max,
                                  value: systemVolValue,
                                  onChangeStart: (value) {
                                    isSystemDragging = true;
                                    dragSystemVol.value = value;
                                    FlutterVolumeController.setVolume(value);
                                    _triggerSystemIndicator();
                                  },
                                  onChanged: (value) {
                                    dragSystemVol.value = value;
                                    FlutterVolumeController.setVolume(value);
                                    if (isSystemDragging) {
                                      _triggerSystemIndicator();
                                    }
                                  },
                                  onChangeEnd: (value) {
                                    isSystemDragging = false;
                                    dragSystemVol.value = value;
                                    FlutterVolumeController.setVolume(value);
                                  },
                                ),
                                if (_showSystemCustomIndicator ||
                                    _isSystemHovering)
                                  Positioned(
                                    left: leftOffset - 24.0,
                                    top: -40,
                                    child: IgnorePointer(
                                      child: _CustomValueIndicator(
                                        value: systemVolValue * 100,
                                        suffix: "%",
                                        color: scheme.secondary,
                                        textColor: scheme.onSecondary,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8.0),
                const Divider(height: 20),
                const SizedBox(height: 4.0),
                // App Volume Slider
                Padding(
                  padding: const EdgeInsets.fromLTRB(16.0, 4.0, 16.0, 8.0),
                  child: Text(
                    "应用音量",
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 12,
                    ),
                  ),
                ),
                SliderTheme(
                  data: const SliderThemeData(
                    showValueIndicator: ShowValueIndicator.never,
                  ),
                  child: ListenableBuilder(
                    listenable: Listenable.merge([dragVolDsp, playbackService]),
                    builder: (context, _) {
                      final dragVolDspValue = dragVolDsp.value;
                      final currentValue = isDragging
                          ? dragVolDspValue
                          : playbackService.volumeDsp;

                      return LayoutBuilder(
                        builder: (context, constraints) {
                          const double padding = 24.0;
                          final double trackWidth =
                              constraints.maxWidth - (padding * 2);
                          const double min = 0.0;
                          const double max = 1.0;
                          final double percent =
                              (currentValue - min) / (max - min);
                          final double leftOffset =
                              padding + (trackWidth * percent);

                          return MouseRegion(
                            onEnter: (_) => setState(() => _isHovering = true),
                            onExit: (_) => setState(() => _isHovering = false),
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.centerLeft,
                              children: [
                                Slider(
                                  thumbColor: scheme.primary,
                                  activeColor: scheme.primary,
                                  inactiveColor: scheme.outline,
                                  min: min,
                                  max: max,
                                  value: currentValue,
                                  onChangeStart: (value) {
                                    isDragging = true;
                                    dragVolDsp.value = value;
                                    playbackService.setVolumeDsp(value);
                                    _triggerIndicator();
                                  },
                                  onChanged: (value) {
                                    dragVolDsp.value = value;
                                    playbackService.setVolumeDsp(value);
                                    // Also trigger indicator on drag
                                    if (isDragging) _triggerIndicator();
                                  },
                                  onChangeEnd: (value) {
                                    isDragging = false;
                                    dragVolDsp.value = value;
                                    playbackService.setVolumeDsp(value);
                                  },
                                ),
                                if (_showCustomIndicator || _isHovering)
                                  Positioned(
                                    left: leftOffset -
                                        24.0, // Center the bubble (width 48)
                                    top: -40,
                                    child: IgnorePointer(
                                      child: _CustomValueIndicator(
                                        value: currentValue * 100,
                                        suffix: "%",
                                        color: scheme.primary,
                                        textColor: scheme.onPrimary,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, _) {
        _menuController = controller;
        return IconButton(
          tooltip: "音量",
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          icon: const Icon(Symbols.volume_up),
          color: scheme.onSecondaryContainer,
        );
      },
    );
  }
}

class _CustomValueIndicator extends StatelessWidget {
  final double value;
  final String suffix;
  final Color color;
  final Color textColor;

  const _CustomValueIndicator({
    required this.value,
    this.suffix = "",
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            "${value.toInt()}$suffix",
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
        CustomPaint(
          size: const Size(12, 6),
          painter: _TrianglePainter(color),
        ),
      ],
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;

  _TrianglePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(0, 0);
    path.lineTo(size.width / 2, size.height);
    path.lineTo(size.width, 0);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _NowPlayingPlaybackModeSwitch extends StatelessWidget {
  const _NowPlayingPlaybackModeSwitch();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playbackService = PlayService.instance.playbackService;

    return ListenableBuilder(
      listenable:
          Listenable.merge([playbackService.shuffle, playbackService.playMode]),
      builder: (context, _) {
        final shuffle = playbackService.shuffle.value;
        final playMode = playbackService.playMode.value;

        final modeText = switch (true) {
          _ when shuffle => "随机播放",
          _ when playMode == PlayMode.singleLoop => "单曲循环",
          _ => "顺序播放",
        };

        final icon = switch (true) {
          _ when shuffle => Symbols.shuffle,
          _ when playMode == PlayMode.singleLoop => Symbols.repeat_one,
          _ => Symbols.repeat,
        };

        return IconButton(
          style: const ButtonStyle(
            backgroundColor: WidgetStatePropertyAll(Colors.transparent),
            overlayColor: WidgetStatePropertyAll(Colors.transparent),
          ),
          tooltip: modeText,
          onPressed: () {
            if (!shuffle && playMode != PlayMode.singleLoop) {
              playbackService.useShuffle(false);
              playbackService.setPlayMode(PlayMode.singleLoop);
              return;
            }
            if (!shuffle && playMode == PlayMode.singleLoop) {
              playbackService.setPlayMode(PlayMode.forward);
              playbackService.useShuffle(true);
              return;
            }

            playbackService.useShuffle(false);
            playbackService.setPlayMode(PlayMode.forward);
          },
          icon: Icon(icon, fill: 0.0, weight: 400.0),
          color: scheme.onSecondaryContainer,
        );
      },
    );
  }
}

/// previous audio, pause/resume, next audio
class _NowPlayingMainControls extends StatelessWidget {
  const _NowPlayingMainControls();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playbackService = PlayService.instance.playbackService;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _GlowingIconButton(
          tooltip: "上一曲",
          onPressed: playbackService.lastAudio,
          iconData: Symbols.skip_previous,
          size: 32,
          glowColor: scheme.primary.withValues(alpha: 0.5),
          iconColor: scheme.onSecondaryContainer,
        ),
        const SizedBox(width: 32),
        StreamBuilder(
          stream: playbackService.playerStateStream,
          initialData: playbackService.playerState,
          builder: (context, snapshot) {
            final playerState = snapshot.data!;
            return _MorphPlayPauseButton(
              playerState: playerState,
              onPlay: playbackService.start,
              onPause: playbackService.pause,
              onReplay: playbackService.playAgain,
              size: 56,
              glowColor: scheme.primary.withValues(alpha: 0.6),
              color: scheme.primary,
              playerStateStream: playbackService.playerStateStream,
            );
          },
        ),
        const SizedBox(width: 32),
        _GlowingIconButton(
          tooltip: "下一曲",
          onPressed: playbackService.nextAudio,
          iconData: Symbols.skip_next,
          size: 32,
          glowColor: scheme.primary.withValues(alpha: 0.5),
          iconColor: scheme.onSecondaryContainer,
        ),
      ],
    );
  }
}

class _GlowingIconButton extends StatefulWidget {
  final String tooltip;
  final VoidCallback onPressed;
  final IconData iconData;
  final double size;
  final Color glowColor;
  final Color iconColor;
  final bool enableGlow;

  const _GlowingIconButton({
    required this.tooltip,
    required this.onPressed,
    required this.iconData,
    required this.size,
    required this.glowColor,
    required this.iconColor,
    this.enableGlow = false,
  });

  @override
  State<_GlowingIconButton> createState() => _GlowingIconButtonState();
}

class _GlowingIconButtonState extends State<_GlowingIconButton> {
  bool _isHovering = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final showGlow = widget.enableGlow || _isHovering;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: widget.onPressed,
        child: SizedBox(
          width: widget.size + 16,
          height: widget.size + 16,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Glow Layer
              if (showGlow)
                Positioned.fill(
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(
                      sigmaX: 10,
                      sigmaY: 10,
                    ),
                    child: Center(
                      child: Icon(
                        widget.iconData,
                        size: widget.size,
                        color: widget.glowColor,
                        fill: 0.0,
                        weight: 400.0,
                      ),
                    ),
                  ),
                ),
              // Icon Layer
              AnimatedScale(
                duration: const Duration(milliseconds: 120),
                curve: const Cubic(0.4, 0, 0.2, 1),
                scale: _isPressed ? 0.9 : 1.0,
                child: Icon(
                  widget.iconData,
                  size: widget.size,
                  color: widget.iconColor,
                  fill: 0.0,
                  weight: 400.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MorphPlayPauseButton extends StatefulWidget {
  const _MorphPlayPauseButton({
    required this.playerState,
    required this.onPlay,
    required this.onPause,
    required this.onReplay,
    required this.size,
    required this.glowColor,
    required this.color,
    required this.playerStateStream,
  });
  final PlayerState playerState;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onReplay;
  final double size;
  final Color glowColor;
  final Color color;
  final Stream<PlayerState> playerStateStream;

  @override
  State<_MorphPlayPauseButton> createState() => _MorphPlayPauseButtonState();
}

class _MorphPlayPauseButtonState extends State<_MorphPlayPauseButton>
    with SingleTickerProviderStateMixin {
  bool _isHovering = false;
  bool _isPressed = false;
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 220));
  late PlayerState _state = widget.playerState;

  @override
  void initState() {
    super.initState();
    _controller.value = _state == PlayerState.playing ? 1.0 : 0.0;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        child: StreamBuilder<PlayerState>(
          stream: widget.playerStateStream,
          initialData: _state,
          builder: (context, snapshot) {
            _state = snapshot.data ?? _state;
            final isPlaying = _state == PlayerState.playing;
            _controller.animateTo(
              isPlaying ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 240),
              curve: const Cubic(0.2, 0.0, 0.0, 1.0),
            );

            late final VoidCallback onPressed;
            if (_state == PlayerState.playing) {
              onPressed = widget.onPause;
            } else if (_state == PlayerState.completed) {
              onPressed = widget.onReplay;
            } else {
              onPressed = widget.onPlay;
            }

            final showGlow = _isHovering;

            return SizedBox(
              width: widget.size + 16,
              height: widget.size + 16,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (showGlow)
                    Positioned.fill(
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: Center(
                          child: AnimatedIcon(
                            icon: AnimatedIcons.play_pause,
                            progress: _controller,
                            color: widget.glowColor,
                            size: widget.size,
                          ),
                        ),
                      ),
                    ),
                  AnimatedScale(
                    duration: const Duration(milliseconds: 120),
                    curve: const Cubic(0.4, 0, 0.2, 1),
                    scale: _isPressed ? 0.9 : 1.0,
                    child: IconButton(
                      tooltip: isPlaying ? "暂停" : "播放",
                      onPressed: onPressed,
                      icon: AnimatedIcon(
                        icon: AnimatedIcons.play_pause,
                        progress: _controller,
                        color: widget.color,
                        size: widget.size,
                      ),
                      style: ButtonStyle(
                        backgroundColor:
                            const WidgetStatePropertyAll(Colors.transparent),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HotkeyPulseIconButton extends StatefulWidget {
  const _HotkeyPulseIconButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    required this.hotkeyAction,
    this.style,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final Widget icon;
  final HotkeyUiAction hotkeyAction;
  final ButtonStyle? style;

  @override
  State<_HotkeyPulseIconButton> createState() => _HotkeyPulseIconButtonState();
}

class _HotkeyPulseIconButtonState extends State<_HotkeyPulseIconButton> {
  double _scale = 1.0;
  Timer? _timer;
  int _lastSerial = 0;
  late final VoidCallback _listener;

  void _pulse() {
    _timer?.cancel();
    setState(() => _scale = 0.92);
    _timer = Timer(MotionDuration.fast, () {
      if (mounted) setState(() => _scale = 1.0);
    });
  }

  @override
  void initState() {
    super.initState();
    _listener = () {
      final event = HOTKEY_UI_FEEDBACK.lastEvent;
      if (event == null) return;
      if (event.action != widget.hotkeyAction) return;
      if (event.serial == _lastSerial) return;
      _lastSerial = event.serial;
      _pulse();
    };
    HOTKEY_UI_FEEDBACK.addListener(_listener);
  }

  @override
  void dispose() {
    _timer?.cancel();
    HOTKEY_UI_FEEDBACK.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      duration: MotionDuration.fast,
      curve: MotionCurve.standard,
      scale: _scale,
      child: IconButton(
        tooltip: widget.tooltip,
        onPressed: widget.onPressed,
        icon: widget.icon,
        style: widget.style,
      ),
    );
  }
}

/// glow slider
class _NowPlayingSlider extends StatefulWidget {
  const _NowPlayingSlider();

  @override
  State<_NowPlayingSlider> createState() => _NowPlayingSliderState();
}

class _NowPlayingSliderState extends State<_NowPlayingSlider>
    with SingleTickerProviderStateMixin {
  final dragPosition = ValueNotifier(0.0);
  bool isDragging = false;
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playbackService = context.watch<PlaybackService>();
    final nowPlayingLength = playbackService.length;

    return SizedBox(
      height: 24, // Slider height
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Current Time (Left)
          Positioned(
            left: 24,
            top: 0,
            bottom: 0,
            child: Center(
              child: StreamBuilder(
                stream: playbackService.positionStream,
                initialData: playbackService.position,
                builder: (context, snapshot) {
                  final pos = snapshot.data ?? 0.0;
                  return Text(
                    Duration(milliseconds: (pos * 1000).toInt())
                        .toStringMSS(),
                    style: TextStyle(
                      color: scheme.onSecondaryContainer,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  );
                },
              ),
            ),
          ),
          // Total Time (Right)
          Positioned(
            right: 24,
            top: 0,
            bottom: 0,
            child: Center(
              child: Text(
                Duration(milliseconds: (nowPlayingLength * 1000).toInt())
                    .toStringMSS(),
                style: TextStyle(
                  color: scheme.onSecondaryContainer,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          // Slider
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 84.0), // Space for time text
            child: StreamBuilder(
              stream: playbackService.playerStateStream,
              initialData: playbackService.playerState,
              builder: (context, playerStateSnapshot) => ListenableBuilder(
                listenable: dragPosition,
                builder: (context, _) => StreamBuilder(
                  stream: playbackService.positionStream,
                  initialData: playbackService.position,
                  builder: (context, positionSnapshot) {
                    final position = isDragging
                        ? dragPosition.value
                        : positionSnapshot.data! > nowPlayingLength
                            ? nowPlayingLength
                            : positionSnapshot.data!;
                    final max = nowPlayingLength > 0 ? nowPlayingLength : 1.0;
                    final fraction = (position / max).clamp(0.0, 1.0);

                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: (details) {
                            isDragging = true;
                            final value = (details.localPosition.dx / width)
                                    .clamp(0.0, 1.0) *
                                max;
                            dragPosition.value = value;
                          },
                          onHorizontalDragUpdate: (details) {
                            final value = (details.localPosition.dx / width)
                                    .clamp(0.0, 1.0) *
                                max;
                            dragPosition.value = value;
                          },
                          onHorizontalDragEnd: (details) {
                            isDragging = false;
                            playbackService.seek(dragPosition.value);
                          },
                          onTapDown: (details) {
                            final value = (details.localPosition.dx / width)
                                    .clamp(0.0, 1.0) *
                                max;
                            playbackService.seek(value);
                          },
                          child: AnimatedBuilder(
                            animation: _controller,
                            builder: (context, child) {
                              return CustomPaint(
                                painter: _GlowSliderPainter(
                                  fraction: fraction,
                                  color: scheme.primary,
                                  glowColor: scheme.primaryContainer,
                                  animationValue: _controller.value,
                                  inactiveColor: scheme.surfaceContainerHighest,
                                ),
                                size: Size(width, 24),
                              );
                            },
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// _NowPlayingTimeDisplay removed

class _GlowSliderPainter extends CustomPainter {
  final double fraction;
  final Color color;
  final Color glowColor;
  final Color inactiveColor;
  final double animationValue;

  _GlowSliderPainter({
    required this.fraction,
    required this.color,
    required this.glowColor,
    required this.inactiveColor,
    required this.animationValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.fill;

    final double height = 4.0;
    final double centerY = size.height / 2;
    final double activeWidth = size.width * fraction;

    // Inactive track
    paint.color = inactiveColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, centerY - height / 2, size.width, height),
        Radius.circular(height / 2),
      ),
      paint,
    );

    // Active track (Solid color, no animation/glow on the track itself to reduce visual noise)
    final Rect activeRect =
        Rect.fromLTWH(0, centerY - height / 2, activeWidth, height);
    if (activeWidth > 0) {
      paint.color = color;
      paint.shader = null;
      canvas.drawRRect(
        RRect.fromRectAndRadius(activeRect, Radius.circular(height / 2)),
        paint,
      );
    }

    // Thumb
    paint.shader = null;
    paint.color = color;
    // Draw thumb shadow/glow (Strong glow for the current progress)
    canvas.drawCircle(
      Offset(activeWidth, centerY),
      10, // glow radius
      Paint()
        ..color = glowColor.withValues(alpha: 0.6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    // Draw thumb
    canvas.drawCircle(Offset(activeWidth, centerY), 6, paint);
  }

  @override
  bool shouldRepaint(covariant _GlowSliderPainter oldDelegate) {
    return oldDelegate.fraction != fraction ||
        oldDelegate.animationValue != animationValue;
  }
}

/// title, artist, album, cover
class _NowPlayingInfo extends StatefulWidget {
  const _NowPlayingInfo();

  @override
  State<_NowPlayingInfo> createState() => __NowPlayingInfoState();
}

class __NowPlayingInfoState extends State<_NowPlayingInfo> {
  final playbackService = PlayService.instance.playbackService;
  ImageProvider<Object>? _loResCover;
  String? _loResCoverPath;
  ImageProvider<Object>? _hiResCover;
  String? _hiResCoverPath;
  Timer? _hiResDebounceTimer;
  int _coverRequestToken = 0;

  void _onPlaybackChange() {
    _coverRequestToken += 1;
    final token = _coverRequestToken;
    final nextAudio = playbackService.nowPlaying;
    if (nextAudio == null) {
      if (_loResCoverPath != null || _hiResCoverPath != null) {
        _hiResDebounceTimer?.cancel();
        setState(() {
          _loResCover = null;
          _loResCoverPath = null;
          _hiResCover = null;
          _hiResCoverPath = null;
        });
      }
      return;
    }

    if (nextAudio.path == _loResCoverPath &&
        nextAudio.path == _hiResCoverPath) {
      return;
    }

    nextAudio.cover.then((image) async {
      if (!mounted) return;
      if (token != _coverRequestToken) return;
      // Double check if the audio is still the same
      if (playbackService.nowPlaying?.path != nextAudio.path) return;

      if (image != null) {
        if (token != _coverRequestToken) return;
        await precacheImage(image, context);
      }

      if (!mounted) return;
      if (token != _coverRequestToken) return;
      setState(() {
        _loResCover = image;
        _loResCoverPath = nextAudio.path;
      });
    });

    _hiResDebounceTimer?.cancel();
    _hiResDebounceTimer = Timer(const Duration(milliseconds: 260), () {
      nextAudio.largeCover.then((image) async {
        if (!mounted) return;
        if (token != _coverRequestToken) return;
        if (playbackService.nowPlaying?.path != nextAudio.path) return;

        if (image != null) {
          if (token != _coverRequestToken) return;
          await precacheImage(image, context);
        }

        if (!mounted) return;
        if (token != _coverRequestToken) return;
        setState(() {
          _hiResCover = image;
          _hiResCoverPath = nextAudio.path;
        });
      });
    });
  }

  @override
  void initState() {
    super.initState();
    playbackService.addListener(_onPlaybackChange);
    // Initial load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final delay = playbackService.nowPlayingChangedRecently
          ? const Duration(milliseconds: 200)
          : Duration.zero;
      if (delay == Duration.zero) {
        _onPlaybackChange();
      } else {
        _hiResDebounceTimer?.cancel();
        _hiResDebounceTimer = Timer(delay, () {
          if (!mounted) return;
          _onPlaybackChange();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final nowPlaying = playbackService.nowPlaying;
    final nowPlayingPath = nowPlaying?.path;
    final heroEnabled = !playbackService.nowPlayingChangedRecently;

    final placeholder = Image.asset(
      'app_icon.ico',
      width: 400.0,
      height: 400.0,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => Icon(
        Symbols.broken_image,
        size: 400.0,
        color: scheme.onSecondaryContainer,
      ),
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520.0),
      child: LayoutBuilder(builder: (context, constraints) {
        const infoPaddingTop = 0.0;
        const infoSpacing = 14.0;
        const textBlockHeight = 86.0;

        final maxWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : (520.0 + textBlockHeight + infoPaddingTop + infoSpacing);

        final coverMax =
            (maxHeight - infoPaddingTop - infoSpacing - textBlockHeight)
                .clamp(160.0, 420.0)
                .toDouble();
        final coverWidthLimit = maxWidth.clamp(160.0, 520.0).toDouble();
        final coverSize =
            coverWidthLimit < coverMax ? coverWidthLimit : coverMax;

        final currentCover =
            (_hiResCoverPath == nowPlayingPath && _hiResCover != null)
                ? _hiResCover
                : (_loResCoverPath == nowPlayingPath ? _loResCover : null);
        final coverWidget = currentCover == null
            ? Center(child: placeholder)
            : Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12.0),
                  boxShadow: [
                    // 1. 环境光晕 (Ambient Glow)
                    BoxShadow(
                      color: scheme.primary.withOpacity(0.25),
                      spreadRadius: -4,
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                    // 2. 轮廓描边 (Outline)
                    BoxShadow(
                      color: scheme.primary.withOpacity(0.15),
                      spreadRadius: 1,
                      blurRadius: 0,
                      offset: Offset.zero,
                    ),
                    // 3. 深邃阴影 (Depth Shadow)
                    BoxShadow(
                      color: Colors.black.withOpacity(0.20),
                      spreadRadius: 0,
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12.0),
                  child: Image(
                    image: currentCover!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (_, __, ___) => FittedBox(
                      fit: BoxFit.contain,
                      child: placeholder,
                    ),
                  ),
                ),
              );

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          switchInCurve: Curves.easeOutQuart,
          switchOutCurve: Curves.easeInQuart,
          transitionBuilder: (child, animation) {
            final offsetAnimation = Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(animation);

            final scaleAnimation = Tween<double>(
              begin: 0.92,
              end: 1.0,
            ).animate(animation);

            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: offsetAnimation,
                child: ScaleTransition(
                  scale: scaleAnimation,
                  child: child,
                ),
              ),
            );
          },
          child: Container(
            key: ValueKey(nowPlayingPath ?? 'now_playing_none'),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: coverSize,
                  height: coverSize,
                  child: heroEnabled && nowPlayingPath != null
                      ? Hero(
                          tag: nowPlayingPath,
                          createRectTween: (begin, end) => MaterialRectArcTween(
                            begin: begin,
                            end: end,
                          ),
                          flightShuttleBuilder: (flightContext, animation,
                              direction, fromHeroContext, toHeroContext) {
                            final fromHero = fromHeroContext.widget as Hero;
                            return fromHero.child;
                          },
                          child: RepaintBoundary(child: coverWidget),
                        )
                      : RepaintBoundary(child: coverWidget),
                ),
                const SizedBox(height: 24.0),
                Text(
                  nowPlaying == null ? "Coriander Music" : nowPlaying.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 24,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  nowPlaying == null ? "Enjoy Music" : nowPlaying.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 16,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  @override
  void dispose() {
    playbackService.removeListener(_onPlaybackChange);
    _hiResDebounceTimer?.cancel();
    super.dispose();
  }
}
