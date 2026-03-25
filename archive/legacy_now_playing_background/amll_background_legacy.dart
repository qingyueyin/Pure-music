// Archived on 2026-03-19 before AMLL background rewrite.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:pure_music/core/advanced_color_extraction.dart';
import 'package:pure_music/core/amll_palette.dart';

/// AMLL 风格的 Fragment Shader 背景
/// 基于 Apple Music 的 Mesh Gradient 原理
/// 使用 Flutter Fragment Shader 实现流动渐变效果
class AmllBackground extends StatefulWidget {
  final Color? dominantColor;
  final MonetColorScheme? monetColorScheme;
  final ImageProvider? albumCover;
  final double flowSpeed;
  final double intensity;
  final Stream<Float32List>? spectrumStream;
  final Widget? child;

  const AmllBackground({
    super.key,
    this.dominantColor,
    this.monetColorScheme,
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
  Duration _lastTickElapsed = Duration.zero;

  AmllPalette _palette = const AmllPalette(
    base: Colors.blue,
    support: Colors.purple,
    shadow: Colors.indigo,
    highlight: Colors.cyan,
  );

  late final AnimationController _paletteController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  Animation<Color?>? _aBase;
  Animation<Color?>? _aSupport;
  Animation<Color?>? _aShadow;
  Animation<Color?>? _aHighlight;

  @override
  void initState() {
    super.initState();
    _loadProgram();
    _updateColors();
    _bindSpectrumStream();

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
    final next = deriveAmllPalette(
      monet: widget.monetColorScheme,
      fallback: widget.dominantColor,
    );

    if (!_paletteController.isAnimating && _aBase == null) {
      setState(() {
        _palette = next;
      });
      return;
    }

    final curved = CurvedAnimation(
      parent: _paletteController,
      curve: Curves.easeInOutCubic,
    );

    _aBase = ColorTween(begin: _palette.base, end: next.base).animate(curved);
    _aSupport = ColorTween(begin: _palette.support, end: next.support).animate(curved);
    _aShadow = ColorTween(begin: _palette.shadow, end: next.shadow).animate(curved);
    _aHighlight = ColorTween(begin: _palette.highlight, end: next.highlight).animate(curved);

    _paletteController.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      setState(() {
        _palette = next;
        _aBase = null;
        _aSupport = null;
        _aShadow = null;
        _aHighlight = null;
      });
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
    if (widget.monetColorScheme != oldWidget.monetColorScheme) {
      _updateColors();
    } else if (widget.dominantColor != oldWidget.dominantColor) {
      _updateColors();
    }
    if (widget.spectrumStream != oldWidget.spectrumStream) {
      _bindSpectrumStream();
    }
  }

  @override
  void dispose() {
    _spectrumSub?.cancel();
    _paletteController.dispose();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final program = _program;
    if (program == null) {
      return _buildFallbackBackground();
    }

    return RepaintBoundary(
      child: CustomPaint(
        painter: _AmllBackgroundPainter(
          program: program,
          color1: _aBase?.value ?? _palette.base,
          color2: _aSupport?.value ?? _palette.support,
          color3: _aShadow?.value ?? _palette.shadow,
          color4: _aHighlight?.value ?? _palette.highlight,
          time: _time,
          intensity: widget.intensity.clamp(0.35, 1.25).toDouble(),
          lowFreqVolume: _lowFreqVolume,
        ),
        child: widget.child ?? const SizedBox.expand(),
      ),
    );
  }

  Widget _buildFallbackBackground() {
    final base = widget.dominantColor ?? Colors.blue;
    final hsl = HSLColor.fromColor(base);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            base,
            hsl.withHue((hsl.hue + 60) % 360).toColor(),
            hsl.withHue((hsl.hue + 120) % 360).toColor(),
            hsl.withHue((hsl.hue + 180) % 360).toColor(),
          ],
        ),
      ),
      child: widget.child ?? const SizedBox.expand(),
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

  double _c(double channel) => channel.clamp(0.0, 1.0).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (!w.isFinite || !h.isFinite || w <= 1 || h <= 1) return;

    final shader = program.fragmentShader();
    final timeScaled = time * 18.0;
    shader.setFloat(0, w);
    shader.setFloat(1, h);
    shader.setFloat(2, timeScaled);
    shader.setFloat(3, intensity);
    shader.setFloat(4, lowFreqVolume);
    shader.setFloat(5, _c(color1.r));
    shader.setFloat(6, _c(color1.g));
    shader.setFloat(7, _c(color1.b));
    shader.setFloat(8, _c(color2.r));
    shader.setFloat(9, _c(color2.g));
    shader.setFloat(10, _c(color2.b));
    shader.setFloat(11, _c(color3.r));
    shader.setFloat(12, _c(color3.g));
    shader.setFloat(13, _c(color3.b));
    shader.setFloat(14, _c(color4.r));
    shader.setFloat(15, _c(color4.g));
    shader.setFloat(16, _c(color4.b));

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
