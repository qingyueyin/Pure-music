import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

const _listItemEntryDistance = 12.0;
const _listItemEntrySpring = SpringDescription(
  mass: 1,
  stiffness: 625,
  damping: 50,
);
const _tabSwitchDistance = 20.0;
const _tabExitDistance = 12.0;
final Expando<double> _listItemEntryOffsets = Expando<double>();
final Expando<Set<Object>> _listItemEnteredIdentities = Expando<Set<Object>>();

bool _claimListItemEntrance(ScrollPosition? scrollPosition, Object? identity) {
  if (scrollPosition == null || identity == null) return true;
  return (_listItemEnteredIdentities[scrollPosition] ??= <Object>{})
      .add(identity);
}

class MotionDuration {
  static const xFast = Duration(milliseconds: 120);
  static const fast = Duration(milliseconds: 180);
  static const base = Duration(milliseconds: 280);
  static const medium = Duration(milliseconds: 360);
  static const slow = Duration(milliseconds: 420);
  static const xSlow = Duration(milliseconds: 560);
}

class MotionCurve {
  static const standard = Curves.fastOutSlowIn;
  static const emphasized = Curves.easeInOutCubic;
  static const entrance = Cubic(0.23, 1, 0.32, 1);
}

class DirectionalListItemEntrance extends StatelessWidget {
  const DirectionalListItemEntrance({
    super.key,
    required this.child,
    this.identity,
  });

  final Widget child;
  final Object? identity;

  @override
  Widget build(BuildContext context) {
    final scrollPosition = Scrollable.maybeOf(context)?.position;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final identity = this.identity;
    final animateEntrance = !reduceMotion;
    final offset = !animateEntrance
        ? 0.0
        : scrollPosition == null
            ? _listItemEntryDistance
            : _listItemEntryOffsets[scrollPosition] ?? _listItemEntryDistance;
    return _DirectionalListItemEntrance(
      key: identity == null ? null : ValueKey<Object>(identity),
      scrollPosition: scrollPosition,
      identity: identity,
      offset: offset,
      animateEntrance: animateEntrance,
      reduceMotion: reduceMotion,
      child: child,
    );
  }
}

class DirectionalTabView extends StatefulWidget {
  const DirectionalTabView({
    super.key,
    required this.index,
    required this.children,
  }) : assert(index >= 0 && index < children.length);

  final int index;
  final List<Widget> children;

  @override
  State<DirectionalTabView> createState() => _DirectionalTabViewState();
}

