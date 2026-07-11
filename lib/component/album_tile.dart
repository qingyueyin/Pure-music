import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

class AlbumTile extends StatefulWidget {
  const AlbumTile({
    super.key,
    required this.album,
    this.multiSelectController,
    this.view = ContentView.list,
  });

  final Album album;
  final MultiSelectController<Album>? multiSelectController;
  final ContentView view;

  @override
  State<AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends State<AlbumTile> {
  bool _hovered = false;
  late Future<ImageProvider?> _coverFuture;
  late Future<AlbumColor?> _albumColorFuture;

  @override
  void initState() {
    super.initState();
    _refreshFutures();
  }

  @override
  void didUpdateWidget(covariant AlbumTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.album != widget.album || oldWidget.view != widget.view) {
      _refreshFutures();
    }
  }

  int get _coverSize => widget.view == ContentView.list ? 48 : 160;

  void _refreshFutures() {
    if (widget.album.works.isEmpty) {
      _coverFuture = Future<ImageProvider?>.value(null);
      _albumColorFuture = Future<AlbumColor?>.value(null);
      return;
    }

    _coverFuture = widget.album.thumbnailCover(size: _coverSize);
    _albumColorFuture = widget.view == ContentView.table
        ? AlbumColorCache.instance.getAlbumColor(widget.album)
        : Future<AlbumColor?>.value(null);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final menuStyle = appMenuStyle;
    final menuItemStyle = appMenuItemStyle;
    final placeholder = Icon(
      Symbols.queue_music,
      size: 48,
      color: scheme.onSurface,
    );
    final hasWorks = widget.album.works.isNotEmpty;
    final isSelected =
        widget.multiSelectController?.selected.contains(widget.album) == true;
    final isMultiSelectView =
        widget.multiSelectController?.enableMultiSelectView == true;
    return MenuTheme(
      data: MenuThemeData(style: menuStyle),
      child: MenuAnchor(
        consumeOutsideTap: true,
        style: menuStyle,
        menuChildren: [
          MenuItemButton(
            style: menuItemStyle,
            onPressed: hasWorks
                ? () => context.push(
                      app_paths.ALBUM_DETAIL_PAGE,
                      extra: widget.album,
                    )
                : null,
            leadingIcon: const Icon(Symbols.open_in_new),
            child: const Text('打开'),
          ),
          if (widget.multiSelectController != null)
            MenuItemButton(
              style: menuItemStyle,
              onPressed: () {
                widget.multiSelectController!.useMultiSelectView(true);
                widget.multiSelectController!.select(widget.album);
              },
              leadingIcon: const Icon(Symbols.select),
              child: const Text('多选'),
            ),
        ],
        builder: (context, controller, _) => AnimatedContainer(
          duration: MotionDuration.fast,
          curve: MotionCurve.standard,
          decoration: BoxDecoration(
            color: isSelected
                ? scheme.secondaryContainer
                : widget.view == ContentView.list && _hovered
                    ? scheme.onSurface.withValues(alpha: Alpha.hover)
                    : Colors.transparent,
            borderRadius: AppRadius.smCircular,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onHover: (v) => setState(() => _hovered = v),
              onTap: () {
                if (controller.isOpen) {
                  controller.close();
                  return;
                }

                if (!isMultiSelectView) {
                  if (hasWorks) {
                    context.push(
                      app_paths.ALBUM_DETAIL_PAGE,
                      extra: widget.album,
                    );
                  }
                  return;
                }

                if (isSelected) {
                  widget.multiSelectController?.unselect(widget.album);
                } else {
                  widget.multiSelectController?.select(widget.album);
                }
              },
              onLongPress: () {
                if (widget.multiSelectController == null) return;
                if (isMultiSelectView) return;
                widget.multiSelectController!.useMultiSelectView(true);
                widget.multiSelectController!.select(widget.album);
              },
              onSecondaryTapDown: (details) {
                if (isMultiSelectView) return;
                controller.open(
                  position: details.localPosition.translate(0, -140),
                );
              },
              borderRadius: AppRadius.smCircular,
              child: Stack(
                children: [
                  widget.view == ContentView.list
                      ? Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Row(
                            children: [
                              FutureBuilder(
                                future: _coverFuture,
                                builder: (context, snapshot) {
                                  if (snapshot.data == null) {
                                    return placeholder;
                                  }
                                  return ClipRRect(
                                    borderRadius: AppRadius.smCircular,
                                    child: Image(
                                      image: snapshot.data!,
                                      width: 48.0,
                                      height: 48.0,
                                      errorBuilder: (_, __, ___) => placeholder,
                                      fit: BoxFit.cover,
                                    ),
                                  );
                                },
                              ),
                              Flexible(
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 12.0),
                                  child: Text(
                                    widget.album.name,
                                    softWrap: false,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: scheme.onSurface),
                                  ),
                                ),
                              ),
                              if (isMultiSelectView)
                                Checkbox(
                                  value: isSelected,
                                  onChanged: (v) {
                                    if (v == true) {
                                      widget.multiSelectController
                                          ?.select(widget.album);
                                    } else {
                                      widget.multiSelectController
                                          ?.unselect(widget.album);
                                    }
                                  },
                                ),
                            ],
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: SizedBox(
                                width: double.infinity,
                                child: FutureBuilder(
                                  future: _coverFuture,
                                  builder: (context, snapshot) {
                                    if (snapshot.data == null) {
                                      return placeholder;
                                    }
                                    return ClipRRect(
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(8.0),
                                      ),
                                      child: Image(
                                        image: snapshot.data!,
                                        errorBuilder: (_, __, ___) =>
                                            placeholder,
                                        fit: BoxFit.cover,
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            FutureBuilder(
                              future: _albumColorFuture,
                              builder: (context, snapshot) {
                                if (snapshot.data == null) {
                                  return Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        4.0, 8.0, 4.0, 4.0),
                                    child: Text(
                                      widget.album.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: scheme.onSurface,
                                        fontWeight: AppType.weightBold,
                                      ),
                                    ),
                                  );
                                }

                                final primaryColor = snapshot.data!.primary;
                                final onPrimaryColor = snapshot.data!.onPrimary;
                                return Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12.0,
                                    vertical: 8.0,
                                  ),
                                  decoration: BoxDecoration(
                                    color: primaryColor,
                                    borderRadius: const BorderRadius.vertical(
                                      bottom: Radius.circular(8.0),
                                    ),
                                  ),
                                  child: Text(
                                    widget.album.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: onPrimaryColor,
                                      fontWeight: AppType.weightBold,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                  if (isMultiSelectView && widget.view != ContentView.list)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Material(
                        type: MaterialType.transparency,
                        child: Checkbox(
                          value: isSelected,
                          onChanged: (v) {
                            if (v == true) {
                              widget.multiSelectController
                                  ?.select(widget.album);
                            } else {
                              widget.multiSelectController
                                  ?.unselect(widget.album);
                            }
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
