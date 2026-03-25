import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:pure_music/core/advanced_color_extraction.dart';
import 'package:pure_music/mesh_gradient/core/amll_bhp_mesh.dart';
import 'package:pure_music/mesh_gradient/core/amll_control_point_presets.dart';
import 'package:pure_music/mesh_gradient/core/amll_mesh_transition_state.dart';
import 'package:pure_music/mesh_gradient/core/control_point.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

class MeshGradientBackground extends StatefulWidget {
  final NowPlayingBackgroundInputs inputs;
  final Color fallbackColor;

  const MeshGradientBackground({
    super.key,
    required this.inputs,
    required this.fallbackColor,
  });

  @override
  State<MeshGradientBackground> createState() => _MeshGradientBackgroundState();
}

class _MeshGradientBackgroundState extends State<MeshGradientBackground>
    with TickerProviderStateMixin {
  static const _transitionDuration = Duration(milliseconds: 880);
  static const _subdivisions = 20;

  late final AnimationController _transitionController = AnimationController(
    vsync: this,
    duration: _transitionDuration,
  )
    ..value = 1.0
    ..addListener(() {
      if (mounted) setState(() {});
    })
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          _scene = _scene.settle();
        });
      }
    });

  MeshGradientTransitionState<_MeshLayerPayload> _scene =
      const MeshGradientTransitionState.empty();

  StreamSubscription<Float32List>? _spectrumSub;
  Ticker? _ticker;
  Duration _lastTickElapsed = Duration.zero;

  double _time = 0.0;
  double _lowFreqVolume = 0.0;

  @override
  void initState() {
    super.initState();
    _syncScene(animate: false);
    _bindSpectrumStream();
    _setAnimationActive(widget.inputs.shouldAnimate);
  }

  @override
  void didUpdateWidget(MeshGradientBackground oldWidget) {
    super.didUpdateWidget(oldWidget);

    final coverChanged =
        widget.inputs.albumCoverBytes != oldWidget.inputs.albumCoverBytes;
    final colorChanged =
        widget.inputs.dominantColor != oldWidget.inputs.dominantColor ||
            widget.inputs.monetScheme != oldWidget.inputs.monetScheme;

    if (coverChanged || colorChanged) {
      _syncScene(animate: true);
    }

    if (widget.inputs.shouldAnimate != oldWidget.inputs.shouldAnimate) {
      _setAnimationActive(widget.inputs.shouldAnimate);
    }

    if (widget.inputs.spectrumStream != oldWidget.inputs.spectrumStream ||
        widget.inputs.shouldAnimate != oldWidget.inputs.shouldAnimate) {
      _bindSpectrumStream();
    }
  }

  @override
  void dispose() {
    _spectrumSub?.cancel();
    _ticker?.dispose();
    _transitionController.dispose();
    super.dispose();
  }

  void _setAnimationActive(bool active) {
    if (!active) {
      _ticker?.stop();
      _lastTickElapsed = Duration.zero;
      return;
    }

    _ticker ??= createTicker((elapsed) {
      final dt = (elapsed - _lastTickElapsed).inMicroseconds / 1000000.0;
      _lastTickElapsed = elapsed;
      if (!mounted) return;
      setState(() {
        _time += dt * widget.inputs.flowSpeed;
      });
    });
    _lastTickElapsed = Duration.zero;
    if (!_ticker!.isActive) {
      _ticker!.start();
    }
  }

  void _bindSpectrumStream() {
    _spectrumSub?.cancel();
    final stream = widget.inputs.spectrumStream;
    if (stream == null || !widget.inputs.shouldAnimate) return;

    _spectrumSub = stream.listen((frame) {
      if (!mounted || frame.isEmpty) return;

      final usableBins = math.min(8, frame.length);
      var sum = 0.0;
      for (var i = 0; i < usableBins; i++) {
        sum += frame[i].abs();
      }
      final lowFreq = usableBins == 0 ? 0.0 : sum / usableBins;
      final shaped = math.log(1 + lowFreq.clamp(0.0, 1.0) * 9) / math.log(10);
      setState(() {
        _lowFreqVolume =
            (_lowFreqVolume * 0.82 + shaped * 0.18).clamp(0.0, 1.0);
      });
    });
  }

  void _syncScene({required bool animate}) {
    final dominantColor = widget.inputs.dominantColor ?? widget.fallbackColor;
    final signature = _computeBackgroundSignature(
      widget.inputs.albumCoverBytes,
      dominantColor,
    );
    final nextSnapshot = MeshGradientSceneSnapshot(
      signature: signature,
      payload: _MeshLayerPayload(
        signature: signature,
        preset: pickAmllControlPointPreset(seed: signature),
        dominantColorValue: dominantColor.toARGB32(),
        monetScheme: widget.inputs.monetScheme,
        paletteCorners: deriveMeshCornerPalette(
          dominant: dominantColor,
          monetScheme: widget.inputs.monetScheme,
        ),
        phase: ((signature & 0xFFFF) / 0xFFFF) * math.pi * 2.0,
      ),
    );

    if (_scene.current?.signature == signature) {
      setState(() {
        _scene = MeshGradientTransitionState(
          previous: _scene.previous,
          current: nextSnapshot,
        );
      });
      return;
    }

    final nextScene = _scene.push(nextSnapshot);
    final shouldAnimateTransition = animate && nextScene.previous != null;

    setState(() {
      _scene = nextScene;
    });

    if (shouldAnimateTransition) {
      _transitionController.forward(from: 0.0);
    } else {
      _transitionController.value = 1.0;
      setState(() {
        _scene = nextScene.settle();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_scene.current == null) {
      return ColoredBox(color: widget.fallbackColor);
    }

    final transitionValue = _scene.previous == null
        ? 1.0
        : Curves.easeInOutCubic.transform(_transitionController.value);

    return RepaintBoundary(
      child: CustomPaint(
        painter: _MeshGradientPainter(
          fallbackColor: widget.fallbackColor,
          scene: _scene,
          transitionValue: transitionValue,
          time: _time,
          lowFreqVolume: _lowFreqVolume,
          intensity: widget.inputs.intensity,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _MeshLayerPayload {
  final int signature;
  final AmllControlPointPreset preset;
  final int dominantColorValue;
  final MonetColorScheme? monetScheme;
  final List<Color> paletteCorners;
  final double phase;

  const _MeshLayerPayload({
    required this.signature,
    required this.preset,
    required this.dominantColorValue,
    required this.monetScheme,
    required this.paletteCorners,
    required this.phase,
  });
}

class _MeshGradientPainter extends CustomPainter {
  final Color fallbackColor;
  final MeshGradientTransitionState<_MeshLayerPayload> scene;
  final double transitionValue;
  final double time;
  final double lowFreqVolume;
  final double intensity;

  const _MeshGradientPainter({
    required this.fallbackColor,
    required this.scene,
    required this.transitionValue,
    required this.time,
    required this.lowFreqVolume,
    required this.intensity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!size.isFinite || size.width <= 1 || size.height <= 1) {
      return;
    }

    canvas.drawRect(Offset.zero & size, Paint()..color = fallbackColor);

    final previous = scene.previous;
    final current = scene.current;
    if (current == null) return;

    if (previous != null && transitionValue < 1.0) {
      _paintLayer(
        canvas,
        size,
        previous.payload,
        (1.0 - transitionValue).clamp(0.0, 1.0),
      );
    }

    _paintLayer(
      canvas,
      size,
      current.payload,
      (previous == null ? 1.0 : transitionValue).clamp(0.0, 1.0),
    );
  }

  void _paintLayer(
    Canvas canvas,
    Size size,
    _MeshLayerPayload payload,
    double alpha,
  ) {
    if (alpha <= 0.001) return;

    final grid = _buildAnimatedGrid(payload);
    final geometry = AmllBhpMeshGenerator.generate(
      controlPoints: grid,
      subdivisions: _MeshGradientBackgroundState._subdivisions,
    );

    _paintBaseGradient(canvas, size, payload.paletteCorners, alpha);
    _paintAmbientWash(canvas, size, payload.paletteCorners, alpha);
    _paintCurveSweep(canvas, size, geometry, payload.paletteCorners, alpha);
    _paintGlowBlobs(canvas, size, geometry, payload.paletteCorners, alpha);
    _paintSoftMist(canvas, size, geometry, payload.paletteCorners, alpha);
    _paintVignette(canvas, size, alpha);
  }

  void _paintBaseGradient(
    Canvas canvas,
    Size size,
    List<Color> corners,
    double alpha,
  ) {
    final baseStops = [0.0, 0.28, 0.72, 1.0];
    final baseShader = ui.Gradient.linear(
      Offset(0, 0),
      Offset(size.width, size.height),
      [
        Color.lerp(corners[0], corners[1], 0.25)!.withValues(alpha: 0.92 * alpha),
        Color.lerp(corners[0], corners[2], 0.45)!.withValues(alpha: 0.84 * alpha),
        Color.lerp(corners[3], corners[2], 0.55)!.withValues(alpha: 0.88 * alpha),
        corners[3].withValues(alpha: 0.95 * alpha),
      ],
      baseStops,
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = baseShader,
    );
  }

  void _paintGlowBlobs(
    Canvas canvas,
    Size size,
    AmllBhpMeshGeometry geometry,
    List<Color> corners,
    double alpha,
  ) {
    final blobSpecs = <({double u, double v, int colorIndex, double radiusScale})>[
      (u: 0.22, v: 0.18, colorIndex: 0, radiusScale: 0.36),
      (u: 0.76, v: 0.28, colorIndex: 1, radiusScale: 0.28),
      (u: 0.33, v: 0.76, colorIndex: 2, radiusScale: 0.32),
    ];
    final minSide = math.min(size.width, size.height);

    for (final blob in blobSpecs) {
      final center = _samplePoint(
        geometry,
        size,
        u: blob.u,
        v: blob.v,
      );
      final radius = minSide *
          (blob.radiusScale +
              lowFreqVolume * 0.018 +
              math.sin(time * 0.14 + blob.colorIndex * 0.7) * 0.008);
      final color = corners[blob.colorIndex].withValues(
        alpha: (0.08 + alpha * 0.12).clamp(0.0, 0.18),
      );
      final shader = ui.Gradient.radial(
        center,
        radius,
        [
          color,
          color.withValues(alpha: color.a * 0.38),
          Colors.transparent,
        ],
        const [0.0, 0.48, 1.0],
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = shader
          ..blendMode = BlendMode.plus
          ..isAntiAlias = true,
      );
    }
  }

  void _paintAmbientWash(
    Canvas canvas,
    Size size,
    List<Color> colors,
    double alpha,
  ) {
    final washShader = ui.Gradient.linear(
      Offset(-size.width * 0.12, size.height * 0.08),
      Offset(size.width * 1.08, size.height * 0.82),
      [
        colors[0].withValues(alpha: 0.0),
        Color.lerp(colors[1], colors[2], 0.4)!.withValues(alpha: 0.10 * alpha),
        Color.lerp(colors[2], colors[3], 0.55)!.withValues(alpha: 0.16 * alpha),
        colors[3].withValues(alpha: 0.0),
      ],
      const [0.0, 0.26, 0.62, 1.0],
    );

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = washShader
        ..blendMode = BlendMode.screen,
    );
  }

  void _paintCurveSweep(
    Canvas canvas,
    Size size,
    AmllBhpMeshGeometry geometry,
    List<Color> colors,
    double alpha,
  ) {
    final minSide = math.min(size.width, size.height);
    final primaryBand = _buildCurveBandPath(
      geometry,
      size,
      base: 0.18,
      slope: 0.48,
      drift: 0.03,
      thickness: minSide * 0.24,
    );
    final primaryBounds = primaryBand.getBounds();
    canvas.drawPath(
      primaryBand,
      Paint()
        ..shader = ui.Gradient.linear(
          primaryBounds.topLeft,
          primaryBounds.bottomRight,
          [
            colors[1].withValues(alpha: 0.0),
            Color.lerp(colors[1], colors[2], 0.45)!
                .withValues(alpha: 0.18 * alpha),
            colors[2].withValues(alpha: 0.08 * alpha),
            colors[2].withValues(alpha: 0.0),
          ],
          const [0.0, 0.32, 0.68, 1.0],
        )
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 52)
        ..blendMode = BlendMode.screen
        ..isAntiAlias = true,
    );

    final secondaryBand = _buildCurveBandPath(
      geometry,
      size,
      base: 0.66,
      slope: -0.18,
      drift: 0.02,
      thickness: minSide * 0.15,
    );
    final secondaryBounds = secondaryBand.getBounds();
    canvas.drawPath(
      secondaryBand,
      Paint()
        ..shader = ui.Gradient.linear(
          secondaryBounds.topLeft,
          secondaryBounds.bottomRight,
          [
            colors[0].withValues(alpha: 0.0),
            Color.lerp(colors[0], colors[3], 0.55)!
                .withValues(alpha: 0.09 * alpha),
            colors[3].withValues(alpha: 0.0),
          ],
          const [0.0, 0.5, 1.0],
        )
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 44)
        ..blendMode = BlendMode.screen
        ..isAntiAlias = true,
    );
  }

  void _paintSoftMist(
    Canvas canvas,
    Size size,
    AmllBhpMeshGeometry geometry,
    List<Color> colors,
    double alpha,
  ) {
    final topCenter = _samplePoint(geometry, size, u: 0.54, v: 0.22);
    final lowerCenter = _samplePoint(geometry, size, u: 0.48, v: 0.72);
    final minSide = math.min(size.width, size.height);

    for (final spec in [
      (
        center: topCenter,
        radius: minSide * (0.52 + lowFreqVolume * 0.03),
        color: Color.lerp(colors[0], colors[1], 0.35)!,
      ),
      (
        center: lowerCenter,
        radius: minSide * (0.42 + lowFreqVolume * 0.02),
        color: Color.lerp(colors[2], colors[3], 0.42)!,
      ),
    ]) {
      final shader = ui.Gradient.radial(
        spec.center,
        spec.radius,
        [
          spec.color.withValues(alpha: 0.06 * alpha),
          spec.color.withValues(alpha: 0.025 * alpha),
          Colors.transparent,
        ],
        const [0.0, 0.56, 1.0],
      );
      canvas.drawCircle(
        spec.center,
        spec.radius,
        Paint()
          ..shader = shader
          ..blendMode = BlendMode.screen
          ..isAntiAlias = true,
      );
    }
  }

  void _paintVignette(Canvas canvas, Size size, double alpha) {
    final center = Offset(size.width * 0.52, size.height * 0.48);
    final radius = math.max(size.width, size.height) * 0.82;
    final shader = ui.Gradient.radial(
      center,
      radius,
      [
        Colors.transparent,
        Colors.black.withValues(alpha: 0.08 * alpha),
        Colors.black.withValues(alpha: 0.28 * alpha),
      ],
      const [0.0, 0.68, 1.0],
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = shader,
    );
  }

  Map2D<ControlPoint> _buildAnimatedGrid(_MeshLayerPayload payload) {
    final grid = buildAmllControlPointGrid(
      preset: payload.preset,
      dominantColorValue: payload.dominantColorValue,
      monetScheme: payload.monetScheme,
    );
    final width = grid.width;
    final height = grid.height;
    final amplitude = (0.02 + lowFreqVolume * 0.022) *
        intensity.clamp(0.45, 1.25);

    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        final cp = grid.at(x, y);
        final u = width == 1 ? 0.0 : x / (width - 1);
        final v = height == 1 ? 0.0 : y / (height - 1);
        final centerWeight = math.pow(
          math.sin(u * math.pi) * math.sin(v * math.pi),
          0.82,
        ).toDouble();
        final phase = payload.phase + x * 0.58 + y * 0.81;
        final xWave = math.sin(time * 0.13 + phase) +
            math.cos(time * 0.075 + phase * 0.7) * 0.38;
        final yWave = math.cos(time * 0.11 + phase * 1.12) +
            math.sin(time * 0.06 + phase * 0.63) * 0.30;
        final pulse = 1.0 + lowFreqVolume * 0.06;

        cp.x = (cp.x + xWave * amplitude * centerWeight).clamp(-1.0, 1.0);
        cp.y = (cp.y + yWave * amplitude * centerWeight).clamp(-1.0, 1.0);
        cp.uScale *= pulse;
        cp.vScale *= pulse;
      }
    }

    return grid;
  }

  Offset _samplePoint(
    AmllBhpMeshGeometry geometry,
    Size size, {
    required double u,
    required double v,
  }) {
    final vx = (u * (geometry.vertexWidth - 1))
        .round()
        .clamp(0, geometry.vertexWidth - 1);
    final vy = (v * (geometry.vertexHeight - 1))
        .round()
        .clamp(0, geometry.vertexHeight - 1);
    final vertex = geometry.vertexAt(vx: vx, vy: vy);
    return Offset(
      (vertex.x + 1.0) * 0.5 * size.width,
      (vertex.y + 1.0) * 0.5 * size.height,
    );
  }

  Path _buildCurveBandPath(
    AmllBhpMeshGeometry geometry,
    Size size, {
    required double base,
    required double slope,
    required double drift,
    required double thickness,
  }) {
    final centerLine = <Offset>[];
    for (var i = 0; i < 7; i++) {
      final u = i / 6;
      final wave = math.sin(time * 0.10 + u * math.pi * 1.28) * drift +
          lowFreqVolume * 0.01;
      final v = (base + slope * u + wave).clamp(0.06, 0.94);
      centerLine.add(_samplePoint(geometry, size, u: u, v: v));
    }

    final top = <Offset>[];
    final bottom = <Offset>[];
    for (var i = 0; i < centerLine.length; i++) {
      final current = centerLine[i];
      final previous = i == 0 ? centerLine[i] : centerLine[i - 1];
      final next =
          i == centerLine.length - 1 ? centerLine[i] : centerLine[i + 1];
      final tangent = next - previous;
      final length = tangent.distance == 0 ? 1.0 : tangent.distance;
      final normal = Offset(-tangent.dy / length, tangent.dx / length);
      top.add(current + normal * (thickness * 0.5));
      bottom.add(current - normal * (thickness * 0.5));
    }

    return _buildSmoothClosedPath([
      ...top,
      ...bottom.reversed,
    ]);
  }

  Path _buildSmoothClosedPath(List<Offset> points) {
    final path = Path();
    if (points.length < 3) return path;
    path.moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length; i++) {
      final current = points[i];
      final next = points[(i + 1) % points.length];
      final mid = Offset(
        (current.dx + next.dx) / 2,
        (current.dy + next.dy) / 2,
      );
      path.quadraticBezierTo(current.dx, current.dy, mid.dx, mid.dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _MeshGradientPainter oldDelegate) {
    return oldDelegate.scene != scene ||
        oldDelegate.transitionValue != transitionValue ||
        oldDelegate.time != time ||
        oldDelegate.lowFreqVolume != lowFreqVolume ||
        oldDelegate.intensity != intensity ||
        oldDelegate.fallbackColor != fallbackColor;
  }
}

int _computeBackgroundSignature(Uint8List? coverBytes, Color fallbackColor) {
  var hash = 0x811C9DC5;

  void mix(int value) {
    hash ^= value & 0xFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }

  if (coverBytes != null && coverBytes.isNotEmpty) {
    final stride = math.max(1, coverBytes.length ~/ 1024);
    for (var i = 0; i < coverBytes.length; i += stride) {
      mix(coverBytes[i]);
    }
    mix(coverBytes.length & 0xFF);
    mix((coverBytes.length >> 8) & 0xFF);
  } else {
    mix((fallbackColor.r * 255).round());
    mix((fallbackColor.g * 255).round());
    mix((fallbackColor.b * 255).round());
  }

  return hash;
}