class _DirectionalTabViewState extends State<DirectionalTabView>
    with TickerProviderStateMixin {
  late final List<_TabMotionChannel> _channels;

  @override
  void initState() {
    super.initState();
    _channels = List.generate(
      widget.children.length,
      (index) => _TabMotionChannel(
        vsync: this,
        opacity: index == widget.index ? 1 : 0,
        offset: index == widget.index
            ? 0
            : index < widget.index
                ? -_tabSwitchDistance
                : _tabSwitchDistance,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant DirectionalTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncChannelCount();
    if (oldWidget.index == widget.index) return;
    final direction = widget.index > oldWidget.index ? 1.0 : -1.0;
    final incoming = _channels[widget.index];
    if (incoming.opacity.value <= 0.001) {
      incoming
        ..offset.value = _tabSwitchDistance * direction
        ..opacity.value = 0.78;
    }
    incoming.animateTo(offset: 0, opacity: 1);

    if (oldWidget.index < _channels.length) {
      _channels[oldWidget.index].animateTo(
        offset: -_tabExitDistance * direction,
        opacity: 0,
      );
    }
  }

  void _syncChannelCount() {
    while (_channels.length < widget.children.length) {
      final index = _channels.length;
      _channels.add(
        _TabMotionChannel(
          vsync: this,
          opacity: index == widget.index ? 1 : 0,
          offset: index < widget.index
              ? -_tabSwitchDistance
              : _tabSwitchDistance,
        ),
      );
    }
    while (_channels.length > widget.children.length) {
      _channels.removeLast().dispose();
    }
  }

  @override
  void dispose() {
    for (final channel in _channels) {
      channel.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Stack(
      fit: StackFit.expand,
      children: List.generate(widget.children.length, (index) {
        final channel = _channels[index];
        return AnimatedBuilder(
          animation: Listenable.merge([channel.offset, channel.opacity]),
          builder: (context, child) {
            final isCurrent = index == widget.index;
            final opacity = channel.opacity.value.clamp(0.0, 1.0);
            final isVisible = isCurrent || opacity > 0.001;
            Widget result = child!;
            if (!reduceMotion && channel.offset.value.abs() > 0.001) {
              result = Transform.translate(
                offset: Offset(channel.offset.value, 0),
                child: result,
              );
            }
            if (opacity < 0.999) {
              result = Opacity(opacity: opacity, child: result);
            }
            return Offstage(
              offstage: !isVisible,
              child: TickerMode(
                enabled: isCurrent,
                child: ExcludeSemantics(
                  excluding: !isCurrent,
                  child: IgnorePointer(
                    ignoring: !isCurrent,
                    child: result,
                  ),
                ),
              ),
            );
          },
          child: widget.children[index],
        );
      }),
    );
  }
}

class _TabMotionChannel {
  _TabMotionChannel({
    required TickerProvider vsync,
    required double opacity,
    required double offset,
  })  : opacity = AnimationController.unbounded(vsync: vsync, value: opacity),
        offset = AnimationController.unbounded(vsync: vsync, value: offset);

  final AnimationController opacity;
  final AnimationController offset;

  void animateTo({required double opacity, required double offset}) {
    this.opacity.animateWith(
          SpringSimulation(
            _listItemEntrySpring,
            this.opacity.value,
            opacity,
            this.opacity.velocity,
          ),
        );
    this.offset.animateWith(
          SpringSimulation(
            _listItemEntrySpring,
            this.offset.value,
            offset,
            this.offset.velocity,
          ),
        );
  }

  void dispose() {
    opacity.dispose();
    offset.dispose();
  }
}

class _DirectionalListItemEntrance extends StatefulWidget {
  const _DirectionalListItemEntrance({
    super.key,
    required this.scrollPosition,
    required this.identity,
    required this.offset,
    required this.animateEntrance,
    required this.reduceMotion,
    required this.child,
  });

  final ScrollPosition? scrollPosition;
  final Object? identity;
  final double offset;
  final bool animateEntrance;
  final bool reduceMotion;
  final Widget child;

  @override
  State<_DirectionalListItemEntrance> createState() =>
      _DirectionalListItemEntranceState();
}

class _DirectionalListItemEntranceState
    extends State<_DirectionalListItemEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final double _entryOffset;

  void _rememberDirection(double scrollDelta) {
    final scrollPosition = widget.scrollPosition;
    if (scrollPosition == null || scrollDelta == 0) return;
    _listItemEntryOffsets[scrollPosition] = scrollDelta.isNegative
        ? -_listItemEntryDistance
        : _listItemEntryDistance;
  }

  @override
  void initState() {
    super.initState();
    _entryOffset = widget.offset;
    final firstEntrance =
        _claimListItemEntrance(widget.scrollPosition, widget.identity);
    final shouldAnimate = widget.animateEntrance && firstEntrance;
    _controller = AnimationController.unbounded(
      vsync: this,
      value: shouldAnimate ? 0 : 1,
    );
    if (shouldAnimate) {
      _controller.animateWith(
        SpringSimulation(_listItemEntrySpring, 0, 1, 0),
      );
    }
  }

  @override
  void didUpdateWidget(covariant _DirectionalListItemEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduceMotion && !oldWidget.reduceMotion) {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          _rememberDirection(event.scrollDelta.dy);
        }
      },
      onPointerMove: (event) {
        if (event.down) _rememberDirection(-event.delta.dy);
      },
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final progress = _controller.value.clamp(0.0, 1.0);
          if (progress >= 0.999) return child!;
          return Opacity(
            opacity: 0.78 + progress * 0.22,
            child: Transform.translate(
              offset: Offset(0, (1 - progress) * _entryOffset),
              child: child,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}
