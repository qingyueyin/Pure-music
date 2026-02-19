import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class GlassmorphicBackground extends StatefulWidget {
  final Color? dominantColor;
  final double blurIntensity;
  final bool animate;
  final Widget? child;

  const GlassmorphicBackground({
    super.key,
    this.dominantColor,
    this.blurIntensity = 20,
    this.animate = true,
    this.child,
  });

  @override
  State<GlassmorphicBackground> createState() => _GlassmorphicBackgroundState();
}

class _GlassmorphicBackgroundState extends State<GlassmorphicBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<Color?> _colorAnimation;
  Color _currentColor = Colors.grey.shade900;
  Color? _previousColor;

  @override
  void initState() {
    super.initState();
    _currentColor = widget.dominantColor ?? Colors.grey.shade900;

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _colorAnimation = ColorTween(
      begin: _currentColor,
      end: _currentColor,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void didUpdateWidget(GlassmorphicBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dominantColor != widget.dominantColor && widget.animate) {
      final newColor = widget.dominantColor ?? Colors.grey.shade900;
      _previousColor = _colorAnimation.value ?? _currentColor;
      _currentColor = newColor;

      _colorAnimation = ColorTween(
        begin: _previousColor,
        end: newColor,
      ).animate(CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeInOut,
      ));
      _animationController.forward(from: 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _colorAnimation,
      builder: (context, child) {
        final color = widget.animate
            ? _colorAnimation.value ?? _currentColor
            : _currentColor;

        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                color.withValues(alpha: 0.9),
                _getComplementaryColor(color).withValues(alpha: 0.7),
                color.withValues(alpha: 0.8),
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
          child: _buildBlurFilter(child: widget.child),
        );
      },
    );
  }

  Widget _buildBlurFilter({Widget? child}) {
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: widget.blurIntensity,
          sigmaY: widget.blurIntensity,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.1),
              width: 0.5,
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  Color _getComplementaryColor(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl.withHue((hsl.hue + 40) % 360).toColor();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }
}
