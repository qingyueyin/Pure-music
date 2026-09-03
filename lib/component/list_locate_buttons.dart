import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/component/stacked_list_view.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// 列表右下角浮动按钮组：定位正在播放 + 回到顶部。
///
/// 监听 [controller] 的滚动位置决定回到顶部按钮的显隐；
/// 定位按钮监听播放服务，当前乐曲在列表中可定位时才显示。
class ListLocateButtons extends StatefulWidget {
  const ListLocateButtons({
    super.key,
    required this.controller,
    this.locateTargetAt,
    this.onScrollToIndex,
    this.onWheel,
  });

  /// 正在滚动的列表控制器。
  final ScrollController controller;

  /// 当前正在播放乐曲在列表中的索引；返回 null 时隐藏定位按钮。
  final int? Function()? locateTargetAt;

  /// 点击定位按钮时滚动到目标索引。
  final void Function(int index)? onScrollToIndex;

  /// 滚轮转发回调（按钮浮层不拦截滚轮）。
  final void Function(double delta)? onWheel;

  @override
  State<ListLocateButtons> createState() => _ListLocateButtonsState();
}

class _ListLocateButtonsState extends State<ListLocateButtons> {
  bool _showScrollToTop = false;

  void _onScrollUpdate() {
    if (!mounted) return;
    final controller = widget.controller;
    final shouldShow =
        controller.hasClients && controller.position.pixels > 320.0;
    if (shouldShow != _showScrollToTop) {
      setState(() => _showScrollToTop = shouldShow);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScrollUpdate);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScrollUpdate();
    });
  }

  @override
  void didUpdateWidget(ListLocateButtons oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScrollUpdate);
      widget.controller.addListener(_onScrollUpdate);
      _showScrollToTop =
          widget.controller.hasClients &&
          widget.controller.position.pixels > 320.0;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScrollUpdate);
    super.dispose();
  }

  /// 平滑滚动到指定位置。
  void _smoothScrollTo(double offset) {
    if (!widget.controller.hasClients) return;
    final position = widget.controller.position;
    if (position is SmoothScrollPosition) {
      position.smoothScrollTo(offset);
      return;
    }
    widget.controller.animateTo(
      offset.clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.fastOutSlowIn,
    );
  }

  void _forwardWheelToList(double delta) {
    if (widget.onWheel != null) {
      widget.onWheel!(delta);
      return;
    }
    if (!AppSettings.instance.enableStackedScrollEffect ||
        MediaQuery.disableAnimationsOf(context)) {
      return;
    }
    if (!widget.controller.hasClients) return;
    final position = widget.controller.position;
    if (position is SmoothScrollPosition) {
      position.pointerScroll(delta);
    }
  }

  Widget _locateNowPlayingButton() {
    final playbackService = PlayService.instance.playbackService;
    final locateTargetAt = widget.locateTargetAt;

    return ListenableBuilder(
      listenable: playbackService.nowPlayingNotifier,
      builder: (context, _) {
        final targetAt = locateTargetAt?.call();
        if (targetAt == null) return const SizedBox.shrink();

        return ResponsiveBuilder(
          builder: (context, screenType) {
            final bottom = screenType == ScreenType.small ? 88.0 : 112.0;
            final right = screenType == ScreenType.small ? 88.0 : 128.0;
            final reduceMotion = MediaQuery.disableAnimationsOf(context);
            final nowPlayingPath = playbackService.nowPlaying?.path ?? '';
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
                  key: ValueKey(nowPlayingPath),
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
                  child: IconButton.filledTonal(
                    tooltip: '定位正在播放',
                    onPressed: () => widget.onScrollToIndex?.call(targetAt),
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
              child: IconButton.filledTonal(
                tooltip: '回到顶部',
                onPressed: () => _smoothScrollTo(0.0),
                style: ButtonStyle(
                  fixedSize: const WidgetStatePropertyAll(Size(40, 40)),
                  padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
                  ),
                ),
                icon: const Icon(Symbols.vertical_align_top),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 内部按钮用 Positioned 布局，外层撑满约束确保定位基准正确。
    return SizedBox.expand(
      child: Stack(children: [_scrollToTopButton(), _locateNowPlayingButton()]),
    );
  }
}
