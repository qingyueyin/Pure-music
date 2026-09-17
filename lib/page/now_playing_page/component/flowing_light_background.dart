import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/audio_reactive_flow.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

const _kDecodeSize = 256;
const _kGaussianShaderAssetPath = 'assets/shaders/pulse_gaussian.frag';
const _kOverscan = 1.3;
const _kDownsampleLow = 16.0;
const _kDownsampleHigh = 24.0;
const _kHighDpiThreshold = 2.625;
const _kMinCropLongest = 96.0;
const _kBlurSigma = 12.0;
const _kBlurChromaBoost = 1.12;
const _kDarkNeutralBackground = Color(0xFF171717);
const _kLightNeutralBackground = Color(0xFFF0F0F0);
const _kFrameInterval = Duration(milliseconds: 42);
const _kArtworkTransitionDuration = Duration(milliseconds: 300);
const _kPlaybackSpeedTransitionDuration = Duration(milliseconds: 650);

const _kCoverPeriod1 = 65.0;
const _kCoverPeriod2 = 50.0;
const _kCoverPeriod3 = 36.0;

const _kPrimaryLayerScale = 1.42;
const _kPrimaryLayerAlpha = 255;
const _kSecondaryLayerAlpha = 124;
const _kLightLayerAlpha = 82;
const _kPrimaryOffset = Offset(0.12, -0.10);
const _kSecondaryOffset = Offset(-0.95, -0.7);
const _kLightOffset = Offset(-0.5, 0.7);

Size _flowingLightCropSize(Size viewport, double devicePixelRatio) {
  if (viewport.isEmpty) return Size.zero;
  final downsample = devicePixelRatio >= _kHighDpiThreshold
      ? _kDownsampleHigh
      : _kDownsampleLow;
  var width = viewport.width / downsample;
  var height = viewport.height / downsample;
  final longest = max(width, height);
  if (longest < _kMinCropLongest) {
    final scale = _kMinCropLongest / longest;
    width *= scale;
    height *= scale;
  }
  return Size(
    max(1.0, width.roundToDouble()),
    max(1.0, height.roundToDouble()),
  );
}

Size _flowingLightOverscanSize(Size cropSize) {
  if (cropSize.isEmpty) return Size.zero;
  return Size(
    max(1.0, (cropSize.width * _kOverscan).roundToDouble()),
    max(1.0, (cropSize.height * _kOverscan).roundToDouble()),
  );
}

double _flowingLightCompositeSigma(Size size) {
  return (size.shortestSide * 0.12).clamp(8.0, 12.0);
}

const _kDarkFlowingLightStyle = _FlowingLightVisualStyle(
  artworkSaturation: 1.40,
  artworkBrightness: 0.82,
  washPrimary: Color(0x1A171717),
  washSecondary: Color(0x0C171717),
  scrim: <Color>[Color(0x2E171717), Color(0x08171717), Color(0x4D171717)],
);
const _kLightFlowingLightStyle = _FlowingLightVisualStyle(
  artworkSaturation: 1.52,
  artworkBrightness: 1.0,
  washPrimary: Color(0x14F0F0F0),
  washSecondary: Color(0x08F0F0F0),
  scrim: <Color>[Color(0x1EF0F0F0), Color(0x00F0F0F0), Color(0x2EF0F0F0)],
);

double flowingLightArtworkCropScale(Size output, Size artwork) {
  if (output.isEmpty || artwork.isEmpty) return 0;
  return max(output.width / artwork.width, output.height / artwork.height) *
      _kPrimaryLayerScale;
}

double flowingLightBreathingScale(
  double audioLevel, {
  double bassTransient = 0.0,
}) {
  return (1.0 +
          audioLevel.clamp(0.0, 1.0) * 0.11 +
          bassTransient.clamp(0.0, 1.0) * 0.07)
      .clamp(1.0, 1.18)
      .toDouble();
}

double flowingLightWarpStrength(
  double audioLevel, {
  double bassTransient = 0.0,
}) {
  final level = audioLevel.isFinite
      ? audioLevel.clamp(0.0, 1.0).toDouble()
      : 0.0;
  final transient = bassTransient.isFinite
      ? bassTransient.clamp(0.0, 1.0).toDouble()
      : 0.0;
  return (level * 0.052 + transient * 0.038).clamp(0.0, 0.09).toDouble();
}

