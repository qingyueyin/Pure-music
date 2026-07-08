import 'dart:ui';

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// `ArtistDetailPage`, `AlbumDetailPage` 页面的主要组件。
///
/// `P`: 第一内容；`S`: 第二内容（主要）；`T`: 第三内容
///
/// 例如：对于 `ArtistDetailPage` 来说，
/// `P` 是 `Artist` 类，`S` 是 `Audio` 类，`T` 是 `Album` 类
///
/// `multiSelectController` 可以使页面进入多选状态。如果它不为空，则 `multiSelectViewActions` 也不可为空
class UniDetailPage<P, S, T> extends StatefulWidget {
  const UniDetailPage({
    super.key,
    required this.pref,
    required this.primaryContent,
    required this.primaryPic,
    required this.backgroundPic,
    required this.picShape,
    required this.title,
    required this.subtitle,
    required this.secondaryContent,
    required this.secondaryContentBuilder,
    this.tertiaryContentTitle,
    this.tertiaryContent,
    this.tertiaryContentBuilder,
    required this.enableShufflePlay,
    required this.enableSortMethod,
    required this.enableSortOrder,
    required this.enableSecondaryContentViewSwitch,
    this.sortMethods,
    this.multiSelectController,
    this.multiSelectViewActions,
    this.enableTabs = false,
    this.secondaryContentTitle = '歌曲',
    this.tertiaryTabIcon = Symbols.list,
    this.onSortMethodChanged,
    this.extraActions,
    this.bodyOverride,
    this.onPrimaryPicTap,
    this.primaryPicBusy = false,
  });

  final PagePreference pref;

  final P primaryContent;

  /// 用来展示内容图片，较高清
  final Future<ImageProvider?> primaryPic;

  /// 当作毛玻璃的背景，较模糊
  final Future<ImageProvider?> backgroundPic;

  final PicShape picShape;

  final String title;
  final String subtitle;

  final List<S> secondaryContent;
  final ContentBuilder<S> secondaryContentBuilder;

  final String? tertiaryContentTitle;
  final List<T>? tertiaryContent;
  final ContentBuilder<T>? tertiaryContentBuilder;

  final bool enableShufflePlay;
  final bool enableSortMethod;
  final bool enableSortOrder;
  final bool enableSecondaryContentViewSwitch;

  final List<SortMethodDesc<S>>? sortMethods;

  final MultiSelectController<S>? multiSelectController;
  final List<Widget>? multiSelectViewActions;

  final bool enableTabs;
  final String secondaryContentTitle;
  final IconData tertiaryTabIcon;
  final VoidCallback? onSortMethodChanged;
  final List<Widget>? extraActions;
  final Widget? bodyOverride;
  final VoidCallback? onPrimaryPicTap;
  final bool primaryPicBusy;

  @override
  State<UniDetailPage<P, S, T>> createState() => _UniDetailPageState<P, S, T>();
}

class _UniDetailPageState<P, S, T> extends State<UniDetailPage<P, S, T>> {
  late SortMethodDesc<S>? currSortMethod =
      resolveSortMethod(widget.pref, widget.sortMethods);
  late SortOrder currSortOrder = widget.pref.sortOrder;
  late ContentView currContentView = widget.pref.contentView;
  int _currentTabIndex = 0;

  @override
  void initState() {
    super.initState();
    currSortMethod?.method(widget.secondaryContent, currSortOrder);
  }

  @override
  void didUpdateWidget(covariant UniDetailPage<P, S, T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final resolvedSortMethod =
        resolveSortMethod(widget.pref, widget.sortMethods);
    if (resolvedSortMethod != null) {
      currSortMethod = resolvedSortMethod;
    }
    currContentView = resolveContentViewAvailabilityChange(
      currentView: currContentView,
      preferredView: widget.pref.contentView,
      wasSwitchAvailable: oldWidget.enableSecondaryContentViewSwitch,
      isSwitchAvailable: widget.enableSecondaryContentViewSwitch,
    );
    currSortMethod?.method(widget.secondaryContent, currSortOrder);
  }

  void setSortMethod(SortMethodDesc<S> sortMethod) {
    setState(() {
      currSortMethod = sortMethod;
      widget.pref.sortMethod = widget.sortMethods?.indexOf(sortMethod) ?? 0;
      currSortMethod?.method(widget.secondaryContent, currSortOrder);
    });
    widget.onSortMethodChanged?.call();
  }

