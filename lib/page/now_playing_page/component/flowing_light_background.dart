import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

const _kDecodeSize = 300;
const _kRenderSize = 200.0;
const _kBlurSigma = 8.0;
const _kOverlayAlpha = 0.10;

const _kPeriod1 = 21.0;
const _kPeriod2 = 13.0;
const _kPeriod3 = 8.0;

const _kWaveAmp = 0.06;

const _kSaturationMatrix = <double>[
  2.18, -1.07, -0.108, 0, 0,
  -0.32, 1.43, -0.108, 0, 0,
  -0.32, -1.07, 2.39, 0, 0,
  0, 0, 0, 1, 0,
];

const _kDarkOverlays = [Color(0x52000000), Color(0x1A000000)];
const _kLightOverlays = [Color(0x95FFFFFF), Color(0x2AFFFFFF)];

class FlowingLightBackground extends StatefulWidget {
  final NowPlayingBackgroundInputs inputs;
  final Color fallbackColor;

  const FlowingLightBackground({
    super.key,
    required this.inputs,
    required this.fallbackColor,
  });

  @override
  State<FlowingLightBackground> createState() => _FlowingLightBackgroundState();
}

class _FlowingLightBackgroundState extends State<FlowingLightBackground>
    with SingleTickerProviderStateMixin {
  ui.Image? _coverImage;
  Color _baseColor = Colors.black;

  double _elapsed = 0;
  double _angle1 = 0;
  double _angle2 = 0;
  double _angle3 = 0;

  late final Ticker _ticker;
  bool _disposed = false;

  final ValueNotifier<int> _frameNotifier = ValueNotifier(0);
  int _lastCoverFingerprint = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _scheduleCoverDecode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncTicker();
    });
  }

  @override
  void didUpdateWidget(covariant FlowingLightBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newBytes = widget.inputs.albumCoverBytes;
    final oldBytes = oldWidget.inputs.albumCoverBytes;
    if (!identical(newBytes, oldBytes)) {
      _scheduleCoverDecode();
    }
    _syncTicker();
  }

  void _syncTicker() {
    final shouldRun = widget.inputs.isVisible;
    if (shouldRun && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
      _frameNotifier.value++;
    }
  }

  void _onTick(Duration elapsed) {
    if (_disposed || !mounted) return;
    final ms = elapsed.inMilliseconds;
    _elapsed = (ms / 1000.0) % 3600;
    _angle1 = (ms / (_kPeriod1 * 1000) * 360) % 360;
    _angle2 = (ms / (_kPeriod2 * 1000) * -360) % 360;
    _angle3 = (ms / (_kPeriod3 * 1000) * -360) % 360;
    _frameNotifier.value++;
  }

  int _coverFingerprint(Uint8List bytes) {
    var hash = bytes.length;
    final step = (bytes.length / 512).ceil();
    for (var i = 0; i < bytes.length; i += step) {
      hash = 0x1fffffff & (hash * 31 + bytes[i]);
    }
    return hash;
  }

  Future<void> _scheduleCoverDecode() async {
    final bytes = widget.inputs.albumCoverBytes;
    if (bytes == null || bytes.isEmpty) {
      _coverImage?.dispose();
      _coverImage = null;
      _baseColor = widget.fallbackColor;
      return;
    }
    final fingerprint = _coverFingerprint(bytes);
    if (fingerprint == _lastCoverFingerprint) return;
    _lastCoverFingerprint = fingerprint;

    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _kDecodeSize,
        targetHeight: _kDecodeSize,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (_disposed || !mounted) {
        frame.image.dispose();
        return;
      }
      _coverImage?.dispose();
      _coverImage = frame.image;
      _computeBaseColor(frame.image);
      _frameNotifier.value++;
    } catch (_) {}
  }

  void _computeBaseColor(ui.Image image) {
    image.toByteData().then((data) {
      if (_disposed || !mounted || data == null) return;
      final pixels = data.buffer.asUint8List();
      final w = image.width;
      final h = image.height;
      var rSum = 0, gSum = 0, bSum = 0, count = 0;
      for (var row = 0; row < 5; row++) {
        final y = (((row + 0.5) * h) / 5).round().clamp(0, h - 1);
        for (var col = 0; col < 5; col++) {
          final x = (((col + 0.5) * w) / 5).round().clamp(0, w - 1);
          final offset = (y * w + x) * 4;
          if (offset + 3 >= pixels.length) continue;
          final a = pixels[offset + 3];
          rSum += pixels[offset] * a ~/ 255;
          gSum += pixels[offset + 1] * a ~/ 255;
          bSum += pixels[offset + 2] * a ~/ 255;
          count++;
        }
      }
      if (count > 0) {
        _baseColor = Color.fromARGB(
          255,
          (rSum / count).round().clamp(0, 255),
          (gSum / count).round().clamp(0, 255),
          (bSum / count).round().clamp(0, 255),
        );
      } else {
        _baseColor = widget.fallbackColor;
      }
      _frameNotifier.value++;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker.dispose();
    _coverImage?.dispose();
    _frameNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final overlays = isDark ? _kDarkOverlays : _kLightOverlays;

    if (_coverImage == null) {
      return ColoredBox(color: scheme.surface);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: scheme.surface),
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _kRenderSize,
            height: _kRenderSize,
            child: CustomPaint(
              painter: _FlowingLightPainter(
                coverImage: _coverImage!,
                baseColor: _baseColor,
                angle1: _angle1,
                angle2: _angle2,
                angle3: _angle3,
                elapsed: _elapsed,
                overlays: overlays,
                repaint: _frameNotifier,
              ),
              size: const Size(_kRenderSize, _kRenderSize),
            ),
          ),
        ),
        Container(color: scheme.surface.withValues(alpha: _kOverlayAlpha)),
      ],
    );
  }
}

