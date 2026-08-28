import 'dart:ui';

import 'package:pure_music/component/alphabet_index_bar.dart';
import 'package:pure_music/component/list_locate_buttons.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/uni_page.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/component/stacked_list_view.dart';
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
    this.secondaryContentSectionBuilder,
    this.tertiaryContentTitle,
    this.tertiaryContent,
    this.tertiaryContentBuilder,
    required this.enableShufflePlay,
    this.enablePlayAll = false,
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
    this.enableSearch = false,
    this.searchQuery = '',
    this.onSearchChanged,
    this.locateButtonsController,
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
  final Widget? Function(BuildContext context, S content, int index)?
  secondaryContentSectionBuilder;

  final String? tertiaryContentTitle;
  final List<T>? tertiaryContent;
  final ContentBuilder<T>? tertiaryContentBuilder;

  final bool enableShufflePlay;
  final bool enablePlayAll;
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
  final bool enableSearch;
  final String searchQuery;
  final ValueChanged<String>? onSearchChanged;

  /// 覆盖默认活动滚动控制器（bodyOverride 使用外部列表时传入）。
  final ScrollController? locateButtonsController;

  @override
  State<UniDetailPage<P, S, T>> createState() => _UniDetailPageState<P, S, T>();
}

class _UniDetailPageState<P, S, T> extends State<UniDetailPage<P, S, T>> {
  static const _headerCollapseExtent = 120.0;

  late SortMethodDesc<S>? currSortMethod = resolveSortMethod(
    widget.pref,
    widget.sortMethods,
  );
  late SortOrder currSortOrder = widget.pref.sortOrder;
  late ContentView currContentView = widget.pref.contentView;
  int _currentTabIndex = 0;
  final _searchController = TextEditingController();
  final _secondaryScrollController = SmoothScrollController();
  final _tertiaryScrollController = SmoothScrollController();
  final _combinedScrollController = SmoothScrollController();
  final _itemKeys = <int, GlobalKey>{};
  Map<String, int> _alphabetSectionIndexes = const {};
  double _contentCrossAxisExtent = 0;

  bool get _hasTertiaryContent =>
      canShowRelatedContentTab(widget.tertiaryContent?.length ?? 0);

  ScrollController get _activeScrollController {
    if (widget.bodyOverride != null) {
      return widget.locateButtonsController ?? _combinedScrollController;
    }
    if (widget.enableTabs && _hasTertiaryContent) {
      return _currentTabIndex == 0
          ? _secondaryScrollController
          : _tertiaryScrollController;
    }
    return _combinedScrollController;
  }

  bool _enableHeaderCollapse(BuildContext context) =>
      AppSettings.instance.enableDetailHeaderCollapseMotion &&
      !MediaQuery.disableAnimationsOf(context) &&
      MediaQuery.sizeOf(context).width >= 560;

  double get _headerCollapseProgress {
    final positions = _activeScrollController.positions;
    if (positions.length != 1) return 0;
    return (positions.first.pixels / _headerCollapseExtent).clamp(0.0, 1.0);
  }

  /// 当前正在播放乐曲在列表中的索引；不在列表中或当前视图不可定位时返回 null。
  int? _locateTargetAt() {
    if (widget.enableTabs && _hasTertiaryContent && _currentTabIndex == 1) {
      return null;
    }
    if (widget.bodyOverride != null) return null;
    final nowPlaying = PlayService.instance.playbackService.nowPlaying;
    if (nowPlaying == null) return null;
    final targetAt = widget.secondaryContent.indexWhere(
      (item) => item is Audio && item.path == nowPlaying.path,
    );
    return targetAt < 0 ? null : targetAt;
  }

  /// 按钮浮层不拦截滚轮：把滚轮位移转发给列表的平滑滚动。
  void _forwardWheelToList(double delta) {
    if (!AppSettings.instance.enableStackedScrollEffect ||
        MediaQuery.disableAnimationsOf(context)) {
      return;
    }
    final controller = _activeScrollController;
    if (!controller.hasClients) return;
    final position = controller.position;
    if (position is SmoothScrollPosition) {
      position.pointerScroll(delta);
    }
  }

