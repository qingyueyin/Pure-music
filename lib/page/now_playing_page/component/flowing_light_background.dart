import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/audio_reactive_flow.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

const _kDecodeSize = 512;
const _kRenderExtent = 320.0;
const _kBlurSigma = 12.0;
const _kDarkNeutralBackground = Color(0xFF171717);
const _kLightNeutralBackground = Color(0xFFF0F0F0);
const _kFrameInterval = Duration(milliseconds: 42);
const _kArtworkTransitionDuration = Duration(milliseconds: 300);

const _kPlaybackSpeedTransitionDuration = Duration(milliseconds: 650);

const _kPeriod1 = 54.0;
const _kPeriod2 = 40.0;
const _kPeriod3 = 30.0;

const _kPrimaryLayerScale = 1.30;
const _kSecondaryLayerScale = 1.50;
const _kLightLayerScale = 1.76;
const _kPrimaryLayerPhase = 0.0;
const _kSecondaryLayerPhase = -0.08 * pi;
const _kLightLayerPhase = 0.12 * pi;
const _kPrimaryLayerAlpha = 224;
const _kSecondaryLayerAlpha = 82;
const _kLightLayerAlpha = 56;
const _kWarpGridDivisions = 5;

enum _FlowingLightLayer { primary, secondary, light }

typedef _FlowingLightLayerMask = ({
  double centerX,
  double centerY,
  double radius,
  double middleStop,
  double outerStop,
  double middleAlpha,
});

final _kIdentityShaderMatrix = Float64List.fromList(<double>[
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
]);

final Float32List _kWarpNormalizedCoordinates = _buildWarpCoordinates();

Float32List _buildWarpCoordinates() {
  const cells = _kWarpGridDivisions - 1;
  const vertexCount = cells * cells * 6;
  final coordinates = Float32List(vertexCount * 2);
  var vertex = 0;

  void addVertex(double u, double v) {
    coordinates[vertex * 2] = u;
    coordinates[vertex * 2 + 1] = v;
    vertex++;
  }

  for (var row = 0; row < cells; row++) {
    final top = row / cells;
    final bottom = (row + 1) / cells;
    for (var column = 0; column < cells; column++) {
      final left = column / cells;
      final right = (column + 1) / cells;
      addVertex(left, top);
      addVertex(right, top);
      addVertex(right, bottom);
      addVertex(left, top);
      addVertex(right, bottom);
      addVertex(left, bottom);
    }
  }
  return coordinates;
}

const _kDarkFlowingLightStyle = _FlowingLightVisualStyle(
  edgeAlpha: 0.05,
  artworkSaturation: 1.18,
  artworkBrightness: 0.72,
  artworkBlackLift: 0.09,
  overlays: <Color>[
    Color(0x08000000),
  ],
);
const _kLightFlowingLightStyle = _FlowingLightVisualStyle(
  edgeAlpha: 0.04,
  artworkSaturation: 1.15,
  artworkBrightness: 1.0,
  artworkBlackLift: 0.0,
  overlays: <Color>[
    Color(0x14FFFFFF),
  ],
);

Size _flowingLightRenderSize(Size viewport) {
  if (viewport.isEmpty) return Size.zero;
  if (viewport.width >= viewport.height) {
    return Size(_kRenderExtent, _kRenderExtent / viewport.aspectRatio);
  }
  return Size(_kRenderExtent * viewport.aspectRatio, _kRenderExtent);
}

double flowingLightArtworkCropScale(Size output, Size artwork) {
  if (output.isEmpty || artwork.isEmpty) return 0;
  return max(
        output.width / artwork.width,
        output.height / artwork.height,
      ) *
      _kPrimaryLayerScale;
}

double flowingLightBreathingScale(
  double audioLevel, {
  double bassTransient = 0.0,
}) {
  return (1.0 +
          audioLevel.clamp(0.0, 1.0) * 0.09 +
          bassTransient.clamp(0.0, 1.0) * 0.26)
      .clamp(1.0, 1.30)
      .toDouble();
}

