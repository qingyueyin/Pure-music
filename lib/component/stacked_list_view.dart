import 'dart:math' as math;

import 'package:flutter/physics.dart' show FrictionSimulation, Tolerance;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';
import 'package:pure_music/component/motion.dart' show SidebarMotionScope, StackedEffectScope;
import 'package:pure_music/core/settings.dart' show AppSettings;

bool _usesSmoothScrollPhysics(ScrollPhysics physics) {
  ScrollPhysics? current = physics;
  while (current != null) {
    if (current is SmoothScrollPhysics) return true;
    current = current.parent;
  }
  return false;
}

/// 在启用 [SmoothScrollPhysics] 时使用 [SmoothScrollPosition] 的滚动控制器。
///
/// 其他 physics 下沿用 Flutter 的标准 position，避免关闭效果后仍改变
/// 原列表的滚动生命周期。
class SmoothScrollController extends ScrollController {
  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    if (!_usesSmoothScrollPhysics(physics)) {
      return super.createScrollPosition(physics, context, oldPosition);
    }
    return SmoothScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
    );
  }
}

/// 平滑滚轮滚动 physics。
///
/// Windows 滚轮事件是离散的大步长输入，直接应用会产生"一蹦一蹦"的跳变。
/// 本 physics 覆写 [ScrollPosition.pointerScroll]，把滚轮位移累积为目标位置，
/// 由滚动活动按摩擦模拟连续推进并自然减速，
/// 让滚动位置本身连续变化，行变换随之平滑。拖拽与惯性滚动不受影响。
class SmoothScrollPhysics extends ScrollPhysics {
  const SmoothScrollPhysics({super.parent = const ClampingScrollPhysics()});

  @override
  SmoothScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      SmoothScrollPhysics(parent: buildParent(ancestor));
}

class _SmoothWheelScrollActivity extends DrivenScrollActivity {
  _SmoothWheelScrollActivity(
    super.delegate,
    super.simulation, {
    required super.vsync,
  }) : super.simulation();

  @override
  bool get shouldIgnorePointer => false;
}

class SmoothScrollPosition extends ScrollPositionWithSingleContext {
  SmoothScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
  });

  /// 速度每秒的衰减指数（越大衰减越快、收尾越干脆，惯性越短）。
  static const double velocityDecayPerSecond = 5.0;

  /// 滚轮输入换算为速度的系数。
  /// 指数衰减下总位移 = v0 / decay，取 delta * decay * multiplier，
  /// 使单次滚轮位移 = delta * multiplier，提升灵敏度与跟手度；
  /// 快速连续滚轮时速度累积，产生连贯的加速感。
  static const double wheelSensitivity = 1.6;

  double get _deltaToVelocity => velocityDecayPerSecond * wheelSensitivity;

  static const _wheelTolerance = Tolerance(distance: 0.05, velocity: 0.5);

  @override
  void pointerScroll(double delta) {
    // 关闭"列表效果"开关或系统"减少动画"时，即使 position 未被重建，
    // 也直接回退到默认滚动行为，避免平滑滚轮残留。
    if (!AppSettings.instance.enableStackedScrollEffect ||
        MediaQuery.maybeDisableAnimationsOf(context.storageContext) == true) {
      super.pointerScroll(delta);
      return;
    }
    if (delta == 0.0) {
      goBallistic(0.0);
      return;
    }
    if ((delta < 0 && pixels <= minScrollExtent) ||
        (delta > 0 && pixels >= maxScrollExtent)) {
      goBallistic(0.0);
      return;
    }

    final inputVelocity = delta * _deltaToVelocity;
    final currentActivity = activity;
    final carriedVelocity =
        currentActivity is _SmoothWheelScrollActivity &&
            currentActivity.velocity.sign == inputVelocity.sign
        ? currentActivity.velocity
        : 0.0;
    final simulation = FrictionSimulation(
      math.exp(-velocityDecayPerSecond),
      pixels,
      carriedVelocity + inputVelocity,
      tolerance: _wheelTolerance,
    );
    updateUserScrollDirection(
      delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );
    beginActivity(
      _SmoothWheelScrollActivity(this, simulation, vsync: context.vsync),
    );
  }

  /// 平滑滚动到指定位置，供"回到顶部""定位正在播放"等按钮调用。
  Future<void> smoothScrollTo(double target) {
    return animateTo(
      target.clamp(minScrollExtent, maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.fastOutSlowIn,
    );
  }
}