double flowingLightArtworkOpacityCeiling() {
  const primary = _kPrimaryLayerAlpha / 255;
  const secondary = _kSecondaryLayerAlpha / 255;
  const light = _kLightLayerAlpha / 255;
  return 1 - (1 - primary) * (1 - secondary) * (1 - light);
}

double _flowingLightVisualResponse(double value, {double exponent = 0.72}) {
  final safe = value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.0;
  return safe <= 0 ? 0.0 : pow(safe, exponent).toDouble();
}

class FlowingLightBackground extends StatefulWidget {
  final NowPlayingBackgroundInputs inputs;

  const FlowingLightBackground({super.key, required this.inputs});

  static Future<void> precache() => _FlowingLightBackgroundState.precache();

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
  final AudioReactiveFlowTransientDetector _lowTransientDetector =
      AudioReactiveFlowTransientDetector();
  final AudioReactiveFlowTransientDetector _broadbandTransientDetector =
      AudioReactiveFlowTransientDetector();
  final _FlowAudioState _audio = _FlowAudioState();
  ui.FragmentShader? _gaussianHorizontal;
  ui.FragmentShader? _gaussianVertical;
  final _BlurFilterHandle _blurHandle = _BlurFilterHandle();
  Size? _blurFilterSize;
  StreamSubscription<Float32List>? _spectrumSubscription;
  int _decodeGeneration = 0;
  bool _disposed = false;
  bool _tickerModeEnabled = true;

  static const double _kIdleSpeed = 0.0;
  static const double _kActiveSpeed = 1.0;
  static ui.FragmentProgram? _cachedGaussianProgram;
  static Future<ui.FragmentProgram?>? _gaussianProgramFuture;