  /// 定位到指定行（行高不固定时按行 key 滚动，保证精确）。
  void _scrollToIndex(int targetAt) {
    if (targetAt < 0 || targetAt >= widget.secondaryContent.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _itemKeys[targetAt]?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 250),
        curve: Curves.fastOutSlowIn,
      );
    });
  }

  void _jumpToIndex(int targetAt) {
    if (targetAt < 0 || targetAt >= widget.secondaryContent.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_activeScrollController.hasClients) return;
      final position = _activeScrollController.position;
      _activeScrollController.jumpTo(
        _offsetForIndex(
          targetAt,
        ).clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  void _updateAlphabetSections() {
    final valueOf = currSortMethod?.alphabetValueOf;
    if (valueOf == null || widget.secondaryContent.length < 2) {
      _alphabetSectionIndexes = const {};
      return;
    }
    final indexes = <String, int>{};
    for (var i = 0; i < widget.secondaryContent.length; i++) {
      indexes.putIfAbsent(
        alphabetSectionFor(valueOf(widget.secondaryContent[i])),
        () => i,
      );
    }
    _alphabetSectionIndexes = indexes;
  }

  int _indexForOffset(double offset) {
    if (currContentView == ContentView.list) {
      return (offset / 64).floor().clamp(0, widget.secondaryContent.length - 1);
    }
    final crossAxisCount = _gridCrossAxisCount();
    final mainAxisStep =
        gridDelegate.mainAxisExtent! + gridDelegate.mainAxisSpacing;
    return ((offset / mainAxisStep).floor() * crossAxisCount).clamp(
      0,
      widget.secondaryContent.length - 1,
    );
  }

  int _gridCrossAxisCount() {
    final crossAxisCount = maxExtentGridCrossAxisCount(
      crossAxisExtent: _contentCrossAxisExtent,
      maxCrossAxisExtent: gridDelegate.maxCrossAxisExtent,
      crossAxisSpacing: gridDelegate.crossAxisSpacing,
    );
    return crossAxisCount;
  }

  double _offsetForIndex(int index) {
    if (currContentView == ContentView.list) return index * 64.0;
    final crossAxisCount = _gridCrossAxisCount();
    final mainAxisStep =
        gridDelegate.mainAxisExtent! + gridDelegate.mainAxisSpacing;
    return (index ~/ crossAxisCount) * mainAxisStep;
  }

  Widget _keyedItem(int index, Widget child) {
    return KeyedSubtree(
      key: _itemKeys.putIfAbsent(index, GlobalKey.new),
      child: child,
    );
  }

  @override
  void initState() {
    super.initState();
    currSortMethod?.method(widget.secondaryContent, currSortOrder);
    _updateAlphabetSections();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _secondaryScrollController.dispose();
    _tertiaryScrollController.dispose();
    _combinedScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant UniDetailPage<P, S, T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final resolvedSortMethod = resolveSortMethod(
      widget.pref,
      widget.sortMethods,
    );
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
    _updateAlphabetSections();
  }

  void setSortMethod(SortMethodDesc<S> sortMethod) {
    setState(() {
      currSortMethod = sortMethod;
      widget.pref.sortMethod = widget.sortMethods?.indexOf(sortMethod) ?? 0;
      currSortMethod?.method(widget.secondaryContent, currSortOrder);
      _updateAlphabetSections();
    });
    widget.onSortMethodChanged?.call();
  }

  void setSortOrder(SortOrder sortOrder) {
    setState(() {
      currSortOrder = sortOrder;
      widget.pref.sortOrder = sortOrder;
      currSortMethod?.method(widget.secondaryContent, currSortOrder);
      _updateAlphabetSections();
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
    if (widget.enablePlayAll) {
      actions.add(PlayAll<S>(contentList: widget.secondaryContent));
    }
    if (widget.enableShufflePlay) {
      actions.add(ShufflePlay<S>(contentList: widget.secondaryContent));
    }
    if (widget.enableSortMethod) {
      actions.add(
        SortMethodComboBox<S>(
          sortMethods: widget.sortMethods!,
          contentList: widget.secondaryContent,
          currSortMethod: currSortMethod!,
          setSortMethod: setSortMethod,
        ),
      );
    }
    if (widget.enableSortOrder) {
      actions.add(
        SortOrderSwitch<S>(
          sortOrder: currSortOrder,
          setSortOrder: setSortOrder,
        ),
      );
    }
    if (widget.enableSecondaryContentViewSwitch) {
      actions.add(
        ContentViewSwitch<S>(
          contentView: currContentView,
          setContentView: setContentView,
        ),
      );
    }
    if (widget.extraActions != null) {
      actions.addAll(widget.extraActions!);
    }

    return widget.multiSelectController == null
        ? result(null, actions, scheme)
        : ListenableBuilder(
            listenable: widget.multiSelectController!,
            builder: (context, _) =>
                result(widget.multiSelectController!, actions, scheme),
          );
  }

  Widget result(
    MultiSelectController<S>? multiSelectController,
    List<Widget> actions,
    ColorScheme scheme,
  ) {
    final hasTertiaryContent = canShowRelatedContentTab(
      widget.tertiaryContent?.length ?? 0,
    );
    final currentTabIndex = hasTertiaryContent ? _currentTabIndex : 0;
    return ListenableBuilder(
      listenable: AppSettings.backgroundNotifier,
      builder: (context, _) {
        final useAppBackground =
            AppSettings.instance.appBackgroundImagePath != null;
        return ColoredBox(
          color: useAppBackground
              ? scheme.surface.withValues(
                  alpha: scheme.brightness == Brightness.dark ? 0.32 : 0.26,
                )
              : scheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                ListenableBuilder(
                  listenable: AppSettings.listMotionNotifier,
                  builder: (context, _) {
                    Widget buildHeader(double collapseProgress) =>
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
                          searchController: widget.enableSearch
                              ? _searchController
                              : null,
                          searchQuery: widget.searchQuery,
                          onSearchChanged: widget.onSearchChanged,
                          useAppBackground: useAppBackground,
                          collapseProgress: collapseProgress,
                        );
                    if (!_enableHeaderCollapse(context)) {
                      return buildHeader(0);
                    }
                    return AnimatedBuilder(
                      animation: _activeScrollController,
                      builder: (context, _) =>
                          buildHeader(_headerCollapseProgress),
                    );
                  },
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
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final showAlphabetIndex =
                                widget.bodyOverride == null &&
                                currentTabIndex == 0 &&
                                _alphabetSectionIndexes.isNotEmpty;
                            _contentCrossAxisExtent =
                                constraints.maxWidth -
                                (showAlphabetIndex ? 32 : 0);
                            return Row(
                              children: [
                                Expanded(
                                  child: MultiSelectPointerRegion<S>(
                                    controller: multiSelectController,
                                    child: ListenableBuilder(
                                      listenable:
                                          AppSettings.listMotionNotifier,
                                      builder: (context, _) =>
                                          widget.bodyOverride ??
                                          (widget.enableTabs
                                              ? DirectionalTabView(
                                                  index: currentTabIndex,
                                                  children: [
                                                    _buildSecondaryContent(
                                                      multiSelectController,
                                                      scheme,
                                                    ),
                                                    if (hasTertiaryContent)
                                                      _buildTertiaryContent(
                                                        scheme,
                                                      ),
                                                  ],
                                                )
                                              : _buildCombinedContent(
                                                  multiSelectController,
                                                  scheme,
                                                )),
                                    ),
                                  ),
                                ),
                                if (showAlphabetIndex)
                                  AlphabetIndexBar(
                                    controller: _activeScrollController,
                                    sectionIndexes: _alphabetSectionIndexes,
                                    indexForOffset: _indexForOffset,
                                    onSelectIndex: _jumpToIndex,
                                    onWheel: _forwardWheelToList,
                                    descending:
                                        currSortOrder == SortOrder.decending,
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                      ListLocateButtons(
                        controller: _activeScrollController,
                        locateTargetAt: _locateTargetAt,
                        onScrollToIndex: _scrollToIndex,
                        onWheel: _forwardWheelToList,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
        final canSwitch = canSwitchTab(
          currentIndex: _currentTabIndex,
          targetIndex: i,
        );
        return OutlinedButton.icon(
          onPressed: canSwitch
              ? () => setState(() => _currentTabIndex = i)
              : null,
          icon: Icon(tabs[i].$2, size: 18),
          label: Text(tabs[i].$1),
          style: ButtonStyle(
            foregroundColor: WidgetStatePropertyAll(
              selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
            ),
            backgroundColor: WidgetStatePropertyAll(
              selected
                  ? scheme.secondaryContainer
                  : scheme.surfaceContainerHighest,
            ),
            side: WidgetStatePropertyAll(
              BorderSide(color: selected ? scheme.primary : scheme.outline),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
            ),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildSecondaryContent(
    MultiSelectController<S>? multiSelectController,
    ColorScheme scheme,
  ) {
    final enableStackedEffect = AppSettings.instance.enableStackedScrollEffect;
    final enableSmoothScrolling =
        enableStackedEffect && !MediaQuery.disableAnimationsOf(context);
    return Material(
      borderRadius: AppRadius.smCircular,
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxCrossAxisExtent = gridDelegate.maxCrossAxisExtent;
          final crossAxisCount = maxExtentGridCrossAxisCount(
            crossAxisExtent: constraints.maxWidth,
            maxCrossAxisExtent: maxCrossAxisExtent,
            crossAxisSpacing: gridDelegate.crossAxisSpacing,
          );
          return CustomScrollView(
            controller: _secondaryScrollController,
            physics: enableSmoothScrolling ? const SmoothScrollPhysics() : null,
            slivers: [
              switch (currContentView) {
                ContentView.list
                    when widget.secondaryContentSectionBuilder != null =>
                  SliverList.builder(
                    itemCount: widget.secondaryContent.length,
                    itemBuilder: (context, i) {
                      final item = widget.secondaryContent[i];
                      final section = widget.secondaryContentSectionBuilder!(
                        context,
                        item,
                        i,
                      );
                      return _keyedItem(
                        i,
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ?section,
                            SizedBox(
                              height: 64,
                              child: widget.secondaryContentBuilder(
                                context,
                                item,
                                i,
                                multiSelectController,
                                ContentView.list,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ContentView.list => SliverFixedExtentList.builder(
                  itemExtent: 64,
                  itemCount: widget.secondaryContent.length,
                  itemBuilder: (context, i) => _keyedItem(
                    i,
                    StackedSliverItem(
                      controller: _secondaryScrollController,
                      rowIndex: i,
                      itemExtent: 64,
                      enabled: enableStackedEffect,
                      child: widget.secondaryContentBuilder(
                        context,
                        widget.secondaryContent[i],
                        i,
                        multiSelectController,
                        ContentView.list,
                      ),
                    ),
                  ),
                ),
                ContentView.table => SliverGrid.builder(
                  gridDelegate: gridDelegate,
                  itemCount: widget.secondaryContent.length,
                  itemBuilder: (context, i) => _keyedItem(
                    i,
                    StackedSliverItem(
                      controller: _secondaryScrollController,
                      rowIndex: i ~/ crossAxisCount,
                      itemExtent:
                          gridDelegate.mainAxisExtent! +
                          gridDelegate.mainAxisSpacing,
                      enabled: enableStackedEffect,
                      child: widget.secondaryContentBuilder(
                        context,
                        widget.secondaryContent[i],
                        i,
                        multiSelectController,
                        ContentView.table,
                      ),
                    ),
                  ),
                ),
              },
              const SliverPadding(padding: EdgeInsets.only(bottom: 96.0)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTertiaryContent(ColorScheme scheme) {
    if (widget.tertiaryContent == null ||
        widget.tertiaryContent!.isEmpty ||
        widget.tertiaryContentBuilder == null) {
      return const SizedBox.shrink();
    }
    final enableStackedEffect = AppSettings.instance.enableStackedScrollEffect;
    final enableSmoothScrolling =
        enableStackedEffect && !MediaQuery.disableAnimationsOf(context);
    return Material(
      borderRadius: AppRadius.smCircular,
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final crossAxisCount = maxExtentGridCrossAxisCount(
            crossAxisExtent: constraints.maxWidth,
            maxCrossAxisExtent: 300,
            crossAxisSpacing: 8,
          );
          return CustomScrollView(
            controller: _tertiaryScrollController,
            physics: enableSmoothScrolling ? const SmoothScrollPhysics() : null,
            slivers: [
              SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 300,
                  mainAxisExtent: 72,
                  mainAxisSpacing: 8.0,
                  crossAxisSpacing: 8.0,
                ),
                itemCount: widget.tertiaryContent!.length,
                itemBuilder: (context, i) => StackedSliverItem(
                  controller: _tertiaryScrollController,
                  rowIndex: i ~/ crossAxisCount,
                  itemExtent: 80,
                  enabled: enableStackedEffect,
                  child: widget.tertiaryContentBuilder!(
                    context,
                    widget.tertiaryContent![i],
                    i,
                    null,
                    ContentView.list,
                  ),
                ),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 96.0)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCombinedContent(
    MultiSelectController<S>? multiSelectController,
    ColorScheme scheme,
  ) {
    final enableStackedEffect = AppSettings.instance.enableStackedScrollEffect;
    final enableSmoothScrolling =
        enableStackedEffect && !MediaQuery.disableAnimationsOf(context);
    return Material(
      borderRadius: AppRadius.smCircular,
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final crossAxisCount = maxExtentGridCrossAxisCount(
            crossAxisExtent: constraints.maxWidth,
            maxCrossAxisExtent: 300,
            crossAxisSpacing: 8,
          );
          return CustomScrollView(
            controller: _combinedScrollController,
            physics: enableSmoothScrolling ? const SmoothScrollPhysics() : null,
            slivers: [
              switch (currContentView) {
                ContentView.list
                    when widget.secondaryContentSectionBuilder != null =>
                  SliverList.builder(
                    itemCount: widget.secondaryContent.length,
                    itemBuilder: (context, i) {
                      final item = widget.secondaryContent[i];
                      final section = widget.secondaryContentSectionBuilder!(
                        context,
                        item,
                        i,
                      );
                      return _keyedItem(
                        i,
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ?section,
                            SizedBox(
                              height: 64,
                              child: widget.secondaryContentBuilder(
                                context,
                                item,
                                i,
                                multiSelectController,
                                ContentView.list,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ContentView.list => SliverFixedExtentList.builder(
                  itemExtent: 64,
                  itemCount: widget.secondaryContent.length,
                  itemBuilder: (context, i) => _keyedItem(
                    i,
                    StackedSliverItem(
                      controller: _combinedScrollController,
                      rowIndex: i,
                      itemExtent: 64,
                      enabled: enableStackedEffect,
                      child: widget.secondaryContentBuilder(
                        context,
                        widget.secondaryContent[i],
                        i,
                        multiSelectController,
                        ContentView.list,
                      ),
                    ),
                  ),
                ),
                ContentView.table => SliverGrid.builder(
                  gridDelegate: gridDelegate,
                  itemCount: widget.secondaryContent.length,
                  itemBuilder: (context, i) => _keyedItem(
                    i,
                    StackedSliverItem(
                      controller: _combinedScrollController,
                      rowIndex: i ~/ crossAxisCount,
                      itemExtent:
                          gridDelegate.mainAxisExtent! +
                          gridDelegate.mainAxisSpacing,
                      enabled: enableStackedEffect,
                      child: widget.secondaryContentBuilder(
                        context,
                        widget.secondaryContent[i],
                        i,
                        multiSelectController,
                        ContentView.table,
                      ),
                    ),
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
                        fontSize: AppType.sectionTitle,
                        fontWeight: AppType.weightBold,
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
                  itemBuilder: (context, i) => StackedSliverItem(
                    controller: _combinedScrollController,
                    rowIndex: i ~/ crossAxisCount,
                    itemExtent: 80,
                    enabled: enableStackedEffect,
                    child: widget.tertiaryContentBuilder!(
                      context,
                      widget.tertiaryContent![i],
                      i,
                      null,
                      ContentView.list,
                    ),
                  ),
                ),
              ],
              const SliverPadding(padding: EdgeInsets.only(bottom: 96.0)),
            ],
          );
        },
      ),
    );
  }
}

enum PicShape { oval, rrect }

class _ActionsRow extends StatelessWidget {
  const _ActionsRow({
    required this.actions,
    this.searchController,
    required this.searchQuery,
    this.onSearchChanged,
    required this.scheme,
  });

  final List<Widget> actions;
  final TextEditingController? searchController;
  final String searchQuery;
  final ValueChanged<String>? onSearchChanged;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 560;
    final showSearch = searchController != null;

    if (!showSearch) {
      return Wrap(spacing: 8.0, runSpacing: 8.0, children: actions);
    }

    final searchField = _CompactSearchBar(
      controller: searchController!,
      query: searchQuery,
      onChanged: onSearchChanged,
      scheme: scheme,
    );

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(spacing: 8.0, runSpacing: 8.0, children: actions),
          const SizedBox(height: 8.0),
          searchField,
        ],
      );
    }

    return Row(
      children: [
        Expanded(child: Wrap(spacing: 8.0, runSpacing: 8.0, children: actions)),
        const SizedBox(width: 12.0),
        SizedBox(width: 220, child: searchField),
      ],
    );
  }
}

class _CompactSearchBar extends StatefulWidget {
  const _CompactSearchBar({
    required this.controller,
    required this.query,
    this.onChanged,
    required this.scheme,
  });

  final TextEditingController controller;
  final String query;
  final ValueChanged<String>? onChanged;
  final ColorScheme scheme;

  @override
  State<_CompactSearchBar> createState() => _CompactSearchBarState();
}

class _CompactSearchBarState extends State<_CompactSearchBar> {
  late final FocusNode _focusNode;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    setState(() => _isFocused = _focusNode.hasFocus);
    HotkeysHelper.onFocusChanges(_focusNode.hasFocus);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    if (_focusNode.hasFocus) HotkeysHelper.onFocusChanges(false);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = _isFocused
        ? widget.scheme.secondaryContainer.withValues(alpha: 0.7)
        : widget.scheme.surfaceContainerHighest.withValues(alpha: 0.5);

    return SizedBox(
      height: 40.0,
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        style: TextStyle(
          color: widget.scheme.onSurface,
          fontSize: AppType.body,
          fontWeight: AppType.weightRegular,
        ),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: bgColor,
          hintText: '搜索…',
          hintStyle: TextStyle(
            color: widget.scheme.onSurfaceVariant.withValues(alpha: 0.5),
            fontSize: AppType.body,
            fontWeight: AppType.weightRegular,
          ),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Icon(
              Symbols.search,
              size: 18,
              color: widget.scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 34,
            maxHeight: 40,
          ),
          suffixIcon: widget.query.isNotEmpty
              ? IconButton(
                  icon: Icon(
                    Symbols.close,
                    size: 16,
                    color: widget.scheme.onSurfaceVariant.withValues(
                      alpha: 0.6,
                    ),
                  ),
                  onPressed: () {
                    widget.controller.clear();
                    widget.onChanged?.call('');
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    maxWidth: 30,
                    minHeight: 40,
                    maxHeight: 40,
                  ),
                )
              : null,
          suffixIconConstraints: const BoxConstraints(maxHeight: 40),
          border: OutlineInputBorder(
            borderRadius: AppRadius.mdCircular,
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: AppRadius.mdCircular,
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: AppRadius.mdCircular,
            borderSide: BorderSide(
              color: widget.scheme.primary.withValues(alpha: 0.5),
              width: 1.5,
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}

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
    this.searchController,
    this.searchQuery = '',
    this.onSearchChanged,
    required this.useAppBackground,
    this.collapseProgress = 0,
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
  final TextEditingController? searchController;
  final String searchQuery;
  final ValueChanged<String>? onSearchChanged;
  final bool useAppBackground;
  final double collapseProgress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth.isFinite && constraints.maxWidth < 560;
        final expandedCoverSize = compact ? 156.0 : 200.0;
        final progress = compact
            ? 0.0
            : Curves.easeOutCubic.transform(collapseProgress.clamp(0.0, 1.0));
        final coverSize = lerpDouble(expandedCoverSize, 72.0, progress)!;
        final gap = lerpDouble(compact ? 12.0 : 16.0, 12.0, progress)!;
        final titleSize = lerpDouble(
          compact ? AppType.pageTitle : AppType.hero,
          AppType.pageTitle,
          progress,
        )!;
        final expandedContentOpacity = 1.0 - progress;

        return Stack(
          children: [
            if (!useAppBackground) ...[
              Positioned.fill(
                child: FutureBuilder(
                  future: backgroundPic,
                  builder: (context, snapshot) {
                    if (snapshot.data == null) return const SizedBox.shrink();

                    return Image(
                      image: snapshot.data!,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    );
                  },
                ),
              ),
              Positioned.fill(
                child: switch (brightness) {
                  Brightness.dark => ColoredBox(
                    color: scheme.surface.withValues(alpha: 0.38),
                  ),
                  Brightness.light => ColoredBox(
                    color: scheme.surface.withValues(alpha: 0.70),
                  ),
                },
              ),
              Positioned.fill(
                child: BackdropFilter(
                  filter: _UniDetailPageHeader._blurFilter,
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
            ],
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
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: titleSize,
                          color: scheme.onSurface,
                          fontWeight: AppType.weightBold,
                        ),
                      ),
                      ClipRect(
                        child: Align(
                          alignment: Alignment.topLeft,
                          heightFactor: expandedContentOpacity,
                          child: Opacity(
                            opacity: expandedContentOpacity,
                            child: Text(
                              subtitle,
                              style: TextStyle(
                                fontSize: AppType.body,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: 8.0 * expandedContentOpacity),
                      _ActionsRow(
                        actions: multiSelectController == null
                            ? actions
                            : multiSelectController!.enableMultiSelectView
                            ? multiSelectViewActions!
                            : actions,
                        searchController: searchController,
                        searchQuery: searchQuery,
                        onSearchChanged: onSearchChanged,
                        scheme: scheme,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
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
    final scheme = Theme.of(context).colorScheme;
    final overlayColor = scheme.onSurface.withValues(alpha: 0.25);

    Widget cover = SizedBox(
      width: widget.size,
      height: widget.size,
      child: FutureBuilder(
        future: widget.futurePic,
        builder: (context, snapshot) {
          return switch (snapshot.connectionState) {
            ConnectionState.done =>
              snapshot.data == null
                  ? widget.placeholder
                  : switch (widget.picShape) {
                      PicShape.oval => ClipOval(
                        child: Image(
                          image: snapshot.data!,
                          width: widget.size,
                          height: widget.size,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => widget.placeholder,
                        ),
                      ),
                      PicShape.rrect => ClipRRect(
                        borderRadius: AppRadius.smCircular,
                        child: Image(
                          image: snapshot.data!,
                          width: widget.size,
                          height: widget.size,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => widget.placeholder,
                        ),
                      ),
                    },
            _ => const Center(child: CircularProgressIndicator()),
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
                      widget.picShape == PicShape.oval
                          ? widget.size / 2
                          : AppRadius.sm,
                    ),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        widget.busy
                            ? SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: scheme.onSurface,
                                ),
                              )
                            : Icon(
                                Symbols.brush,
                                size: 28,
                                color: scheme.onSurface,
                              ),
                        const SizedBox(height: 4),
                        Text(
                          widget.busy ? '选择中' : '更换封面',
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: AppType.body,
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