  void setSortOrder(SortOrder sortOrder) {
    setState(() {
      currSortOrder = sortOrder;
      widget.pref.sortOrder = sortOrder;
      currSortMethod?.method(widget.secondaryContent, currSortOrder);
    });
  }

  void setContentView(ContentView contentView) {
    setState(() {
      currContentView = contentView;
      widget.pref.contentView = contentView;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final List<Widget> actions = [];
    if (widget.enableShufflePlay) {
      actions.add(ShufflePlay<S>(contentList: widget.secondaryContent));
    }
    if (widget.enableSortMethod) {
      actions.add(SortMethodComboBox<S>(
        sortMethods: widget.sortMethods!,
        contentList: widget.secondaryContent,
        currSortMethod: currSortMethod!,
        setSortMethod: setSortMethod,
      ));
    }
    if (widget.enableSortOrder) {
      actions.add(SortOrderSwitch<S>(
        sortOrder: currSortOrder,
        setSortOrder: setSortOrder,
      ));
    }
    if (widget.enableSecondaryContentViewSwitch) {
      actions.add(ContentViewSwitch<S>(
        contentView: currContentView,
        setContentView: setContentView,
      ));
    }
    if (widget.extraActions != null) {
      actions.addAll(widget.extraActions!);
    }

    return widget.multiSelectController == null
        ? result(null, actions, scheme)
        : ListenableBuilder(
            listenable: widget.multiSelectController!,
            builder: (context, _) => result(
              widget.multiSelectController!,
              actions,
              scheme,
            ),
          );
  }

  Widget result(MultiSelectController<S>? multiSelectController,
      List<Widget> actions, ColorScheme scheme) {
    final hasTertiaryContent = canShowRelatedContentTab(
      widget.tertiaryContent?.length ?? 0,
    );
    final currentTabIndex = hasTertiaryContent ? _currentTabIndex : 0;
    return ColoredBox(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            _UniDetailPageHeader(
              pic: widget.primaryPic,
              backgroundPic: widget.backgroundPic,
              picShape: widget.picShape,
              title: widget.title,
              subtitle: widget.subtitle,
              actions: actions,
              multiSelectController: multiSelectController,
              multiSelectViewActions: widget.multiSelectViewActions,
              onPicTap: widget.onPrimaryPicTap,
              picBusy: widget.primaryPicBusy,
            ),
            if (widget.enableTabs && hasTertiaryContent) ...[
              const SizedBox(height: 16.0),
              Align(
                alignment: Alignment.centerLeft,
                child: _buildTabBar(scheme),
              ),
            ],
            const SizedBox(height: 16.0),
            Expanded(
              child: widget.bodyOverride ??
                  (widget.enableTabs
                      ? IndexedStack(
                          index: currentTabIndex,
                          children: [
                            _buildSecondaryContent(
                                multiSelectController, scheme),
                            if (hasTertiaryContent)
                              _buildTertiaryContent(scheme),
                          ],
                        )
                      : _buildCombinedContent(multiSelectController, scheme)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar(ColorScheme scheme) {
    final hasTertiary = canShowRelatedContentTab(
      widget.tertiaryContent?.length ?? 0,
    );
    final tabs = <(String, IconData)>[
      (widget.secondaryContentTitle, Symbols.music_note),
      if (hasTertiary)
        (widget.tertiaryContentTitle ?? '', widget.tertiaryTabIcon),
    ];
    return Wrap(
      spacing: 8.0,
      runSpacing: 8.0,
      children: List.generate(tabs.length, (i) {
        final selected = _currentTabIndex == i;
        final canSwitch =
            canSwitchTab(currentIndex: _currentTabIndex, targetIndex: i);
        return OutlinedButton.icon(
          onPressed:
              canSwitch ? () => setState(() => _currentTabIndex = i) : null,
          icon: Icon(tabs[i].$2, size: 18),
          label: Text(tabs[i].$1),
          style: ButtonStyle(
            foregroundColor: WidgetStatePropertyAll(
              selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
            ),
            backgroundColor: WidgetStatePropertyAll(
              selected ? scheme.secondaryContainer : Colors.transparent,
            ),
            side: WidgetStatePropertyAll(
              BorderSide(
                color: selected
                    ? scheme.secondaryContainer
                    : scheme.outlineVariant.withValues(alpha: 0.84),
              ),
            ),
            shape: const WidgetStatePropertyAll(StadiumBorder()),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildSecondaryContent(
      MultiSelectController<S>? multiSelectController, ColorScheme scheme) {
    return Material(
      borderRadius: BorderRadius.circular(8.0),
      type: MaterialType.transparency,
      child: CustomScrollView(
        slivers: [
          switch (currContentView) {
            ContentView.list => SliverFixedExtentList.builder(
                itemExtent: 64,
                itemCount: widget.secondaryContent.length,
                itemBuilder: (context, i) => widget.secondaryContentBuilder(
                  context,
                  widget.secondaryContent[i],
                  i,
                  multiSelectController,
                  ContentView.list,
                ),
              ),
            ContentView.table => SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemCount: widget.secondaryContent.length,
                itemBuilder: (context, i) => widget.secondaryContentBuilder(
                  context,
                  widget.secondaryContent[i],
                  i,
                  multiSelectController,
                  ContentView.table,
                ),
              ),
          },
          const SliverPadding(padding: EdgeInsets.only(bottom: 96.0)),
        ],
      ),
    );
  }

  Widget _buildTertiaryContent(ColorScheme scheme) {
    if (widget.tertiaryContent == null ||
        widget.tertiaryContent!.isEmpty ||
        widget.tertiaryContentBuilder == null) {
      return const SizedBox.shrink();
    }
    return Material(
      borderRadius: BorderRadius.circular(8.0),
      type: MaterialType.transparency,
      child: CustomScrollView(
        slivers: [
          SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 300,
              mainAxisExtent: 72,
              mainAxisSpacing: 8.0,
              crossAxisSpacing: 8.0,
            ),
            itemCount: widget.tertiaryContent!.length,
            itemBuilder: (context, i) => widget.tertiaryContentBuilder!(
              context,
              widget.tertiaryContent![i],
              i,
              null,
              ContentView.list,
            ),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 96.0)),
        ],
      ),
    );
  }

  Widget _buildCombinedContent(
      MultiSelectController<S>? multiSelectController, ColorScheme scheme) {
    return Material(
      borderRadius: BorderRadius.circular(8.0),
      type: MaterialType.transparency,
      child: CustomScrollView(
        slivers: [
          switch (currContentView) {
            ContentView.list => SliverFixedExtentList.builder(
                itemExtent: 64,
                itemCount: widget.secondaryContent.length,
                itemBuilder: (context, i) => widget.secondaryContentBuilder(
                  context,
                  widget.secondaryContent[i],
                  i,
                  multiSelectController,
                  ContentView.list,
                ),
              ),
            ContentView.table => SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemCount: widget.secondaryContent.length,
                itemBuilder: (context, i) => widget.secondaryContentBuilder(
                  context,
                  widget.secondaryContent[i],
                  i,
                  multiSelectController,
                  ContentView.table,
                ),
              ),
          },
          if (widget.tertiaryContent != null &&
              widget.tertiaryContent!.isNotEmpty &&
              widget.tertiaryContentTitle != null) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  widget.tertiaryContentTitle!,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 18.0,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 300,
                mainAxisExtent: 72,
                mainAxisSpacing: 8.0,
                crossAxisSpacing: 8.0,
              ),
              itemCount: widget.tertiaryContent!.length,
              itemBuilder: (context, i) => widget.tertiaryContentBuilder!(
                context,
                widget.tertiaryContent![i],
                i,
                null,
                ContentView.list,
              ),
            ),
          ],
          const SliverPadding(padding: EdgeInsets.only(bottom: 96.0)),
        ],
      ),
    );
  }
}

enum PicShape { oval, rrect }

class _UniDetailPageHeader extends StatelessWidget {
  static final _blurFilter = ImageFilter.blur(sigmaX: 100, sigmaY: 100);
  const _UniDetailPageHeader({
    required this.pic,
    required this.backgroundPic,
    required this.picShape,
    required this.title,
    required this.subtitle,
    this.multiSelectController,
    required this.actions,
    this.multiSelectViewActions,
    this.onPicTap,
    this.picBusy = false,
  });

  final Future<ImageProvider?> pic;
  final Future<ImageProvider?> backgroundPic;
  final PicShape picShape;

  final String title;
  final String subtitle;
  final MultiSelectController? multiSelectController;
  final List<Widget> actions;
  final List<Widget>? multiSelectViewActions;
  final VoidCallback? onPicTap;
  final bool picBusy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth.isFinite && constraints.maxWidth < 560;
        final coverSize = compact ? 156.0 : 200.0;
        final gap = compact ? 12.0 : 16.0;

        return SizedBox(
          height: coverSize,
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder(
                future: backgroundPic,
                builder: (context, snapshot) {
                  if (snapshot.data == null) return const SizedBox.shrink();

                  return Image(
                    image: snapshot.data!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  );
                },
              ),
              switch (brightness) {
                Brightness.dark => ColoredBox(
                    color: scheme.surface.withValues(alpha: 0.38),
                  ),
                Brightness.light => ColoredBox(
                    color: scheme.surface.withValues(alpha: 0.70),
                  ),
              },
              BackdropFilter(
                filter: _UniDetailPageHeader._blurFilter,
                child: const ColoredBox(color: Colors.transparent),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _HoverableCover(
                    futurePic: pic,
                    picShape: picShape,
                    scheme: scheme,
                    size: coverSize,
                    onTap: onPicTap,
                    busy: picBusy,
                    placeholder: Icon(
                      Symbols.queue_music,
                      size: coverSize,
                      color: scheme.onSurface,
                    ),
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: compact ? 20.0 : 22.0,
                              color: scheme.onSurface,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 14.0,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 8.0),
                        Wrap(
                          spacing: 8.0,
                          runSpacing: 8.0,
                          children: multiSelectController == null
                              ? actions
                              : multiSelectController!.enableMultiSelectView
                                  ? multiSelectViewActions!
                                  : actions,
                        )
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HoverableCover extends StatefulWidget {
  final Future<ImageProvider?> futurePic;
  final PicShape picShape;
  final ColorScheme scheme;
  final double size;
  final VoidCallback? onTap;
  final bool busy;
  final Widget placeholder;
  const _HoverableCover({
    required this.futurePic,
    required this.picShape,
    required this.scheme,
    required this.size,
    this.onTap,
    this.busy = false,
    required this.placeholder,
  });

  @override
  State<_HoverableCover> createState() => _HoverableCoverState();
}

class _HoverableCoverState extends State<_HoverableCover> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final overlayColor =
        (brightness == Brightness.light ? Colors.black : Colors.white)
            .withValues(alpha: 0.25);

    Widget cover = SizedBox(
      width: widget.size,
      height: widget.size,
      child: FutureBuilder(
        future: widget.futurePic,
        builder: (context, snapshot) {
          return switch (snapshot.connectionState) {
            ConnectionState.done => snapshot.data == null
                ? widget.placeholder
                : switch (widget.picShape) {
                    PicShape.oval => ClipOval(
                        child: Image(
                          image: snapshot.data!,
                          width: widget.size,
                          height: widget.size,
                          errorBuilder: (_, __, ___) => widget.placeholder,
                        ),
                      ),
                    PicShape.rrect => ClipRRect(
                        borderRadius: BorderRadius.circular(8.0),
                        child: Image(
                          image: snapshot.data!,
                          width: widget.size,
                          height: widget.size,
                          errorBuilder: (_, __, ___) => widget.placeholder,
                        ),
                      ),
                  },
            _ => const Center(
                child: CircularProgressIndicator(),
              ),
          };
        },
      ),
    );

    if (widget.onTap == null && !widget.busy) return cover;

    return MouseRegion(
      onEnter: (_) {
        if (!widget.busy) setState(() => _isHovered = true);
      },
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.busy ? null : widget.onTap,
        child: Stack(
          children: [
            cover,
            if (_isHovered || widget.busy)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: overlayColor,
                    borderRadius: BorderRadius.circular(
                      widget.picShape == PicShape.oval ? widget.size / 2 : 8,
                    ),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        widget.busy
                            ? const SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Symbols.brush,
                                size: 28,
                                color: Colors.white,
                              ),
                        const SizedBox(height: 4),
                        Text(
                          widget.busy ? '选择中' : '更换封面',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
