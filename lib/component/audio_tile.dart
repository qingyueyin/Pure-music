import 'dart:async';

import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/scroll_aware_future_builder.dart';
import 'package:pure_music/core/cache.dart';
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
  bool _isRemovingFromPlaylist = false;
  Playlist? _addingToPlaylist;
  bool _menuRequested = false;
  double? _rangeScrollOrigin;

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
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: AppType.caption,
          ),
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
            onClose: () {
              if (mounted && _menuRequested) {
                setState(() => _menuRequested = false);
              }
            },
            menuChildren: _menuRequested
                ? [
                    /// artists
                    ...List.generate(audio.splitedArtists.length, (i) {
                      final name = audio.splitedArtists[i];
                      final artist =
                          AudioLibrary.instance.artistCollection[name];
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
                              context.push(
                                app_paths.ALBUM_DETAIL_PAGE,
                                extra: album,
                              );
                            },
                      leadingIcon: const Icon(Symbols.album),
                      child: Text(audio.album),
                    ),

                    /// 下一首播放
                    MenuItemButton(
                      style: menuItemStyle,
                      onPressed:
                          canAddAudioToNext(
                            hasNowPlaying:
                                PlayService
                                    .instance
                                    .playbackService
                                    .nowPlaying !=
                                null,
                            isPendingFeedback: false,
                          )
                          ? () {
                              PlayService.instance.playbackService.addToNext(
                                audio,
                              );
                              showTextOnSnackBar(
                                '已加入下一首',
                                variant: ToastVariant.success,
                              );
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
                          widget.multiSelectController!.useMultiSelectView(
                            true,
                          );
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
                              .map(
                                (playlist) => playlist.containsPath(audio.path),
                              )
                              .toList(growable: false);
                          final isBusy =
                              _addingToPlaylist != null ||
                              _isRemovingFromPlaylist;
                          final canOpenAddMenu =
                              canOpenSingleAudioAddToPlaylistMenu(
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
                              final isAdding = identical(
                                _addingToPlaylist,
                                playlist,
                              );
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
                        onPressed:
                            canStartSinglePlaylistRemoval(
                              hasRemoveAction:
                                  widget.onRemoveFromPlaylist != null,
                              isRemoving: _isRemovingFromPlaylist,
                              isAddingToPlaylist: _addingToPlaylist != null,
                            )
                            ? removeFromPlaylist
                            : null,
                        leadingIcon: _isRemovingFromPlaylist
                            ? const SizedBox(
                                width: 18.0,
                                height: 18.0,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.0,
                                ),
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
                  ]
                : const <Widget>[],
            builder: (context, controller, _) {
              final titleColor = effectiveFocus
                  ? scheme.primary
                  : scheme.onSurface;
              final metadataColor = effectiveFocus
                  ? scheme.primary.withValues(alpha: 0.78)
                  : scheme.onSurfaceVariant;
              final backgroundColor = isSelected
                  ? scheme.secondaryContainer
                  : effectiveFocus
                  ? scheme.primary.withAlpha(20)
                  : Colors.transparent;

              return DirectionalListItemEntrance(
                identity: audio,
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
                        _rangeScrollOrigin = Scrollable.maybeOf(
                          context,
                        )?.position.pixels;
                        widget.multiSelectController?.beginRangeSelection(
                          widget.playlist,
                          widget.audioIndex,
                        );
                      },
                      onLongPressMoveUpdate: (details) {
                        final scrollPosition = Scrollable.maybeOf(
                          context,
                        )?.position.pixels;
                        final scrollDelta =
                            scrollPosition == null || _rangeScrollOrigin == null
                            ? 0.0
                            : scrollPosition - _rangeScrollOrigin!;
                        final targetIndex =
                            widget.audioIndex +
                            ((details.localOffsetFromOrigin.dy + scrollDelta) /
                                    64)
                                .round();
                        widget.multiSelectController?.updateRangeSelection(
                          targetIndex,
                        );
                      },
                      onLongPressEnd: (_) {
                        _rangeScrollOrigin = null;
                        widget.multiSelectController?.endRangeSelection();
                      },
                      onLongPressCancel: () {
                        _rangeScrollOrigin = null;
                        widget.multiSelectController?.endRangeSelection();
                      },
                      onSecondaryTapDown: (details) {
                        if (widget
                                .multiSelectController
                                ?.enableMultiSelectView ==
                            true) {
                          return;
                        }

                        final position = details.localPosition.translate(
                          0,
                          -240,
                        );
                        if (_menuRequested) {
                          controller.open(position: position);
                          return;
                        }
                        setState(() => _menuRequested = true);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted || !_menuRequested) return;
                          controller.open(position: position);
                        });
                      },
                      child: InkWell(
                        focusColor: Colors.transparent,
                        hoverColor: scheme.onSurface.withAlpha(10),
                        onHover: (hovering) {
                          final multiSelectController =
                              widget.multiSelectController;
                          if (hovering &&
                              multiSelectController?.isRangeSelecting == true) {
                            multiSelectController!.updateRangeSelection(
                              widget.audioIndex,
                            );
                          }
                        },
                        borderRadius: AppRadius.smCircular,
                        onTap: () {
                          if (controller.isOpen) {
                            controller.close();
                            return;
                          }

                          if (widget.multiSelectController == null ||
                              !widget
                                  .multiSelectController!
                                  .enableMultiSelectView) {
                            PlayService.instance.playbackService.play(
                              widget.audioIndex,
                              widget.playlist,
                            );
                          } else {
                            if (widget.multiSelectController!.selected.contains(
                              audio,
                            )) {
                              widget.multiSelectController!.unselect(audio);
                            } else {
                              widget.multiSelectController!.select(audio);
                            }
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8.0),
                          child: Row(
                            children: [
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
                                      style: TextStyle(
                                        color: titleColor,
                                        fontSize: AppType.subtitle,
                                        fontWeight: AppType.weightMedium,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(width: 4.0),
                                    Text(
                                      '${audio.artist} - ${audio.album}',
                                      style: TextStyle(color: metadataColor),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8.0),
                              Text(
                                Duration(
                                  seconds: audio.duration,
                                ).toStringHMMSS(),
                                style: TextStyle(color: metadataColor),
                              ),
                              if (widget.multiSelectController != null &&
                                  widget
                                      .multiSelectController!
                                      .enableMultiSelectView)
                                Padding(
                                  padding: const EdgeInsets.only(left: 8.0),
                                  child: Checkbox(
                                    value: isSelected,
                                    onChanged: (v) {
                                      if (v == true) {
                                        widget.multiSelectController!.select(
                                          audio,
                                        );
                                      } else {
                                        widget.multiSelectController!.unselect(
                                          audio,
                                        );
                                      }
                                    },
                                  ),
                                ),
                              if (widget.action != null)
                                Padding(
                                  padding: const EdgeInsets.only(left: 8.0),
                                  child: widget.action!,
                                ),
                            ],
                          ),
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
class _SmallCoverWidget extends StatelessWidget {
  final Audio audio;
  const _SmallCoverWidget({required this.audio});

  @override
  Widget build(BuildContext context) {
    final initialProvider = CoverImageCache.instance.getCached(
      path: audio.path,
      width: 48,
      height: 48,
    );
    return ScrollAwareFutureBuilder<ImageProvider?>(
      identity: '${audio.path}|${audio.modified}',
      initialData: initialProvider,
      future: () => audio.cover,
      builder: (context, snapshot) {
        final provider = snapshot.data;
        if (provider == null) {
          return snapshot.connectionState == ConnectionState.done
              ? _placeholder(context)
              : _loadingPlaceholder(context);
        }
        return ClipRRect(
          borderRadius: AppRadius.smCircular,
          child: Image(
            image: provider,
            width: 48.0,
            height: 48.0,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _placeholder(context),
          ),
        );
      },
    );
  }

  Widget _loadingPlaceholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 48.0,
      height: 48.0,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.22),
        borderRadius: AppRadius.smCircular,
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 48.0,
      height: 48.0,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: AppRadius.smCircular,
      ),
      child: Icon(
        Symbols.music_note,
        size: 22,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
      ),
    );
  }
}
