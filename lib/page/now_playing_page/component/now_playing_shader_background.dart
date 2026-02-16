import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class NowPlayingShaderBackground extends StatefulWidget {
  final Animation<double> repaint;
  final ColorScheme scheme;
  final Brightness brightness;
  final Stream<Float32List>? spectrumStream;
  final double intensity;
  final Widget? fallback;

  const NowPlayingShaderBackground({
    super.key,
    required this.repaint,
    required this.scheme,
    required this.brightness,
    this.spectrumStream,
    this.intensity = 1.0,
    this.fallback,
  });

  @override
  State<NowPlayingShaderBackground> createState() =>
      _NowPlayingShaderBackgroundState();
}

class _NowPlayingShaderBackgroundState extends State<NowPlayingShaderBackground>
    with AutomaticKeepAliveClientMixin {
  static Future<ui.FragmentProgram>? _programFuture;

  static Future<ui.FragmentProgram> _loadProgram() {
    return _programFuture ??=
        ui.FragmentProgram.fromAsset('assets/shaders/now_playing_bg.frag');
  }

  ui.FragmentProgram? _program;
  StreamSubscription<Float32List>? _spectrumSub;
  final _SpectrumNotifier _spectrum = _SpectrumNotifier();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadProgram().then((p) {
      if (!mounted) return;
      setState(() {
        _program = p;
      });
    });
    _bindSpectrumStream();
  }

  @override
  void didUpdateWidget(covariant NowPlayingShaderBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spectrumStream != widget.spectrumStream) {
      _bindSpectrumStream();
    }
  }

  void _bindSpectrumStream() {
    _spectrumSub?.cancel();
    final stream = widget.spectrumStream;
    if (stream == null) return;
    _spectrumSub = stream.listen((Float32List frame) {
      if (!mounted) return;
      _spectrum.updateFrom(frame);
    });
  }

  @override
  void dispose() {
    _spectrumSub?.cancel();
    _spectrum.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final program = _program;
    if (program == null) {
      return widget.fallback ?? const SizedBox.expand();
    }

    final repaint = Listenable.merge([widget.repaint, _spectrum]);
    return RepaintBoundary(
      child: CustomPaint(
        painter: _NowPlayingShaderPainter(
          program: program,
          scheme: widget.scheme,
          brightness: widget.brightness,
          intensity: widget.intensity,
          spectrum: _spectrum,
          animation: widget.repaint,
          repaint: repaint,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _NowPlayingShaderPainter extends CustomPainter {
  final ui.FragmentProgram program;
  final ColorScheme scheme;
  final Brightness brightness;
  final double intensity;
  final _SpectrumNotifier spectrum;
  final Animation<double> animation;

  _NowPlayingShaderPainter({
    required this.program,
    required this.scheme,
    required this.brightness,
    required this.intensity,
    required this.spectrum,
    required this.animation,
    required Listenable repaint,
  }) : super(repaint: repaint);

  double _c(double channel) => channel.clamp(0.0, 1.0).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (!w.isFinite || !h.isFinite || w <= 1 || h <= 1) return;

    final shader = program.fragmentShader();
    final time = animation.value * 22.0;
    final bright = brightness == Brightness.light ? 1.0 : 0.0;
    final safeIntensity = intensity.clamp(0.0, 2.0).toDouble();

    final primary = scheme.primary;
    final secondary = scheme.secondary;
    final tertiary = scheme.tertiary;

    shader.setFloat(0, w);
    shader.setFloat(1, h);
    shader.setFloat(2, time);
    shader.setFloat(3, bright);
    shader.setFloat(4, safeIntensity);

    shader.setFloat(5, _c(primary.r));
    shader.setFloat(6, _c(primary.g));
    shader.setFloat(7, _c(primary.b));

    shader.setFloat(8, _c(secondary.r));
    shader.setFloat(9, _c(secondary.g));
    shader.setFloat(10, _c(secondary.b));

    shader.setFloat(11, _c(tertiary.r));
    shader.setFloat(12, _c(tertiary.g));
    shader.setFloat(13, _c(tertiary.b));

    final s = spectrum.value;
    for (int i = 0; i < 8; i++) {
      shader.setFloat(14 + i, i < s.length ? s[i] : 0.0);
    }

    final paint = Paint()..shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _NowPlayingShaderPainter oldDelegate) {
    return oldDelegate.scheme != scheme ||
        oldDelegate.brightness != brightness ||
        oldDelegate.intensity != intensity ||
        oldDelegate.program != program;
  }
}

class _SpectrumNotifier extends ChangeNotifier {
  final Float32List value = Float32List(8);
  int _lastUs = 0;

  void updateFrom(Float32List frame) {
    if (frame.isEmpty) return;

    final nowUs = DateTime.now().microsecondsSinceEpoch;
    if (nowUs - _lastUs < 10 * 1000) return;
    _lastUs = nowUs;

    final n = frame.length >= 8 ? 8 : frame.length;
    var changed = false;
    for (int i = 0; i < 8; i++) {
      final next = i < n ? frame[i] : 0.0;
      final prev = value[i];
      if (!changed && (next - prev).abs() > 0.004) {
        changed = true;
      }
      value[i] = next;
    }
    if (changed) notifyListeners();
  }
}
