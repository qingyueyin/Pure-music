import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pure_music/component/motion.dart';

class CoverPointerSheen extends StatefulWidget {
  const CoverPointerSheen({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;
  final bool enabled;

  @override
  State<CoverPointerSheen> createState() => _CoverPointerSheenState();
}

class _CoverPointerSheenState extends State<CoverPointerSheen>
    with SingleTickerProviderStateMixin {
  final _position = ValueNotifier<Offset>(Offset.zero);
  late final AnimationController _opacity;
  late final Listenable _paintListenable;
  ScrollPosition? _scrollPosition;
  bool _hovered = false;
  bool _scrolling = false;

  @override
  void initState() {
    super.initState();
    _opacity = AnimationController(
      vsync: this,
      duration: MotionDuration.xFast,
    );
    _paintListenable = Listenable.merge([_position, _opacity]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attachScroll(Scrollable.maybeOf(context)?.position);
  }

  @override
  void didUpdateWidget(CoverPointerSheen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) {
      _hovered = false;
      _opacity.value = 0;
    }
  }

  @override
  void dispose() {
    _attachScroll(null);
    _opacity.dispose();
    _position.dispose();
    super.dispose();
  }

  void _attachScroll(ScrollPosition? position) {
    if (identical(_scrollPosition, position)) return;
    _scrollPosition?.isScrollingNotifier.removeListener(_onScrollChanged);
    _scrollPosition = position;
    _scrollPosition?.isScrollingNotifier.addListener(_onScrollChanged);
    _syncScrolling();
  }

  void _onScrollChanged() => _syncScrolling();

  void _syncScrolling() {
    final scrolling = _scrollPosition?.isScrollingNotifier.value ?? false;
    if (_scrolling == scrolling) return;
    _scrolling = scrolling;
    if (scrolling) {
      _opacity.value = 0;
    } else if (_hovered && widget.enabled) {
      _opacity.forward();
    }
  }

  void _onEnter(PointerEnterEvent event) {
    _hovered = true;
    _position.value = event.localPosition;
    if (!_scrolling) _opacity.forward();
  }

  void _onHover(PointerHoverEvent event) {
    if (_scrolling) return;
    _position.value = event.localPosition;
  }

  void _onExit(PointerExitEvent event) {
    _hovered = false;
    _opacity.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !MediaQuery.disableAnimationsOf(context);
    if (!enabled) return widget.child;

    return MouseRegion(
      opaque: false,
      onEnter: _onEnter,
      onHover: _onHover,
      onExit: _onExit,
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _paintListenable,
                  builder: (context, _) {
                    final opacity = _opacity.value;
                    if (opacity <= 0.01) return const SizedBox.shrink();
                    return CustomPaint(
                      painter: CoverPointerSheenPainter(
                        center: _position.value,
                        opacity: opacity,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CoverPointerSheenPainter extends CustomPainter {
  const CoverPointerSheenPainter({required this.center, required this.opacity});

  final Offset center;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0.01 || size.isEmpty) return;
    final radius = size.shortestSide * 0.6;
    final shader = RadialGradient(
      colors: [
        const Color(0xFFFFFFFF).withValues(alpha: 0.14 * opacity),
        const Color(0xFFFFFFFF).withValues(alpha: 0.05 * opacity),
        const Color(0x00FFFFFF),
      ],
      stops: const [0.0, 0.45, 1.0],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(CoverPointerSheenPainter oldDelegate) {
    return oldDelegate.center != center || oldDelegate.opacity != opacity;
  }
}
