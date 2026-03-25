import 'dart:math';

import 'package:flutter/material.dart';

class BreathingDots extends StatefulWidget {
  final double dotSize;
  final Color dotColor;
  final Duration breathDuration;
  final VoidCallback? onTap;
  final AnimationController? controller;

  const BreathingDots({
    super.key,
    this.dotSize = 8.0,
    this.dotColor = Colors.white,
    this.breathDuration = const Duration(seconds: 2),
    this.onTap,
    this.controller,
  });

  @override
  State<BreathingDots> createState() => _BreathingDotsState();
}

class _BreathingDotsState extends State<BreathingDots>
    with SingleTickerProviderStateMixin {
  AnimationController? _fallbackController;

  AnimationController get _controller {
    return widget.controller ?? _ensureFallbackController();
  }

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _ensureFallbackController();
    }
  }

  AnimationController _ensureFallbackController() {
    return _fallbackController ??= AnimationController(
      vsync: this,
      duration: widget.breathDuration,
    )..repeat(reverse: true);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final eased = Curves.easeInOut.transform(_controller.value);
            return Opacity(
              opacity: 0.3 + eased * 0.7,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDot(0),
                  _buildDot(1),
                  _buildDot(2),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildDot(int index) {
    return Transform.translate(
      offset: Offset(0, -_getOffset(index)),
      child: Container(
        width: widget.dotSize,
        height: widget.dotSize,
        margin: EdgeInsets.symmetric(horizontal: widget.dotSize * 0.5),
        decoration: BoxDecoration(
          color: widget.dotColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.dotColor.withValues(alpha: 0.5),
              blurRadius: widget.dotSize,
              spreadRadius: widget.dotSize * 0.2,
            ),
          ],
        ),
      ),
    );
  }

  double _getOffset(int index) {
    final phase = (index * 0.5 + _controller.value) * 2 * pi;
    return 2 * sin(phase).abs();
  }

  @override
  void dispose() {
    _fallbackController?.dispose();
    super.dispose();
  }
}