int maxExtentGridCrossAxisCount({
  required double crossAxisExtent,
  required double maxCrossAxisExtent,
  required double crossAxisSpacing,
}) {
  return math.max(
    1,
    (crossAxisExtent / (maxCrossAxisExtent + crossAxisSpacing)).ceil(),
  );
}

/// 堆叠滚动效果列表。
///
/// 滚动时，滚出视口顶部的行逐渐缩小并淡出（像卡片被压到后面），
/// 从底部进入的行由缩小渐显到正常（像卡片从后面翻出来）。
/// 行在视口中部的正常位置保持原尺寸与不透明度。
///
/// 行高固定（[itemExtent]），变换只作用于绘制，不改变布局。
/// 每行按自身进度独立监听滚动：视口内的行不重建，过渡带内的行只重建轻量变换层。
/// 列表滚动由 [SmoothScrollPhysics] 平滑驱动，变换与位置严格同步。
class StackedListView extends StatelessWidget {
  const StackedListView({
    super.key,
    required this.controller,
    required this.itemExtent,
    required this.itemCount,
    required this.itemBuilder,
    this.padding,
  });

  final ScrollController controller;
  final double itemExtent;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry? padding;

  /// 顶部/底部过渡区内行最小缩放比例（1 表示不缩小）。
  static const double maxShrink = 0.7;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final physics = reduceMotion ? null : const SmoothScrollPhysics();
    return StackedEffectScope(
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(physics: physics),
        child: ListView.builder(
          controller: controller,
          padding: padding,
          itemExtent: itemExtent,
          itemCount: itemCount,
          itemBuilder: (context, index) =>
              _itemAt(context, index, reduceMotion),
        ),
      ),
    );
  }

  Widget _itemAt(BuildContext context, int index, bool reduceMotion) {
    final child = itemBuilder(context, index);
    if (reduceMotion) return child;
    return _StackedRowSlot(
      controller: controller,
      itemTopBase: index * itemExtent,
      itemExtent: itemExtent,
      child: child,
    );
  }
}

/// 行的堆叠进度：0 表示无视差；负值顶部过渡，正值底部过渡；绝对值 1 表示已离开过渡带。
double _stackedRowProgress({
  required double itemTop,
  required double itemExtent,
  required double viewportHeight,
}) {
  if (viewportHeight < itemExtent * 2) return 0.0;
  // 过渡区取 2 倍行高，让缩放淡出更从容。
  final transitionExtent = itemExtent * 2.0;
  // 顶部滚出进度：行顶滚出越多值越大。
  final topProgress = (-itemTop / transitionExtent).clamp(0.0, 1.0);
  // 底部进入进度：行底未进入视口的部分占比。
  final bottomProgress =
      ((itemTop - (viewportHeight - itemExtent)) / transitionExtent).clamp(
        0.0,
        1.0,
      );
  final progress = math.max(topProgress, bottomProgress).toDouble();
  if (progress <= 0.0) return 0.0;
  return topProgress > bottomProgress ? -progress : progress;
}

/// 只在自身堆叠进度变化时重建的行。
///
/// 视口内的行进度恒为 0，滚动时不再逐帧重建；行离开过渡带时只重建一次。
class _StackedRowSlot extends StatefulWidget {
  const _StackedRowSlot({
    required this.controller,
    required this.itemTopBase,
    required this.itemExtent,
    required this.child,
  });

  final ScrollController controller;

  /// 未减滚动偏移的行顶。
  final double itemTopBase;
  final double itemExtent;
  final Widget child;

  @override
  State<_StackedRowSlot> createState() => _StackedRowSlotState();
}

