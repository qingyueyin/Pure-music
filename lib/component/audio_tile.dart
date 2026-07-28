import 'dart:async';
import 'dart:typed_data';

import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

/// 由[playlist]和[audioIndex]确定audio，而不是直接传入audio，
/// 这是为了实现点击列表项播放乐曲时指定该列表为播放列表。
/// 同时，播放乐曲时也是需要index和playlist来定位audio和设置播放列表。
class AudioTile extends StatefulWidget {
  const AudioTile({
    super.key,
    required this.audioIndex,
    required this.playlist,
    this.focus = false,
    this.leading,
    this.action,
    this.multiSelectController,
    this.onRemoveFromPlaylist,
  });

  final int audioIndex;
  final List<Audio> playlist;
  final bool focus;
  final Widget? leading;
  final Widget? action;
  final MultiSelectController? multiSelectController;
  final FutureOr<void> Function(Audio audio)? onRemoveFromPlaylist;

  @override
  State<AudioTile> createState() => _AudioTileState();
}

class _AudioTileState extends State<AudioTile> {
  bool _hovered = false;
  bool _isRemovingFromPlaylist = false;
  Playlist? _addingToPlaylist;
  int? _dragStartIndex;
  int? _lastDragTargetIndex;
  final Set<Audio> _dragRange = {};
  final Set<Audio> _preDragSelection = {};

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final audio = widget.playlist[widget.audioIndex];
    final playbackService = PlayService.instance.playbackService;
    final menuStyle = appMenuStyle;
    final menuItemStyle = appMenuItemStyle;
    final album = AudioLibrary.instance.albumCollection[audio.album];

