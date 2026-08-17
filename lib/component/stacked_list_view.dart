import 'dart:math' as math;

import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart';

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
  ) =>
      SmoothScrollPosition(
        physics: physics,
        context: context,
        oldPosition: oldPosition,
      );
}

/// 平滑滚轮滚动 physics。
///
/// Windows 滚轮事件是离散的大步长输入，直接应用会产生"一蹦一蹦"的跳变。
/// 本 physics 覆写 [ScrollPosition.pointerScroll]，把滚轮位移累积为目标位置，
/// 由 [Ticker] 每帧按剩余距离的比例逼近（速度与距离成正比，自然减速），
/// 让滚动位置本身连续变化，行变换随之平滑。拖拽与惯性滚动不受影响。
class SmoothScrollPhysics extends ScrollPhysics {
  const SmoothScrollPhysics({super.parent});

  @override
  SmoothScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      SmoothScrollPhysics(parent: buildParent(ancestor));
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

  double _velocity = 0;
  double? _targetPixels;
  Duration? _lastTickElapsed;
  Ticker? _ticker;
  bool _dragging = false;

  /// 按钮触发时的逼近系数（单向指数逼近目标，无回弹）。
  static const double buttonApproachFactor = 0.13;

  @override
  void pointerScroll(double delta) {
    if (delta == 0.0) return;
    // 用户滚轮输入接管，取消按钮目标。
    _targetPixels = null;
    // 速度累积：快滚时速度叠加（加速感），反向滚轮反向驱动（可纠错）。
    _velocity += delta * _deltaToVelocity;
    _ensureTicker();
  }

  /// 平滑滚动到指定位置，供"回到顶部""定位正在播放"等按钮调用。
  void smoothScrollTo(double target) {
    _targetPixels = target.clamp(minScrollExtent, maxScrollExtent);
    _velocity = 0;
    _ensureTicker();
  }

  /// 确保 ticker 运行：停止过的 ticker 需要重新 start，否则滚轮会失效。
  void _ensureTicker() {
    var ticker = _ticker;
    if (ticker == null) {
      ticker = Ticker(_onTick);
      _ticker = ticker;
    }
    if (!ticker.isActive) {
      // 重启后 Ticker 的 elapsed 从 0 重新累计，重置上一帧时间，
      // 否则首帧 dt 算出负数（clamp 成 0），在边界处误判为越界。
      _lastTickElapsed = null;
      ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final last = _lastTickElapsed;
    _lastTickElapsed = elapsed;
    var dt = last == null ? 0.016 : (elapsed - last).inMicroseconds / 1e6;
    dt = dt.clamp(0.0, 0.05);
    if (_dragging) return;

    final target = _targetPixels;
    if (target != null) {
      final remaining = target - pixels;
      if (remaining.abs() < 0.5) {
        jumpTo(target);
        _targetPixels = null;
        _ticker?.stop();
        return;
      }
      jumpTo(pixels + remaining * buttonApproachFactor);
      return;
    }

    final step = _velocity * dt;
    // 无输入时自然减速；有输入时由 pointerScroll 持续累加。
    _velocity *= math.exp(-velocityDecayPerSecond * dt);

    var next = pixels + step;
    if (next <= minScrollExtent) {
      jumpTo(minScrollExtent);
      _velocity = math.min(0, _velocity);
      _stopWhenSettled();
      return;
    }
    if (next >= maxScrollExtent) {
      jumpTo(maxScrollExtent);
      _velocity = math.max(0, _velocity);
      _stopWhenSettled();
      return;
    }
    if (_velocity.abs() < 0.5 && step.abs() < 0.05) {
      _ticker?.stop();
      return;
    }
    jumpTo(next);
  }

  void _stopWhenSettled() {
    if (_velocity.abs() < 0.5) {
      _ticker?.stop();
    }
  }

  @override
  void beginActivity(ScrollActivity? activity) {
    super.beginActivity(activity);
    if (activity is DragScrollActivity) {
      _dragging = true;
      _velocity = 0;
    } else if (_dragging) {
      // 拖拽结束（进入惯性或静止），速度重置，由 physics 接管惯性。
      _dragging = false;
      _velocity = 0;
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }
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
    return ScrollConfiguration(
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
      behavior: ScrollConfiguration.of(context).copyWith(
        physics: const SmoothScrollPhysics(),
      ),
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
    final mainAxisExtent = gridDelegate.mainAxisExtent;
    // mainAxisExtent 为空时（用 childAspectRatio 决定高度），
    // 按最大格宽 / 宽高比 估算行高，堆叠动画对几像素误差不敏感。
    final tileHeight = mainAxisExtent ??
        gridDelegate.maxCrossAxisExtent / gridDelegate.childAspectRatio;
    final mainAxisStep = tileHeight + gridDelegate.mainAxisSpacing;
    final maxCrossAxisExtent = gridDelegate.maxCrossAxisExtent;
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(physics: physics),
      child: GridView.builder(
        controller: controller,
        padding: padding,
        gridDelegate: gridDelegate,
        itemCount: itemCount,
        itemBuilder: (context, index) {
          final child = itemBuilder(context, index);
          if (reduceMotion) return child;
          final width = MediaQuery.of(context).size.width;
          final crossAxisCount =
              ((width - (padding?.horizontal ?? 0)) / maxCrossAxisExtent)
                  .floor()
                  .clamp(1, 100);
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
  });

  final ScrollController controller;
  final int rowIndex;
  final double itemExtent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
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
        if (viewportHeight < itemExtent * 2) return child!;
        final itemTop = rowIndex * itemExtent - offset;
        return StackedItemTransform(
          itemTop: itemTop,
          itemExtent: itemExtent,
          viewportHeight: viewportHeight,
          child: child!,
        );
      },
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
        ((itemTop - (viewportHeight - itemExtent)) / transitionExtent)
            .clamp(0.0, 1.0);

    final progress = math.max(topProgress, bottomProgress);
    if (progress <= 0.0) return child;
    if (progress >= 1.0) return const SizedBox.shrink();

    final scale = 1.0 - (1.0 - StackedListView.maxShrink) * progress;
    final alignment = topProgress > bottomProgress
        ? Alignment.topCenter
        : Alignment.bottomCenter;
    return Opacity(
      opacity: 1.0 - progress,
      child: Transform.scale(
        scale: scale,
        alignment: alignment,
        child: child,
      ),
    );
  }
}