class _StackedRowSlotState extends State<_StackedRowSlot> {
  final ValueNotifier<double> _progress = ValueNotifier<double>(0.0);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncProgress);
    _syncProgress();
  }

  @override
  void didUpdateWidget(covariant _StackedRowSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncProgress);
      widget.controller.addListener(_syncProgress);
    }
    // 视口尺寸变化不一定会通知滚动控制器，重建时补算一次。
    _syncProgress();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncProgress);
    _progress.dispose();
    super.dispose();
  }

  void _syncProgress() {
    final positions = widget.controller.positions;
    final next = positions.isEmpty
        ? 0.0
        : _stackedRowProgress(
            itemTop: widget.itemTopBase - positions.first.pixels,
            itemExtent: widget.itemExtent,
            viewportHeight: positions.first.viewportDimension,
          );
    if (_progress.value != next) _progress.value = next;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: _progress,
      child: widget.child,
      builder: (context, progress, child) => progress == 0.0
          ? child!
          : _StackedVisual(
              signedProgress: progress,
              itemExtent: widget.itemExtent,
              child: child!,
            ),
    );
  }
}

/// 为列表视图提供平滑滚轮 physics 的便捷包装。
class StackedScrollConfiguration extends StatelessWidget {
  const StackedScrollConfiguration({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(
        context,
      ).copyWith(physics: const SmoothScrollPhysics()),
      child: child,
    );
  }
}

/// 自带平滑滚轮的 [ListView]（不等高内容列表，如设置页/统计页）。
///
/// 打开"列表效果"开关时使用 [SmoothScrollPhysics]，滚动平滑跟手；
/// 关闭或系统"减少动画"时回退默认滚动。内部持有自己的
/// [SmoothScrollController]，不依赖外部。
class SmoothScrollListView extends StatefulWidget {
  const SmoothScrollListView({super.key, this.padding, required this.children});

  final EdgeInsetsGeometry? padding;
  final List<Widget> children;

  @override
  State<SmoothScrollListView> createState() => _SmoothScrollListViewState();
}

class _SmoothScrollListViewState extends State<SmoothScrollListView> {
  late SmoothScrollController _controller;
  bool _smoothEnabled = false;

  @override
  void initState() {
    super.initState();
    _controller = SmoothScrollController();
    AppSettings.listMotionNotifier.addListener(_syncSmooth);
  }

  bool _computeSmooth() =>
      AppSettings.instance.enableStackedScrollEffect &&
      !MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSmooth();
  }

  /// 平滑状态变化时更换 controller，让滚动视图重新创建 position。
  ///
  /// 只改 [ListView.physics] 不会重建已创建的 [SmoothScrollPosition]，
  /// 平滑滚轮会残留；换 controller 后 [Scrollable] 会把旧 position 作为
  /// oldPosition 传入，滚动位置得以保留，physics 为 null 时则回退标准滚动。
  void _syncSmooth() {
    final next = _computeSmooth();
    if (next == _smoothEnabled || !mounted) return;
    final previous = _controller;
    setState(() {
      _smoothEnabled = next;
      _controller = SmoothScrollController();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !identical(previous, _controller)) previous.dispose();
    });
  }

  @override
  void dispose() {
    AppSettings.listMotionNotifier.removeListener(_syncSmooth);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: _controller,
      physics: _smoothEnabled ? const SmoothScrollPhysics() : null,
      padding: widget.padding,
      children: widget.children,
    );
  }
}

/// 带堆叠动画的网格视图。
class StackedGridView extends StatelessWidget {
  const StackedGridView({
    super.key,
    required this.controller,
    required this.gridDelegate,
    required this.itemCount,
    required this.itemBuilder,
    this.padding,
  });

  final ScrollController controller;
  final SliverGridDelegateWithMaxCrossAxisExtent gridDelegate;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry? padding;

