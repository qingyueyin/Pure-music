import 'dart:async';

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/component/stacked_list_view.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/page_sort.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/workload_policy.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/page/uni_page_components.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

typedef ContentBuilder<T> =
    Widget Function(
      BuildContext context,
      T item,
      int index,
      MultiSelectController<T>? multiSelectController,
      ContentView view,
    );

typedef SortMethod<T> = void Function(List<T> list, SortOrder order);
typedef BackgroundSortMethod<T> =
    Future<List<T>?> Function(
      List<T> list,
      SortOrder order,
      PageSortControl control,
    );

class SortMethodDesc<T> {
  IconData icon;
  String name;
  SortMethod<T> method;
  BackgroundSortMethod<T>? backgroundMethod;

  SortMethodDesc({
    required this.icon,
    required this.name,
    required this.method,
    this.backgroundMethod,
  });
}

SortMethodDesc<T>? resolveSortMethod<T>(
  PagePreference pref,
  List<SortMethodDesc<T>>? sortMethods,
) {
  if (sortMethods == null || sortMethods.isEmpty) {
    return null;
  }
  final index = pref.sortMethod.clamp(0, sortMethods.length - 1).toInt();
  if (pref.sortMethod != index) pref.sortMethod = index;
  return sortMethods[index];
}

const gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 300,
  mainAxisExtent: 64,
  mainAxisSpacing: 8.0,
  crossAxisSpacing: 8.0,
);

