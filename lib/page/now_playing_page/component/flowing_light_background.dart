import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:pure_music/page/now_playing_page/component/audio_reactive_flow.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

const _kDecodeSize = 512;
const _kRenderSize = 512.0;
const _kBlurSigma = 35.0;
const _kFrameInterval = Duration(milliseconds: 42);
const _kArtworkTransitionDuration = Duration(milliseconds: 500);

const _kPeriod1 = 100.0;
const _kPeriod2 = 70.0;
const _kPeriod3 = 40.0;

const _kPrimaryLayerScale = 1.38;
const _kSecondaryLayerScale = 1.58;
const _kLightLayerScale = 1.78;
const _kPrimaryLayerPhase = 0.08 * pi;
const _kSecondaryLayerPhase = -0.38 * pi;
const _kLightLayerPhase = 0.62 * pi;

const _kDarkOverlays = <Color>[];
const _kLightOverlays = <Color>[];

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
  final AudioReactiveFlowEnvelope _envelope = AudioReactiveFlowEnvelope();
  StreamSubscription<Float32List>? _spectrumSubscription;
  int _decodeGeneration = 0;
  bool _disposed = false;

  // Heartbeat pulse: spike on energy rise, then decay.
  double _pulseLow = 0;
  double _pulseMid = 0;
  double _pulseHigh = 0;
  double _lastEnvelopeLow = 0;
  double _lastEnvelopeMid = 0;
  double _lastEnvelopeHigh = 0;

  // EMA-smoothed audio for responsive speed modulation.
  double _smoothedLow = 0;
  double _smoothedMid = 0;
  double _smoothedHigh = 0;

  @override
  void initState() {
    super.initState();
    _motionClock = Stopwatch();
    _transitionClock = Stopwatch();
    _ticker = createTicker(_onTick);
    _scheduleCoverDecode();
    _subscribeSpectrum();
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
    if (!identical(
      widget.inputs.spectrumStream,
      oldWidget.inputs.spectrumStream,
    )) {
      _spectrumSubscription?.cancel();
      _subscribeSpectrum();
    }
    _syncAnimationState();
  }

  void _subscribeSpectrum() {
    final stream = widget.inputs.spectrumStream;
    if (stream == null) return;
    _spectrumSubscription = stream.listen(_handleSpectrum);
  }

  void _handleSpectrum(Float32List bands) {
    if (_disposed) return;
    final response = AudioReactiveFlowResponse.fromBands(bands);
    _envelope.update(response);
    // EMA smoothing (α=0.15) — gentle, musical feel.
    _smoothedLow = _smoothedLow * 0.85 + response.low.clamp(0.0, 1.0) * 0.15;
    _smoothedMid = _smoothedMid * 0.85 + response.mid.clamp(0.0, 1.0) * 0.15;
    _smoothedHigh = _smoothedHigh * 0.85 + response.high.clamp(0.0, 1.0) * 0.15;
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

    // Update heartbeat pulses every tick regardless of paint skip.
    _updatePulses();

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

  void _updatePulses() {
    if (!widget.inputs.audioReactiveFlow) {
      _pulseLow = 0;
      _pulseMid = 0;
      _pulseHigh = 0;
      return;
    }
    final env = _envelope.value;

    // Spike on energy rise, then exponential decay.
    if (env.low > _lastEnvelopeLow) {
      _pulseLow = (_pulseLow + env.low * 0.5).clamp(0.0, 1.0);
    } else {
      _pulseLow *= 0.88;
    }
    if (env.mid > _lastEnvelopeMid) {
      _pulseMid = (_pulseMid + env.mid * 0.5).clamp(0.0, 1.0);
    } else {
      _pulseMid *= 0.88;
    }
    if (env.high > _lastEnvelopeHigh) {
      _pulseHigh = (_pulseHigh + env.high * 0.5).clamp(0.0, 1.0);
    } else {
      _pulseHigh *= 0.88;
    }
    _lastEnvelopeLow = env.low;
    _lastEnvelopeMid = env.mid;
    _lastEnvelopeHigh = env.high;
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
    _spectrumSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final coverImage = _coverImage;
    final overlays =
        scheme.brightness == Brightness.dark ? _kDarkOverlays : _kLightOverlays;
    final response = _envelope.value;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: widget.fallbackColor),
        AnimatedOpacity(
          opacity: coverImage != null ? 1.0 : 0.0,
          duration: _kArtworkTransitionDuration,
          curve: Curves.easeOut,
          child: FittedBox(
            fit: BoxFit.cover,
            child: RepaintBoundary(
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
                    audioReactiveFlow: widget.inputs.audioReactiveFlow,
                    response: response,
                    smoothedLow: _smoothedLow,
                    smoothedMid: _smoothedMid,
                    smoothedHigh: _smoothedHigh,
                    pulseLow: _pulseLow,
                    pulseMid: _pulseMid,
                    pulseHigh: _pulseHigh,
                    overlays: overlays,
                    repaint: _frameNotifier,
                  ),
                  size: const Size.square(_kRenderSize),
                ),
              ),
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
    this.coverImage,
    required this.baseColor,
    required this.previousCoverImage,
    required this.previousBaseColor,
    required this.previousMotionTime,
    required this.motionClock,
    required this.transitionClock,
    required this.flowSpeed,
    required this.audioReactiveFlow,
    required this.response,
    required this.smoothedLow,
    required this.smoothedMid,
    required this.smoothedHigh,
    required this.pulseLow,
    required this.pulseMid,
    required this.pulseHigh,
    required this.overlays,
    required ValueNotifier<int> repaint,
  }) : super(repaint: repaint);

  final ui.Image? coverImage;
  final Color baseColor;
  final ui.Image? previousCoverImage;
  final Color previousBaseColor;
  final double previousMotionTime;
  final Stopwatch motionClock;
  final Stopwatch transitionClock;
  final double flowSpeed;
  final bool audioReactiveFlow;
  final AudioReactiveFlowResponse response;
  final double smoothedLow;
  final double smoothedMid;
  final double smoothedHigh;
  final double pulseLow;
  final double pulseMid;
  final double pulseHigh;
  final List<Color> overlays;

  static const _artworkCurve = Cubic(0, 0, 0.3, 1);
  static final _blurFilter = ui.ImageFilter.blur(
    sigmaX: _kBlurSigma,
    sigmaY: _kBlurSigma,
  );

  final ui.Paint _blurPaint = ui.Paint()..imageFilter = _blurFilter;
  final ui.Paint _coverPaint = ui.Paint();

  ui.Paint? _vignettePaint;

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
        response,
      );
    }
    _drawFrame(
      canvas,
      size,
      coverImage,
      baseColor,
      _motionTime,
      _transitionProgress,
      response,
    );
  }

  void _drawFrame(
    Canvas canvas,
    Size size,
    ui.Image? image,
    Color fillColor,
    double time,
    double opacity,
    AudioReactiveFlowResponse response,
  ) {
    final alpha = (opacity * 255).round().clamp(0, 255);
    if (alpha == 0 || image == null) return;
    _blurPaint.color =
        alpha == 255 ? Colors.white : Color.fromARGB(alpha, 255, 255, 255);
    canvas.saveLayer(null, _blurPaint);
    canvas.drawColor(fillColor.withValues(alpha: 0.10), BlendMode.src);

    // `time` already incorporates flowSpeed from _motionTime.
    // Audio adds a gentle speed nudge but stays musical — the breathing pulse
    // carries the rhythmic feel, not wild speed swings.
    final primarySpeed = audioReactiveFlow
        ? (1.0 + smoothedLow * 1.2)
        : 1.0;
    final secondarySpeed = audioReactiveFlow
        ? (1.0 + smoothedMid * 1.2)
        : 1.0;
    final lightSpeed = audioReactiveFlow
        ? (1.0 + smoothedHigh * 1.5)
        : 1.0;

    // Gentle orbital drift so layers don't just spin in place.
    final primaryDriftX = sin(time * 0.5) * 0.10;
    final primaryDriftY = cos(time * 0.6) * 0.10;
    final secondaryDriftX = sin(time * 0.7 + 1.0) * 0.08;
    final secondaryDriftY = cos(time * 0.8 + 1.0) * 0.08;
    final lightDriftX = sin(time * 0.9 + 2.0) * 0.12;
    final lightDriftY = cos(time * 1.0 + 2.0) * 0.12;

    // Heartbeat breathing: spike on energy rise, exponential decay.
    final primaryBreathe = audioReactiveFlow
        ? (1.0 + pulseLow * 0.15)
        : 1.0;
    final secondaryBreathe = audioReactiveFlow
        ? (1.0 + pulseMid * 0.15)
        : 1.0;
    final lightBreathe = audioReactiveFlow
        ? (1.0 + pulseHigh * 0.20)
        : 1.0;

    final baseScale = max(
      size.width / image.width,
      size.height / image.height,
    );
    _drawLayer(
      canvas,
      size,
      image,
      baseScale * _kPrimaryLayerScale * primaryBreathe,
      time / _kPeriod1 * 2 * pi * primarySpeed + _kPrimaryLayerPhase,
      primaryDriftX,
      primaryDriftY,
      _coverPaint,
    );
    _drawLayer(
      canvas,
      size,
      image,
      baseScale * _kSecondaryLayerScale * secondaryBreathe,
      -time / _kPeriod2 * 2 * pi * secondarySpeed + _kSecondaryLayerPhase,
      -0.95 + secondaryDriftX,
      -0.70 + secondaryDriftY,
      _coverPaint,
    );
    _drawLayer(
      canvas,
      size,
      image,
      baseScale * _kLightLayerScale * lightBreathe,
      -time / _kPeriod3 * 2 * pi * lightSpeed + _kLightLayerPhase,
      -0.50 + lightDriftX,
      0.70 + lightDriftY,
      _coverPaint,
      rotateAroundOutputCenter: true,
    );

    for (final overlay in overlays) {
      canvas.drawColor(overlay, BlendMode.srcOver);
    }

    // Subtle vignette for depth.
    _vignettePaint ??= ui.Paint()
      ..shader = ui.Gradient.radial(
        size.center(Offset.zero),
        size.longestSide * 0.7,
        [Colors.transparent, Colors.black.withValues(alpha: 0.10)],
      );
    canvas.drawRect(Offset.zero & size, _vignettePaint!);
    canvas.restore();
  }

  void _drawLayer(
    Canvas canvas,
    Size size,
    ui.Image image,
    double scale,
    double angle,
    double offsetX,
    double offsetY,
    ui.Paint paint, {
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
    canvas.drawImage(image, Offset.zero, paint);
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
        oldDelegate.audioReactiveFlow != audioReactiveFlow ||
        oldDelegate.response != response ||
        oldDelegate.smoothedLow != smoothedLow ||
        oldDelegate.smoothedMid != smoothedMid ||
        oldDelegate.smoothedHigh != smoothedHigh ||
        oldDelegate.pulseLow != pulseLow ||
        oldDelegate.pulseMid != pulseMid ||
        oldDelegate.pulseHigh != pulseHigh ||
        oldDelegate.overlays != overlays;
  }

  @override
  bool? hitTest(Offset position) => null;
}
