// Archived on 2026-03-19 before AMLL background rewrite.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Apple Music 风格的 Mesh Gradient 背景
/// 基于 Bicubic Hermite Patch Mesh 实现真正的流体渐变效果
class MeshGradientBackground extends StatefulWidget {
  final ImageProvider? albumImage;
  final Color? dominantColor;
  final double flowSpeed;
  final double intensity;
  final bool enableAnimation;
  final Stream<Float32List>? spectrumStream;
  final Widget? fallback;

  const MeshGradientBackground({
    super.key,
    this.albumImage,
    this.dominantColor,
    this.flowSpeed = 1.0,
    this.intensity = 1.0,
    this.enableAnimation = true,
    this.spectrumStream,
    this.fallback,
  });

  @override
  State<MeshGradientBackground> createState() => _MeshGradientBackgroundState();
}

class _MeshGradientBackgroundState extends State<MeshGradientBackground>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Ticker _ticker;
  ui.FragmentProgram? _program;
  StreamSubscription<Float32List>? _spectrumSub;

  double _time = 0.0;
  double _lowFreqVolume = 0.0;
  Duration _lastTickElapsed = Duration.zero;

  Color _currentColor = Colors.blue;
  Color _previousColor = Colors.blue;
  late final AnimationController _colorController;
  late Animation<Color?> _colorAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    );

    _colorController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _currentColor = widget.dominantColor ?? Colors.blue;
    _previousColor = _currentColor;
    _colorAnimation = ColorTween(
      begin: _currentColor,
      end: _currentColor,
    ).animate(CurvedAnimation(
      parent: _colorController,
      curve: Curves.easeInOut,
    ));

    _loadProgram();
    _bindSpectrumStream();

    if (widget.enableAnimation) {
      _animationController.repeat();
      _ticker = createTicker((elapsed) {
        final dt = (elapsed - _lastTickElapsed).inMicroseconds / 1000000.0;
        _lastTickElapsed = elapsed;
        if (!mounted) return;
        setState(() {
          _time += dt * widget.flowSpeed;
        });
      });
      _ticker.start();
    }
  }

  Future<void> _loadProgram() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'assets/shaders/mesh_gradient_runtime.frag',
      );
      if (mounted) {
        setState(() {
          _program = program;
        });
      }
    } catch (e) {
      debugPrint('Failed to load mesh_gradient shader: $e');
    }
  }

  void _bindSpectrumStream() {
    _spectrumSub?.cancel();
    final stream = widget.spectrumStream;
    if (stream == null) return;

    _spectrumSub = stream.listen((frame) {
      if (!mounted) return;
      if (frame.isEmpty) return;

      final lowFreq = frame.length >= 8
          ? frame.sublist(0, 8).reduce((a, b) => a + b) / 8
          : frame.reduce((a, b) => a + b) / frame.length;

      setState(() {
        _lowFreqVolume = _lowFreqVolume * 0.7 + lowFreq * 0.3;
      });
    });
  }

  void _transitionToColor(Color newColor) {
    _previousColor = _colorAnimation.value ?? _currentColor;
    _currentColor = newColor;

    _colorAnimation = ColorTween(
      begin: _previousColor,
      end: newColor,
    ).animate(CurvedAnimation(
      parent: _colorController,
      curve: Curves.easeInOut,
    ));

    _colorController.forward(from: 0);
  }

  @override
  void didUpdateWidget(MeshGradientBackground oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.enableAnimation != oldWidget.enableAnimation) {
      if (widget.enableAnimation) {
        _animationController.repeat();
        _ticker.start();
      } else {
        _animationController.stop();
        _ticker.stop();
      }
    }

    if (widget.spectrumStream != oldWidget.spectrumStream) {
      _bindSpectrumStream();
    }

    if (widget.dominantColor != oldWidget.dominantColor &&
        widget.dominantColor != null) {
      _transitionToColor(widget.dominantColor!);
    }
  }

  @override
  void dispose() {
    _spectrumSub?.cancel();
    _animationController.dispose();
    _colorController.dispose();
    if (widget.enableAnimation) {
      _ticker.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final program = _program;
    if (program == null) {
      return widget.fallback ?? Container(color: Colors.black);
    }

    final color = _colorAnimation.value ?? _currentColor;

    return RepaintBoundary(
      child: CustomPaint(
        painter: _MeshGradientPainter(
          program: program,
          time: _time,
          lowFreqVolume: _lowFreqVolume,
          dominantColor: color,
          intensity: widget.intensity,
          albumImage: widget.albumImage,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _MeshGradientPainter extends CustomPainter {
  final ui.FragmentProgram program;
  final double time;
  final double lowFreqVolume;
  final Color dominantColor;
  final double intensity;
  final ImageProvider? albumImage;

  _MeshGradientPainter({
    required this.program,
    required this.time,
    required this.lowFreqVolume,
    required this.dominantColor,
    required this.intensity,
    this.albumImage,
  });

  double _c(double channel) => channel.clamp(0.0, 1.0).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (!w.isFinite || !h.isFinite || w <= 1 || h <= 1) return;

    final shader = program.fragmentShader();

    shader.setFloat(0, w);
    shader.setFloat(1, h);
    shader.setFloat(2, time * 18.0);
    shader.setFloat(3, intensity.clamp(0.35, 1.25).toDouble());
    shader.setFloat(4, lowFreqVolume);
    shader.setFloat(5, _c(dominantColor.r));
    shader.setFloat(6, _c(dominantColor.g));
    shader.setFloat(7, _c(dominantColor.b));
    shader.setFloat(8, w / h);

    final paint = Paint()..shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _MeshGradientPainter oldDelegate) {
    return oldDelegate.time != time ||
        oldDelegate.lowFreqVolume != lowFreqVolume ||
        oldDelegate.dominantColor != dominantColor ||
        oldDelegate.intensity != intensity;
  }
}