  static Future<void> precache() async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    await _gaussianProgram();
  }

  static Future<ui.FragmentProgram?> _gaussianProgram() {
    final cached = _cachedGaussianProgram;
    if (cached != null) return Future<ui.FragmentProgram?>.value(cached);
    return _gaussianProgramFuture ??= () async {
      try {
        final program = await ui.FragmentProgram.fromAsset(
          _kGaussianShaderAssetPath,
        );
        _cachedGaussianProgram = program;
        return program;
      } catch (_) {
        _gaussianProgramFuture = null;
        return null;
      }
    }();
  }

  double _smoothedPlaybackSpeed = _kIdleSpeed;
  double _targetPlaybackSpeed = _kIdleSpeed;
  double _playbackSpeedTransitionFrom = _kIdleSpeed;
  double _playbackSpeedTransitionProgress = 1.0;

  @override
  void initState() {
    super.initState();
    _transitionClock = Stopwatch();
    _ticker = createTicker(_onTick);
    _blurHandle.filter = _fallbackBlurFilter(_kBlurSigma);
    _scheduleCoverDecode();
    final cachedProgram = _cachedGaussianProgram;
    if (cachedProgram != null) {
      _applyGaussianProgram(cachedProgram);
    } else {
      _loadGaussianFilters();
    }
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
    final shouldListen =
        stream != null &&
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
    _resetAudioVisual();
  }

  void _handleSpectrum(Float32List bands) {
    if (_disposed) return;
    final response = AudioReactiveFlowResponse.fromBands(bands);
    if (!widget.inputs.audioReactiveFlow) return;
    final normalized = _normalizer.update(response);
    // 音量不到满时用标定频谱，满音量用原始值以免压掉鼓点动态。
    final useNormalized = AppPreference.instance.playbackPref.volumeDsp < 0.98;
    final driven = useNormalized ? normalized : response;
    _envelope.update(driven);
    final lowTransient = _lowTransientDetector.update(driven.low);
    final broadbandTransient = _broadbandTransientDetector.updateResponse(
      driven,
    );
    _audio.captureTransient(lowTransient, broadbandTransient);
    _audio.noteEnergy(audioReactiveFlowBeatEnergy(driven));
  }

  void _resetAudioVisual() {
    _lowTransientDetector.reset();
    _broadbandTransientDetector.reset();
    _envelope.reset();
    _audio.reset();
  }

  void _resetAudioResponse() {
    _normalizer.reset();
    _resetAudioVisual();
  }

  void _syncAnimationState() {
    if (_disposed) return;
    _syncSpectrumSubscription();
    final canMove =
        _coverImage != null &&
        _tickerModeEnabled &&
        widget.inputs.enableAnimation &&
        widget.inputs.isVisible;
    final isPlaying =
        canMove && widget.inputs.playerState == PlayerState.playing;
    _setPlaybackSpeedTarget(isPlaying ? _kActiveSpeed : _kIdleSpeed);

    final shouldMove =
        canMove &&
        (isPlaying ||
            _playbackSpeedTransitionProgress < 1.0 ||
            _smoothedPlaybackSpeed > _kIdleSpeed);
    final shouldTransition =
        _tickerModeEnabled &&
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
      _resetAudioVisual();
      return;
    }
    _playbackSpeedTransitionFrom = _smoothedPlaybackSpeed;
    _targetPlaybackSpeed = target;
    _playbackSpeedTransitionProgress = 0.0;
  }

  double _updatePlaybackSpeed(double deltaSeconds) {
    final previousSpeed = _smoothedPlaybackSpeed;
    if (_playbackSpeedTransitionProgress >= 1.0) return previousSpeed;
    _playbackSpeedTransitionProgress =
        (_playbackSpeedTransitionProgress +
                deltaSeconds /
                    (_kPlaybackSpeedTransitionDuration.inMicroseconds /
                        Duration.microsecondsPerSecond))
            .clamp(0.0, 1.0);
    final t = _playbackSpeedTransitionProgress;
    final eased = t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t;
    _smoothedPlaybackSpeed =
        _playbackSpeedTransitionFrom +
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
    final audioSpeed = widget.inputs.audioReactiveFlow
        ? _audio.motionSpeed
        : 1.0;
    _motion.time +=
        deltaSeconds * widget.inputs.flowSpeed * averageSpeed * audioSpeed;
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
    final isSettled =
        _smoothedPlaybackSpeed == _kIdleSpeed &&
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
    _audio.updatePulses(deltaSeconds);
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

  ui.ImageFilter _fallbackBlurFilter(double sigma) {
    return ui.ImageFilter.blur(
      sigmaX: sigma,
      sigmaY: sigma,
      tileMode: TileMode.clamp,
    );
  }

  Future<void> _loadGaussianFilters() async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    try {
      final program = await _gaussianProgram();
      if (program == null || _disposed) return;
      _applyGaussianProgram(program);
      if (mounted && _blurFilterSize != null) _frameNotifier.value++;
    } catch (_) {
      _gaussianHorizontal?.dispose();
      _gaussianVertical?.dispose();
      _gaussianHorizontal = null;
      _gaussianVertical = null;
    }
  }

  void _applyGaussianProgram(ui.FragmentProgram program) {
    final horizontal = program.fragmentShader();
    final vertical = program.fragmentShader();
    if (_disposed) {
      horizontal.dispose();
      vertical.dispose();
      return;
    }
    _configureSeparableBlurShader(horizontal, horizontal: true);
    _configureSeparableBlurShader(vertical, horizontal: false);
    final filter = ui.ImageFilter.compose(
      inner: ui.ImageFilter.shader(horizontal),
      outer: ui.ImageFilter.shader(vertical),
    );
    _gaussianHorizontal?.dispose();
    _gaussianVertical?.dispose();
    _gaussianHorizontal = horizontal;
    _gaussianVertical = vertical;
    _blurHandle.filter = filter;
    final knownSize = _blurFilterSize;
    _blurFilterSize = null;
    if (knownSize != null) {
      _blurFilterFor(knownSize);
    }
  }

  void _configureSeparableBlurShader(
    ui.FragmentShader shader, {
    required bool horizontal,
    double sigma = _kBlurSigma,
  }) {
    final inv2s2 = 1.0 / (2.0 * sigma * sigma);
    shader
      ..setFloat(2, horizontal ? 1.0 : 0.0)
      ..setFloat(3, horizontal ? 0.0 : 1.0)
      ..setFloat(4, inv2s2)
      ..setFloat(5, horizontal ? 1.0 : _kBlurChromaBoost);
  }

  ui.ImageFilter _blurFilterFor(Size size) {
    if (_blurFilterSize == size) return _blurHandle.filter;
    final sigma = _flowingLightCompositeSigma(size);
    final horizontal = _gaussianHorizontal;
    final vertical = _gaussianVertical;
    if (horizontal != null && vertical != null) {
      _configureSeparableBlurShader(horizontal, horizontal: true, sigma: sigma);
      _configureSeparableBlurShader(vertical, horizontal: false, sigma: sigma);
    } else {
      _blurHandle.filter = _fallbackBlurFilter(sigma);
    }
    _blurFilterSize = size;
    return _blurHandle.filter;
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
    image.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    _decodeGeneration++;
    _ticker.dispose();
    _transitionClock.stop();
    _gaussianHorizontal?.dispose();
    _gaussianHorizontal = null;
    _gaussianVertical?.dispose();
    _gaussianVertical = null;
    _coverImage?.dispose();
    _previousCoverImage?.dispose();
    _pendingCover?.image.dispose();
    _frameNotifier.dispose();
    _spectrumSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    final coverImage = _coverImage;
    final style = isDark ? _kDarkFlowingLightStyle : _kLightFlowingLightStyle;
    final backgroundColor = isDark
        ? _kDarkNeutralBackground
        : _kLightNeutralBackground;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: backgroundColor),
        LayoutBuilder(
          builder: (context, constraints) {
            final cropSize = _flowingLightCropSize(
              constraints.biggest,
              MediaQuery.devicePixelRatioOf(context),
            );
            final overscanSize = _flowingLightOverscanSize(cropSize);
            if (cropSize.isEmpty || overscanSize.isEmpty) {
              return const SizedBox.shrink();
            }
            _blurFilterFor(overscanSize);
            return AnimatedOpacity(
              opacity: coverImage != null ? 1.0 : 0.0,
              duration: _kArtworkTransitionDuration,
              curve: Curves.easeOut,
              child: FittedBox(
                fit: BoxFit.fill,
                child: SizedBox.fromSize(
                  size: cropSize,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.center,
                      minWidth: overscanSize.width,
                      maxWidth: overscanSize.width,
                      minHeight: overscanSize.height,
                      maxHeight: overscanSize.height,
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
                          blurHandle: _blurHandle,
                          repaint: _frameNotifier,
                        ),
                        size: overscanSize,
                      ),
                    ),
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

class _BlurFilterHandle {
  ui.ImageFilter filter = ui.ImageFilter.blur(
    sigmaX: _kBlurSigma,
    sigmaY: _kBlurSigma,
    tileMode: TileMode.clamp,
  );
}

class _FlowMotionState {
  double time = 0.0;
}

class _FlowAudioState {
  double low = 0.0;
  double mid = 0.0;
  double high = 0.0;
  double onset = 0.0;
  double motionSpeed = 1.0;
  double _latestEnergy = 0.0;
  double _previousEnergy = 0.0;
  final AudioReactiveFlowPulseEnvelope _lowPulse =
      AudioReactiveFlowPulseEnvelope();
  final AudioReactiveFlowPulseEnvelope _broadbandPulse =
      AudioReactiveFlowPulseEnvelope();
  final AudioReactiveFlowVisualSpring _visualHit =
      AudioReactiveFlowVisualSpring();

  double get lowTransient => _lowPulse.value;
  double get broadbandTransient => _broadbandPulse.value;
  double get visualHit => _visualHit.value;

  void captureTransient(double lowTransient, double broadbandTransient) {
    _lowPulse.trigger(lowTransient);
    _broadbandPulse.trigger(broadbandTransient);
  }

  void noteEnergy(double energy) {
    _latestEnergy = energy.isFinite ? energy.clamp(0.0, 1.0).toDouble() : 0.0;
  }

  void updatePulses(double deltaSeconds) {
    _lowPulse.advance(deltaSeconds);
    _broadbandPulse.advance(deltaSeconds);
    onset = audioReactiveFlowOnsetPulse(
      currentEnergy: _latestEnergy,
      previousEnergy: _previousEnergy,
      previousPulse: onset,
    );
    _previousEnergy = _latestEnergy;
    final visualTarget =
        (_lowPulse.value * 0.48 + _broadbandPulse.value * 0.18 + onset * 0.46)
            .clamp(0.0, 1.0)
            .toDouble();
    _visualHit.follow(visualTarget, deltaSeconds);
    final energy = audioReactiveFlowBeatEnergy(
      AudioReactiveFlowResponse(low, mid, high),
    );
    final target = audioReactiveFlowMotionSpeedTarget(
      energy: energy,
      onset: onset,
    );
    final timeConstant = target > motionSpeed ? 0.07 : 0.22;
    final response = 1 - exp(-deltaSeconds / timeConstant);
    motionSpeed += (target - motionSpeed) * response;
  }

  void reset() {
    low = 0.0;
    mid = 0.0;
    high = 0.0;
    onset = 0.0;
    motionSpeed = 1.0;
    _latestEnergy = 0.0;
    _previousEnergy = 0.0;
    _lowPulse.reset();
    _broadbandPulse.reset();
    _visualHit.reset();
  }
}

class _FlowingLightVisualStyle {
  const _FlowingLightVisualStyle({
    required this.artworkSaturation,
    required this.artworkBrightness,
    required this.washPrimary,
    required this.washSecondary,
    required this.scrim,
  });

  final double artworkSaturation;
  final double artworkBrightness;
  final Color washPrimary;
  final Color washSecondary;
  final List<Color> scrim;
}

ui.ColorFilter _flowingLightColorFilter(double saturation, double brightness) {
  const redLuminance = 0.2126;
  const greenLuminance = 0.7152;
  const blueLuminance = 0.0722;
  final inverse = 1.0 - saturation;
  return ui.ColorFilter.matrix(<double>[
    brightness * (inverse * redLuminance + saturation),
    brightness * inverse * greenLuminance,
    brightness * inverse * blueLuminance,
    0,
    0,
    brightness * inverse * redLuminance,
    brightness * (inverse * greenLuminance + saturation),
    brightness * inverse * blueLuminance,
    0,
    0,
    brightness * inverse * redLuminance,
    brightness * inverse * greenLuminance,
    brightness * (inverse * blueLuminance + saturation),
    0,
    0,
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
    required this.blurHandle,
    required ValueNotifier<int> repaint,
  }) : _linearColorFilter = _flowingLightColorFilter(
         style.artworkSaturation,
         style.artworkBrightness,
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
  final _BlurFilterHandle blurHandle;
  final ui.ColorFilter _linearColorFilter;

  static const _artworkCurve = Cubic(0, 0, 0.3, 1);
  late final ui.Paint _coverPaint = ui.Paint()
    ..filterQuality = FilterQuality.low
    ..colorFilter = _linearColorFilter;
  late final ui.Paint _compositePaint = ui.Paint()
    ..filterQuality = FilterQuality.low;
  ui.Paint? _scrimPaint;
  Size? _scrimPaintSize;
  List<Color>? _scrimPaintColors;

  double get _motionTime => motion.time;

  double get _transitionProgress {
    if (previousCoverImage == null) return 1;
    final linear =
        transitionClock.elapsedMicroseconds /
        _kArtworkTransitionDuration.inMicroseconds;
    return _artworkCurve.transform(linear.clamp(0.0, 1.0));
  }

  @override
  void paint(Canvas canvas, Size size) {
    _compositePaint.imageFilter = blurHandle.filter;
    final previous = previousCoverImage;
    if (previous != null) {
      _drawFrame(canvas, size, previous, previousMotionTime, 1.0);
    }
    _drawFrame(canvas, size, coverImage, _motionTime, _transitionProgress);
    canvas.drawRect(Offset.zero & size, _scrimPaintFor(size));
  }

  void _drawFrame(
    Canvas canvas,
    Size size,
    ui.Image? image,
    double time,
    double opacity,
  ) {
    if (image == null || opacity <= 0) return;
    final low = audioReactiveFlow
        ? _flowingLightVisualResponse(audio.low, exponent: 0.78)
        : 0.0;
    final mid = audioReactiveFlow
        ? _flowingLightVisualResponse(audio.mid, exponent: 0.80)
        : 0.0;
    final high = audioReactiveFlow
        ? _flowingLightVisualResponse(audio.high, exponent: 0.82)
        : 0.0;
    final broadbandHit = audioReactiveFlow
        ? _flowingLightVisualResponse(audio.broadbandTransient, exponent: 0.66)
        : 0.0;
    final visualHit = audioReactiveFlow
        ? _flowingLightVisualResponse(audio.visualHit, exponent: 0.62)
        : 0.0;
    final warp = audioReactiveFlow
        ? flowingLightWarpStrength(
            low * 0.52 + mid * 0.30 + high * 0.18,
            bassTransient: (broadbandHit * 0.38 + visualHit * 0.62)
                .clamp(0.0, 1.0)
                .toDouble(),
          )
        : 0.0;
    final breathe = audioReactiveFlow
        ? flowingLightBreathingScale(low, bassTransient: visualHit)
        : 1.0;
    final pulse = (breathe - 1.0).clamp(0.0, 0.10);
    _compositePaint.color = const Color(
      0xFFFFFFFF,
    ).withValues(alpha: opacity.clamp(0.0, 1.0));
    canvas.saveLayer(Offset.zero & size, _compositePaint);
    _drawCoverLayer(
      canvas,
      size,
      image,
      time: time,
      period: _kCoverPeriod1,
      clockwise: false,
      offset: Offset(
        _kPrimaryOffset.dx + low * 0.015,
        _kPrimaryOffset.dy - low * 0.01,
      ),
      extraRotation: false,
      squash: Offset(
        1.0 + low * 0.02 + visualHit * 0.03,
        1.0 - low * 0.012 - visualHit * 0.018,
      ),
      alpha: _kPrimaryLayerAlpha,
      scaleMul: 1.0 + pulse * 0.40,
      phase: 0.2,
    );
    _drawCoverLayer(
      canvas,
      size,
      image,
      time: time,
      period: _kCoverPeriod2,
      clockwise: true,
      offset: Offset(
        _kSecondaryOffset.dx - warp * 0.35 - mid * 0.03,
        _kSecondaryOffset.dy + low * 0.02,
      ),
      extraRotation: false,
      squash: Offset(
        1.0 - mid * 0.025 - visualHit * 0.035,
        1.0 + mid * 0.03 + visualHit * 0.045,
      ),
      alpha: _kSecondaryLayerAlpha,
      scaleMul: 1.22 + pulse * 0.62,
      phase: 1.7,
    );
    _drawCoverLayer(
      canvas,
      size,
      image,
      time: time,
      period: _kCoverPeriod3,
      clockwise: true,
      offset: Offset(
        _kLightOffset.dx + warp * 0.4,
        _kLightOffset.dy - low * 0.03,
      ),
      extraRotation: true,
      squash: Offset(
        1.0 + high * 0.03 + visualHit * 0.05,
        1.0 - high * 0.02 - visualHit * 0.035,
      ),
      alpha: _kLightLayerAlpha,
      scaleMul: 1.38 + pulse * 0.88,
      phase: 3.1,
    );
    canvas.drawColor(style.washPrimary, BlendMode.srcOver);
    canvas.drawColor(style.washSecondary, BlendMode.srcOver);
    canvas.restore();
  }

  void _drawCoverLayer(
    Canvas canvas,
    Size size,
    ui.Image image, {
    required double time,
    required double period,
    required bool clockwise,
    required Offset offset,
    required bool extraRotation,
    required Offset squash,
    required int alpha,
    required double scaleMul,
    required double phase,
  }) {
    final cycle = time / period * 2 * pi;
    final rotation =
        (clockwise ? cycle : -cycle) * (extraRotation ? 1.35 : 1.0);
    final diagonal = max(size.width, size.height) * _kOverscan;
    final coverScale = diagonal / max(image.height.toDouble(), 1.0) * scaleMul;
    final translateX = -(diagonal - size.width) / 2;
    final translateY = -(diagonal - size.height) / 2;
    final rotatePivot = Offset(
      diagonal / 2 + sin(cycle * 0.47 + phase) * size.width * 0.22,
      diagonal / 2 + cos(cycle * 0.39 - phase) * size.height * 0.18,
    );
    _coverPaint.color = Color.fromARGB(alpha, 255, 255, 255);
    canvas.save();
    canvas
      ..translate(
        size.width * offset.dx + translateX,
        size.height * offset.dy + translateY,
      )
      ..translate(rotatePivot.dx, rotatePivot.dy)
      ..rotate(rotation)
      ..translate(-rotatePivot.dx, -rotatePivot.dy)
      ..scale(coverScale * squash.dx, coverScale * squash.dy);
    canvas.drawImage(image, Offset.zero, _coverPaint);
    canvas.restore();
  }

  ui.Paint _scrimPaintFor(Size size) {
    if (_scrimPaint == null ||
        _scrimPaintSize != size ||
        _scrimPaintColors != style.scrim) {
      _scrimPaintSize = size;
      _scrimPaintColors = style.scrim;
      _scrimPaint = ui.Paint()
        ..shader = ui.Gradient.linear(
          Offset(size.width * 0.5, 0),
          Offset(size.width * 0.5, size.height),
          style.scrim,
          const <double>[0.0, 0.46, 1.0],
        );
    }
    return _scrimPaint!;
  }

  @override
  bool shouldRepaint(covariant _FlowingLightPainter oldDelegate) {
    return !identical(oldDelegate.coverImage, coverImage) ||
        !identical(oldDelegate.previousCoverImage, previousCoverImage) ||
        oldDelegate.previousMotionTime != previousMotionTime ||
        oldDelegate.audioReactiveFlow != audioReactiveFlow ||
        !identical(oldDelegate.audio, audio) ||
        oldDelegate.style != style ||
        !identical(oldDelegate.blurHandle, blurHandle);
  }

  @override
  bool? hitTest(Offset position) => null;
}