class LibraryPagePreparing extends StatelessWidget {
  const LibraryPagePreparing({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: title,
      subtitle: subtitle,
      actions: const <Widget>[],
      body: const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class MultiSelectController<T> extends ChangeNotifier {
  final Set<T> selected = {};
  bool enableMultiSelectView = false;

  void useMultiSelectView(bool multiSelectView) {
    enableMultiSelectView = multiSelectView;
    notifyListeners();
  }

  void select(T item) {
    selected.add(item);
    notifyListeners();
  }

  void unselect(T item) {
    selected.remove(item);
    notifyListeners();
  }

  void clear() {
    selected.clear();
    notifyListeners();
  }

  void selectAll(Iterable<T> items) {
    selected.addAll(items);
    notifyListeners();
  }
}

/// `AudiosPage`, `ArtistsPage`, `AlbumsPage`, `FoldersPage`, `FolderDetailPage` 页面的主要组件，
/// 提供随机播放以及更改排序方式、排序顺序、内容视图的支持。
///
/// `enableShufflePlay` 只能在 `T` 是 `Audio` 时为 `ture`
///
/// `enableSortMethod` 为 `true` 时，`sortMethods` 不可为空且必须包含一个 `SortMethodDesc`
///
/// `defaultContentView` 表示默认的内容视图。如果设置为 `ContentView.list`，就以单行列表视图展示内容；
/// 如果是 `ContentView.table`，就以最大 300 * 64 的子组件以 8 为间距组成的表格展示内容。
///
/// `multiSelectController` 可以使页面进入多选状态。如果它不为空，则 `multiSelectViewActions` 也不可为空
class UniPage<T> extends StatefulWidget {
  const UniPage({
    super.key,
    required this.pref,
    required this.title,
    this.subtitle,
    required this.contentList,
    required this.contentBuilder,
    this.primaryAction,
    required this.enableShufflePlay,
    required this.enableSortMethod,
    required this.enableSortOrder,
    required this.enableContentViewSwitch,
    this.sortMethods,
    this.locateTo,
    this.multiSelectController,
    this.multiSelectViewActions,
    this.gridDelegate,
    this.contentRevision,
    this.contentIsPrepared = false,
    this.enableStackedList = false,
  });

  final PagePreference pref;

  final String title;
  final String? subtitle;

  final List<T> contentList;
  final ContentBuilder<T> contentBuilder;

  final Widget? primaryAction;

  final bool enableShufflePlay;
  final bool enableSortMethod;
  final bool enableSortOrder;
  final bool enableContentViewSwitch;

  final List<SortMethodDesc<T>>? sortMethods;

  final T? locateTo;

  final MultiSelectController<T>? multiSelectController;
  final List<Widget>? multiSelectViewActions;

  final SliverGridDelegate? gridDelegate;
  final Object? contentRevision;
  final bool contentIsPrepared;

  /// 列表视图启用堆叠滚动效果（滚出顶部缩小淡出、底部进入渐显）。
  final bool enableStackedList;

  @override
  State<UniPage<T>> createState() => _UniPageState<T>();
}

/// 诊断埋点：性能工具累计 UniPage 构建耗时；未安装观察者时零开销。
int uniPageBuildMicros = 0;
int uniPageContentAreaMicros = 0;

class _UniPageState<T> extends State<UniPage<T>> {
  static const int _backgroundSortItemThreshold = 4096;
  late SortMethodDesc<T>? currSortMethod = resolveSortMethod(
    widget.pref,
    widget.sortMethods,
  );
  late SortOrder currSortOrder = widget.pref.sortOrder;
  late ContentView currContentView = widget.enableContentViewSwitch
      ? widget.pref.contentView
      : ContentView.table;
  late final ScrollController listScrollController = widget.enableStackedList
      ? SmoothScrollController()
      : ScrollController();
  late final ScrollController tableScrollController = ScrollController();
  bool _showScrollToTop = false;
  int _sortRequest = 0;
  bool _backgroundSortPending = false;
  bool _backgroundSortWorkerActive = false;
  String _pendingSortReason = 'sort';

  ScrollController get scrollController => currContentView == ContentView.list
      ? listScrollController
      : tableScrollController;

  void _rememberPreparedPageOrder() {
    AudioLibrary.instance.rememberPreparedPageOrder(
      widget.contentList,
      sortMethod: widget.pref.sortMethod,
      sortOrder: currSortOrder,
    );
  }

  void _prepareContent(String reason) {
    final sortStopwatch = Stopwatch()..start();
    currSortMethod?.method(widget.contentList, currSortOrder);
    sortStopwatch.stop();
    final indexStopwatch = Stopwatch()..start();
    _rememberPreparedPageOrder();
    indexStopwatch.stop();
    logger.i(
      '[perf] page prepare title=${widget.title} reason=$reason '
      'items=${widget.contentList.length} '
      'sort=${sortStopwatch.elapsedMicroseconds}us '
      'pathIndex=${indexStopwatch.elapsedMicroseconds}us',
    );
  }

  void _cancelBackgroundSort() {
    _sortRequest++;
    _backgroundSortPending = false;
  }

  void _scheduleBackgroundSort(String reason) {
    _sortRequest++;
    _backgroundSortPending = true;
    _pendingSortReason = reason;
    if (!_backgroundSortWorkerActive) {
      unawaited(_runBackgroundSortWorker());
    }
  }

  Future<void> _runBackgroundSortWorker() async {
    _backgroundSortWorkerActive = true;
    try {
      while (mounted && _backgroundSortPending) {
        _backgroundSortPending = false;
        final request = _sortRequest;
        final backgroundMethod = currSortMethod?.backgroundMethod;
        if (backgroundMethod == null ||
            widget.contentList.length < _backgroundSortItemThreshold) {
          continue;
        }
        final reason = _pendingSortReason;
        final order = currSortOrder;
        final source = widget.contentList;
        final sortStopwatch = Stopwatch()..start();
        late final List<T>? sorted;
        try {
          sorted = await backgroundMethod(
            source,
            order,
            PageSortControl(
              isCurrent: () => mounted && request == _sortRequest,
              batchSize: () => libraryObjectBatchSizeFor(
                processorBudget: applicationProcessorBudget,
                hasPlaybackSession: PlayService.instance.hasPlaybackSession,
              ),
            ),
          );
        } catch (error, trace) {
          logger.e('后台页面排序失败', error: error, stackTrace: trace);
          if (!mounted || request != _sortRequest) continue;
          setState(() => _prepareContent(reason));
          continue;
        }
        sortStopwatch.stop();
        if (!mounted || request != _sortRequest) continue;
        if (sorted == null || sorted.length != widget.contentList.length) {
          setState(() => _prepareContent(reason));
          continue;
        }
        final indexStopwatch = Stopwatch()..start();
        widget.contentList.setAll(0, sorted);
        _rememberPreparedPageOrder();
        indexStopwatch.stop();
        setState(() {});
        logger.i(
          '[perf] page prepare title=${widget.title} reason=$reason '
          'items=${widget.contentList.length} '
          'sort=${sortStopwatch.elapsedMicroseconds}us '
          'pathIndex=${indexStopwatch.elapsedMicroseconds}us background=true',
        );
      }
    } finally {
      _backgroundSortWorkerActive = false;
      if (mounted && _backgroundSortPending) {
        unawaited(_runBackgroundSortWorker());
      }
    }
  }

  void _prepareIncomingContent(String reason) {
    if (!widget.contentIsPrepared) {
      _prepareContent(reason);
      return;
    }
    final indexStopwatch = Stopwatch()..start();
    indexStopwatch.stop();
    logger.i(
      '[perf] page prepare title=${widget.title} reason=$reason '
      'items=${widget.contentList.length} sort=0us '
      'pathIndex=${indexStopwatch.elapsedMicroseconds}us cached=true',
    );
  }

  /// 平滑滚动到指定位置；非平滑控制器回退到默认动画滚动。
  void _smoothScrollTo(double offset) {
    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    if (position is SmoothScrollPosition) {
      position.smoothScrollTo(offset);
    } else {
      scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 250),
        curve: Curves.fastOutSlowIn,
      );
    }
  }

  /// 按钮浮层不拦截滚轮：鼠标停留在浮层按钮上滚动时，
  /// 把滚轮位移转发给列表的平滑滚动。
  void _forwardWheelToList(double delta) {
    if (currContentView != ContentView.list) return;
    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    if (position is SmoothScrollPosition) {
      position.pointerScroll(delta);
    }
  }

  void _scrollToIndex(int targetAt) {
    if (targetAt < 0 || targetAt >= widget.contentList.length) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollController.hasClients) return;

      if (currContentView == ContentView.list) {
        _smoothScrollTo(targetAt * 64.0);
      } else {
        final renderObject = context.findRenderObject();
        if (renderObject is RenderBox) {
          final width = renderObject.size.width;
          final crossAxisCount = (width / 300).ceil().clamp(1, 100);
          final offset = (targetAt ~/ crossAxisCount) * (64.0 + 8.0);
          _smoothScrollTo(offset);
        }
      }
    });
  }

  Widget _locateNowPlayingButton() {
    if (widget.contentList is! List<Audio>) return const SizedBox.shrink();
    final playbackService = PlayService.instance.playbackService;

    return ListenableBuilder(
      listenable: playbackService,
      builder: (context, _) {
        final nowPlaying = playbackService.nowPlaying;
        if (nowPlaying == null) return const SizedBox.shrink();

        final targetAt = AudioLibrary.instance.audiosPageIndexForPath(
          nowPlaying.path,
        );
        if (targetAt == null) return const SizedBox.shrink();

        return ResponsiveBuilder(
          builder: (context, screenType) {
            final bottom = screenType == ScreenType.small ? 88.0 : 112.0;
            final right = screenType == ScreenType.small ? 88.0 : 128.0;
            final reduceMotion = MediaQuery.disableAnimationsOf(context);
            return Positioned(
              right: right,
              bottom: bottom,
              child: Listener(
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    _forwardWheelToList(event.scrollDelta.dy);
                  }
                },
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(nowPlaying.path),
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: MotionDuration.fast,
                  curve: MotionCurve.standard,
                  builder: (context, t, child) => Opacity(
                    opacity: t,
                    child: Transform.scale(
                      scale: reduceMotion ? 1.0 : 0.7 + t * 0.3,
                      filterQuality: FilterQuality.low,
                      child: child,
                    ),
                  ),
                  child: Focus(
                    canRequestFocus: false,
                    descendantsAreFocusable: false,
                    child: IconButton.filledTonal(
                      tooltip: '定位正在播放',
                      onPressed: () => _scrollToIndex(targetAt),
                      style: ButtonStyle(
                        fixedSize: const WidgetStatePropertyAll(Size(40, 40)),
                        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                        shape: WidgetStatePropertyAll(
                          RoundedRectangleBorder(
                          borderRadius: AppRadius.smCircular,
                        ),
                      ),
                    ),
                    icon: const Icon(Symbols.my_location),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
  }

  Widget _scrollToTopButton() {
    return ResponsiveBuilder(
      builder: (context, screenType) {
        final bottom = screenType == ScreenType.small ? 88.0 : 112.0;
        final right = screenType == ScreenType.small ? 88.0 : 128.0;
        final reduceMotion = MediaQuery.disableAnimationsOf(context);
        return Positioned(
          right: right,
          bottom: bottom + 56.0,
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _forwardWheelToList(event.scrollDelta.dy);
              }
            },
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: _showScrollToTop ? 1.0 : 0.0),
              duration: MotionDuration.fast,
              curve: MotionCurve.standard,
              builder: (context, t, child) => IgnorePointer(
                ignoring: t <= 0.01,
                child: Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: reduceMotion ? 1.0 : 0.7 + t * 0.3,
                    filterQuality: FilterQuality.low,
                    child: child,
                  ),
                ),
              ),
              child: Focus(
                canRequestFocus: false,
                descendantsAreFocusable: false,
                child: IconButton.filledTonal(
                  tooltip: '回到顶部',
                  onPressed: () => _smoothScrollTo(0.0),
                style: ButtonStyle(
                  fixedSize: const WidgetStatePropertyAll(Size(40, 40)),
                  padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                      borderRadius: AppRadius.smCircular,
                    ),
                  ),
                ),
                icon: const Icon(Symbols.vertical_align_top),
              ),
            ),
          ),
          ),
        );
      },
    );
  }

  void _onScrollUpdate() {
    if (!mounted) return;
    final shouldShow =
        scrollController.hasClients && scrollController.position.pixels > 320.0;
    if (shouldShow != _showScrollToTop) {
      setState(() => _showScrollToTop = shouldShow);
    }
  }

  @override
  void initState() {
    super.initState();
    _prepareIncomingContent('init');
    listScrollController.addListener(_onScrollUpdate);
    tableScrollController.addListener(_onScrollUpdate);
    if (widget.locateTo == null) return;

    final locateTo = widget.locateTo;
    final targetAt = locateTo is Audio
        ? AudioLibrary.instance.audiosPageIndexForPath(locateTo.path) ?? -1
        : widget.contentList.indexOf(locateTo as T);
    if (targetAt < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scrollController.hasClients) return;
      if (currContentView == ContentView.list) {
        scrollController.jumpTo(targetAt * 64);
      } else {
        final renderObject = context.findRenderObject();
        if (renderObject is RenderBox) {
          final width = renderObject.size.width;
          final crossAxisCount = (width / 300).ceil().clamp(1, 100);
          final offset = (targetAt ~/ crossAxisCount) * (64.0 + 8.0);
          scrollController.jumpTo(offset);
        }
      }
    });
  }

  @override
  void didUpdateWidget(covariant UniPage<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final canReusePreparedContent =
        widget.contentRevision != null &&
        widget.contentRevision == oldWidget.contentRevision &&
        identical(oldWidget.contentList, widget.contentList);
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
      wasSwitchAvailable: oldWidget.enableContentViewSwitch,
      isSwitchAvailable: widget.enableContentViewSwitch,
    );
    if (!canReusePreparedContent) {
      _cancelBackgroundSort();
      _prepareIncomingContent('update');
    }
  }

  @override
  void dispose() {
    _cancelBackgroundSort();
    listScrollController.dispose();
    tableScrollController.dispose();
    super.dispose();
  }

  void setSortMethod(SortMethodDesc<T> sortMethod) {
    final useBackground =
        sortMethod.backgroundMethod != null &&
        widget.contentList.length >= _backgroundSortItemThreshold;
    if (useBackground) {
      setState(() {
        currSortMethod = sortMethod;
        widget.pref.sortMethod = widget.sortMethods?.indexOf(sortMethod) ?? 0;
      });
      _scheduleBackgroundSort('sortMethod');
      return;
    }
    _cancelBackgroundSort();
    setState(() {
      currSortMethod = sortMethod;
      widget.pref.sortMethod = widget.sortMethods?.indexOf(sortMethod) ?? 0;
      _prepareContent('sortMethod');
    });
  }

  void setSortOrder(SortOrder sortOrder) {
    final useBackground =
        currSortMethod?.backgroundMethod != null &&
        widget.contentList.length >= _backgroundSortItemThreshold;
    if (useBackground) {
      setState(() {
        currSortOrder = sortOrder;
        widget.pref.sortOrder = sortOrder;
      });
      _scheduleBackgroundSort('sortOrder');
      return;
    }
    _cancelBackgroundSort();
    setState(() {
      currSortOrder = sortOrder;
      widget.pref.sortOrder = sortOrder;
      _prepareContent('sortOrder');
    });
  }

  void setContentView(ContentView contentView) {
    if (currContentView == contentView) return;
    final nextController = contentView == ContentView.list
        ? listScrollController
        : tableScrollController;
    setState(() {
      currContentView = contentView;
      widget.pref.contentView = contentView;
      _showScrollToTop =
          nextController.hasClients && nextController.position.pixels > 320.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final buildStopwatch = Stopwatch()..start();
    try {
      final List<Widget> actions = [];
      if (widget.primaryAction != null) {
        actions.add(widget.primaryAction!);
      }
      if (widget.enableShufflePlay) {
        actions.add(ShufflePlay<T>(contentList: widget.contentList));
      }
      if (widget.enableSortMethod) {
        actions.add(
          SortMethodComboBox<T>(
            sortMethods: widget.sortMethods!,
            contentList: widget.contentList,
            currSortMethod: currSortMethod!,
            setSortMethod: setSortMethod,
          ),
        );
      }
      if (widget.enableSortOrder) {
        actions.add(
          SortOrderSwitch<T>(
            sortOrder: currSortOrder,
            setSortOrder: setSortOrder,
          ),
        );
      }
      if (widget.enableContentViewSwitch) {
        actions.add(
          ContentViewSwitch<T>(
            contentView: currContentView,
            setContentView: setContentView,
          ),
        );
      }

      return widget.multiSelectController == null
          ? result(null, actions)
          : ListenableBuilder(
              listenable: widget.multiSelectController!,
              builder: (context, _) =>
                  result(widget.multiSelectController!, actions),
            );
    } finally {
      buildStopwatch.stop();
      uniPageBuildMicros += buildStopwatch.elapsed.inMicroseconds;
    }
  }

  Widget _buildContentArea(MultiSelectController<T>? multiSelectController) {
    final stopwatch = Stopwatch()..start();
    try {
      if (widget.contentList.isEmpty) {
        return _UniPageEmptyState(title: widget.title);
      }

      final listView = widget.enableStackedList
          ? StackedListView(
              controller: listScrollController,
              itemExtent: 64,
              itemCount: widget.contentList.length,
              padding: const EdgeInsets.only(bottom: 96.0, right: 20),
              itemBuilder: (context, i) => widget.contentBuilder(
                context,
                widget.contentList[i],
                i,
                multiSelectController,
                ContentView.list,
              ),
            )
          : ListView.builder(
              controller: listScrollController,
              padding: const EdgeInsets.only(bottom: 96.0, right: 20),
              itemCount: widget.contentList.length,
              itemExtent: 64,
              itemBuilder: (context, i) => widget.contentBuilder(
                context,
                widget.contentList[i],
                i,
                multiSelectController,
                ContentView.list,
              ),
            );
      final tableView = GridView.builder(
        controller: tableScrollController,
        padding: const EdgeInsets.only(bottom: 96.0, right: 20),
        gridDelegate: widget.gridDelegate ?? gridDelegate,
        itemCount: widget.contentList.length,
        itemBuilder: (context, i) => widget.contentBuilder(
          context,
          widget.contentList[i],
          i,
          multiSelectController,
          ContentView.table,
        ),
      );

      return Row(
        children: [
          Expanded(
            child: widget.enableContentViewSwitch
                ? DirectionalTabView(
                    index: currContentView == ContentView.list ? 0 : 1,
                    children: [listView, tableView],
                  )
                : tableView,
          ),
        ],
      );
    } finally {
      stopwatch.stop();
      uniPageContentAreaMicros += stopwatch.elapsed.inMicroseconds;
    }
  }

  Widget result(
    MultiSelectController<T>? multiSelectController,
    List<Widget> actions,
  ) {
    final scheme = Theme.of(context).colorScheme;

    return PageScaffold(
      title: widget.title,
      subtitle: widget.subtitle,
      actions: multiSelectController == null
          ? actions
          : multiSelectController.enableMultiSelectView
          ? widget.multiSelectViewActions!
          : actions,
      body: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            _buildContentArea(multiSelectController),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        scheme.surfaceContainer.withValues(alpha: 0.06),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _scrollToTopButton(),
            _locateNowPlayingButton(),
          ],
        ),
      ),
    );
  }
}

class _UniPageEmptyState extends StatelessWidget {
  const _UniPageEmptyState({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return QuietEmptyState(
      icon: Symbols.library_music,
      title: '$title 还没有内容',
      message: '添加音乐或刷新曲库后，这里会显示对应内容。',
      padding: const EdgeInsets.fromLTRB(24.0, 24.0, 44.0, 96.0),
    );
  }
}
