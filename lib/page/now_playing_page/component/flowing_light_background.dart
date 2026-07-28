import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

const _kDecodeSize = 300;
const _kRenderSize = 200.0;
const _kBlurSigma = 25.0;
const _kFrameInterval = Duration(milliseconds: 42);
const _kArtworkTransitionDuration = Duration(milliseconds: 500);

const _kPeriod1 = 100.0;
const _kPeriod2 = 70.0;
const _kPeriod3 = 40.0;

const _kSaturationMatrix = <double>[
  2.18,
  -1.07,
  -0.108,
  0,
  0,
  -0.32,
  1.43,
  -0.108,
  0,
  0,
  -0.32,
  -1.07,
  2.39,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
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
  ui.Image? _previousCoverImage;
  Color _baseColor = Colors.black;
  Color _previousBaseColor = Colors.black;
  double _previousMotionTime = 0;
  _DecodedCover? _pendingCover;

  late final Stopwatch _motionClock;
  late final Stopwatch _transitionClock;
  late final Ticker _ticker;
  Duration? _lastPaintElapsed;

  final ValueNotifier<int> _frameNotifier = ValueNotifier(0);
  int _decodeGeneration = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _motionClock = Stopwatch();
    _transitionClock = Stopwatch();
    _ticker = createTicker(_onTick);
    _scheduleCoverDecode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncAnimationState();
    });
  }

  @override
  void didUpdateWidget(covariant FlowingLightBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      widget.inputs.albumCoverBytes,
      oldWidget.inputs.albumCoverBytes,
    )) {
      _scheduleCoverDecode();
    }
    _syncAnimationState();
  }

  void _syncAnimationState() {
    if (_disposed) return;
    final shouldMove = _coverImage != null && widget.inputs.shouldAnimate;
    final shouldTransition =
        _previousCoverImage != null && widget.inputs.isVisible;

    if (shouldMove) {
      _motionClock.start();
    } else {
      _motionClock.stop();
    }
    if (shouldTransition) {
      _transitionClock.start();
    } else {
      _transitionClock.stop();
    }

    final shouldTick = shouldMove || shouldTransition;
    if (shouldTick && !_ticker.isActive) {
      _lastPaintElapsed = null;
      _ticker.start();
    } else if (!shouldTick && _ticker.isActive) {
      _ticker.stop();
      _lastPaintElapsed = null;
    }
  }

  void _onTick(Duration elapsed) {
    if (_disposed || !mounted) return;
    final lastPaintElapsed = _lastPaintElapsed;
    if (lastPaintElapsed == null) {
      _lastPaintElapsed = elapsed;
    } else {
      final sinceLastPaint = elapsed - lastPaintElapsed;
      if (sinceLastPaint < _kFrameInterval) return;
      final completedIntervals =
          sinceLastPaint.inMicroseconds ~/ _kFrameInterval.inMicroseconds;
      _lastPaintElapsed =
          lastPaintElapsed + _kFrameInterval * completedIntervals;
    }

    if (_previousCoverImage != null &&
        _transitionClock.elapsed >= _kArtworkTransitionDuration) {
      _finishArtworkTransition();
      return;
    }
    _frameNotifier.value++;
  }

  Future<void> _scheduleCoverDecode() async {
    final generation = ++_decodeGeneration;
    final bytes = widget.inputs.albumCoverBytes;
    if (bytes == null || bytes.isEmpty) {
      _clearArtwork();
      return;
    }

    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _kDecodeSize,
        targetHeight: _kDecodeSize,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final baseColor = await _sampleBaseColor(image, widget.fallbackColor);
      if (_disposed || !mounted || generation != _decodeGeneration) {
        image.dispose();
        return;
      }
      final decoded = _DecodedCover(image, baseColor);
      image = null;
      _acceptDecodedCover(decoded);
    } catch (_) {
      image?.dispose();
    } finally {
      codec?.dispose();
    }
  }

  Future<Color> _sampleBaseColor(ui.Image image, Color fallbackColor) async {
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return fallbackColor;
      final pixels = data.buffer.asUint8List();
      final width = image.width;
      final height = image.height;
      var red = 0;
      var green = 0;
      var blue = 0;
      var count = 0;

      for (var row = 0; row < 5; row++) {
        final y = (((row + 0.5) * height) / 5).floor().clamp(0, height - 1);
        for (var column = 0; column < 5; column++) {
          final x = (((column + 0.5) * width) / 5).floor().clamp(0, width - 1);
          final offset = (y * width + x) * 4;
          if (offset + 3 >= pixels.length) continue;
          final alpha = pixels[offset + 3];
          red += pixels[offset] * alpha ~/ 255;
          green += pixels[offset + 1] * alpha ~/ 255;
          blue += pixels[offset + 2] * alpha ~/ 255;
          count++;
        }
      }
      if (count == 0) return fallbackColor;
      return Color.fromARGB(
        255,
        (red / count).floor().clamp(0, 255),
        (green / count).floor().clamp(0, 255),
        (blue / count).floor().clamp(0, 255),
      );
    } catch (_) {
      return fallbackColor;
    }
  }

  void _acceptDecodedCover(_DecodedCover decoded) {
    if (_previousCoverImage != null) {
      _pendingCover?.image.dispose();
      _pendingCover = decoded;
      return;
    }
    if (_coverImage == null) {
      setState(() {
        _coverImage = decoded.image;
        _baseColor = decoded.baseColor;
      });
      _syncAnimationState();
      return;
    }
    _startArtworkTransition(decoded);
  }

  void _startArtworkTransition(_DecodedCover decoded) {
    final currentTime = _motionTime;
    setState(() {
      _previousCoverImage = _coverImage;
      _previousBaseColor = _baseColor;
      _previousMotionTime = currentTime;
      _coverImage = decoded.image;
      _baseColor = decoded.baseColor;
      _transitionClock
        ..stop()
        ..reset();
    });
    _syncAnimationState();
  }

  void _finishArtworkTransition() {
    final completedPrevious = _previousCoverImage;
    final pending = _pendingCover;
    _pendingCover = null;
    completedPrevious?.dispose();

    if (pending == null) {
      setState(() {
        _previousCoverImage = null;
        _transitionClock
          ..stop()
          ..reset();
      });
    } else {
      final currentTime = _motionTime;
      setState(() {
        _previousCoverImage = _coverImage;
        _previousBaseColor = _baseColor;
        _previousMotionTime = currentTime;
        _coverImage = pending.image;
        _baseColor = pending.baseColor;
        _transitionClock
          ..stop()
          ..reset();
      });
    }
    _syncAnimationState();
  }

  void _clearArtwork() {
    _coverImage?.dispose();
    _previousCoverImage?.dispose();
    _pendingCover?.image.dispose();
    _coverImage = null;
    _previousCoverImage = null;
    _pendingCover = null;
    _transitionClock
      ..stop()
      ..reset();
    if (mounted) setState(() {});
    _syncAnimationState();
  }

  double get _motionTime =>
      _motionClock.elapsedMicroseconds /
      Duration.microsecondsPerSecond *
      widget.inputs.flowSpeed;

  @override
  void dispose() {
    _disposed = true;
    _decodeGeneration++;
    _ticker.dispose();
    _motionClock.stop();
    _transitionClock.stop();
    _coverImage?.dispose();
    _previousCoverImage?.dispose();
    _pendingCover?.image.dispose();
    _frameNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final coverImage = _coverImage;
    if (coverImage == null) {
      return ColoredBox(color: widget.fallbackColor);
    }

    final overlays =
        scheme.brightness == Brightness.dark ? _kDarkOverlays : _kLightOverlays;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: widget.fallbackColor),
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _kRenderSize,
            height: _kRenderSize,
            child: CustomPaint(
              painter: _FlowingLightPainter(
                coverImage: coverImage,
                baseColor: _baseColor,
                previousCoverImage: _previousCoverImage,
                previousBaseColor: _previousBaseColor,
                previousMotionTime: _previousMotionTime,
                motionClock: _motionClock,
                transitionClock: _transitionClock,
                flowSpeed: widget.inputs.flowSpeed,
                overlays: overlays,
                repaint: _frameNotifier,
              ),
              size: const Size.square(_kRenderSize),
            ),
          ),
        ),
      ],
    );
  }
}

