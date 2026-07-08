// ignore_for_file: camel_case_types

import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/component/hotkey_ui_feedback.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/side_nav.dart';
import 'package:pure_music/component/title_bar.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/color_extraction.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/memory_monitor.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:flutter/foundation.dart';
import 'package:pure_music/core/settings.dart';
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
import 'package:pure_music/native/rust/api/color_extraction.dart' as rust_color;
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
  Timer? _songChangeTrimTimer;
  Timer? _cursorHideTimer;
  int _coverRequestToken = 0;
  bool _cursorHidden = false;
  bool _lastImmersive = false;
  Color? _dominantColor;
  List<Color>? _preExtractedPalette;
  final ColorExtractionService _colorService = ColorExtractionService();

  /// 用于防重复：同一次切歌内只提取一次调色板
  int _lastPaletteToken = -1;

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

  /// Guard against race conditions in async cover loading.
  /// Returns true if the request is stale and should be aborted.
  bool _isCoverRequestStale(int token, String expectedPath) {
    return token != _coverRequestToken ||
        playbackService.nowPlaying?.path != expectedPath ||
        !mounted;
  }

  /// 用Rust k-means 一次性提取调色板和主色。
  /// 结果同时用于背景 mesh gradient 和主题种子色。
  Future<void> _extractPaletteOnce(
      Uint8List bytes, int token, String path) async {
    if (_lastPaletteToken == token) return; // 已提取过
    _lastPaletteToken = token;

    try {
      final rustColors = await rust_color.extractColorsFromImage(
        imageBytes: bytes,
        numColors: 4,
      );
      if (_isCoverRequestStale(token, path)) return;
      if (rustColors.isEmpty) {
        _lastPaletteToken = -1;
        return;
      }

      final palette = rustColors.map((argb) => Color(argb)).toList();
      final dominant = palette.first;

      // 缓存调色板（供后续同步读取）
      _colorService.cachePaletteForPath(path, palette);

      setState(() {
        _dominantColor = dominant;
        _preExtractedPalette = palette;
      });

      // 同步更新主题种子色，仅在封面取色开启时生效。
      if (AppSettings.instance.enableCoverColorExtraction) {
        ThemeProvider.instance.applySeedColorDirectly(dominant, path);
      }
    } catch (_) {
      if (!_isCoverRequestStale(token, path)) {
        _lastPaletteToken = -1;
      }
      // Rust 提取失败时静默忽略。
    }
  }

  void updateCover() {
    final path = playbackService.nowPlaying?.path;
    if (path == null) {
      if (_nowPlayingCoverPath != null || nowPlayingCover != null) {
        _coverDebounceTimer?.cancel();
        _songChangeTrimTimer?.cancel();
        _coverRequestToken++;
        PaintingBinding.instance.imageCache.clear();
        setState(() {
          _nowPlayingCoverPath = null;
          nowPlayingCover = null;
          _nowPlayingCoverBytes = null;
          _dominantColor = null;
          _preExtractedPalette = null;
        });
      }
      return;
    }

    if (path == _nowPlayingCoverPath) return;
    _nowPlayingCoverPath = path;
    // 不清空 nowPlayingCover / _nowPlayingCoverBytes，保留旧值作背景，等新数据到位后自然替换
    _dominantColor = null;
    _preExtractedPalette = null;

    _coverDebounceTimer?.cancel();
    _songChangeTrimTimer?.cancel();
    _coverRequestToken++;
    final token = _coverRequestToken;
    _lastPaletteToken = -1; // 新歌重置 token

    // 首帧即用：从同步缓存读主色，用小封面当背景，零等待零跳变
    final aud = playbackService.nowPlaying;
    if (aud != null) {
      final cachedPalette = _colorService.getCachedPaletteForPath(path);
      if (cachedPalette != null && cachedPalette.isNotEmpty) {
        _dominantColor = cachedPalette.first;
        _preExtractedPalette = cachedPalette;
        _lastPaletteToken = token;
      } else {
        final cached = _colorService.getCachedColorForPath(path);
        if (cached != null) {
          _dominantColor = cached;
        }
        final smallBytes = aud.smallCoverBytes;
        if (smallBytes != null) {
          unawaited(_extractPaletteOnce(smallBytes, token, path));
        }
      }
      // 切歌时先用小封面做背景，再等取色结果驱动过渡。
      final smallBytes = aud.smallCoverBytes;
      if (smallBytes != null) {
        _nowPlayingCoverBytes = smallBytes;
      }
    }
    if (mounted) setState(() {});

    _songChangeTrimTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || playbackService.nowPlaying?.path != path) return;
      MemoryMonitorService.instance.trimAfterSongChange();
    });

    _coverDebounceTimer = Timer(MotionDuration.base, () async {
      final audio = playbackService.nowPlaying;
      if (audio == null || _isCoverRequestStale(token, path)) return;

      final cover = await audio.cover;
      if (_isCoverRequestStale(token, path)) return;

      if (cover != null) {
        final bytes = await getPictureFromPath(
          path: path,
          width: 160,
          height: 160,
        );
        if (_isCoverRequestStale(token, path)) return;

        if (bytes != null) {
          // 同一首歌只取色一次；没有小封面结果时再用 160px 封面补上。
          await _extractPaletteOnce(bytes, token, path);
          _nowPlayingCoverBytes = bytes;
          if (mounted) setState(() {});
        } else {
          setState(() {
            _nowPlayingCoverBytes = null;
            _dominantColor = null;
            _preExtractedPalette = null;
          });
        }
      } else {
        setState(() {
          _nowPlayingCoverBytes = null;
          _dominantColor = null;
          _preExtractedPalette = null;
        });
      }

      if (nowPlayingCover == cover) return;
      setState(() {
        nowPlayingCover = cover;
      });
    });
  }

  void _onViewModeChanged() {
    if (!mounted) return;
    if (nowPlayingViewMode.value == NowPlayingViewMode.withPlaylist) {
      // 进入播放列表：取消光标隐藏计时器，标题栏用ValueListenableBuilder 负责隐藏。
      _cursorHideTimer?.cancel();
    } else {
      // 退出播放列表：恢复标题栏和光标。
      _bumpCursor();
    }
  }

  @override
  void initState() {
    super.initState();
    playbackService.nowPlayingNotifier.addListener(updateCover);
    playbackService.playerStateNotifier.addListener(_updatePlayPauseState);
    nowPlayingViewMode.addListener(_onViewModeChanged);
    updateCover();
    _bumpCursor();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      PlayService.instance.lyricService.forceEmitCurrentLine();
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
    nowPlayingViewMode.removeListener(_onViewModeChanged);
    _coverDebounceTimer?.cancel();
    _songChangeTrimTimer?.cancel();
    _cursorHideTimer?.cancel();
    final cover = nowPlayingCover;
    nowPlayingCover = null;
    _nowPlayingCoverBytes = null;
    _preExtractedPalette = null;
    if (cover != null) unawaited(cover.evict());
    // 离开播放页时释放大图封面缓存，列表页不需要这些缓存。
    CoverImageCache.instance.trimMemory();
    super.dispose();
  }

  static Color _softenColor(Color color, {required bool isDark}) {
    final hsl = HSLColor.fromColor(color);
    if (isDark) {
      final softLightness = (hsl.lightness * 0.55).clamp(0.10, 0.40);
      return hsl.withLightness(softLightness).toColor();
    } else {
      final softLightness = (hsl.lightness * 0.50 + 0.38).clamp(0.50, 0.80);
      return hsl.withLightness(softLightness).toColor();
    }
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
        return Scaffold(
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
                              final route = ModalRoute.of(context);
                              final isVisible = route == null ||
                                  route.isCurrent ||
                                  route.animation?.status ==
                                      AnimationStatus.reverse;
                              final backgroundInputs =
                                  NowPlayingBackgroundInputs(
                                albumCoverBytes: _nowPlayingCoverBytes,
                                dominantColor: _dominantColor,
                                spectrumStream: playbackService.spectrumStream,
                                enableAnimation: true,
                                isVisible: isVisible,
                                playerState: playerState,
                                flowSpeed: 1.0,
                                intensity:
                                    brightness == Brightness.dark ? 1.0 : 0.9,
                                preExtractedColors: _preExtractedPalette,
                              );
                              final softBg = _dominantColor != null
                                  ? _softenColor(_dominantColor!,
                                      isDark: brightness == Brightness.dark)
                                  : _softenColor(scheme.primary,
                                      isDark: brightness == Brightness.dark);
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
                ListenableBuilder(
                  listenable: AppSettings.rebuildNotifier,
                  builder: (context, _) {
                    final useMonet =
                        AppSettings.instance.useMaterialYouForControls;
                    return IconButtonTheme(
                      data: IconButtonThemeData(
                        style: ButtonStyle(
                          foregroundColor: useMonet
                              ? WidgetStatePropertyAll(scheme.primary)
                              : null,
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
                    );
                  },
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
                        padding: const EdgeInsets.symmetric(horizontal: 12.0),
                        child: ValueListenableBuilder(
                          valueListenable: nowPlayingViewMode,
                          builder: (context, viewMode, _) {
                            final inPlaylist =
                                viewMode == NowPlayingViewMode.withPlaylist;
                            final shouldHide = _cursorHidden || inPlaylist;
                            return AnimatedOpacity(
                              duration: const Duration(milliseconds: 150),
                              opacity: shouldHide ? 0.0 : 1.0,
                              child: IgnorePointer(
                                ignoring: shouldHide,
                                child: Row(
                                  children: [
                                    ResponsiveBuilder2(
                                      builder: (context, screenType) {
                                        if (screenType != ScreenType.small) {
                                          return const SizedBox.shrink();
                                        }
                                        return Builder(
                                          builder: (context) => IconButton(
                                            tooltip: '侧边栏',
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
                            );
                          },
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
        );
      },
    );
  }
}

class _NowPlayingMoreAction extends StatefulWidget {
  const _NowPlayingMoreAction();

  @override
  State<_NowPlayingMoreAction> createState() => _NowPlayingMoreActionState();
}

class _NowPlayingMoreActionState extends State<_NowPlayingMoreAction> {
  Audio? _addingAudioToPlaylist;
  Playlist? _addingTargetPlaylist;

  Future<void> _addNowPlayingToPlaylist(
    Audio audio,
    Playlist playlist,
  ) async {
    if (_addingAudioToPlaylist != null) {
      return;
    }

    if (playlist.containsPath(audio.path)) {
      showTextOnSnackBar('歌曲“${audio.title}”已存在');
      return;
    }

    setState(() {
      _addingAudioToPlaylist = audio;
      _addingTargetPlaylist = playlist;
    });
    try {
      playlist.addPath(audio.path);
      final saved = await savePlaylists();
      if (!mounted) return;
      if (!saved) {
        playlist.removeByPath(audio.path);
        showTextOnSnackBar('保存歌单失败');
        return;
      }
      showTextOnSnackBar(
        '成功将“${audio.title}”添加到歌单“${playlist.name}”',
      );
    } finally {
      _addingAudioToPlaylist = null;
      _addingTargetPlaylist = null;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final playbackService = context.watch<PlaybackService>();
    final nowPlaying = playbackService.nowPlaying;
    final scheme = Theme.of(context).colorScheme;
    final menuStyle = appMenuStyle;
    final menuItemStyle = appMenuItemStyle;

    if (nowPlaying == null) {
      return IconButton(
        tooltip: '更多',
        onPressed: null,
        icon: const Icon(Symbols.more_vert),
        color: useMonet ? scheme.primary : scheme.onSurface,
      );
    }

    return MenuTheme(
      data: MenuThemeData(style: menuStyle),
      child: MenuAnchor(
        style: menuStyle,
        menuChildren: [
          ...List.generate(
            nowPlaying.splitedArtists.length,
            (i) {
              final artistName = nowPlaying.splitedArtists[i];
              final artist = AudioLibrary.instance.artistCollection[artistName];
              return MenuItemButton(
                style: menuItemStyle,
                onPressed: artist == null
                    ? null
                    : () {
                        context.pushReplacement(
                          app_paths.ARTIST_DETAIL_PAGE,
                          extra: artist,
                        );
                      },
                leadingIcon: const Icon(Symbols.people),
                child: Text(artistName),
              );
            },
          ),
          MenuItemButton(
            style: menuItemStyle,
            onPressed:
                AudioLibrary.instance.albumCollection[nowPlaying.album] == null
                    ? null
                    : () {
                        final album = AudioLibrary
                            .instance.albumCollection[nowPlaying.album]!;
                        context.pushReplacement(
                          app_paths.ALBUM_DETAIL_PAGE,
                          extra: album,
                        );
                      },
            leadingIcon: const Icon(Symbols.album),
            child: Text(nowPlaying.album),
          ),
          if (playlists.isEmpty)
            MenuItemButton(
              style: menuItemStyle,
              onPressed: null,
              leadingIcon: const Icon(Symbols.queue_music),
              child: const Text('添加到歌单'),
            )
          else
            Builder(
              builder: (_) {
                final playlistMemberships = playlists
                    .map((playlist) => playlist.containsPath(nowPlaying.path))
                    .toList(growable: false);
                final isAddingNowPlaying = identical(
                  _addingAudioToPlaylist,
                  nowPlaying,
                );
                final canOpenAddMenu = canOpenSingleAudioAddToPlaylistMenu(
                  hasAudio: true,
                  isBusy: _addingAudioToPlaylist != null,
                  alreadyInPlaylists: playlistMemberships,
                );
                if (!canOpenAddMenu) {
                  return MenuItemButton(
                    style: menuItemStyle,
                    onPressed: null,
                    leadingIcon: isAddingNowPlaying
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            playlistMemberships.every(
                              (alreadyIn) => alreadyIn,
                            )
                                ? Symbols.check
                                : Symbols.queue_music,
                          ),
                    child: Text(isAddingNowPlaying ? '添加中' : '添加到歌单'),
                  );
                }
                return SubmenuButton(
                  style: menuItemStyle,
                  menuChildren: List.generate(playlists.length, (i) {
                    final playlist = playlists[i];
                    final isAddingTarget =
                        identical(_addingAudioToPlaylist, nowPlaying) &&
                            identical(_addingTargetPlaylist, playlist);
                    final alreadyInPlaylist = playlistMemberships[i];
                    return MenuItemButton(
                      style: menuItemStyle,
                      onPressed:
                          _addingAudioToPlaylist == null && !alreadyInPlaylist
                              ? () => _addNowPlayingToPlaylist(
                                    nowPlaying,
                                    playlist,
                                  )
                              : null,
                      leadingIcon: isAddingTarget
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              alreadyInPlaylist
                                  ? Symbols.check
                                  : Symbols.queue_music,
                            ),
                      child: Text(playlist.name),
                    );
                  }),
                  child: Text(isAddingNowPlaying ? '添加中' : '添加到歌单'),
                );
              },
            ),
          MenuItemButton(
            style: menuItemStyle,
            onPressed: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                showDialog<void>(
                  context: context,
                  builder: (context) => SetLyricSourceDialog(audio: nowPlaying),
                );
              });
            },
            leadingIcon: const Icon(Symbols.lyrics),
            child: const Text('歌词来源'),
          ),
          MenuItemButton(
            style: menuItemStyle,
            onPressed: () {
              context.pushReplacement(
                app_paths.AUDIO_DETAIL_PAGE,
                extra: nowPlaying,
              );
            },
            leadingIcon: const Icon(Symbols.info),
            child: const Text('详细信息'),
          ),
        ],
        builder: (context, controller, _) => IconButton(
          tooltip: '更多',
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          icon: const Icon(Symbols.more_vert),
          color: useMonet ? scheme.primary : scheme.onSurface,
        ),
      ),
    );
  }
}

class _NowPlayingPlaybackModeSwitch extends StatefulWidget {
  const _NowPlayingPlaybackModeSwitch();

  @override
  State<_NowPlayingPlaybackModeSwitch> createState() =>
      _NowPlayingPlaybackModeSwitchState();
}

class _NowPlayingPlaybackModeSwitchState
    extends State<_NowPlayingPlaybackModeSwitch> {
  bool _isSaving = false;

  Future<void> _changeMode({
    required bool shuffle,
    required PlayMode playMode,
  }) async {
    if (_isSaving) return;

    setState(() => _isSaving = true);
    try {
      final playbackService = PlayService.instance.playbackService;
      if (!shuffle && playMode != PlayMode.singleLoop) {
        playbackService.useShuffle(false);
        playbackService.setPlayMode(PlayMode.singleLoop);
      } else if (!shuffle && playMode == PlayMode.singleLoop) {
        playbackService.setPlayMode(PlayMode.forward);
        playbackService.useShuffle(true);
      } else {
        playbackService.useShuffle(false);
        playbackService.setPlayMode(PlayMode.forward);
      }
      await AppPreference.instance.savePlaybackOnly();
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final scheme = Theme.of(context).colorScheme;
    final color = useMonet ? scheme.primary : scheme.onSurface;
    final disabledColor = color.withValues(alpha: 0.38);
    final playbackService = PlayService.instance.playbackService;

    return ListenableBuilder(
      listenable:
          Listenable.merge([playbackService.shuffle, playbackService.playMode]),
      builder: (context, _) {
        final shuffle = playbackService.shuffle.value;
        final playMode = playbackService.playMode.value;

        final modeText = switch (true) {
          _ when shuffle => '随机播放',
          _ when playMode == PlayMode.singleLoop => '单曲循环',
          _ => '顺序播放',
        };

        final icon = switch (true) {
          _ when shuffle => Symbols.shuffle,
          _ when playMode == PlayMode.singleLoop => Symbols.repeat_one,
          _ => Symbols.repeat,
        };

        return IconButton(
          tooltip: _isSaving ? '保存中' : modeText,
          onPressed: _isSaving
              ? null
              : () => _changeMode(shuffle: shuffle, playMode: playMode),
          icon: _isSaving
              ? SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              : Icon(icon, fill: 0.0, weight: 400.0),
          color: color,
          disabledColor: disabledColor,
        );
      },
    );
  }
}

class _ExclusiveModeSwitch extends StatelessWidget {
  const _ExclusiveModeSwitch();

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final scheme = Theme.of(context).colorScheme;
    //
    return ValueListenableBuilder(
      valueListenable: PlayService.instance.playbackService.wasapiExclusive,
      builder: (context, exclusive, _) {
        final foregroundColor = exclusive
            ? scheme.onPrimaryContainer
            : (useMonet ? scheme.primary : scheme.onSurface);

        return IconButton(
          tooltip: exclusive ? '关闭独占' : '打开独占',
          style: IconButton.styleFrom(
            backgroundColor: exclusive ? scheme.primaryContainer : null,
          ),
          onPressed: () {
            PlayService.instance.playbackService.useExclusiveMode(!exclusive);
          },
          icon: Center(
            child: Text(
              exclusive ? 'Excl' : 'Shrd',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: foregroundColor,
              ),
            ),
          ),
          color: foregroundColor,
        );
      },
    );
  }
}

class _DesktopLyricSwitch extends StatefulWidget {
  const _DesktopLyricSwitch();

  @override
  State<_DesktopLyricSwitch> createState() => _DesktopLyricSwitchState();
}

class _DesktopLyricSwitchState extends State<_DesktopLyricSwitch> {
  bool _isStarting = false;

  Future<void> _startDesktopLyric() async {
    if (_isStarting) return;

    setState(() => _isStarting = true);
    try {
      await PlayService.instance.desktopLyricService.startDesktopLyric();
    } finally {
      if (mounted) {
        setState(() => _isStarting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final scheme = Theme.of(context).colorScheme;
    //
    return ListenableBuilder(
      listenable: PlayService.instance.desktopLyricService,
      builder: (context, _) {
        final desktopLyricService = PlayService.instance.desktopLyricService;
        final isRunning = desktopLyricService.isRunning;
        final isKilling = desktopLyricService.isKilling;

        if (_isStarting && !isRunning) {
          return IconButton(
            tooltip: '正在打开桌面歌词...',
            onPressed: null,
            icon: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            color: useMonet ? scheme.primary : scheme.onSurface,
          );
        }

        // 关闭过程中显示loading 并禁用按钮。
        if (isKilling) {
          return IconButton(
            tooltip: '正在关闭桌面歌词...',
            onPressed: null,
            icon: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(),
            ),
            color: useMonet ? scheme.primary : scheme.onSurface,
          );
        }

        final foregroundColor = isRunning
            ? scheme.onPrimaryContainer
            : (useMonet ? scheme.primary : scheme.onSurface);

        return IconButton(
          tooltip: !isRunning
              ? '打开桌面歌词'
              : desktopLyricService.isLocked
                  ? '解锁桌面歌词'
                  : '关闭桌面歌词',
          style: IconButton.styleFrom(
            backgroundColor: isRunning ? scheme.primaryContainer : null,
          ),
          onPressed: !isRunning
              ? _startDesktopLyric
              : desktopLyricService.isLocked
                  ? desktopLyricService.sendUnlockMessage
                  : desktopLyricService.killDesktopLyric,
          icon: Icon(
            desktopLyricService.isLocked ? Symbols.lock : Symbols.toast,
            fill: isRunning ? 1 : 0,
          ),
          color: foregroundColor,
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
  bool _disposed = false;
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
  late final VoidCallback _nowPlayingListener;

  void _scheduleAutoClose() {
    _autoCloseTimer?.cancel();
    _autoCloseTimer = Timer(const Duration(milliseconds: 950), () {
      if (_disposed || !mounted) return;
      if (isDragging || isSystemDragging || _isHovering || _isSystemHovering) {
        _scheduleAutoClose();
        return;
      }
      _menuController?.close();
    });
  }

  Future<double?> _readSystemVol({required Duration timeout}) async {
    return systemVolumeService.read(timeout: timeout);
  }

  @override
  void initState() {
    super.initState();
    _hotkeyListener = () {
      if (_disposed || !mounted) return;
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
    _nowPlayingListener = () {
      if (_disposed || !mounted) return;
      final v = playbackService.volumeDsp;
      if ((v - _lastVolumeDsp).abs() <= 0.0001) return;
      _lastVolumeDsp = v;
      if (_isMenuOpen && !isDragging) {
        _triggerIndicator();
      }
    };
    playbackService.nowPlayingNotifier.addListener(_nowPlayingListener);
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
    _disposed = true;
    _systemVolBoostTimer?.cancel();
    _indicatorTimer?.cancel();
    _systemIndicatorTimer?.cancel();
    _autoCloseTimer?.cancel();
    playbackService.nowPlayingNotifier.removeListener(_nowPlayingListener);
    systemVolumeService.volume.removeListener(_systemVolValueListener);
    hotkeyUiFeedback.removeListener(_hotkeyListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final scheme = Theme.of(context).colorScheme;
    final menuWidth = (MediaQuery.sizeOf(context).width - 64.0)
        .clamp(180.0, 300.0)
        .toDouble();
    //

    return MenuAnchor(
      style: appMenuStyle,
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
            width: menuWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // System Volume Slider
                Padding(
                  padding: const EdgeInsets.fromLTRB(16.0, 4.0, 16.0, 8.0),
                  child: Text(
                    '系统音量',
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
                                        suffix: '%',
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
                    '应用音量',
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
                                        suffix: '%',
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
          tooltip: '音量',
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          icon: const Icon(Symbols.volume_up),
          color: useMonet ? scheme.primary : scheme.onSurface,
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
    this.suffix = '',
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
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '${value.toInt()}$suffix',
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

class _GlowingIconButton extends StatefulWidget {
  static final _glowBlurFilter = ImageFilter.blur(sigmaX: 10, sigmaY: 10);

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
                      imageFilter: _GlowingIconButton._glowBlurFilter,
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
  static final _glowBlurFilter = ImageFilter.blur(sigmaX: 10, sigmaY: 10);

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
  StreamSubscription<PlayerState>? _playerStateSubscription;

  @override
  void initState() {
    super.initState();
    _controller.value = _state == PlayerState.playing ? 1.0 : 0.0;
    _bindPlayerStateStream();
  }

  void _bindPlayerStateStream() {
    _playerStateSubscription?.cancel();
    _playerStateSubscription = widget.playerStateStream.listen((newState) {
      if (!mounted) return;
      _syncPlayerState(newState);
    });
  }

  void _syncPlayerState(PlayerState state) {
    if (!mounted || state == _state) return;
    setState(() {
      _state = state;
    });
    _controller.animateTo(
      state == PlayerState.playing ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 240),
      curve: const Cubic(0.2, 0.0, 0.0, 1.0),
    );
  }

  @override
  void didUpdateWidget(covariant _MorphPlayPauseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playerStateStream != widget.playerStateStream) {
      _bindPlayerStateStream();
    }
    if (oldWidget.playerState != widget.playerState &&
        widget.playerState != _state) {
      _syncPlayerState(widget.playerState);
    }
  }

  @override
  void dispose() {
    _playerStateSubscription?.cancel();
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
        child: Builder(
          builder: (context) {
            final isPlaying = _state == PlayerState.playing;

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
                        imageFilter: _MorphPlayPauseButton._glowBlurFilter,
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
                      tooltip: isPlaying ? '暂停' : '播放',
                      onPressed: onPressed,
                      icon: AnimatedIcon(
                        icon: AnimatedIcons.play_pause,
                        progress: _controller,
                        color: widget.color,
                        size: widget.size,
                      ),
                      style: const ButtonStyle(
                        backgroundColor:
                            WidgetStatePropertyAll(Colors.transparent),
                        overlayColor:
                            WidgetStatePropertyAll(Colors.transparent),
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
  final NowPlayingMode mode;
  const _NowPlayingSlider({required this.mode});

  @override
  State<_NowPlayingSlider> createState() => _NowPlayingSliderState();
}

class _NowPlayingSliderState extends State<_NowPlayingSlider>
    with TickerProviderStateMixin {
  final dragPosition = ValueNotifier(0.0);
  final livePosition = ValueNotifier(0.0);
  final livePositionSeconds = ValueNotifier(0);
  final isDragging = ValueNotifier(false);
  late final PlaybackService _playbackService;
  late final VoidCallback _playerStateListener;
  late final VoidCallback _nowPlayingListener;
  Timer? _positionSyncTimer;
  Ticker? _progressTicker;
  Duration _lastProgressTickElapsed = Duration.zero;
  int _lastPositionMs = -1;
  bool _isPlaying = false;
  double _trackLength = 1.0;
  late final AnimationController _wavyController;

  @override
  void initState() {
    super.initState();
    _wavyController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );
    _playbackService = context.read<PlaybackService>();
    _isPlaying = _playbackService.playerState == PlayerState.playing;
    _syncFromNative(force: true);
    _syncWavyAnimation(_playbackService.playerState);
    _syncProgressDriver(_playbackService.playerState);
    _playerStateListener = () {
      final state = _playbackService.playerState;
      _syncWavyAnimation(state);
      _syncProgressDriver(state);
    };
    _playbackService.playerStateNotifier.addListener(_playerStateListener);
    _nowPlayingListener = () {
      _syncFromNative(force: true);
      _syncProgressDriver(_playbackService.playerState);
      if (mounted) setState(() {});
    };
    _playbackService.nowPlayingNotifier.addListener(_nowPlayingListener);
  }

  void _syncFromNative({bool force = false}) {
    _trackLength = _playbackService.length;
    _syncLivePosition(_playbackService.position, force: force);
  }

  void _syncWavyAnimation(PlayerState state) {
    final enabled =
        AppSettings.instance.wavyBarEnabledModes.contains(widget.mode);
    if (enabled && state == PlayerState.playing) {
      if (!_wavyController.isAnimating) _wavyController.repeat();
    } else {
      _wavyController.stop();
    }
  }

  void _syncProgressDriver(PlayerState state) {
    _isPlaying = state == PlayerState.playing;
    _syncFromNative(force: true);
    if (!_isPlaying) {
      _positionSyncTimer?.cancel();
      _positionSyncTimer = null;
      _progressTicker?.stop();
      return;
    }
    _positionSyncTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _syncFromNative(force: true);
    });
    _startProgressTicker();
  }

  void _startProgressTicker() {
    if (_progressTicker?.isActive == true) return;
    _lastProgressTickElapsed = Duration.zero;
    _progressTicker ??= createTicker(_onProgressTick);
    _progressTicker!.start();
  }

  void _onProgressTick(Duration elapsed) {
    if (!_isPlaying) return;
    if (_lastProgressTickElapsed == Duration.zero) {
      _lastProgressTickElapsed = elapsed;
      return;
    }
    final delta = elapsed - _lastProgressTickElapsed;
    _lastProgressTickElapsed = elapsed;
    if (delta <= Duration.zero) return;
    final length = _trackLength;
    final next = livePosition.value + delta.inMicroseconds / 1000000.0;
    _syncLivePosition(
      length > 0 ? next.clamp(0.0, length).toDouble() : next,
    );
  }

  void _syncLivePosition(double position, {bool force = false}) {
    final nowMs = (position * 1000).round();
    if (!force && nowMs == _lastPositionMs) return;
    _lastPositionMs = nowMs;
    livePosition.value = position;
    final seconds = position.floor();
    if (livePositionSeconds.value != seconds) {
      livePositionSeconds.value = seconds;
    }
  }

  @override
  void activate() {
    super.activate();
    _syncFromNative(force: true);
    _syncProgressDriver(_playbackService.playerState);
  }

  @override
  void dispose() {
    _positionSyncTimer?.cancel();
    _progressTicker?.dispose();
    _playbackService.playerStateNotifier.removeListener(_playerStateListener);
    _playbackService.nowPlayingNotifier.removeListener(_nowPlayingListener);
    dragPosition.dispose();
    livePosition.dispose();
    livePositionSeconds.dispose();
    isDragging.dispose();
    _wavyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playbackService = context.read<PlaybackService>();
    final nowPlayingLength = playbackService.length;
    final useMonetBar = AppSettings.instance.useMaterialYouForProgressBar;
    final useWavyBar =
        AppSettings.instance.wavyBarEnabledModes.contains(widget.mode);
    final barColor = useMonetBar ? scheme.primary : scheme.onSurface;
    final barGlow = useMonetBar
        ? scheme.primaryContainer
        : scheme.onSurface.withValues(alpha: 0.3);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _PlaybackPositionText(
                secondsListenable: livePositionSeconds,
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: SizedBox(
            height: 24,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final max = nowPlayingLength > 0 ? nowPlayingLength : 1.0;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (details) {
                    isDragging.value = true;
                    final value =
                        (details.localPosition.dx / width).clamp(0.0, 1.0) *
                            max;
                    dragPosition.value = value;
                  },
                  onHorizontalDragUpdate: (details) {
                    final value =
                        (details.localPosition.dx / width).clamp(0.0, 1.0) *
                            max;
                    dragPosition.value = value;
                  },
                  onHorizontalDragEnd: (details) {
                    isDragging.value = false;
                    _syncLivePosition(dragPosition.value, force: true);
                    playbackService.seek(dragPosition.value);
                  },
                  onTapDown: (details) {
                    final value =
                        (details.localPosition.dx / width).clamp(0.0, 1.0) *
                            max;
                    _syncLivePosition(value, force: true);
                    playbackService.seek(value);
                  },
                  child: CustomPaint(
                    painter: _ProgressSliderPainter(
                      livePosition: livePosition,
                      dragPosition: dragPosition,
                      isDragging: isDragging,
                      max: max,
                      color: barColor,
                      glowColor: barGlow,
                      inactiveColor: scheme.brightness == Brightness.dark
                          ? scheme.surfaceContainerHighest
                          : const Color(0x33FFFFFF),
                      useWavyBar: useWavyBar,
                      wavyController: _wavyController,
                    ),
                    size: Size(width, 24),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _PlaybackPositionText extends StatefulWidget {
  const _PlaybackPositionText({
    required this.secondsListenable,
    required this.color,
  });

  final ValueListenable<int> secondsListenable;
  final Color color;

  @override
  State<_PlaybackPositionText> createState() => _PlaybackPositionTextState();
}

class _PlaybackPositionTextState extends State<_PlaybackPositionText> {
  late int _displaySeconds;

  @override
  void initState() {
    super.initState();
    _displaySeconds = widget.secondsListenable.value;
    widget.secondsListenable.addListener(_onPositionChanged);
  }

  void _onPositionChanged() {
    final nextSeconds = widget.secondsListenable.value;
    if (nextSeconds == _displaySeconds || !mounted) return;
    setState(() {
      _displaySeconds = nextSeconds;
    });
  }

  @override
  void didUpdateWidget(covariant _PlaybackPositionText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.secondsListenable != widget.secondsListenable) {
      oldWidget.secondsListenable.removeListener(_onPositionChanged);
      widget.secondsListenable.addListener(_onPositionChanged);
      _displaySeconds = widget.secondsListenable.value;
    }
  }

  @override
  void dispose() {
    widget.secondsListenable.removeListener(_onPositionChanged);
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

class _ProgressSliderPainter extends CustomPainter {
  final ValueListenable<double> livePosition;
  final ValueListenable<double> dragPosition;
  final ValueListenable<bool> isDragging;
  final double max;
  final Color color;
  final Color glowColor;
  final Color inactiveColor;
  final bool useWavyBar;
  final Animation<double> wavyController;
  final Paint _paint = Paint()
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.fill;
  final Paint _thumbGlowPaint = Paint()
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
  final Path _wavePath = Path();

  _ProgressSliderPainter({
    required this.livePosition,
    required this.dragPosition,
    required this.isDragging,
    required this.max,
    required this.color,
    required this.glowColor,
    required this.inactiveColor,
    required this.useWavyBar,
    required this.wavyController,
  }) : super(
          repaint: Listenable.merge([
            livePosition,
            dragPosition,
            isDragging,
            if (useWavyBar) wavyController,
          ]),
        );

  double get _fraction {
    final position = isDragging.value
        ? dragPosition.value
        : livePosition.value > max
            ? max
            : livePosition.value;
    return max > 0 ? (position / max).clamp(0.0, 1.0) : 0.0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final fraction = _fraction;
    if (useWavyBar) {
      _paintWavy(canvas, size, fraction, wavyController.value * 2 * pi);
      return;
    }

    const double height = 4.0;
    final double centerY = size.height / 2;
    final double activeWidth = size.width * fraction;

    // Inactive track
    _paint
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round
      ..shader = null
      ..maskFilter = null
      ..color = inactiveColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, centerY - height / 2, size.width, height),
        const Radius.circular(height / 2),
      ),
      _paint,
    );

    // Active track (Solid color, no animation/glow on the track itself to reduce visual noise)
    final Rect activeRect =
        Rect.fromLTWH(0, centerY - height / 2, activeWidth, height);
    if (activeWidth > 0) {
      _paint
        ..color = color
        ..shader = null;
      canvas.drawRRect(
        RRect.fromRectAndRadius(activeRect, const Radius.circular(height / 2)),
        _paint,
      );
    }

    // Thumb
    _paint
      ..shader = null
      ..color = color;
    // Draw thumb shadow (very subtle, avoid visual distraction)
    _thumbGlowPaint.color = glowColor.withValues(alpha: 0.15);
    canvas.drawCircle(
      Offset(activeWidth, centerY),
      5,
      _thumbGlowPaint,
    );
    // Draw thumb
    canvas.drawCircle(Offset(activeWidth, centerY), 6, _paint);
  }

  void _paintWavy(Canvas canvas, Size size, double fraction, double phase) {
    const double strokeWidth = 3.5;
    final double centerY = size.height / 2;
    final double activeWidth = size.width * fraction;

    final paint = _paint
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = null
      ..maskFilter = null;

    // Inactive track: straight line
    paint.color = inactiveColor;
    canvas.drawLine(
      Offset(activeWidth, centerY),
      Offset(size.width, centerY),
      paint,
    );

    if (activeWidth <= 0) return;

    // Active track: sine wave
    const double amplitude = 2.5;
    const double wavelength = 44.0;
    const double sampleStep = 1.5;
    const double freq = 2 * pi / wavelength;

    final wavePath = _wavePath..reset();
    wavePath.moveTo(0, centerY + amplitude * sin(phase));
    for (double x = 0.0; x <= activeWidth; x += sampleStep) {
      wavePath.lineTo(x, centerY + amplitude * sin(phase + x * freq));
    }
    if (activeWidth > 0) {
      wavePath.lineTo(
        activeWidth,
        centerY + amplitude * sin(phase + activeWidth * freq),
      );
    }

    paint.color = color;
    canvas.drawPath(wavePath, paint);

    // Thumb glow
    paint
      ..style = PaintingStyle.fill
      ..color = glowColor.withValues(alpha: 0.15)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawCircle(Offset(activeWidth, centerY), 5, paint);

    // Thumb
    paint
      ..shader = null
      ..maskFilter = null
      ..color = color;
    canvas.drawCircle(Offset(activeWidth, centerY), 6, paint);
  }

  @override
  bool shouldRepaint(covariant _ProgressSliderPainter oldDelegate) {
    return oldDelegate.livePosition != livePosition ||
        oldDelegate.dragPosition != dragPosition ||
        oldDelegate.isDragging != isDragging ||
        oldDelegate.max != max ||
        oldDelegate.color != color ||
        oldDelegate.glowColor != glowColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.useWavyBar != useWavyBar ||
        oldDelegate.wavyController != wavyController;
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
  ImageProvider<Object>? _coverImage;
  String? _coverPath;
  int _coverToken = 0;

  void _onPlaybackChange() {
    _coverToken++;
    final token = _coverToken;
    final nextAudio = playbackService.nowPlaying;
    if (nextAudio == null) {
      setState(() {
        _coverImage = null;
        _coverPath = null;
      });
      return;
    }

    if (nextAudio.path == _coverPath && _coverImage != null) return;

    _coverPath = nextAudio.path;

    // 切歌首帧：立即用已缓存的小封面，没有则透明（不闪占位图标）
    final smallBytes = nextAudio.smallCoverBytes;
    setState(() {
      _coverImage = smallBytes != null ? MemoryImage(smallBytes) : null;
    });

    // 小封面未缓存则异步加载
    if (smallBytes == null) {
      nextAudio.loadSmallCoverBytes().then((bytes) {
        if (!mounted || token != _coverToken) return;
        if (playbackService.nowPlaying?.path != nextAudio.path) return;
        setState(() {
          _coverImage ??= bytes != null ? MemoryImage(bytes) : null;
        });
      });
    }

    // 异步加载高清封面，gaplessPlayback 无缝替换
    nextAudio.largeCover.then((hiRes) {
      if (!mounted || token != _coverToken) return;
      if (playbackService.nowPlaying?.path != nextAudio.path) return;
      if (hiRes != null) {
        setState(() => _coverImage = hiRes);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    playbackService.nowPlayingNotifier.addListener(_onPlaybackChange);

    final audio = playbackService.nowPlaying;
    if (audio != null) {
      final currentPath = audio.path;
      _coverPath = currentPath;
      final smallBytes = audio.smallCoverBytes;
      _coverImage = smallBytes != null ? MemoryImage(smallBytes) : null;
      if (_coverImage == null) {
        audio.loadSmallCoverBytes().then((bytes) {
          if (!mounted) return;
          if (playbackService.nowPlaying?.path != currentPath) return;
          setState(() {
            _coverImage = bytes != null ? MemoryImage(bytes) : null;
          });
        });
      }
      audio.largeCover.then((hiRes) {
        if (!mounted) return;
        if (playbackService.nowPlaying?.path != currentPath) return;
        if (hiRes != null) setState(() => _coverImage = hiRes);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final nowPlaying = playbackService.nowPlaying;
    final nowPlayingPath = nowPlaying?.path;
    final heroEnabled = !playbackService.nowPlayingChangedRecently;

    final placeholder = Icon(
      Symbols.queue_music,
      size: 400.0,
      color: scheme.onSurface.withAlpha(60),
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

        final coverWidget = _coverImage != null
            ? Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12.0),
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
                  borderRadius: BorderRadius.circular(12.0),
                  child: Image(
                    image: _coverImage!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (_, __, ___) => FittedBox(
                      fit: BoxFit.contain,
                      child: placeholder,
                    ),
                  ),
                ),
              )
            : nowPlaying == null
                ? Center(child: placeholder)
                : SizedBox(width: coverSize, height: coverSize);

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
                          child: RepaintBoundary(child: coverWidget),
                        )
                      : RepaintBoundary(child: coverWidget),
                ),
                const SizedBox(height: 24.0),
                Text(
                  nowPlaying == null ? 'Pure Music' : nowPlaying.title,
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
                  nowPlaying == null ? 'Enjoy Music' : nowPlaying.artist,
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
    playbackService.nowPlayingNotifier.removeListener(_onPlaybackChange);
    super.dispose();
  }
}
