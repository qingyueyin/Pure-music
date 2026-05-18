import 'dart:typed_data';

import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/utils.dart';
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
  });

  final int audioIndex;
  final List<Audio> playlist;
  final bool focus;
  final Widget? leading;
  final Widget? action;
  final MultiSelectController? multiSelectController;

  @override
  State<AudioTile> createState() => _AudioTileState();
}

class _AudioTileState extends State<AudioTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final audio = widget.playlist[widget.audioIndex];
    final playbackService = PlayService.instance.playbackService;
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
                if (artist == null) return const SizedBox.shrink();
                return MenuItemButton(
                  style: menuItemStyle,
                  onPressed: () {
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
                onPressed: () {
                  final album =
                      AudioLibrary.instance.albumCollection[audio.album];
                  if (album == null) {
                    showTextOnSnackBar('未找到专辑"${audio.album}"');
                    return;
                  }
                  context.push(app_paths.ALBUM_DETAIL_PAGE, extra: album);
                },
                leadingIcon: const Icon(Symbols.album),
                child: Text(audio.album),
              ),

              /// 下一首播放
              MenuItemButton(
                style: menuItemStyle,
                onPressed: () {
                  PlayService.instance.playbackService.addToNext(audio);
                },
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
              SubmenuButton(
                style: menuItemStyle,
                menuChildren: List.generate(
                  PLAYLISTS.length,
                  (i) => MenuItemButton(
                    style: menuItemStyle,
                    onPressed: () {
                      final added = PLAYLISTS[i].containsPath(audio.path);
                      if (added) {
                        showTextOnSnackBar('歌曲${audio.title}已存在');
                        return;
                      }

                      PLAYLISTS[i].addPath(audio.path);
                      showTextOnSnackBar(
                        '成功将${audio.title}添加到歌单${PLAYLISTS[i].name}',
                      );
                    },
                    leadingIcon: const Icon(Symbols.queue_music),
                    child: Text(PLAYLISTS[i].name),
                  ),
                ),
                child: const Text('添加到歌单'),
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

              return AnimatedContainer(
                duration: MotionDuration.base,
                curve: MotionCurve.standard,
                height: 64.0,
                decoration: BoxDecoration(
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(8.0),
                  border: effectiveFocus && !isSelected
                      ? Border.all(color: scheme.primary.withAlpha(89))
                      : null,
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    focusColor: Colors.transparent,
                    borderRadius: BorderRadius.circular(8.0),
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
                    onLongPress: () {
                      if (widget.multiSelectController == null) return;
                      if (widget.multiSelectController!.enableMultiSelectView) {
                        return;
                      }
                      widget.multiSelectController!.useMultiSelectView(true);
                      widget.multiSelectController!.select(audio);
                    },
                    onSecondaryTapDown: (details) {
                      if (widget.multiSelectController?.enableMultiSelectView ==
                          true) {
                        return;
                      }

                      controller.open(
                          position: details.localPosition.translate(0, -240));
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Row(children: [
                        if (widget.leading != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 16.0),
                            child: widget.leading!,
                          ),

                        /// cover (ZeroBit pattern: 同步渲染已缓存字节，不走 FutureBuilder)
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
                                    TextStyle(color: textColor, fontSize: 16),
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
                            widget.multiSelectController!.enableMultiSelectView)
                          Padding(
                            padding: const EdgeInsets.only(left: 8.0),
                            child: Checkbox(
                              value: isSelected,
                              onChanged: (v) {
                                if (v == true) {
                                  widget.multiSelectController!.select(audio);
                                } else {
                                  widget.multiSelectController!.unselect(audio);
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
              );
            },
          ),
        );
      },
    );
  }
}
/// ZeroBit-pattern 小封面组件：
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
        borderRadius: BorderRadius.circular(8.0),
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
        borderRadius: BorderRadius.circular(8.0),
      ),
    );
  }
}