class _DecodedCover {
  const _DecodedCover(this.image, this.baseColor);

  final ui.Image image;
  final Color baseColor;
}

class _FlowingLightPainter extends CustomPainter {
  _FlowingLightPainter({
    required this.coverImage,
    required this.baseColor,
    required this.previousCoverImage,
    required this.previousBaseColor,
    required this.previousMotionTime,
    required this.motionClock,
    required this.transitionClock,
    required this.flowSpeed,
    required this.overlays,
    required ValueNotifier<int> repaint,
  }) : super(repaint: repaint);

  final ui.Image coverImage;
  final Color baseColor;
  final ui.Image? previousCoverImage;
  final Color previousBaseColor;
  final double previousMotionTime;
  final Stopwatch motionClock;
  final Stopwatch transitionClock;
  final double flowSpeed;
  final List<Color> overlays;

  static const _artworkCurve = Cubic(0, 0, 0.3, 1);
  static const _saturationFilter = ui.ColorFilter.matrix(_kSaturationMatrix);
  static final _blurFilter = ui.ImageFilter.blur(
    sigmaX: _kBlurSigma,
    sigmaY: _kBlurSigma,
  );

  final ui.Paint _blurPaint = ui.Paint()..imageFilter = _blurFilter;
  final ui.Paint _coverPaint = ui.Paint()..colorFilter = _saturationFilter;

