import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Apple Music 风格的渐变网格背景渲染
/// 
/// 基于 Mesh Gradient 技术，使用 Fragment Shader 实现
/// 模拟 Apple Music 的流动渐变背景效果
class AppleMusicBackground extends StatefulWidget {
  final Widget? child;
  final ImageProvider? albumCover;
  final bool animate;
  final Duration duration;
  final double intensity;
  
  const AppleMusicBackground({
    super.key,
    this.child,
    this.albumCover,
    this.animate = true,
    this.duration = const Duration(seconds: 10),
    this.intensity = 1.0,
  });

  @override
  State<AppleMusicBackground> createState() => _AppleMusicBackgroundState();
}

class _AppleMusicBackgroundState extends State<AppleMusicBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  ui.FragmentProgram? _program;
  Color _dominantColor = Colors.blue;
  Color _secondaryColor = Colors.purple;
  Color _tertiaryColor = Colors.cyan;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    )..repeat(reverse: true);

    _loadProgram();
    _extractColors();
  }

  @override
  void didUpdateWidget(AppleMusicBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.albumCover != widget.albumCover) {
      _extractColors();
    }
  }

  Future<void> _loadProgram() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'assets/shaders/apple_music_bg.frag',
      );
      if (mounted) {
        setState(() {
          _program = program;
        });
      }
    } catch (e) {
      debugPrint('Failed to load shader: $e');
    }
  }

  Future<void> _extractColors() async {
    if (widget.albumCover == null) return;
    
    // TODO: 使用 palette_generator 提取专辑封面主色
    // 这里暂时使用随机生成的颜色
    final random = math.Random();
    setState(() {
      _dominantColor = Color.fromRGBO(
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
        1.0,
      );
      _secondaryColor = Color.fromRGBO(
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
        1.0,
      );
      _tertiaryColor = Color.fromRGBO(
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
        1.0,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final program = _program;
    if (program == null) {
      return widget.child ?? const SizedBox.expand();
    }

    return Stack(
      children: [
        RepaintBoundary(
          child: CustomPaint(
            painter: _AppleMusicBgPainter(
              program: program,
              dominantColor: _dominantColor,
              secondaryColor: _secondaryColor,
              tertiaryColor: _tertiaryColor,
              animation: _controller,
              animate: widget.animate,
              intensity: widget.intensity,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        if (widget.child != null) widget.child!,
      ],
    );
  }
}

class _AppleMusicBgPainter extends CustomPainter {
  final ui.FragmentProgram program;
  final Color dominantColor;
  final Color secondaryColor;
  final Color tertiaryColor;
  final Animation<double> animation;
  final bool animate;
  final double intensity;

  _AppleMusicBgPainter({
    required this.program,
    required this.dominantColor,
    required this.secondaryColor,
    required this.tertiaryColor,
    required this.animation,
    required this.animate,
    required this.intensity,
  }) : super(repaint: animate ? animation : null);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (!w.isFinite || !h.isFinite || w <= 1 || h <= 1) return;

    final shader = program.fragmentShader();
    final time = animate ? animation.value : 0.0;

    // 设置 uniforms
    shader.setFloat(0, w); // uSize.x
    shader.setFloat(1, h); // uSize.y
    shader.setFloat(2, time); // uTime
    shader.setFloat(3, intensity); // uIntensity

    // 设置颜色
    shader.setFloat(4, dominantColor.r);
    shader.setFloat(5, dominantColor.g);
    shader.setFloat(6, dominantColor.b);

    shader.setFloat(7, secondaryColor.r);
    shader.setFloat(8, secondaryColor.g);
    shader.setFloat(9, secondaryColor.b);

    shader.setFloat(10, tertiaryColor.r);
    shader.setFloat(11, tertiaryColor.g);
    shader.setFloat(12, tertiaryColor.b);

    final paint = Paint()..shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_AppleMusicBgPainter oldDelegate) {
    return oldDelegate.dominantColor != dominantColor ||
        oldDelegate.secondaryColor != secondaryColor ||
        oldDelegate.tertiaryColor != tertiaryColor ||
        oldDelegate.intensity != intensity;
  }
}
