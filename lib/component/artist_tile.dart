import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/enums.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/app_paths.dart' as app_paths;

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
  bool _hovered = false;
  late Future<ImageProvider?> _coverFuture;

  @override
  void initState() {
    super.initState();
    _coverFuture = widget.artist.works.first.cover;
  }

  @override
  void didUpdateWidget(covariant ArtistTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artist != widget.artist) {
      _coverFuture = widget.artist.works.first.cover;
    }
  }

  @override
  Widget build(BuildContext context) {
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
    final placeholder = Icon(
      Symbols.broken_image,
      color: scheme.onSurface,
      size: 48,
    );
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
            onPressed: () => context.push(
              app_paths.ARTIST_DETAIL_PAGE,
              extra: widget.artist,
            ),
            leadingIcon: const Icon(Symbols.open_in_new),
            child: const Text("打开"),
          ),
          if (widget.multiSelectController != null)
            MenuItemButton(
              style: menuItemStyle,
              onPressed: () {
                widget.multiSelectController!.useMultiSelectView(true);
                widget.multiSelectController!.select(widget.artist);
              },
              leadingIcon: const Icon(Symbols.select),
              child: const Text("多选"),
            ),
        ],
        builder: (context, controller, _) => AnimatedContainer(
          duration: MotionDuration.fast,
          curve: MotionCurve.standard,
          decoration: BoxDecoration(
            color: isSelected
                ? scheme.secondaryContainer
                : widget.view == ContentView.list && _hovered
                    ? scheme.onSurface.withValues(alpha: 0.04)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8.0),
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
                  context.push(
                    app_paths.ARTIST_DETAIL_PAGE,
                    extra: widget.artist,
                  );
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
              borderRadius: BorderRadius.circular(8.0),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  children: [
                    FutureBuilder(
                      future: _coverFuture,
                      builder: (context, snapshot) {
                        if (snapshot.data == null) {
                          return placeholder;
                        }
                        return ClipOval(
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
                          widget.artist.name,
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
                            widget.multiSelectController?.select(widget.artist);
                          } else {
                            widget.multiSelectController
                                ?.unselect(widget.artist);
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
    );
  }
}
