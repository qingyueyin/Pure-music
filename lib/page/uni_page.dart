import 'dart:async';

import 'package:pure_music/component/alphabet_index_bar.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/component/list_locate_buttons.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/stacked_list_view.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/page_sort.dart';
import 'package:pure_music/core/settings.dart';
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
  String Function(T item)? alphabetValueOf;

  SortMethodDesc({
    required this.icon,
    required this.name,
    required this.method,
    this.backgroundMethod,
    this.alphabetValueOf,
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
  static bool Function()? _activeBackHandler;

  final Set<T> selected = {};
  bool enableMultiSelectView = false;
  List<T>? _rangeItems;
  int? _rangeStartIndex;
  int? _rangeTargetIndex;
  final Set<T> _rangeItemsTouched = {};
  bool _rangeDeselecting = false;
  final Set<T> _selectionBeforeRange = {};
  bool Function()? _backHandler;

  bool get isRangeSelecting => _rangeStartIndex != null;

  static bool consumeBack() {
    final handler = _activeBackHandler;
    if (handler == null) return false;
    final consumed = handler();
    if (!consumed && identical(_activeBackHandler, handler)) {
      _activeBackHandler = null;
    }
    return consumed;
  }

  void useMultiSelectView(bool multiSelectView) {
    if (multiSelectView) {
      _backHandler ??= () {
        if (!enableMultiSelectView) return false;
        useMultiSelectView(false);
        clear();
        return true;
      };
      _activeBackHandler = _backHandler;
    } else {
      endRangeSelection();
      if (identical(_activeBackHandler, _backHandler)) {
        _activeBackHandler = null;
      }
    }
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
    endRangeSelection();
    selected.clear();
    notifyListeners();
  }

  void selectAll(Iterable<T> items) {
    endRangeSelection();
    selected.addAll(items);
    notifyListeners();
  }

  void beginRangeSelection(List<T> items, int startIndex) {
    if (startIndex < 0 || startIndex >= items.length) return;
    endRangeSelection();
    _rangeItems = items;
    _rangeStartIndex = startIndex;
    _rangeTargetIndex = startIndex;
    _selectionBeforeRange
      ..clear()
      ..addAll(selected);
    // 起始项已选中时，本次拖动改为取消选中经过的条目。
    _rangeDeselecting = selected.contains(items[startIndex]);
    _rangeItemsTouched.add(items[startIndex]);
    if (!enableMultiSelectView) {
      useMultiSelectView(true);
    } else {
      _activeBackHandler = _backHandler;
    }
    if (_rangeDeselecting) {
      selected.remove(items[startIndex]);
    } else {
      selected.add(items[startIndex]);
    }
    notifyListeners();
  }

  void updateRangeSelection(int targetIndex) {
    final items = _rangeItems;
    final startIndex = _rangeStartIndex;
    final oldTargetIndex = _rangeTargetIndex;
    if (items == null ||
        startIndex == null ||
        oldTargetIndex == null ||
        items.isEmpty) {
      return;
    }
    final target = targetIndex.clamp(0, items.length - 1);
    if (target == oldTargetIndex) return;

    final oldMin = startIndex < oldTargetIndex ? startIndex : oldTargetIndex;
    final oldMax = startIndex > oldTargetIndex ? startIndex : oldTargetIndex;
    final newMin = startIndex < target ? startIndex : target;
    final newMax = startIndex > target ? startIndex : target;
    _rangeTargetIndex = target;

    for (var i = oldMin; i <= oldMax; i++) {
      final item = items[i];
      if (i >= newMin && i <= newMax) continue;
      if (!_rangeItemsTouched.remove(item)) continue;
      final wasSelectedBefore = _selectionBeforeRange.contains(item);
      // 拖出范围的条目恢复为拖动前的选中状态。
      if (_rangeDeselecting) {
        if (wasSelectedBefore) selected.add(item);
      } else if (!wasSelectedBefore) {
        selected.remove(item);
      }
    }
    for (var i = newMin; i <= newMax; i++) {
      final item = items[i];
      if (!_rangeItemsTouched.add(item)) continue;
      if (_rangeDeselecting) {
        selected.remove(item);
      } else {
        selected.add(item);
      }
    }
    notifyListeners();
  }

  void endRangeSelection() {
    _rangeItems = null;
    _rangeStartIndex = null;
    _rangeTargetIndex = null;
    _rangeItemsTouched.clear();
    _selectionBeforeRange.clear();
    _rangeDeselecting = false;
  }

  @override
  void dispose() {
    if (identical(_activeBackHandler, _backHandler)) {
      _activeBackHandler = null;
    }
    _backHandler = null;
    super.dispose();
  }
}

class MultiSelectPointerRegion<T> extends StatelessWidget {
  const MultiSelectPointerRegion({
    super.key,
    required this.controller,
    required this.child,
  });

  final MultiSelectController<T>? controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerUp: (_) => controller?.endRangeSelection(),
      onPointerCancel: (_) => controller?.endRangeSelection(),
      child: child,
    );
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
    this.enableStackedEffect = true,
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

  /// 是否启用堆叠滚动效果（平滑滚轮始终启用）。
  final bool enableStackedEffect;

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
  late final ScrollController listScrollController = SmoothScrollController();
  late final ScrollController tableScrollController = SmoothScrollController();
  int _sortRequest = 0;
  bool _backgroundSortPending = false;
  bool _backgroundSortWorkerActive = false;
  String _pendingSortReason = 'sort';
  Map<String, int> _alphabetSectionIndexes = const {};
  double _contentCrossAxisExtent = 0;

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
    _updateAlphabetSections();
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
    _alphabetSectionIndexes = const {};
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
        _updateAlphabetSections();
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
    _updateAlphabetSections();
    indexStopwatch.stop();
    logger.i(
      '[perf] page prepare title=${widget.title} reason=$reason '
      'items=${widget.contentList.length} sort=0us '
      'pathIndex=${indexStopwatch.elapsedMicroseconds}us cached=true',
    );
  }

  void _updateAlphabetSections() {
    final valueOf = currSortMethod?.alphabetValueOf;
    if (valueOf == null || widget.contentList.length < 2) {
      _alphabetSectionIndexes = const {};
      return;
    }
    final indexes = <String, int>{};
    for (var i = 0; i < widget.contentList.length; i++) {
      indexes.putIfAbsent(
        alphabetSectionFor(valueOf(widget.contentList[i])),
        () => i,
      );
    }
    _alphabetSectionIndexes = indexes;
  }

  /// 平滑滚动到指定位置。
  void _smoothScrollTo(double offset) {
    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    if (position is SmoothScrollPosition) {
      position.smoothScrollTo(offset);
      return;
    }
    scrollController.animateTo(
      offset.clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.fastOutSlowIn,
    );
  }

  /// 按钮浮层不拦截滚轮：鼠标停留在浮层按钮上滚动时，
  /// 把滚轮位移转发给当前列表。
  void _forwardWheelToList(double delta) {
    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    if (currContentView == ContentView.list &&
        AppSettings.instance.enableStackedScrollEffect &&
        !MediaQuery.disableAnimationsOf(context) &&
        position is SmoothScrollPosition) {
      position.pointerScroll(delta);
      return;
    }
    position.pointerScroll(delta);
  }

  void _scrollToIndex(int targetAt) {
    if (targetAt < 0 || targetAt >= widget.contentList.length) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollController.hasClients) return;
      _smoothScrollTo(_offsetForIndex(targetAt));
    });
  }

  void _jumpToIndex(int targetAt) {
    if (targetAt < 0 || targetAt >= widget.contentList.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollController.hasClients) return;
      final position = scrollController.position;
      scrollController.jumpTo(
        _offsetForIndex(
          targetAt,
        ).clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  ({int crossAxisCount, double mainAxisStep})? _gridMetrics() {
    final delegate = widget.gridDelegate ?? gridDelegate;
    if (delegate is! SliverGridDelegateWithMaxCrossAxisExtent ||
        _contentCrossAxisExtent <= 0) {
      return null;
    }
    final crossAxisExtent = (_contentCrossAxisExtent - 20).clamp(
      0.0,
      double.infinity,
    );
    final crossAxisCount = maxExtentGridCrossAxisCount(
      crossAxisExtent: crossAxisExtent,
      maxCrossAxisExtent: delegate.maxCrossAxisExtent,
      crossAxisSpacing: delegate.crossAxisSpacing,
    );
    final usableCrossAxisExtent =
        (crossAxisExtent - delegate.crossAxisSpacing * (crossAxisCount - 1))
            .clamp(0.0, double.infinity);
    final tileWidth = usableCrossAxisExtent / crossAxisCount;
    final tileHeight =
        delegate.mainAxisExtent ?? tileWidth / delegate.childAspectRatio;
    return (
      crossAxisCount: crossAxisCount,
      mainAxisStep: tileHeight + delegate.mainAxisSpacing,
    );
  }

  double _offsetForIndex(int index) {
    if (currContentView == ContentView.list) return index * 64.0;
    final metrics = _gridMetrics();
    if (metrics != null) {
      return (index ~/ metrics.crossAxisCount) * metrics.mainAxisStep;
    }
    if (!scrollController.hasClients || widget.contentList.isEmpty) return 0;
    return scrollController.position.maxScrollExtent *
        index /
        widget.contentList.length;
  }

  int _indexForOffset(double offset) {
    if (currContentView == ContentView.list) {
      return (offset / 64.0).floor().clamp(0, widget.contentList.length - 1);
    }
    final metrics = _gridMetrics();
    if (metrics != null && metrics.mainAxisStep > 0) {
      return ((offset / metrics.mainAxisStep).floor() * metrics.crossAxisCount)
          .clamp(0, widget.contentList.length - 1);
    }
    if (!scrollController.hasClients ||
        scrollController.position.maxScrollExtent <= 0) {
      return 0;
    }
    return (offset /
            scrollController.position.maxScrollExtent *
            widget.contentList.length)
        .floor()
        .clamp(0, widget.contentList.length - 1);
  }

  /// 定位当前正在播放乐曲在列表中的索引；非乐曲列表或不在列表中时返回 null。
  int? _locateTargetAt() {
    final nowPlaying = PlayService.instance.playbackService.nowPlaying;
    if (nowPlaying == null) return null;
    final path = pendingFolderKey(nowPlaying.path);
    if (path.isEmpty) return null;
    if (widget.contentList is List<Audio>) {
      return AudioLibrary.instance.audiosPageIndexForPath(path);
    }
    for (var i = 0; i < widget.contentList.length; i++) {
      final item = widget.contentList[i];
      if (item is Artist &&
          item.works.any((a) => pendingFolderKey(a.path) == path)) {
        return i;
      }
      if (item is AudioFolder &&
          item.audios.any((a) => pendingFolderKey(a.path) == path)) {
        return i;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _prepareIncomingContent('init');
    if (widget.locateTo == null) return;

    final locateTo = widget.locateTo;
    final targetAt = locateTo is Audio
        ? AudioLibrary.instance.audiosPageIndexForPath(locateTo.path) ?? -1
        : widget.contentList.indexOf(locateTo as T);
    if (targetAt < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scrollController.hasClients) return;
      scrollController.jumpTo(_offsetForIndex(targetAt));
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
    setState(() {
      currContentView = contentView;
      widget.pref.contentView = contentView;
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

      final enableListMotion =
          AppSettings.instance.enableStackedScrollEffect &&
          !MediaQuery.disableAnimationsOf(context);
      final enableStackedEffect =
          widget.enableStackedEffect &&
          AppSettings.instance.enableStackedScrollEffect;
      final listView = enableStackedEffect
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
              physics: enableListMotion ? const SmoothScrollPhysics() : null,
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
      final tableView = enableStackedEffect
          ? StackedGridView(
              controller: tableScrollController,
              gridDelegate:
                  (widget.gridDelegate ?? gridDelegate)
                      as SliverGridDelegateWithMaxCrossAxisExtent,
              itemCount: widget.contentList.length,
              padding: const EdgeInsets.only(bottom: 96.0, right: 20),
              itemBuilder: (context, i) => widget.contentBuilder(
                context,
                widget.contentList[i],
                i,
                multiSelectController,
                ContentView.table,
              ),
            )
          : GridView.builder(
              controller: tableScrollController,
              physics: enableListMotion ? const SmoothScrollPhysics() : null,
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

      return LayoutBuilder(
        builder: (context, constraints) {
          final showAlphabetIndex = _alphabetSectionIndexes.isNotEmpty;
          _contentCrossAxisExtent =
              constraints.maxWidth - (showAlphabetIndex ? 32 : 0);
          return Row(
            children: [
              Expanded(
                child: MultiSelectPointerRegion<T>(
                  controller: multiSelectController,
                  child: widget.enableContentViewSwitch
                      ? DirectionalTabView(
                          index: currContentView == ContentView.list ? 0 : 1,
                          children: [listView, tableView],
                        )
                      : tableView,
                ),
              ),
              if (showAlphabetIndex)
                AlphabetIndexBar(
                  controller: scrollController,
                  sectionIndexes: _alphabetSectionIndexes,
                  indexForOffset: _indexForOffset,
                  onSelectIndex: _jumpToIndex,
                  onWheel: _forwardWheelToList,
                  descending: currSortOrder == SortOrder.decending,
                ),
            ],
          );
        },
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
      body: ListenableBuilder(
        listenable: AppSettings.listMotionNotifier,
        builder: (context, _) => Material(
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
              ListLocateButtons(
                controller: scrollController,
                locateTargetAt: _locateTargetAt,
                onScrollToIndex: _scrollToIndex,
                onWheel: _forwardWheelToList,
              ),
            ],
          ),
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