class _FlowingLightPainter extends CustomPainter {
  _FlowingLightPainter({
    required this.coverImage,
    required this.baseColor,
    required this.angle1,
    required this.angle2,
    required this.angle3,
    required this.elapsed,
    required this.overlays,
    required ValueNotifier<int> repaint,
  }) : super(repaint: repaint);

  final ui.Image coverImage;
  final Color baseColor;
  final double angle1;
  final double angle2;
  final double angle3;
  final double elapsed;
  final List<Color> overlays;

  static const _saturationFilter = ui.ColorFilter.matrix(_kSaturationMatrix);
  static final _blurPaint = ui.Paint()
    ..imageFilter = ui.ImageFilter.blur(
        sigmaX: _kBlurSigma, sigmaY: _kBlurSigma);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(null, _blurPaint);
    _drawContent(canvas, size);
    canvas.restore();

    _drawHighlight(canvas, size);

    for (final overlay in overlays) {
      canvas.drawColor(overlay, BlendMode.srcOver);
    }
  }

  void _drawContent(Canvas canvas, Size size) {
    canvas.drawColor(baseColor, BlendMode.src);

    final scale = 1.5 * size.width / coverImage.width;

    final t = elapsed;
    final kw = _kWaveAmp * size.width;
    final kh = _kWaveAmp * size.height;
    final dx1 = sin(t * 0.7) * kw;
    final dy1 = cos(t * 0.9) * kh;
    final dx2 = sin(t * 1.1 + 2.0) * kw * 1.2;
    final dy2 = cos(t * 0.8 + 1.5) * kh * 1.2;
    final dx3 = sin(t * 1.5 + 4.0) * kw * 1.5;
    final dy3 = cos(t * 1.3 + 3.0) * kh * 1.5;

    _drawLayer(canvas, size, scale, angle1,
        dx1 / size.width, dy1 / size.height, false);
    _drawLayer(canvas, size, scale, angle2,
        -0.95 + dx2 / size.width, -0.70 + dy2 / size.height, false);
    _drawLayer(canvas, size, scale, angle3,
        -0.50 + dx3 / size.width, 0.70 + dy3 / size.height, true);
  }

  void _drawHighlight(Canvas canvas, Size size) {
    final t = elapsed;
    final cx = size.width * (0.5 + 0.35 * sin(t * 0.4));
    final cy = size.height * (0.5 + 0.35 * cos(t * 0.55));
    final radius = size.width * 0.6;

    final gradient = ui.Gradient.radial(
      Offset(cx, cy),
      radius,
      [const Color(0x30FFFFFF), const Color(0x00FFFFFF)],
    );

    canvas.drawRect(
      Offset.zero & size,
      ui.Paint()..shader = gradient,
    );
  }

  void _drawLayer(Canvas canvas, Size size, double scale,
      double angleDeg, double offsetX, double offsetY,
      bool centerRotate) {
    canvas.save();

    if (centerRotate) {
      canvas.translate(size.width / 2, size.height / 2);
      canvas.rotate(angleDeg * 3.1415926535 / 180.0);
      canvas.translate(offsetX * size.width, offsetY * size.height);
    } else {
      canvas.translate(size.width / 2 + offsetX * size.width,
          size.height / 2 + offsetY * size.height);
      canvas.rotate(angleDeg * 3.1415926535 / 180.0);
    }

    final sw = coverImage.width * scale;
    final sh = coverImage.height * scale;
    canvas.translate(-sw / 2, -sh / 2);
    canvas.scale(scale, scale);
    canvas.drawImage(coverImage, Offset.zero, _coverPaint);
    canvas.restore();
  }

  static final ui.Paint _coverPaint =
      ui.Paint()..colorFilter = _saturationFilter;

  @override
  bool shouldRepaint(_FlowingLightPainter oldDelegate) => false;

  @override
  bool? hitTest(Offset position) => null;
}