    Future<void> removeFromPlaylist() async {
      if (!canStartSinglePlaylistRemoval(
        hasRemoveAction: widget.onRemoveFromPlaylist != null,
        isRemoving: _isRemovingFromPlaylist,
        isAddingToPlaylist: _addingToPlaylist != null,
      )) {
        return;
      }
      final confirmed = await showDangerConfirmDialog(
        context: context,
        title: '从歌单移除歌曲？',
        message: '只会从当前歌单移除这首歌曲，不会删除本地音乐文件。',
        confirmLabel: '移除',
        details: Text(
          audio.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: AppType.caption),
        ),
      );
      if (!confirmed || !mounted) return;
      setState(() => _isRemovingFromPlaylist = true);
      try {
        await Future<void>.sync(() => widget.onRemoveFromPlaylist!(audio));
      } finally {
        if (mounted) {
          setState(() => _isRemovingFromPlaylist = false);
        }
      }
    }

    Future<void> addToPlaylist(Playlist target) async {
      if (_addingToPlaylist != null || _isRemovingFromPlaylist) {
        return;
      }
      final added = target.containsPath(audio.path);
      if (added) {
        showTextOnSnackBar('歌曲已在歌单中');
        return;
      }

      setState(() => _addingToPlaylist = target);
      try {
        target.addPath(audio.path);
        final saved = await savePlaylists();
        if (!mounted) return;
        if (!saved) {
          target.removeByPath(audio.path);
          showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
          return;
        }
        showTextOnSnackBar('已添加到歌单', variant: ToastVariant.success);
      } finally {
        _addingToPlaylist = null;
        if (mounted) setState(() {});
      }
    }

    return ListenableBuilder(
      listenable: playbackService,
      builder: (context, _) {
        final isNowPlaying = playbackService.nowPlaying?.path == audio.path;
        final effectiveFocus = widget.focus || isNowPlaying;
        final isSelected =
            widget.multiSelectController?.selected.contains(audio) == true;

        return MenuTheme(
          data: MenuThemeData(style: menuStyle),
          child: MenuAnchor(
            consumeOutsideTap: true,
            style: menuStyle,
            menuChildren: [
              /// artists
              ...List.generate(audio.splitedArtists.length, (i) {
                final name = audio.splitedArtists[i];
                final artist = AudioLibrary.instance.artistCollection[name];
                return MenuItemButton(
                  style: menuItemStyle,
                  onPressed: artist == null
                      ? null
                      : () {
                          context.push(
                            app_paths.ARTIST_DETAIL_PAGE,
                            extra: artist,
                          );
                        },
                  leadingIcon: const Icon(Symbols.artist),
                  child: Text(name),
                );
              }),

              /// album
              MenuItemButton(
                style: menuItemStyle,
                onPressed: album == null
                    ? null
                    : () {
                        context.push(app_paths.ALBUM_DETAIL_PAGE, extra: album);
                      },
                leadingIcon: const Icon(Symbols.album),
                child: Text(audio.album),
              ),

              /// 下一首播放
              MenuItemButton(
                style: menuItemStyle,
                onPressed: canAddAudioToNext(
                  hasNowPlaying:
                      PlayService.instance.playbackService.nowPlaying != null,
                  isPendingFeedback: false,
                )
                    ? () {
                        PlayService.instance.playbackService.addToNext(audio);
                        showTextOnSnackBar('已加入下一首', variant: ToastVariant.success);
                      }
                    : null,
                leadingIcon: const Icon(Symbols.plus_one),
                child: const Text('下一首播放'),
              ),

              /// 多选
              if (widget.multiSelectController != null)
                MenuItemButton(
                  style: menuItemStyle,
                  onPressed: () {
                    widget.multiSelectController!.useMultiSelectView(true);
                    widget.multiSelectController!.select(audio);
                  },
                  leadingIcon: const Icon(Symbols.select),
                  child: const Text('多选'),
                ),

              /// add to playlist
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
                        .map((playlist) => playlist.containsPath(audio.path))
                        .toList(growable: false);
                    final isBusy =
                        _addingToPlaylist != null || _isRemovingFromPlaylist;
                    final canOpenAddMenu = canOpenSingleAudioAddToPlaylistMenu(
                      hasAudio: true,
                      isBusy: isBusy,
                      alreadyInPlaylists: playlistMemberships,
                    );
                    if (!canOpenAddMenu) {
                      return MenuItemButton(
                        style: menuItemStyle,
                        onPressed: null,
                        leadingIcon: _addingToPlaylist != null
                            ? const SizedBox(
                                width: 18.0,
                                height: 18.0,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.0,
                                ),
                              )
                            : Icon(
                                playlistMemberships.every(
                                  (alreadyIn) => alreadyIn,
                                )
                                    ? Symbols.check
                                    : Symbols.queue_music,
                              ),
                        child: const Text('添加到歌单'),
                      );
                    }
                    return SubmenuButton(
                      style: menuItemStyle,
                      menuChildren: List.generate(playlists.length, (i) {
                        final playlist = playlists[i];
                        final isAdding = identical(_addingToPlaylist, playlist);
                        final alreadyInPlaylist = playlistMemberships[i];
                        return MenuItemButton(
                          style: menuItemStyle,
                          onPressed: isBusy || alreadyInPlaylist
                              ? null
                              : () => addToPlaylist(playlist),
                          leadingIcon: isAdding
                              ? const SizedBox(
                                  width: 18.0,
                                  height: 18.0,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.0,
                                  ),
                                )
                              : Icon(
                                  alreadyInPlaylist
                                      ? Symbols.check
                                      : Symbols.queue_music,
                                ),
                          child: Text(playlist.name),
                        );
                      }),
                      child: const Text('添加到歌单'),
                    );
                  },
                ),

              /// remove from playlist
              if (widget.onRemoveFromPlaylist != null)
                MenuItemButton(
                  style: menuItemStyle,
                  onPressed: canStartSinglePlaylistRemoval(
                    hasRemoveAction: widget.onRemoveFromPlaylist != null,
                    isRemoving: _isRemovingFromPlaylist,
                    isAddingToPlaylist: _addingToPlaylist != null,
                  )
                      ? removeFromPlaylist
                      : null,
                  leadingIcon: _isRemovingFromPlaylist
                      ? const SizedBox(
                          width: 18.0,
                          height: 18.0,
                          child: CircularProgressIndicator(strokeWidth: 2.0),
                        )
                      : Icon(Symbols.remove_circle, color: scheme.error),
                  child: Text(_isRemovingFromPlaylist ? '移除中' : '从歌单移除'),
                ),

              /// to detail page
              MenuItemButton(
                style: menuItemStyle,
                onPressed: () {
                  context.push(app_paths.AUDIO_DETAIL_PAGE, extra: audio);
                },
                leadingIcon: const Icon(Symbols.info),
                child: const Text('详细信息'),
              ),
            ],
            builder: (context, controller, _) {
              final textColor =
                  effectiveFocus ? scheme.primary : scheme.onSurface;
              final backgroundColor = isSelected
                  ? scheme.secondaryContainer
                  : effectiveFocus
                      ? scheme.primary.withAlpha(20)
                      : _hovered
                          ? scheme.onSurface.withAlpha(10)
                          : Colors.transparent;

              return TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: MotionDuration.base,
                curve: MotionCurve.standard,
                builder: (context, t, child) {
                  return Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, (1 - t) * 20),
                      child: child,
                    ),
                  );
                },
                child: AnimatedContainer(
                  duration: MotionDuration.base,
                  curve: MotionCurve.standard,
                  height: 64.0,
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    borderRadius: AppRadius.smCircular,
                    border: effectiveFocus && !isSelected
                        ? Border.all(color: scheme.primary.withAlpha(89))
                        : null,
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: GestureDetector(
                    onLongPressStart: (details) {
                      if (widget.multiSelectController == null) return;

                      if (!widget
                          .multiSelectController!.enableMultiSelectView) {
                        widget.multiSelectController!.useMultiSelectView(true);
                      }

                      _dragStartIndex = widget.audioIndex;
                      _lastDragTargetIndex = widget.audioIndex;
                      _preDragSelection
                        ..clear()
                        ..addAll(
                          widget.multiSelectController!.selected.cast<Audio>(),
                        );
                      _dragRange.clear();
                      _dragRange.add(audio);
                      widget.multiSelectController!.select(audio);
                    },
                    onLongPressMoveUpdate: (details) {
                      if (_dragStartIndex == null ||
                          widget.multiSelectController == null) {
                        return;
                      }

                      final dy = details.localOffsetFromOrigin.dy;
                      final delta = (dy / 64).round();
                      final targetIndex = (_dragStartIndex! + delta)
                          .clamp(0, widget.playlist.length - 1);

                      if (targetIndex == _lastDragTargetIndex) return;

                      final oldMin = _dragStartIndex! < _lastDragTargetIndex!
                          ? _dragStartIndex!
                          : _lastDragTargetIndex!;
                      final oldMax = _dragStartIndex! > _lastDragTargetIndex!
                          ? _dragStartIndex!
                          : _lastDragTargetIndex!;
                      final newMin = _dragStartIndex! < targetIndex
                          ? _dragStartIndex!
                          : targetIndex;
                      final newMax = _dragStartIndex! > targetIndex
                          ? _dragStartIndex!
                          : targetIndex;

                      _lastDragTargetIndex = targetIndex;

                      for (int i = oldMin; i <= oldMax; i++) {
                        final item = widget.playlist[i];
                        final inNewRange = i >= newMin && i <= newMax;
                        if (!inNewRange &&
                            _dragRange.contains(item) &&
                            !_preDragSelection.contains(item)) {
                          widget.multiSelectController!.unselect(item);
                          _dragRange.remove(item);
                        }
                      }

                      for (int i = newMin; i <= newMax; i++) {
                        if (i < oldMin || i > oldMax) {
                          final item = widget.playlist[i];
                          if (!_dragRange.contains(item)) {
                            widget.multiSelectController!.select(item);
                            _dragRange.add(item);
                          }
                        }
                      }
                    },
                    onLongPressEnd: (details) {
                      _dragStartIndex = null;
                      _lastDragTargetIndex = null;
                      _dragRange.clear();
                      _preDragSelection.clear();
                    },
                    onLongPressCancel: () {
                      _dragStartIndex = null;
                      _lastDragTargetIndex = null;
                      _dragRange.clear();
                      _preDragSelection.clear();
                    },
                    onSecondaryTapDown: (details) {
                      if (widget.multiSelectController?.enableMultiSelectView ==
                          true) {
                        return;
                      }

                      controller.open(
                          position: details.localPosition.translate(0, -240));
                    },
                    child: InkWell(
                      focusColor: Colors.transparent,
                      borderRadius: AppRadius.smCircular,
                      onHover: (v) => setState(() => _hovered = v),
                      onTap: () {
                        if (controller.isOpen) {
                          controller.close();
                          return;
                        }

                        if (widget.multiSelectController == null ||
                            !widget
                                .multiSelectController!.enableMultiSelectView) {
                          PlayService.instance.playbackService
                              .play(widget.audioIndex, widget.playlist);
                        } else {
                          if (widget.multiSelectController!.selected
                              .contains(audio)) {
                            widget.multiSelectController!.unselect(audio);
                          } else {
                            widget.multiSelectController!.select(audio);
                          }
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        child: Row(children: [
                          if (widget.leading != null)
                            Padding(
                              padding: const EdgeInsets.only(right: 16.0),
                              child: widget.leading!,
                            ),

                          /// cover: 同步渲染已缓存字节，不走 FutureBuilder
                          _SmallCoverWidget(audio: audio),
                          const SizedBox(width: 16.0),

                          /// title, artist and album
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  audio.title,
                                  style:
                                      TextStyle(color: textColor, fontSize: AppType.subtitle),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(width: 4.0),
                                Text(
                                  '${audio.artist} - ${audio.album}',
                                  style: TextStyle(color: textColor),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8.0),
                          Text(
                            Duration(seconds: audio.duration).toStringHMMSS(),
                            style: TextStyle(
                              color: effectiveFocus
                                  ? scheme.primary
                                  : scheme.onSurface,
                            ),
                          ),
                          if (widget.multiSelectController != null &&
                              widget
                                  .multiSelectController!.enableMultiSelectView)
                            Padding(
                              padding: const EdgeInsets.only(left: 8.0),
                              child: Checkbox(
                                value: isSelected,
                                onChanged: (v) {
                                  if (v == true) {
                                    widget.multiSelectController!.select(audio);
                                  } else {
                                    widget.multiSelectController!
                                        .unselect(audio);
                                  }
                                },
                              ),
                            ),
                          if (widget.action != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 8.0),
                              child: widget.action!,
                            ),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    },
  );
  }
}

/// 小封面组件：
/// 同步检查 Audio._smallCoverBytes，已缓存则用 Image.memory 直接渲染；
/// 未缓存则显示纯色占位 + 异步加载后写回 Audio 并 setState。
/// 不使用 FutureBuilder，避免任何闪烁。
class _SmallCoverWidget extends StatefulWidget {
  final Audio audio;
  const _SmallCoverWidget({required this.audio});

  @override
  State<_SmallCoverWidget> createState() => _SmallCoverWidgetState();
}

class _SmallCoverWidgetState extends State<_SmallCoverWidget> {
  Uint8List? _cached;

  @override
  void initState() {
    super.initState();
    _cached = widget.audio.smallCoverBytes;
    if (_cached == null) {
      _load();
    }
  }

  @override
  void didUpdateWidget(_SmallCoverWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audio != widget.audio ||
        widget.audio.smallCoverBytes != _cached) {
      final bytes = widget.audio.smallCoverBytes;
      if (bytes != null && !identical(bytes, _cached)) {
        setState(() => _cached = bytes);
      } else if (bytes == null && _cached != null) {
        setState(() => _cached = null);
        _load();
      }
    }
  }

  Future<void> _load() async {
    final bytes = await widget.audio.loadSmallCoverBytes();
    if (mounted && bytes != null) {
      setState(() => _cached = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cached != null) {
      return ClipRRect(
        borderRadius: AppRadius.smCircular,
        child: Image.memory(
          _cached!,
          width: 48.0,
          height: 48.0,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _placeholder(context),
        ),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      width: 48.0,
      height: 48.0,
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: AppRadius.smCircular,
      ),
    );
  }
}
