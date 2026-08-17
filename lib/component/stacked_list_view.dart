import 'dart:math' as math;

import 'package:flutter/physics.dart' show FrictionSimulation, Tolerance;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';
import 'package:pure_music/component/motion.dart' show StackedEffectScope;

/// 使用 [SmoothScrollPosition] 的滚动控制器。
///
/// 列表使用外部 [ScrollController] 时，position 由控制器创建，
/// 不会经过 physics 的 `createScrollPosition`，因此需要控制器本身
/// 提供平滑 position。
class SmoothScrollController extends ScrollController {
  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => SmoothScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
  );
}

/// 平滑滚轮滚动 physics。
///
/// Windows 滚轮事件是离散的大步长输入，直接应用会产生"一蹦一蹦"的跳变。
/// 本 physics 覆写 [ScrollPosition.pointerScroll]，把滚轮位移累积为目标位置，
/// 由滚动活动按摩擦模拟连续推进并自然减速，
/// 让滚动位置本身连续变化，行变换随之平滑。拖拽与惯性滚动不受影响。
class SmoothScrollPhysics extends ScrollPhysics {
  const SmoothScrollPhysics({super.parent});

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
}

class SmoothScrollPosition extends ScrollPositionWithSingleContext {
  SmoothScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
  });

  /// 速度每秒的衰减指数（越小惯性越长）。
  static const double velocityDecayPerSecond = 3.0;

  /// 滚轮输入换算为速度的系数。
  /// 指数衰减下总位移 = v0 / decay，取 delta * decay 使单次滚轮
  /// 的位移恰好等于滚轮输入量；快速连续滚轮时速度累积，产生加速感。
  double get _deltaToVelocity => velocityDecayPerSecond;

  static const _wheelTolerance = Tolerance(distance: 0.05, velocity: 0.5);

  @override
  void pointerScroll(double delta) {
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
/// 每个行用独立的 [AnimatedBuilder] 监听滚动，行内容通过 [child] 缓存，
/// 滚动时只重建轻量的变换层，行内容本身不参与重建。
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
          itemBuilder: (context, index) {
            final child = itemBuilder(context, index);
            if (reduceMotion) return child;
            return AnimatedBuilder(
              animation: controller,
              child: child,
              builder: (context, child) {
                final attached = controller.positions;
                if (attached.length != 1) {
                  if (attached.isEmpty) return child!;
                }
                final position = attached.first;
                final offset = position.pixels;
                final viewportHeight = position.viewportDimension;
                // 视口高度异常（视图切换动画中尚未稳定）时不应用变换。
                if (viewportHeight < itemExtent * 2) return child!;
                final itemTop = index * itemExtent - offset;
                return StackedItemTransform(
                  itemTop: itemTop,
                  itemExtent: itemExtent,
                  viewportHeight: viewportHeight,
                  child: child!,
                );
              },
            );
          },
        ),
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
    final maxCrossAxisExtent = gridDelegate.maxCrossAxisExtent;
    return StackedEffectScope(
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(physics: physics),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final crossAxisExtent = math.max(
              0.0,
              constraints.maxWidth - (padding?.horizontal ?? 0),
            );
            final crossAxisCount = maxExtentGridCrossAxisCount(
              crossAxisExtent: crossAxisExtent,
              maxCrossAxisExtent: maxCrossAxisExtent,
              crossAxisSpacing: gridDelegate.crossAxisSpacing,
            );
            final usableCrossAxisExtent = math.max(
              0.0,
              crossAxisExtent -
                  gridDelegate.crossAxisSpacing * (crossAxisCount - 1),
            );
            final tileWidth = usableCrossAxisExtent / crossAxisCount;
            final tileHeight =
                gridDelegate.mainAxisExtent ??
                tileWidth / gridDelegate.childAspectRatio;
            final mainAxisStep = tileHeight + gridDelegate.mainAxisSpacing;
            return GridView.builder(
              controller: controller,
              padding: padding,
              gridDelegate: gridDelegate,
              itemCount: itemCount,
              itemBuilder: (context, index) {
                final child = itemBuilder(context, index);
                if (reduceMotion) return child;
                final row = index ~/ crossAxisCount;
                return AnimatedBuilder(
                  animation: controller,
                  child: child,
                  builder: (context, child) {
                    final attached = controller.positions;
                    if (attached.length != 1) {
                      if (attached.isEmpty) return child!;
                    }
                    final position = attached.first;
                    final offset = position.pixels;
                    final viewportHeight = position.viewportDimension;
                    if (viewportHeight < mainAxisStep * 2) return child!;
                    final itemTop = row * mainAxisStep - offset;
                    return StackedItemTransform(
                      itemTop: itemTop,
                      itemExtent: mainAxisStep,
                      viewportHeight: viewportHeight,
                      child: child!,
                    );
                  },
                );
              },
            );
          },
        ),
      ),
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
  });

  final ScrollController controller;
  final int rowIndex;
  final double itemExtent;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (!enabled || reduceMotion) return child;
    return StackedEffectScope(
      child: AnimatedBuilder(
        animation: controller,
        child: child,
        builder: (context, child) {
          final attached = controller.positions;
          if (attached.length != 1) {
            if (attached.isEmpty) return child!;
          }
          final position = attached.first;
          final offset = position.pixels;
          final viewportHeight = position.viewportDimension;
          if (viewportHeight < itemExtent * 2) return child!;
          final itemTop = rowIndex * itemExtent - offset;
          return StackedItemTransform(
            itemTop: itemTop,
            itemExtent: itemExtent,
            viewportHeight: viewportHeight,
            child: child!,
          );
        },
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

    final progress = math.max(topProgress, bottomProgress);
    if (progress <= 0.0) return child;
    if (progress >= 1.0) return const SizedBox.shrink();

    final scale = 1.0 - (1.0 - StackedListView.maxShrink) * progress;
    final alignment = topProgress > bottomProgress
        ? Alignment.topCenter
        : Alignment.bottomCenter;
    return Opacity(
      opacity: 1.0 - progress,
      child: Transform.scale(scale: scale, alignment: alignment, child: child),
    );
  }
}