  double get _motionTime =>
      motionClock.elapsedMicroseconds /
      Duration.microsecondsPerSecond *
      flowSpeed;

  double get _transitionProgress {
    if (previousCoverImage == null) return 1;
    final linear = transitionClock.elapsedMicroseconds /
        _kArtworkTransitionDuration.inMicroseconds;
    return _artworkCurve.transform(linear.clamp(0.0, 1.0));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final previous = previousCoverImage;
    if (previous != null) {
      _drawFrame(
        canvas,
        size,
        previous,
        previousBaseColor,
        previousMotionTime,
        1,
      );
    }
    _drawFrame(
      canvas,
      size,
      coverImage,
      baseColor,
      _motionTime,
      _transitionProgress,
    );
  }

  void _drawFrame(
    Canvas canvas,
    Size size,
    ui.Image image,
    Color fillColor,
    double time,
    double opacity,
  ) {
    final alpha = (opacity * 255).round().clamp(0, 255);
    if (alpha == 0) return;
    _blurPaint.color =
        alpha == 255 ? Colors.white : Color.fromARGB(alpha, 255, 255, 255);
    canvas.saveLayer(null, _blurPaint);
    canvas.drawColor(fillColor, BlendMode.src);

    final scale = 1.5 *
        max(
          size.width / image.width,
          size.height / image.height,
        );
    _drawLayer(canvas, size, image, scale, time / _kPeriod1 * 2 * pi, 0, 0);
    _drawLayer(
      canvas,
      size,
      image,
      scale,
      -time / _kPeriod2 * 2 * pi,
      -0.95,
      -0.70,
    );
    _drawLayer(
      canvas,
      size,
      image,
      scale,
      -time / _kPeriod3 * 2 * pi,
      -0.50,
      0.70,
      rotateAroundOutputCenter: true,
    );

    for (final overlay in overlays) {
      canvas.drawColor(overlay, BlendMode.srcOver);
    }
    canvas.restore();
  }

  void _drawLayer(
    Canvas canvas,
    Size size,
    ui.Image image,
    double scale,
    double angle,
    double offsetX,
    double offsetY, {
    bool rotateAroundOutputCenter = false,
  }) {
    canvas.save();
    if (rotateAroundOutputCenter) {
      canvas.translate(size.width / 2, size.height / 2);
      canvas.rotate(angle);
      canvas.translate(offsetX * size.width, offsetY * size.height);
      canvas.rotate(angle);
    } else {
      canvas.translate(
        size.width / 2 + offsetX * size.width,
        size.height / 2 + offsetY * size.height,
      );
      canvas.rotate(angle);
    }
    final width = image.width * scale;
    final height = image.height * scale;
    canvas.translate(-width / 2, -height / 2);
    canvas.scale(scale, scale);
    canvas.drawImage(image, Offset.zero, _coverPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FlowingLightPainter oldDelegate) {
    return oldDelegate.coverImage != coverImage ||
        oldDelegate.baseColor != baseColor ||
        oldDelegate.previousCoverImage != previousCoverImage ||
        oldDelegate.previousBaseColor != previousBaseColor ||
        oldDelegate.previousMotionTime != previousMotionTime ||
        oldDelegate.flowSpeed != flowSpeed ||
        oldDelegate.overlays != overlays;
  }

  @override
  bool? hitTest(Offset position) => null;
}
