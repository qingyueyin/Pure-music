import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// AMLL 风格的 Fragment Shader 背景
/// 基于 Apple Music 的 Mesh Gradient 原理
/// 使用 Flutter Fragment Shader 实现流动渐变效果
class AmllBackground extends StatefulWidget {
  final Color? dominantColor;
  final ImageProvider? albumCover;
  final double flowSpeed;
  final double intensity;
  final Stream<Float32List>? spectrumStream;
  final Widget? child;

  const AmllBackground({
    super.key,
    this.dominantColor,
    this.albumCover,
    this.flowSpeed = 1.0,
    this.intensity = 1.0,
    this.spectrumStream,
    this.child,
  });

  @override
  State<AmllBackground> createState() => _AmllBackgroundState();
}

class _AmllBackgroundState extends State<AmllBackground>
    with SingleTickerProviderStateMixin {
  ui.FragmentProgram? _program;
  StreamSubscription<Float32List>? _spectrumSub;
  double _lowFreqVolume = 0.0;
  double _time = 0.0;
  late Ticker _ticker;

  Color _color1 = Colors.blue;
  Color _color2 = Colors.purple;
  Color _color3 = Colors.cyan;
  Color _color4 = Colors.indigo;

  @override
  void initState() {
    super.initState();
    _loadProgram();
    _updateColors();
    _bindSpectrumStream();

    _ticker = createTicker((elapsed) {
      setState(() {
        _time += 0.016 * widget.flowSpeed;
      });
    });
    _ticker.start();
  }

  Future<void> _loadProgram() async {
    try {
      final program =
          await ui.FragmentProgram.fromAsset('assets/shaders/amll_background.frag');
      if (mounted) {
        setState(() => _program = program);
      }
    } catch (e) {
      debugPrint('Failed to load amll_background shader: $e');
    }
  }

  void _updateColors() {
    final base = widget.dominantColor ?? Colors.blue;
    final hsl = HSLColor.fromColor(base);

    setState(() {
      _color1 = base;
      _color2 = hsl.withHue((hsl.hue + 60) % 360).toColor();
      _color3 = hsl.withHue((hsl.hue + 180) % 360).toColor();
      _color4 = hsl.withHue((hsl.hue + 240) % 360).toColor();
    });
  }

  void _bindSpectrumStream() {
    _spectrumSub?.cancel();
    final stream = widget.spectrumStream;
    if (stream == null) return;

    _spectrumSub = stream.listen((frame) {
      if (!mounted || frame.isEmpty) return;
      final lowFreq = frame.length >= 8
          ? frame.sublist(0, 8).reduce((a, b) => a + b) / 8
          : frame.reduce((a, b) => a + b) / frame.length;
      setState(() {
        _lowFreqVolume = (_lowFreqVolume * 0.7 + lowFreq * 0.3).clamp(0.0, 1.0);
      });
    });
  }

  @override
  void didUpdateWidget(AmllBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.dominantColor != oldWidget.dominantColor) {
      _updateColors();
    }
    if (widget.spectrumStream != oldWidget.spectrumStream) {
      _bindSpectrumStream();
    }
  }

  @override
  void dispose() {
    _spectrumSub?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final program = _program;
    if (program == null) {
      return widget.child ?? Container(color: Colors.black);
    }

    return RepaintBoundary(
      child: CustomPaint(
        painter: _AmllBackgroundPainter(
          program: program,
          color1: _color1,
          color2: _color2,
          color3: _color3,
          color4: _color4,
          time: _time,
          intensity: widget.intensity,
          lowFreqVolume: _lowFreqVolume,
        ),
        child: widget.child,
      ),
    );
  }
}

class _AmllBackgroundPainter extends CustomPainter {
  final ui.FragmentProgram program;
  final Color color1, color2, color3, color4;
  final double time;
  final double intensity;
  final double lowFreqVolume;

  _AmllBackgroundPainter({
    required this.program,
    required this.color1,
    required this.color2,
    required this.color3,
    required this.color4,
    required this.time,
    required this.intensity,
    required this.lowFreqVolume,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (!w.isFinite || !h.isFinite || w <= 1 || h <= 1) return;

    final shader = program.fragmentShader();
    shader.setFloat(0, w);
    shader.setFloat(1, h);
    shader.setFloat(2, time);
    shader.setFloat(3, intensity);
    shader.setFloat(4, lowFreqVolume);
    shader.setFloat(5, color1.r);
    shader.setFloat(6, color1.g);
    shader.setFloat(7, color1.b);
    shader.setFloat(8, color2.r);
    shader.setFloat(9, color2.g);
    shader.setFloat(10, color2.b);
    shader.setFloat(11, color3.r);
    shader.setFloat(12, color3.g);
    shader.setFloat(13, color3.b);
    shader.setFloat(14, color4.r);
    shader.setFloat(15, color4.g);
    shader.setFloat(16, color4.b);

    final paint = Paint()..shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _AmllBackgroundPainter old) {
    return old.time != time ||
        old.intensity != intensity ||
        old.lowFreqVolume != lowFreqVolume ||
        old.color1 != color1 ||
        old.color2 != color2 ||
        old.color3 != color3 ||
        old.color4 != color4;
  }
}