double flowingLightWarpStrength(
  double audioLevel, {
  double bassTransient = 0.0,
}) {
  final level =
      audioLevel.isFinite ? audioLevel.clamp(0.0, 1.0).toDouble() : 0.0;
  final transient =
      bassTransient.isFinite ? bassTransient.clamp(0.0, 1.0).toDouble() : 0.0;
  return (level * 0.018 + transient * 0.07).clamp(0.0, 0.085).toDouble();
}

double flowingLightArtworkOpacityCeiling() {
  const primary = _kPrimaryLayerAlpha / 255;
  const secondary = _kSecondaryLayerAlpha / 255;
  const light = _kLightLayerAlpha / 255;
  return 1 - (1 - primary) * (1 - secondary) * (1 - light);
}

class FlowingLightBackground extends StatefulWidget {
  final NowPlayingBackgroundInputs inputs;

  const FlowingLightBackground({
    super.key,
    required this.inputs,
  });

  @override
  State<FlowingLightBackground> createState() => _FlowingLightBackgroundState();
}

class _FlowingLightBackgroundState extends State<FlowingLightBackground>
    with SingleTickerProviderStateMixin {
  ui.Image? _coverImage;
  ui.Image? _previousCoverImage;
  double _previousMotionTime = 0;
  _DecodedCover? _pendingCover;

  late final Stopwatch _transitionClock;
  late final Ticker _ticker;
  final _FlowMotionState _motion = _FlowMotionState();
  Duration? _lastTickElapsed;
  Duration? _lastPaintElapsed;

  final ValueNotifier<int> _frameNotifier = ValueNotifier(0);
  final AudioReactiveFlowEnvelope _envelope = AudioReactiveFlowEnvelope();
  final AudioReactiveFlowNormalizer _normalizer = AudioReactiveFlowNormalizer();
  final AudioReactiveFlowTransientDetector _transientDetector =
      AudioReactiveFlowTransientDetector();
  final _FlowAudioState _audio = _FlowAudioState();
  final _FlowingLightShaderCache _shaderCache = _FlowingLightShaderCache();
  StreamSubscription<Float32List>? _spectrumSubscription;
  int _decodeGeneration = 0;
  bool _disposed = false;
  bool _tickerModeEnabled = true;

  // Smooth playback speed transition to avoid jerk on pause/resume.
  static const double _kIdleSpeed = 0.0;
  static const double _kActiveSpeed = 1.0;
  double _smoothedPlaybackSpeed = _kIdleSpeed;
  double _targetPlaybackSpeed = _kIdleSpeed;
  double _playbackSpeedTransitionFrom = _kIdleSpeed;
  double _playbackSpeedTransitionProgress = 1.0;

  @override
  void initState() {
    super.initState();
    _transitionClock = Stopwatch();
    _ticker = createTicker(_onTick);
    _scheduleCoverDecode();
    _syncSpectrumSubscription();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncAnimationState();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    if (_tickerModeEnabled == tickerModeEnabled) return;
    _tickerModeEnabled = tickerModeEnabled;
    _syncAnimationState();
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
      _spectrumSubscription = null;
    }
    if (!widget.inputs.audioReactiveFlow &&
        oldWidget.inputs.audioReactiveFlow) {
      _resetAudioResponse();
    }
    _syncAnimationState();
  }

  void _syncSpectrumSubscription() {
    final stream = widget.inputs.spectrumStream;
    final shouldListen = stream != null &&
        _tickerModeEnabled &&
        _coverImage != null &&
        widget.inputs.enableAnimation &&
        widget.inputs.audioReactiveFlow &&
        widget.inputs.isVisible &&
        widget.inputs.playerState == PlayerState.playing;
    if (shouldListen) {
      _spectrumSubscription ??= stream.listen(_handleSpectrum);
      return;
    }
    _spectrumSubscription?.cancel();
    _spectrumSubscription = null;
    _resetAudioResponse();
  }

  void _handleSpectrum(Float32List bands) {
    if (_disposed) return;
    final response = AudioReactiveFlowResponse.fromBands(bands);
    if (!widget.inputs.audioReactiveFlow) return;
    _audio.captureBass(_transientDetector.update(response.low));
    final normalized = _normalizer.update(response);
    _envelope.update(normalized);
  }

  void _resetAudioResponse() {
    _normalizer.reset();
    _transientDetector.reset();
    _envelope.reset();
    _audio.reset();
  }

  void _syncAnimationState() {
    if (_disposed) return;
    _syncSpectrumSubscription();
    final canMove = _coverImage != null &&
        _tickerModeEnabled &&
        widget.inputs.enableAnimation &&
        widget.inputs.isVisible;
    final isPlaying =
        canMove && widget.inputs.playerState == PlayerState.playing;
    _setPlaybackSpeedTarget(isPlaying ? _kActiveSpeed : _kIdleSpeed);

    final shouldMove = canMove &&
        (isPlaying ||
            _playbackSpeedTransitionProgress < 1.0 ||
            _smoothedPlaybackSpeed > _kIdleSpeed);
    final shouldTransition = _tickerModeEnabled &&
        _previousCoverImage != null &&
        widget.inputs.isVisible;

    if (shouldTransition) {
      _transitionClock.start();
    } else {
      _transitionClock.stop();
    }

    final shouldTick = shouldMove || shouldTransition;
    if (shouldTick && !_ticker.isActive) {
      _lastTickElapsed = null;
      _lastPaintElapsed = null;
      _ticker.start();
    } else if (!shouldTick && _ticker.isActive) {
      _ticker.stop();
      _lastTickElapsed = null;
      _lastPaintElapsed = null;
    }
  }

  void _setPlaybackSpeedTarget(double target) {
    if (_targetPlaybackSpeed == target) return;
    if (target == _kIdleSpeed) {
      _targetPlaybackSpeed = _kIdleSpeed;
      _smoothedPlaybackSpeed = _kIdleSpeed;
      _playbackSpeedTransitionFrom = _kIdleSpeed;
      _playbackSpeedTransitionProgress = 1.0;
      _resetAudioResponse();
      return;
    }
    _playbackSpeedTransitionFrom = _smoothedPlaybackSpeed;
    _targetPlaybackSpeed = target;
    _playbackSpeedTransitionProgress = 0.0;
  }

  double _updatePlaybackSpeed(double deltaSeconds) {
    final previousSpeed = _smoothedPlaybackSpeed;
    if (_playbackSpeedTransitionProgress >= 1.0) return previousSpeed;
    _playbackSpeedTransitionProgress = (_playbackSpeedTransitionProgress +
            deltaSeconds /
                (_kPlaybackSpeedTransitionDuration.inMicroseconds /
                    Duration.microsecondsPerSecond))
        .clamp(0.0, 1.0);
    final t = _playbackSpeedTransitionProgress;
    final eased = t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t;
    _smoothedPlaybackSpeed = _playbackSpeedTransitionFrom +
        (_targetPlaybackSpeed - _playbackSpeedTransitionFrom) * eased;
    return (previousSpeed + _smoothedPlaybackSpeed) / 2;
  }

  void _onTick(Duration elapsed) {
    if (_disposed || !mounted) return;

    final previousTick = _lastTickElapsed;
    _lastTickElapsed = elapsed;
    final deltaSeconds = previousTick == null
        ? 0.0
        : (elapsed - previousTick).inMicroseconds /
            Duration.microsecondsPerSecond;
    final averageSpeed = _updatePlaybackSpeed(deltaSeconds);
    _motion.time += deltaSeconds * widget.inputs.flowSpeed * averageSpeed;

    // Update heartbeat pulses every tick regardless of paint skip.
    _updatePulses(deltaSeconds);

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
    final isSettled = _smoothedPlaybackSpeed == _kIdleSpeed &&
        _playbackSpeedTransitionProgress >= 1.0;
    if (isSettled) {
      _audio.reset();
    }
    _frameNotifier.value++;
    if (isSettled) {
      _syncAnimationState();
    }
  }

  void _updatePulses(double deltaSeconds) {
    if (!widget.inputs.audioReactiveFlow) {
      _audio.reset();
      return;
    }
    final env = _envelope.value;
    _audio.low = _followEnergy(_audio.low, env.low, deltaSeconds);
    _audio.mid = _followEnergy(_audio.mid, env.mid, deltaSeconds);
    _audio.high = _followEnergy(_audio.high, env.high, deltaSeconds);
    _audio.updateBassPulse(deltaSeconds);
  }

  double _followEnergy(double current, double energy, double deltaSeconds) {
    final x = energy.clamp(0.0, 1.0).toDouble();
    final target = x * x * x * (x * (x * 6 - 15) + 10);
    final timeConstant = target > current ? 0.085 : 0.28;
    final response = 1 - exp(-deltaSeconds / timeConstant);
    return current + (target - current) * response;
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
      final blurredImage = await _createBlurredCover(image);
      image.dispose();
      image = blurredImage;
      if (_disposed || !mounted || generation != _decodeGeneration) {
        image.dispose();
        return;
      }
      final decoded = _DecodedCover(image);
      image = null;
      _acceptDecodedCover(decoded);
    } catch (_) {
      image?.dispose();
      if (!_disposed && mounted && generation == _decodeGeneration) {
        _clearArtwork();
      }
    } finally {
      codec?.dispose();
    }
  }

  Future<ui.Image> _createBlurredCover(ui.Image source) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final bounds = Rect.fromLTWH(
      0,
      0,
      source.width.toDouble(),
      source.height.toDouble(),
    );
    final blurPaint = Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: _kBlurSigma,
        sigmaY: _kBlurSigma,
        tileMode: TileMode.clamp,
      );
    canvas.saveLayer(bounds, blurPaint);
    canvas.drawImage(source, Offset.zero, Paint());
    canvas.restore();
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(source.width, source.height);
    } finally {
      picture.dispose();
    }
  }

  void _acceptDecodedCover(_DecodedCover decoded) {
    if (_previousCoverImage != null) {
      final oldPending = _pendingCover;
      if (oldPending != null) {
        _disposeImage(oldPending.image);
      }
      _pendingCover = decoded;
      return;
    }
    if (_coverImage == null) {
      setState(() {
        _coverImage = decoded.image;
      });
      _syncAnimationState();
      return;
    }
    _startArtworkTransition(decoded);
  }

  void _startArtworkTransition(_DecodedCover decoded) {
    final currentTime = _motion.time;
    setState(() {
      _previousCoverImage = _coverImage;
      _previousMotionTime = currentTime;
      _coverImage = decoded.image;
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
    if (pending == null) {
      setState(() {
        _previousCoverImage = null;
        _transitionClock
          ..stop()
          ..reset();
      });
    } else {
      final currentTime = _motion.time;
      setState(() {
        _previousCoverImage = _coverImage;
        _previousMotionTime = currentTime;
        _coverImage = pending.image;
        _transitionClock
          ..stop()
          ..reset();
      });
    }
    _disposeImagesAfterFrame([completedPrevious]);
    _syncAnimationState();
  }

  void _clearArtwork() {
    final current = _coverImage;
    final previous = _previousCoverImage;
    final pending = _pendingCover;
    _coverImage = null;
    _previousCoverImage = null;
    _pendingCover = null;
    _transitionClock
      ..stop()
      ..reset();
    if (mounted && !_disposed) {
      setState(() {});
      _disposeImagesAfterFrame([current, previous, pending?.image]);
    } else {
      if (current != null) _disposeImage(current);
      if (previous != null) _disposeImage(previous);
      if (pending != null) _disposeImage(pending.image);
    }
    _syncAnimationState();
  }

  void _disposeImagesAfterFrame(Iterable<ui.Image?> images) {
    final disposable = images.whereType<ui.Image>().toList(growable: false);
    if (disposable.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final image in disposable) {
        _disposeImage(image);
      }
    });
  }

  void _disposeImage(ui.Image image) {
    _shaderCache.disposeImage(image);
    image.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    _decodeGeneration++;
    _ticker.dispose();
    _transitionClock.stop();
    _shaderCache.dispose();
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
    final style = scheme.brightness == Brightness.dark
        ? _kDarkFlowingLightStyle
        : _kLightFlowingLightStyle;
    final neutralBackground = scheme.brightness == Brightness.dark
        ? _kDarkNeutralBackground
        : _kLightNeutralBackground;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: neutralBackground),
        LayoutBuilder(
          builder: (context, constraints) {
            final renderSize = _flowingLightRenderSize(constraints.biggest);
            return AnimatedOpacity(
              opacity: coverImage != null ? 1.0 : 0.0,
              duration: _kArtworkTransitionDuration,
              curve: Curves.easeOut,
              child: FittedBox(
                fit: BoxFit.fill,
                child: SizedBox.fromSize(
                  size: renderSize,
                  child: CustomPaint(
                    painter: _FlowingLightPainter(
                      coverImage: coverImage,
                      previousCoverImage: _previousCoverImage,
                      previousMotionTime: _previousMotionTime,
                      motion: _motion,
                      transitionClock: _transitionClock,
                      audioReactiveFlow: widget.inputs.audioReactiveFlow,
                      audio: _audio,
                      style: style,
                      shaderCache: _shaderCache,
                      repaint: _frameNotifier,
                    ),
                    size: renderSize,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _DecodedCover {
  const _DecodedCover(this.image);

  final ui.Image image;
}

class _FlowMotionState {
  double time = 0.0;
}

class _FlowAudioState {
  double low = 0.0;
  double mid = 0.0;
  double high = 0.0;
  final AudioReactiveFlowPulseEnvelope _bassPulse =
      AudioReactiveFlowPulseEnvelope();

  double get bassTransient => _bassPulse.value;

  void captureBass(double transient) {
    _bassPulse.trigger(transient);
  }

  void updateBassPulse(double deltaSeconds) {
    _bassPulse.advance(deltaSeconds);
  }

  void reset() {
    low = 0.0;
    mid = 0.0;
    high = 0.0;
    _bassPulse.reset();
  }
}

class _FlowingLightVisualStyle {
  const _FlowingLightVisualStyle({
    required this.edgeAlpha,
    required this.artworkSaturation,
    required this.artworkBrightness,
    required this.artworkBlackLift,
    required this.overlays,
  });

  final double edgeAlpha;
  final double artworkSaturation;
  final double artworkBrightness;
  final double artworkBlackLift;
  final List<Color> overlays;
}

class _WarpMeshBuffer {
  final positions = Float32List(_kWarpNormalizedCoordinates.length);
  final textureCoordinates = Float32List(_kWarpNormalizedCoordinates.length);
  final colors = Int32List(_kWarpNormalizedCoordinates.length ~/ 2);
  int _imageWidth = 0;
  int _imageHeight = 0;

  void syncTextureCoordinates(ui.Image image) {
    if (_imageWidth == image.width && _imageHeight == image.height) return;
    _imageWidth = image.width;
    _imageHeight = image.height;
    for (var index = 0;
        index < _kWarpNormalizedCoordinates.length;
        index += 2) {
      textureCoordinates[index] =
          _kWarpNormalizedCoordinates[index] * image.width;
      textureCoordinates[index + 1] =
          _kWarpNormalizedCoordinates[index + 1] * image.height;
    }
  }
}

class _FlowingLightShaderCache {
  final Map<ui.Image, ui.ImageShader> _shaders = Map.identity();

  ui.ImageShader get(ui.Image image) {
    return _shaders.putIfAbsent(
      image,
      () => ui.ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        _kIdentityShaderMatrix,
        filterQuality: FilterQuality.medium,
      ),
    );
  }

  void disposeImage(ui.Image image) {
    _shaders.remove(image)?.dispose();
  }

  void dispose() {
    for (final shader in _shaders.values) {
      shader.dispose();
    }
    _shaders.clear();
  }
}

ui.ColorFilter _flowingLightLinearColorFilter(
  double saturation,
  double brightness,
  double blackLift,
) {
  const redLuminance = 0.2126;
  const greenLuminance = 0.7152;
  const blueLuminance = 0.0722;
  final inverse = 1.0 - saturation;
  final offset = blackLift.clamp(0.0, 1.0) * 255;
  return ui.ColorFilter.matrix(<double>[
    brightness * (inverse * redLuminance + saturation),
    brightness * inverse * greenLuminance,
    brightness * inverse * blueLuminance,
    0,
    offset,
    brightness * inverse * redLuminance,
    brightness * (inverse * greenLuminance + saturation),
    brightness * inverse * blueLuminance,
    0,
    offset,
    brightness * inverse * redLuminance,
    brightness * inverse * greenLuminance,
    brightness * (inverse * blueLuminance + saturation),
    0,
    offset,
    0,
    0,
    0,
    1,
    0,
  ]);
}

class _FlowingLightPainter extends CustomPainter {
  _FlowingLightPainter({
    this.coverImage,
    required this.previousCoverImage,
    required this.previousMotionTime,
    required this.motion,
    required this.transitionClock,
    required this.audioReactiveFlow,
    required this.audio,
    required this.style,
    required this.shaderCache,
    required ValueNotifier<int> repaint,
  })  : _linearColorFilter = _flowingLightLinearColorFilter(
          style.artworkSaturation,
          style.artworkBrightness,
          style.artworkBlackLift,
        ),
        super(repaint: repaint);

  final ui.Image? coverImage;
  final ui.Image? previousCoverImage;
  final double previousMotionTime;
  final _FlowMotionState motion;
  final Stopwatch transitionClock;
  final bool audioReactiveFlow;
  final _FlowAudioState audio;
  final _FlowingLightVisualStyle style;
  final _FlowingLightShaderCache shaderCache;
  final ui.ColorFilter _linearColorFilter;

  static const _artworkCurve = Cubic(0, 0, 0.3, 1);
  late final ui.Paint _primaryPaint = ui.Paint()
    ..filterQuality = FilterQuality.medium
    ..colorFilter = _linearColorFilter;
  late final ui.Paint _secondaryPaint = ui.Paint()
    ..filterQuality = FilterQuality.medium
    ..colorFilter = _linearColorFilter;
  late final ui.Paint _lightPaint = ui.Paint()
    ..filterQuality = FilterQuality.medium
    ..colorFilter = _linearColorFilter;
  final _primaryMesh = _WarpMeshBuffer();
  final _secondaryMesh = _WarpMeshBuffer();
  final _lightMesh = _WarpMeshBuffer();
  ui.Paint? _edgePaint;
  Size? _edgePaintSize;
  double? _edgePaintAlpha;

  double get _motionTime => motion.time;

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
        previousMotionTime,
        1,
      );
    }
    _drawFrame(
      canvas,
      size,
      coverImage,
      _motionTime,
      _transitionProgress,
    );
    for (final overlay in style.overlays) {
      canvas.drawColor(overlay, BlendMode.srcOver);
    }
    canvas.drawRect(Offset.zero & size, _edgePaintFor(size));
  }

  void _drawFrame(
    Canvas canvas,
    Size size,
    ui.Image? image,
    double time,
    double opacity,
  ) {
    final alpha = (opacity * 255).round().clamp(0, 255);
    if (alpha == 0 || image == null) return;

    const driftAmp = 0.052;
    final primaryDriftX = sin(time * 0.5) * driftAmp;
    final primaryDriftY = cos(time * 0.6) * driftAmp;
    final secondaryDriftX = sin(time * 0.7 + 1.0) * driftAmp;
    final secondaryDriftY = cos(time * 0.8 + 1.0) * driftAmp;
    final lightDriftX = sin(time * 0.9 + 2.0) * driftAmp * 1.2;
    final lightDriftY = cos(time + 2.0) * driftAmp * 1.2;

    final primaryBreathe = audioReactiveFlow
        ? flowingLightBreathingScale(
            audio.low,
            bassTransient: audio.bassTransient,
          )
        : 1.0;
    final warpStrength = audioReactiveFlow
        ? flowingLightWarpStrength(
            audio.low,
            bassTransient: audio.bassTransient,
          )
        : 0.0;
    final imageShader = shaderCache.get(image);
    final primaryScale = flowingLightArtworkCropScale(
      size,
      Size(image.width.toDouble(), image.height.toDouble()),
    );
    _drawLayer(
      canvas,
      size,
      image,
      primaryScale * primaryBreathe,
      time / _kPeriod1 * 2 * pi + _kPrimaryLayerPhase,
      primaryDriftX,
      -0.10 + primaryDriftY,
      _primaryPaint,
      layer: _FlowingLightLayer.primary,
      mesh: _primaryMesh,
      warpAmplitude: warpStrength,
      warpPhase: time * 3.2,
      shader: imageShader,
      opacity: opacity,
    );
    _drawLayer(
      canvas,
      size,
      image,
      primaryScale /
          _kPrimaryLayerScale *
          _kSecondaryLayerScale *
          primaryBreathe,
      -time / _kPeriod2 * 2 * pi + _kSecondaryLayerPhase,
      0.41 + secondaryDriftX,
      0.23 + secondaryDriftY,
      _secondaryPaint,
      layer: _FlowingLightLayer.secondary,
      mesh: _secondaryMesh,
      warpAmplitude: warpStrength * 0.76,
      warpPhase: -time * 2.4 + 0.8,
      shader: imageShader,
      opacity: opacity,
    );
    _drawLayer(
      canvas,
      size,
      image,
      primaryScale / _kPrimaryLayerScale * _kLightLayerScale * primaryBreathe,
      -time / _kPeriod3 * 2 * pi + _kLightLayerPhase,
      -0.42 + lightDriftX,
      0.28 + lightDriftY,
      _lightPaint,
      layer: _FlowingLightLayer.light,
      mesh: _lightMesh,
      warpAmplitude: warpStrength * 0.56,
      warpPhase: time * 4.4 + 1.5,
      shader: imageShader,
      opacity: opacity,
    );
  }

  void _drawLayer(
    Canvas canvas,
    Size size,
    ui.Image image,
    double scale,
    double rotation,
    double offsetX,
    double offsetY,
    ui.Paint paint, {
    required _FlowingLightLayer layer,
    required _WarpMeshBuffer mesh,
    double warpAmplitude = 0.0,
    double warpPhase = 0.0,
    required ui.Shader shader,
    required double opacity,
  }) {
    final center = size.center(Offset.zero);
    paint.shader = shader;
    final vertices = _warpedVertices(
      image: image,
      size: size,
      center: center,
      scale: scale,
      rotation: rotation,
      offsetX: offsetX,
      offsetY: offsetY,
      amplitude: warpAmplitude,
      phase: warpPhase,
      layer: layer,
      mesh: mesh,
      opacity: opacity,
    );
    try {
      canvas.drawVertices(vertices, BlendMode.modulate, paint);
    } finally {
      vertices.dispose();
      paint.shader = null;
    }
  }

  ui.Vertices _warpedVertices({
    required ui.Image image,
    required Size size,
    required Offset center,
    required double scale,
    required double rotation,
    required double offsetX,
    required double offsetY,
    required double amplitude,
    required double phase,
    required _FlowingLightLayer layer,
    required _WarpMeshBuffer mesh,
    required double opacity,
  }) {
    mesh.syncTextureCoordinates(image);
    final imageWidth = image.width.toDouble();
    final imageHeight = image.height.toDouble();
    final imageCenter = Offset(imageWidth / 2, imageHeight / 2);
    final cosRotation = cos(rotation);
    final sinRotation = sin(rotation);
    final displacementX = amplitude * size.width;
    final displacementY = amplitude * size.height * 0.72;
    final crossDisplacement = amplitude * size.shortestSide * 0.28;
    final layerAlpha = switch (layer) {
      _FlowingLightLayer.primary => _kPrimaryLayerAlpha,
      _FlowingLightLayer.secondary => _kSecondaryLayerAlpha,
      _FlowingLightLayer.light => _kLightLayerAlpha,
    };
    final mask = _layerMaskFor(layer, size);
    for (var vertex = 0;
        vertex < _kWarpNormalizedCoordinates.length ~/ 2;
        vertex++) {
      final u = _kWarpNormalizedCoordinates[vertex * 2];
      final v = _kWarpNormalizedCoordinates[vertex * 2 + 1];
      final sourceX = u * imageWidth;
      final sourceY = v * imageHeight;
      final localX = (sourceX - imageCenter.dx) * scale;
      final localY = (sourceY - imageCenter.dy) * scale;
      final rotatedX = localX * cosRotation - localY * sinRotation;
      final rotatedY = localX * sinRotation + localY * cosRotation;
      final waveX = sin(v * 2 * pi + phase) * displacementX;
      final waveY = cos(u * 2 * pi + phase * 0.73) * displacementY;
      final crossWave =
          sin((u + v) * 2 * pi + phase * 1.17) * crossDisplacement;
      final outputX = center.dx + offsetX * size.width + rotatedX + waveX;
      final outputY = center.dy + offsetY * size.height + rotatedY + waveY;
      final x = outputX + crossWave;
      final y = outputY + crossWave * 0.65;
      mesh.positions[vertex * 2] = x;
      mesh.positions[vertex * 2 + 1] = y;
      final maskAlpha = _layerMaskAlpha(mask, x, y);
      final alpha = (layerAlpha * maskAlpha * opacity).round().clamp(0, 255);
      mesh.colors[vertex] = (alpha << 24) | 0x00FFFFFF;
    }
    return ui.Vertices.raw(
      ui.VertexMode.triangles,
      mesh.positions,
      colors: mesh.colors,
      textureCoordinates: mesh.textureCoordinates,
    );
  }

  _FlowingLightLayerMask _layerMaskFor(
    _FlowingLightLayer layer,
    Size size,
  ) {
    return switch (layer) {
      _FlowingLightLayer.primary => (
          centerX: size.width * 0.50,
          centerY: size.height * 0.40,
          radius: size.shortestSide * 1.12,
          middleStop: 0.58,
          outerStop: 0.82,
          middleAlpha: 210 / 255,
        ),
      _FlowingLightLayer.secondary => (
          centerX: size.width * 0.84,
          centerY: size.height * 0.68,
          radius: size.shortestSide * 0.95,
          middleStop: 0.52,
          outerStop: 0.82,
          middleAlpha: 100 / 255,
        ),
      _FlowingLightLayer.light => (
          centerX: size.width * 0.16,
          centerY: size.height * 0.72,
          radius: size.shortestSide * 0.95,
          middleStop: 0.52,
          outerStop: 0.82,
          middleAlpha: 100 / 255,
        ),
    };
  }

  double _layerMaskAlpha(_FlowingLightLayerMask mask, double x, double y) {
    final dx = x - mask.centerX;
    final dy = y - mask.centerY;
    final distanceSquared = dx * dx + dy * dy;
    final middleRadius = mask.radius * mask.middleStop;
    if (distanceSquared <= middleRadius * middleRadius) return 1.0;
    final outerRadius = mask.radius * mask.outerStop;
    final distance = sqrt(distanceSquared);
    if (distance <= outerRadius) {
      final local = (distance - middleRadius) / (outerRadius - middleRadius);
      return 1.0 + (mask.middleAlpha - 1.0) * local;
    }
    if (distance >= mask.radius) return 0.0;
    final local = (distance - outerRadius) / (mask.radius - outerRadius);
    return mask.middleAlpha * (1.0 - local);
  }

  ui.Paint _edgePaintFor(Size size) {
    if (_edgePaint == null ||
        _edgePaintSize != size ||
        _edgePaintAlpha != style.edgeAlpha) {
      _edgePaintSize = size;
      _edgePaintAlpha = style.edgeAlpha;
      _edgePaint = ui.Paint()
        ..shader = ui.Gradient.radial(
          size.center(Offset.zero),
          size.longestSide * 0.64,
          [
            Colors.transparent,
            Colors.black.withValues(alpha: style.edgeAlpha),
          ],
        );
    }
    return _edgePaint!;
  }

  @override
  bool shouldRepaint(covariant _FlowingLightPainter oldDelegate) {
    return !identical(oldDelegate.coverImage, coverImage) ||
        !identical(oldDelegate.previousCoverImage, previousCoverImage) ||
        oldDelegate.previousMotionTime != previousMotionTime ||
        oldDelegate.audioReactiveFlow != audioReactiveFlow ||
        !identical(oldDelegate.audio, audio) ||
        oldDelegate.style != style;
  }

  @override
  bool? hitTest(Offset position) => null;
}