  static const double maxShrink = 0.7;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final physics = reduceMotion ? null : const SmoothScrollPhysics();
    final metrics = _gridMetrics(context);
    return StackedEffectScope(
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(physics: physics),
        child: GridView.builder(
          controller: controller,
          padding: padding,
          gridDelegate: gridDelegate,
          itemCount: itemCount,
          itemBuilder: (context, index) =>
              _itemAt(context, index, metrics, reduceMotion),
        ),
      ),
    );
  }

  ({int crossAxisCount, double mainAxisStep}) _gridMetrics(
    BuildContext context,
  ) {
    final pad = padding?.horizontal ?? 0;
    final columnExtent = math.max(
      0.0,
      SidebarMotionScope.columnLayoutWidthOf(context) - pad,
    );
    final crossAxisCount = maxExtentGridCrossAxisCount(
      crossAxisExtent: columnExtent,
      maxCrossAxisExtent: gridDelegate.maxCrossAxisExtent,
      crossAxisSpacing: gridDelegate.crossAxisSpacing,
    );
    final usableCrossAxisExtent = math.max(
      0.0,
      columnExtent - gridDelegate.crossAxisSpacing * (crossAxisCount - 1),
    );
    final tileWidth = usableCrossAxisExtent / crossAxisCount;
    final tileHeight =
        gridDelegate.mainAxisExtent ??
        tileWidth / gridDelegate.childAspectRatio;
    return (
      crossAxisCount: crossAxisCount,
      mainAxisStep: tileHeight + gridDelegate.mainAxisSpacing,
    );
  }

  Widget _itemAt(
    BuildContext context,
    int index,
    ({int crossAxisCount, double mainAxisStep}) metrics,
    bool reduceMotion,
  ) {
    final child = itemBuilder(context, index);
    if (reduceMotion) return child;
    final row = index ~/ metrics.crossAxisCount;
    return _StackedRowSlot(
      controller: controller,
      itemTopBase: row * metrics.mainAxisStep,
      itemExtent: metrics.mainAxisStep,
      child: child,
    );
  }
}

/// 给 sliver 列表项包堆叠变换（用于 CustomScrollView / SliverFixedExtentList /
/// SliverGrid 等 sliver 场景）。
///
/// [rowIndex] 是该 item 所在的行号（单列列表即 index，网格为 index ~/ crossAxisCount）。
/// [itemExtent] 是行的主轴步长（含间距）。
class StackedSliverItem extends StatelessWidget {
  const StackedSliverItem({
    super.key,
    required this.controller,
    required this.rowIndex,
    required this.itemExtent,
    required this.child,
    this.enabled = true,
    this.leadingScrollExtent = 0,
  });

  final ScrollController controller;
  final int rowIndex;
  final double itemExtent;
  final Widget child;
  final bool enabled;
  final double leadingScrollExtent;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (!enabled || reduceMotion) return child;
    return StackedEffectScope(
      child: _StackedRowSlot(
        controller: controller,
        itemTopBase: leadingScrollExtent + rowIndex * itemExtent,
        itemExtent: itemExtent,
        child: child,
      ),
    );
  }
}

class StackedItemTransform extends StatelessWidget {
  const StackedItemTransform({
    super.key,
    required this.itemTop,
    required this.itemExtent,
    required this.viewportHeight,
    required this.child,
  });

  /// 行顶相对视口顶部的偏移（滚出顶部为负，视口下方为正）。
  final double itemTop;
  final double itemExtent;
  final double viewportHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final signedProgress = _stackedRowProgress(
      itemTop: itemTop,
      itemExtent: itemExtent,
      viewportHeight: viewportHeight,
    );
    if (signedProgress == 0.0) return child;
    return _StackedVisual(
      signedProgress: signedProgress,
      itemExtent: itemExtent,
      child: child,
    );
  }
}

/// 过渡带内的缩放淡出：只在进度非零时存在，进度归零即被换回原始行。
class _StackedVisual extends StatelessWidget {
  const _StackedVisual({
    required this.signedProgress,
    required this.itemExtent,
    required this.child,
  });

  final double signedProgress;
  final double itemExtent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final progress = signedProgress.abs();
    if (progress >= 1.0) {
      // 隐藏滚出视口的内容，但保留行高，避免列表滚动范围被压缩。
      return SizedBox(height: itemExtent, child: const SizedBox.shrink());
    }
    final scale = 1.0 - (1.0 - StackedListView.maxShrink) * progress;
    final alignment = signedProgress < 0
        ? Alignment.topCenter
        : Alignment.bottomCenter;
    return Opacity(
      opacity: 1.0 - progress,
      // 仅过渡期成层：saveLayer 只做合成，不再逐帧重录行内容，离开过渡带即移除。
      child: Transform.scale(
        scale: scale,
        alignment: alignment,
        child: RepaintBoundary(child: child),
      ),
    );
  }
}
