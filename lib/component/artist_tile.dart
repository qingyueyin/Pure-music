import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/scroll_aware_future_builder.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

class ArtistTile extends StatefulWidget {
  const ArtistTile({
    super.key,
    required this.artist,
    this.multiSelectController,
    this.view = ContentView.list,
  });

  final Artist artist;
  final MultiSelectController<Artist>? multiSelectController;
  final ContentView view;

  @override
  State<ArtistTile> createState() => _ArtistTileState();
}

class _ArtistTileState extends State<ArtistTile> {
  String get _currentCoverIdentity => '${widget.artist.primaryPath}|48';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final menuStyle = appMenuStyle;
    final menuItemStyle = appMenuItemStyle;
    final placeholder = Icon(
      Symbols.queue_music,
      color: scheme.onSurface,
      size: 48,
    );
    final hasWorks = widget.artist.works.isNotEmpty;
    final cachedCover = hasWorks
        ? widget.artist.cachedThumbnailPicture(size: 48)
        : null;
    final isSelected =
        widget.multiSelectController?.selected.contains(widget.artist) == true;
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
                    app_paths.ARTIST_DETAIL_PAGE,
                    extra: widget.artist,
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
                widget.multiSelectController!.select(widget.artist);
              },
              leadingIcon: const Icon(Symbols.select),
              child: const Text('多选'),
            ),
        ],
        builder: (context, controller, _) => DirectionalListItemEntrance(
          identity: widget.artist,
          child: AnimatedContainer(
            duration: MotionDuration.fast,
            curve: MotionCurve.standard,
            decoration: BoxDecoration(
              color: isSelected
                  ? scheme.secondaryContainer
                  : Colors.transparent,
              borderRadius: AppRadius.smCircular,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                hoverColor: widget.view == ContentView.list
                    ? scheme.onSurface.withValues(alpha: Alpha.hover)
                    : Colors.transparent,
                onTap: () {
                  if (controller.isOpen) {
                    controller.close();
                    return;
                  }

                  if (!isMultiSelectView) {
                    if (hasWorks) {
                      context.push(
                        app_paths.ARTIST_DETAIL_PAGE,
                        extra: widget.artist,
                      );
                    }
                    return;
                  }

                  if (isSelected) {
                    widget.multiSelectController?.unselect(widget.artist);
                  } else {
                    widget.multiSelectController?.select(widget.artist);
                  }
                },
                onLongPress: () {
                  if (widget.multiSelectController == null) return;
                  if (isMultiSelectView) return;
                  widget.multiSelectController!.useMultiSelectView(true);
                  widget.multiSelectController!.select(widget.artist);
                },
                onSecondaryTapDown: (details) {
                  if (isMultiSelectView) return;
                  controller.open(
                    position: details.localPosition.translate(0, -140),
                  );
                },
                borderRadius: AppRadius.smCircular,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      ScrollAwareFutureBuilder<ImageProvider?>(
                        identity: _currentCoverIdentity,
                        initialData: cachedCover,
                        future: () => hasWorks
                            ? widget.artist.thumbnailPicture(size: 48)
                            : Future<ImageProvider?>.value(null),
                        builder: (context, snapshot) {
                          if (snapshot.data == null) {
                            return placeholder;
                          }
                          return ClipOval(
                            child: Image(
                              image: snapshot.data!,
                              width: 48.0,
                              height: 48.0,
                              errorBuilder: (_, _, _) => placeholder,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                          );
                        },
                      ),
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12.0),
                          child: Text(
                            widget.artist.name,
                            softWrap: widget.view == ContentView.table,
                            maxLines: widget.view == ContentView.table ? 2 : 1,
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
                              widget.multiSelectController?.select(
                                widget.artist,
                              );
                            } else {
                              widget.multiSelectController?.unselect(
                                widget.artist,
                              );
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
