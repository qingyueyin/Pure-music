import 'dart:math';

import 'package:flutter/material.dart';

class BreathingDots extends StatefulWidget {
  final double dotSize;
  final Color dotColor;
  final Duration breathDuration;
  final VoidCallback? onTap;

  const BreathingDots({
    super.key,
    this.dotSize = 8.0,
    this.dotColor = Colors.white,
    this.breathDuration = const Duration(seconds: 2),
    this.onTap,
  });

  @override
  State<BreathingDots> createState() => _BreathingDotsState();
}

class _BreathingDotsState extends State<BreathingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.breathDuration,
    )..repeat(reverse: true);

    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          return Opacity(
            opacity: 0.3 + _animation.value * 0.7,
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
    _controller.dispose();
    super.dispose();
  }
}
