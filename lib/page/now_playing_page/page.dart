// ignore_for_file: camel_case_types

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:pure_music/core/advanced_color_extraction.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/component/hotkey_ui_feedback.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/side_nav.dart';
import 'package:pure_music/component/title_bar.dart';
import 'package:pure_music/core/color_extraction.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:pure_music/core/system_volume_service.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/page/now_playing_page/component/current_playlist_view.dart';
import 'package:pure_music/page/now_playing_page/component/equalizer_dialog.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_source_view.dart';
import 'package:pure_music/page/now_playing_page/component/pitch_control.dart';
import 'package:pure_music/page/now_playing_page/component/vertical_lyric_view.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_service.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

part 'small_page.dart';
part 'large_page.dart';
part 'immersive_page.dart';

final nowPlayingViewMode = ValueNotifier(
  AppPreference.instance.nowPlayingPagePref.nowPlayingViewMode,
);

class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key});

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  final playbackService = PlayService.instance.playbackService;
  ImageProvider<Object>? nowPlayingCover;
  Uint8List? _nowPlayingCoverBytes;
  String? _nowPlayingCoverPath;
  Timer? _coverDebounceTimer;
  Timer? _cursorHideTimer;
  bool _cursorHidden = false;
  bool _lastImmersive = false;
  Color? _dominantColor;
  MonetColorScheme? _monetScheme;
  final ColorExtractionService _colorService = ColorExtractionService();
  final AdvancedColorExtractionService _advancedColorService =
      AdvancedColorExtractionService();

  static Color _softenColor(Color color, {required bool isDark}) {
    final hsl = HSLColor.fromColor(color);
    if (isDark) {
      // Keep saturation intact, only darken slightly for readability
      final softLightness = (hsl.lightness * 0.55).clamp(0.10, 0.40);
      return hsl.withLightness(softLightness).toColor();
    } else {
      // Keep saturation intact, only lighten slightly for readability
      final softLightness = (hsl.lightness * 0.50 + 0.38).clamp(0.50, 0.80);
      return hsl.withLightness(softLightness).toColor();
    }
  }

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
          _nowPlayingCoverBytes = null;
          _dominantColor = null;
          _monetScheme = null;
        });
      }
      return;
    }

    if (path == _nowPlayingCoverPath) return;
    _nowPlayingCoverPath = path;

    _coverDebounceTimer?.cancel();
    _coverDebounceTimer = Timer(MotionDuration.base, () async {
      final audio = playbackService.nowPlaying;
      if (audio == null || audio.path != path) return;

      final cover = await audio.cover;
      if (!mounted) return;
      if (playbackService.nowPlaying?.path != path) return;

      if (cover != null) {
        precacheImage(cover, context);
        final bytes = await getPictureFromPath(
          path: path,
          width: 160,
          height: 160,
        );
        if (!mounted) return;
        if (playbackService.nowPlaying?.path != path) return;
        if (bytes != null && mounted) {
          final results = await Future.wait<Object?>([
            _colorService.extractDominantColor(bytes),
            _advancedColorService.extractMonetScheme(bytes),
          ]);
          if (!mounted) return;
          if (playbackService.nowPlaying?.path != path) return;
          final monetScheme = results[1] as MonetColorScheme?;
          final color =
              (results[0] as Color?) ?? monetScheme?.primary;
          setState(() {
            _nowPlayingCoverBytes = bytes;
            _dominantColor = monetScheme?.primary ?? color;
            _monetScheme = monetScheme;
          });
        } else if (mounted) {
          setState(() {
            _nowPlayingCoverBytes = null;
            _dominantColor = null;
            _monetScheme = null;
          });
        }
      } else {
        setState(() {
          _nowPlayingCoverBytes = null;
          _dominantColor = null;
          _monetScheme = null;
        });
      }

      if (nowPlayingCover == cover) return;
      setState(() {
        nowPlayingCover = cover;
      });
    });
  }

  @override
  void initState() {
    super.initState();
    playbackService.nowPlayingNotifier.addListener(updateCover);
    playbackService.playerStateNotifier.addListener(_updatePlayPauseState);
    updateCover();
    _bumpCursor();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      PlayService.instance.lyricService
          .findCurrLyricLineAt(playbackService.position);
    });
  }

  void _updatePlayPauseState() {
    // Trigger rebuild when play/pause state changes
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    playbackService.nowPlayingNotifier.removeListener(updateCover);
    playbackService.playerStateNotifier.removeListener(_updatePlayPauseState);
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
                          ValueListenableBuilder<NowPlayingBackgroundMode>(
                            valueListenable: nowPlayingBackgroundModeNotifier,
                            builder: (context, backgroundMode, _) {
                              return StreamBuilder<PlayerState>(
                                stream: playbackService.playerStateStream,
                                initialData: playbackService.playerState,
                                builder: (context, snapshot) {
                                  final playerState =
                                      snapshot.data ?? playbackService.playerState;
                                  final backgroundInputs =
                                      NowPlayingBackgroundInputs(
                                    albumCoverBytes: _nowPlayingCoverBytes,
                                    dominantColor: _dominantColor,
                                    monetScheme: _monetScheme,
                                    spectrumStream: playbackService.spectrumStream,
                                    enableAnimation: true,
                                    isVisible:
                                        ModalRoute.of(context)?.isCurrent ?? true,
                                    playerState: playerState,
                                    flowSpeed: 1.0,
                                    intensity:
                                        brightness == Brightness.dark ? 1.0 : 0.9,
                                  );
                                  final softBg = _dominantColor != null
                                      ? _softenColor(_dominantColor!, isDark: brightness == Brightness.dark)
                                      : _softenColor(scheme.primary, isDark: brightness == Brightness.dark);
                                  return NowPlayingBackground(
                                    mode: backgroundMode,
                                    inputs: backgroundInputs,
                                    fallbackColor: softBg,
                                  );
                                },
                              );
                            },
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
                            ? const _NowPlayingImmersivePage()
                            : ResponsiveBuilder2(
                                builder: (context, screenType) {
                                  switch (screenType) {
                                    case ScreenType.small:
                                      return const _NowPlayingSmallPage();
                                    case ScreenType.medium:
                                    case ScreenType.large:
                                      return const _NowPlayingLargePage();
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
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 150),
                              opacity: _cursorHidden ? 0.0 : 1.0,
                              child: IgnorePointer(
                                ignoring: _cursorHidden,
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
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder(
      valueListenable: PlayService.instance.playbackService.wasapiExclusive,
      builder: (context, exclusive, _) => IconButton(
        tooltip: exclusive ? "关闭独占" : "打开独占",
        onPressed: () {
          PlayService.instance.playbackService.useExclusiveMode(!exclusive);
        },
        icon: Center(
          child: Text(
            exclusive ? "Excl" : "Shrd",
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ),
        color: scheme.onSurface,
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
        color: scheme.onSurface,
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
          color: scheme.onSurface,
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
            tooltip: snapshot.data != null ? "关闭桌面歌词" : "打开桌面歌词",
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
            color: scheme.onSurface,
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
  final systemVolumeService = SystemVolumeService.instance;
  final dragVolDsp = ValueNotifier(
    AppPreference.instance.playbackPref.volumeDsp,
  );
  final dragSystemVol = ValueNotifier(0.0);

  bool isDragging = false;
  bool isSystemDragging = false;
  bool _isMenuOpen = false;
  double _lastVolumeDsp = -1;
  Timer? _systemVolBoostTimer;
  late final VoidCallback _systemVolValueListener;
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
    return await systemVolumeService.read(timeout: timeout);
  }

  @override
  void initState() {
    super.initState();
    _hotkeyListener = () {
      if (!mounted) return;
      final event = hotkeyUiFeedback.lastEvent;
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
    hotkeyUiFeedback.addListener(_hotkeyListener);
    _lastVolumeDsp = playbackService.volumeDsp;
    playbackService.nowPlayingNotifier.addListener(() {
      if (!mounted) return;
      final v = playbackService.volumeDsp;
      if ((v - _lastVolumeDsp).abs() <= 0.0001) return;
      _lastVolumeDsp = v;
      if (_isMenuOpen && !isDragging) {
        _triggerIndicator();
      }
    });
    systemVolumeService.ensureBound();
    dragSystemVol.value = systemVolumeService.volume.value;
    _systemVolValueListener = () {
      if (!mounted || isSystemDragging) return;
      dragSystemVol.value = systemVolumeService.volume.value;
    };
    systemVolumeService.volume.addListener(_systemVolValueListener);
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
    _systemVolBoostTimer?.cancel();
    _indicatorTimer?.cancel();
    _systemIndicatorTimer?.cancel();
    _autoCloseTimer?.cancel();
    systemVolumeService.volume.removeListener(_systemVolValueListener);
    hotkeyUiFeedback.removeListener(_hotkeyListener);
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
                                    systemVolumeService.set(value);
                                    _triggerSystemIndicator();
                                  },
                                  onChanged: (value) {
                                    dragSystemVol.value = value;
                                    systemVolumeService.set(value);
                                    if (isSystemDragging) {
                                      _triggerSystemIndicator();
                                    }
                                  },
                                  onChangeEnd: (value) {
                                    isSystemDragging = false;
                                    dragSystemVol.value = value;
                                    systemVolumeService.set(value);
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
          color: scheme.onSurface,
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
          color: scheme.onSurface,
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
        IconButton(
          tooltip: "上一曲",
          onPressed: playbackService.lastAudio,
          icon: const Icon(
            Symbols.skip_previous,
            fill: 1.0,
          ),
          color: scheme.onSurface,
        ),
        const SizedBox(width: 32),
        StreamBuilder(
          stream: playbackService.playerStateStream,
          initialData: playbackService.playerState,
          builder: (context, snapshot) {
            final playerState = snapshot.data!;
            final isPlaying = playerState == PlayerState.playing;
            final isCompleted = playerState == PlayerState.completed;
            
            return IconButton(
              tooltip: isPlaying ? "暂停" : "播放",
              onPressed: () {
                if (isPlaying) {
                  playbackService.pause();
                } else if (isCompleted) {
                  playbackService.playAgain();
                } else {
                  playbackService.start();
                }
              },
              icon: Icon(
                isPlaying ? Symbols.pause : Symbols.play_arrow,
                fill: 1.0,
              ),
              color: scheme.onSurface,
            );
          },
        ),
        const SizedBox(width: 32),
        IconButton(
          tooltip: "下一曲",
          onPressed: playbackService.nextAudio,
          icon: const Icon(
            Symbols.skip_next,
            fill: 1.0,
          ),
          color: scheme.onSurface,
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

  const _GlowingIconButton({
    required this.tooltip,
    required this.onPressed,
    required this.iconData,
    required this.size,
    required this.glowColor,
    required this.iconColor,
  });

  @override
  State<_GlowingIconButton> createState() => _GlowingIconButtonState();
}

class _GlowingIconButtonState extends State<_GlowingIconButton> {
  bool _isHovering = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final showGlow = _isHovering;
    final scheme = Theme.of(context).colorScheme;
    final isHoverOrPressed = _isHovering || _isPressed;
    final hoverBgAlpha = _isPressed ? 0.04 : 0.02;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
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
                // Hover Background
                AnimatedOpacity(
                  duration: MotionDuration.fast,
                  curve: MotionCurve.standard,
                  opacity: isHoverOrPressed ? 1.0 : 0.0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.onSecondaryContainer.withValues(
                        alpha: hoverBgAlpha,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
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
    final scheme = Theme.of(context).colorScheme;
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
            final isHoverOrPressed = _isHovering || _isPressed;
            final hoverBgAlpha = _isPressed ? 0.04 : 0.02;

            return SizedBox(
              width: widget.size + 16,
              height: widget.size + 16,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Hover Background
                  AnimatedOpacity(
                    duration: MotionDuration.fast,
                    curve: MotionCurve.standard,
                    opacity: isHoverOrPressed ? 1.0 : 0.0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: scheme.onSecondaryContainer.withValues(
                          alpha: hoverBgAlpha,
                        ),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
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
                        overlayColor:
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
  });

  final String tooltip;
  final VoidCallback onPressed;
  final Widget icon;
  final HotkeyUiAction hotkeyAction;

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
      final event = hotkeyUiFeedback.lastEvent;
      if (event == null) return;
      if (event.action != widget.hotkeyAction) return;
      if (event.serial == _lastSerial) return;
      _lastSerial = event.serial;
      _pulse();
    };
    hotkeyUiFeedback.addListener(_listener);
  }

  @override
  void dispose() {
    _timer?.cancel();
    hotkeyUiFeedback.removeListener(_listener);
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

class _NowPlayingSliderState extends State<_NowPlayingSlider> {
  final dragPosition = ValueNotifier(0.0);
  bool isDragging = false;

  @override
  void dispose() {
    dragPosition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playbackService = context.read<PlaybackService>();
    final nowPlayingLength = playbackService.length;
    final nowPlayingPath = playbackService.nowPlaying?.path;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Time labels on top
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _PlaybackPositionText(
                positionStream: playbackService.positionStream,
                initialPosition: playbackService.position,
                trackKey: nowPlayingPath,
                color: scheme.onSurface,
              ),
              Text(
                Duration(milliseconds: (nowPlayingLength * 1000).toInt())
                    .toStringMSS(),
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        // Slider (align with controls below)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: SizedBox(
            height: 24,
            child: ListenableBuilder(
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
                      child: CustomPaint(
                        painter: _GlowSliderPainter(
                          fraction: fraction,
                          color: scheme.primary,
                          glowColor: scheme.primaryContainer,
                          inactiveColor: scheme.brightness == Brightness.dark
                              ? scheme.surfaceContainerHighest
                              : const Color(0x33FFFFFF),
                        ),
                        size: Size(width, 24),
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
    );
  }
}

class _PlaybackPositionText extends StatefulWidget {
  const _PlaybackPositionText({
    required this.positionStream,
    required this.initialPosition,
    required this.trackKey,
    required this.color,
  });

  final Stream<double> positionStream;
  final double initialPosition;
  final String? trackKey;
  final Color color;

  @override
  State<_PlaybackPositionText> createState() => _PlaybackPositionTextState();
}

class _PlaybackPositionTextState extends State<_PlaybackPositionText> {
  StreamSubscription<double>? _subscription;
  late int _displaySeconds;

  @override
  void initState() {
    super.initState();
    _displaySeconds = widget.initialPosition.floor();
    _bindStream();
  }

  @override
  void didUpdateWidget(covariant _PlaybackPositionText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.positionStream != widget.positionStream) {
      _bindStream();
    }
    if (oldWidget.trackKey != widget.trackKey) {
      _displaySeconds = widget.initialPosition.floor();
    }
  }

  void _bindStream() {
    _subscription?.cancel();
    _subscription = widget.positionStream.listen((position) {
      final nextSeconds = position.floor();
      if (nextSeconds == _displaySeconds || !mounted) return;
      setState(() {
        _displaySeconds = nextSeconds;
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      Duration(seconds: _displaySeconds).toStringMSS(),
      style: TextStyle(
        color: widget.color,
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _GlowSliderPainter extends CustomPainter {
  final double fraction;
  final Color color;
  final Color glowColor;
  final Color inactiveColor;

  _GlowSliderPainter({
    required this.fraction,
    required this.color,
    required this.glowColor,
    required this.inactiveColor,
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
        oldDelegate.color != color ||
        oldDelegate.glowColor != glowColor ||
        oldDelegate.inactiveColor != inactiveColor;
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
    playbackService.nowPlayingNotifier.addListener(_onPlaybackChange);
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
        color: scheme.onSurface,
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
                  borderRadius: BorderRadius.circular(20.0),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: 0.2),
                      spreadRadius: 0,
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20.0),
                  child: Image(
                    image: currentCover,
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
                  nowPlaying == null ? "Pure Music" : nowPlaying.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
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
                    color: scheme.onSurface.withValues(alpha: 0.7),
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
