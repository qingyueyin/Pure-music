import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:pure_music/page/now_playing_page/component/audio_reactive_flow.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

const _kDecodeSize = 256;
const _kGaussianShaderAssetPath = 'assets/shaders/pulse_gaussian.frag';
const _kOverscan = 1.3;
const _kDownsampleLow = 8.0;
const _kDownsampleHigh = 12.0;
const _kHighDpiThreshold = 2.625;
const _kMinCropLongest = 128.0;
const _kBlurSigma = 12.0;
const _kBlurChromaBoost = 1.16;
const _kDarkNeutralBackground = Color(0xFF171717);
const _kLightNeutralBackground = Color(0xFFF0F0F0);
const _kArtworkTransitionDuration = Duration(milliseconds: 300);
const _kPlaybackSpeedTransitionDuration = Duration(milliseconds: 650);
const _kFrameInterval = Duration(milliseconds: 42);

const _kCoverPeriod1 = 75.0;
const _kCoverPeriod2 = 55.0;
const _kCoverPeriod3 = 62.0;
const _kCoverPrefilterSigma = 6.0;

const _kPrimaryLayerScale = 1.42;
const _kPrimaryLayerAlpha = 255;
const _kSecondaryLayerAlpha = 255;
const _kLightLayerAlpha = 255;
const _kPrimaryOffset = Offset(0.0, 0.0);
const _kSecondaryOffset = Offset(0.10, 0.0);
const _kLightOffset = Offset(-0.25, 0.15);
const _kPrimaryScaleMul = 1.0;
const _kSecondaryScaleMul = 0.50;
const _kLightScaleMul = 0.50;
const _kSecondaryOrbit = 0.48;

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
  return (size.shortestSide * 0.10).clamp(8.0, 16.0);
}

const _kDarkFlowingLightStyle = _FlowingLightVisualStyle(
  artworkSaturation: 1.48,
  blackScrim: 0.18,
  washPrimary: Color(0x1F000000),
  washSecondary: Color(0x0A000000),
  scrim: <Color>[Color(0x33171717), Color(0x14171717), Color(0x4D171717)],
);
const _kLightFlowingLightStyle = _FlowingLightVisualStyle(
  artworkSaturation: 1.55,
  blackScrim: 0.0,
  washPrimary: Color(0x70FFFFFF),
  washSecondary: Color(0x24FFFFFF),
  scrim: <Color>[Color(0x1EF0F0F0), Color(0x0AF0F0F0), Color(0x2EF0F0F0)],
);

double flowingLightArtworkCropScale(Size output, Size artwork) {
  if (output.isEmpty || artwork.isEmpty) return 0;
  return max(output.width / artwork.width, output.height / artwork.height) *
      _kPrimaryLayerScale;
}

double flowingLightArtworkOpacityCeiling() {
  const primary = _kPrimaryLayerAlpha / 255;
  const secondary = _kSecondaryLayerAlpha / 255;
  const light = _kLightLayerAlpha / 255;
  return 1 - (1 - primary) * (1 - secondary) * (1 - light);
}

Color flowingLightCoverBaseColor(ByteData pixels, int width, int height) {
  if (width <= 0 || height <= 0) return _kDarkNeutralBackground;
  const grid = 5;
  final data = pixels.buffer.asUint8List();
  final stride = width * 4;
  var red = 0.0;
  var green = 0.0;
  var blue = 0.0;
  var count = 0;
  for (var row = 0; row < grid; row++) {
    final y = (((row + 0.5) * height) / grid).floor().clamp(0, height - 1);
    for (var column = 0; column < grid; column++) {
      final x = (((column + 0.5) * width) / grid).floor().clamp(0, width - 1);
      final index = y * stride + x * 4;
      if (index + 3 >= data.length) continue;
      final alpha = data[index + 3] / 255.0;
      red += data[index] * alpha;
      green += data[index + 1] * alpha;
      blue += data[index + 2] * alpha;
      count++;
    }
  }
  if (count <= 0) return _kDarkNeutralBackground;
  return Color.fromARGB(
    255,
    (red / count).round().clamp(0, 255),
    (green / count).round().clamp(0, 255),
    (blue / count).round().clamp(0, 255),
  );
}

Future<ui.Image> _prefilterCoverImage(ui.Image source) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()
    ..filterQuality = FilterQuality.medium
    ..imageFilter = ui.ImageFilter.blur(
      sigmaX: _kCoverPrefilterSigma,
      sigmaY: _kCoverPrefilterSigma,
      tileMode: TileMode.clamp,
    );
  canvas.drawImage(source, Offset.zero, paint);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(source.width, source.height);
  } finally {
    picture.dispose();
  }
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
  Color _coverBaseColor = _kDarkNeutralBackground;
  Color _previousCoverBaseColor = _kDarkNeutralBackground;
  double _previousMotionTime = 0;
  _DecodedCover? _pendingCover;

  late final Stopwatch _transitionClock;
  late final Ticker _ticker;
  late final _FlowingLightPainter _painter;
  final _FlowMotionState _motion = _FlowMotionState();
  Duration? _lastTickElapsed;
  Duration? _lastPaintElapsed;

  final ValueNotifier<int> _frameNotifier = ValueNotifier(0);
  final AudioReactiveFlowEnvelope _envelope = AudioReactiveFlowEnvelope();
  final AudioReactiveFlowNormalizer _normalizer = AudioReactiveFlowNormalizer();
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
    _painter = _FlowingLightPainter(
      motion: _motion,
      transitionClock: _transitionClock,
      audio: _audio,
      blurHandle: _blurHandle,
      repaint: _frameNotifier,
    );
    _blurHandle.filter = _fallbackBlurFilter(_kBlurSigma);
    _scheduleCoverDecode();
    final cachedProgram = _cachedGaussianProgram;
    if (cachedProgram != null) {
      _applyGaussianProgram(cachedProgram);
    } else {
      _loadGaussianFilters();
    }
    _syncSpectrumSubscription();
    _bindPlayerStateListenable();
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
    if (!identical(
      widget.inputs.playerStateListenable,
      oldWidget.inputs.playerStateListenable,
    )) {
      oldWidget.inputs.playerStateListenable?.removeListener(
        _onPlayerStateListenable,
      );
      _bindPlayerStateListenable();
    }
    if (!widget.inputs.audioReactiveFlow &&
        oldWidget.inputs.audioReactiveFlow) {
      _resetAudioResponse();
    }
    final needsSync =
        !identical(
          widget.inputs.albumCoverBytes,
          oldWidget.inputs.albumCoverBytes,
        ) ||
        !identical(
          widget.inputs.spectrumStream,
          oldWidget.inputs.spectrumStream,
        ) ||
        widget.inputs.audioReactiveFlow != oldWidget.inputs.audioReactiveFlow ||
        widget.inputs.enableAnimation != oldWidget.inputs.enableAnimation ||
        widget.inputs.isVisible != oldWidget.inputs.isVisible ||
        widget.inputs.isPlaybackActive != oldWidget.inputs.isPlaybackActive;
    if (needsSync) _syncAnimationState();
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
        widget.inputs.isPlaybackActive;
    if (shouldListen) {
      if (_spectrumSubscription == null) {
        _audio.markListenStarted();
        _spectrumSubscription = stream.listen(_handleSpectrum);
      }
      return;
    }
    _spectrumSubscription?.cancel();
    _spectrumSubscription = null;
  }

  void _handleSpectrum(Float32List bands) {
    if (_disposed) return;
    if (!widget.inputs.audioReactiveFlow) return;
    final response = AudioReactiveFlowResponse.fromBands(bands);
    // 暂停/进出后先丢掉空频谱，避免把冻住的色场瞬间拉黑。
    if (audioReactiveFlowShouldHoldEnvelope(
      awaitingPlaybackSpectrum: _audio.awaitingPlaybackSpectrum,
      incoming: response,
    )) {
      return;
    }
    _audio.awaitingPlaybackSpectrum = false;
    // 先把三频拉到可用幅度，再交给色场去推缩放/对比/饱和。
    _envelope.update(_normalizer.update(response));
  }

  void _resetAudioVisual() {
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
    final isPlaying = canMove && widget.inputs.isPlaybackActive;
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
    _updateAudio(deltaSeconds);
    final audioSpeed = widget.inputs.audioReactiveFlow
        ? _audio.motionSpeed
        : 1.0;
    _motion.time +=
        deltaSeconds * widget.inputs.flowSpeed * averageSpeed * audioSpeed;

    // 状态每帧都推进，重绘压到 24fps，避免模糊着色器按屏幕刷新率跑。
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
    _frameNotifier.value++;
    if (isSettled) {
      _syncAnimationState();
    }
  }

  void _updateAudio(double deltaSeconds) {
    if (!widget.inputs.audioReactiveFlow) {
      _audio.reset();
      return;
    }
    final env = _envelope.value;
    _audio.low = audioReactiveFlowCurve(env.low);
    _audio.mid = audioReactiveFlowCurve(env.mid);
    _audio.high = audioReactiveFlowCurve(env.high);
    _audio.followSpeed(deltaSeconds);
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
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (_disposed || !mounted || generation != _decodeGeneration) {
        image.dispose();
        return;
      }
      final baseColor = pixels == null
          ? _kDarkNeutralBackground
          : flowingLightCoverBaseColor(pixels, image.width, image.height);
      // 先抹掉封面细纹再旋转，避免三层叠在一起打出条纹。
      final source = image;
      ui.Image filtered;
      try {
        filtered = await _prefilterCoverImage(source);
        if (!identical(filtered, source)) {
          source.dispose();
        }
        image = null;
      } catch (_) {
        filtered = source;
        image = null;
      }
      if (_disposed || !mounted || generation != _decodeGeneration) {
        filtered.dispose();
        return;
      }
      _acceptDecodedCover(_DecodedCover(filtered, baseColor));
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
        _coverBaseColor = decoded.baseColor;
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
      _previousCoverBaseColor = _coverBaseColor;
      _previousMotionTime = currentTime;
      _coverImage = decoded.image;
      _coverBaseColor = decoded.baseColor;
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
        _previousCoverBaseColor = _coverBaseColor;
        _previousMotionTime = currentTime;
        _coverImage = pending.image;
        _coverBaseColor = pending.baseColor;
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
    _coverBaseColor = _kDarkNeutralBackground;
    _previousCoverBaseColor = _kDarkNeutralBackground;
    _transitionClock
      ..stop()
      ..reset();
    // 图片下一帧就销毁，先解除引用，避免淡出期间画到已释放的图。
    _painter
      ..coverImage = null
      ..previousCoverImage = null;
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
    widget.inputs.playerStateListenable?.removeListener(
      _onPlayerStateListenable,
    );
    super.dispose();
  }

  void _bindPlayerStateListenable() {
    widget.inputs.playerStateListenable?.addListener(_onPlayerStateListenable);
  }

  void _onPlayerStateListenable() {
    if (_disposed || !mounted) return;
    _syncAnimationState();
  }

  void _syncPainter({
    required ui.Image coverImage,
    required _FlowingLightVisualStyle style,
    required bool audioReactiveFlow,
  }) {
    final changed =
        !identical(_painter.coverImage, coverImage) ||
        !identical(_painter.previousCoverImage, _previousCoverImage) ||
        _painter.coverBaseColor != _coverBaseColor ||
        _painter.previousCoverBaseColor != _previousCoverBaseColor ||
        _painter.previousMotionTime != _previousMotionTime ||
        _painter.audioReactiveFlow != audioReactiveFlow ||
        _painter.style != style;
    _painter
      ..coverImage = coverImage
      ..previousCoverImage = _previousCoverImage
      ..coverBaseColor = _coverBaseColor
      ..previousCoverBaseColor = _previousCoverBaseColor
      ..previousMotionTime = _previousMotionTime
      ..audioReactiveFlow = audioReactiveFlow
      ..style = style;
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed) return;
        _frameNotifier.value++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    final coverImage = _coverImage;
    final style = isDark ? _kDarkFlowingLightStyle : _kLightFlowingLightStyle;
    final backgroundColor = isDark
        ? _kDarkNeutralBackground
        : _kLightNeutralBackground;
    if (coverImage != null) {
      _syncPainter(
        coverImage: coverImage,
        style: style,
        audioReactiveFlow: widget.inputs.audioReactiveFlow,
      );
    }
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
            // 无效/缺失封面立刻卸掉绘制层，避免还画着上一首的图。
            if (coverImage == null) {
              return const SizedBox.shrink();
            }
            _blurFilterFor(overscanSize);
            return FittedBox(
              fit: BoxFit.fill,
              child: RepaintBoundary(
                // 先把小尺寸流光层光栅化，再由 FittedBox 放大，避免模糊按整窗分辨率执行。
                child: SizedBox.fromSize(
                  size: cropSize,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.center,
                      minWidth: overscanSize.width,
                      maxWidth: overscanSize.width,
                      minHeight: overscanSize.height,
                      maxHeight: overscanSize.height,
                      child: CustomPaint(painter: _painter, size: overscanSize),
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
  const _DecodedCover(this.image, this.baseColor);

  final ui.Image image;
  final Color baseColor;
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
  double motionSpeed = 1.0;
  double _onset = 0.0;
  double _previousEnergy = 0.0;
  bool _skipOnset = false;
  bool awaitingPlaybackSpectrum = false;

  double get onset => _onset;

  void markListenStarted() {
    _skipOnset = true;
    awaitingPlaybackSpectrum = true;
  }

  void followSpeed(double deltaSeconds) {
    final energy = audioReactiveFlowBeatEnergy(
      AudioReactiveFlowResponse(low, mid, high),
    );
    if (_skipOnset) {
      _skipOnset = false;
      _onset = 0;
      _previousEnergy = energy;
    } else {
      _onset = audioReactiveFlowOnsetPulse(
        currentEnergy: energy,
        previousEnergy: _previousEnergy,
        previousPulse: _onset,
      );
      _previousEnergy = energy;
    }
    final target = audioReactiveFlowMotionSpeedTarget(
      energy: energy,
      onset: _onset,
    );
    if (!deltaSeconds.isFinite || deltaSeconds <= 0) return;
    final timeConstant = target > motionSpeed ? 0.07 : 0.22;
    final response = 1 - exp(-deltaSeconds / timeConstant);
    motionSpeed += (target - motionSpeed) * response;
  }

  void reset() {
    low = 0.0;
    mid = 0.0;
    high = 0.0;
    motionSpeed = 1.0;
    _onset = 0.0;
    _previousEnergy = 0.0;
    _skipOnset = false;
    awaitingPlaybackSpectrum = false;
  }
}

class _FlowingLightVisualStyle {
  const _FlowingLightVisualStyle({
    required this.artworkSaturation,
    required this.blackScrim,
    required this.washPrimary,
    required this.washSecondary,
    required this.scrim,
  });

  final double artworkSaturation;
  final double blackScrim;
  final Color washPrimary;
  final Color washSecondary;
  final List<Color> scrim;
}

ui.ColorFilter _flowingLightColorFilter(
  double saturation,
  double blackScrim, [
  double contrast = 1.0,
]) {
  const redLuminance = 0.2126;
  const greenLuminance = 0.7152;
  const blueLuminance = 0.0722;
  final inverse = 1.0 - saturation;
  final scale = (1.0 - blackScrim) * contrast;
  final offset = 127.5 * (1.0 - contrast);
  return ui.ColorFilter.matrix(<double>[
    scale * (inverse * redLuminance + saturation),
    scale * inverse * greenLuminance,
    scale * inverse * blueLuminance,
    0,
    offset,
    scale * inverse * redLuminance,
    scale * (inverse * greenLuminance + saturation),
    scale * inverse * blueLuminance,
    0,
    offset,
    scale * inverse * redLuminance,
    scale * inverse * greenLuminance,
    scale * (inverse * blueLuminance + saturation),
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
    required this.motion,
    required this.transitionClock,
    required this.audio,
    required this.blurHandle,
    required ValueNotifier<int> repaint,
  }) : super(repaint: repaint);

  ui.Image? coverImage;
  ui.Image? previousCoverImage;
  Color coverBaseColor = _kDarkNeutralBackground;
  Color previousCoverBaseColor = _kDarkNeutralBackground;
  double previousMotionTime = 0;
  final _FlowMotionState motion;
  final Stopwatch transitionClock;
  bool audioReactiveFlow = false;
  final _FlowAudioState audio;
  _FlowingLightVisualStyle style = _kDarkFlowingLightStyle;
  final _BlurFilterHandle blurHandle;

  static const _artworkCurve = Cubic(0, 0, 0.3, 1);
  late final ui.Paint _coverPaint = ui.Paint()
    ..filterQuality = FilterQuality.medium;
  late final ui.Paint _compositePaint = ui.Paint()
    ..filterQuality = FilterQuality.low;
  ui.Paint? _scrimPaint;
  Size? _scrimPaintSize;
  List<Color>? _scrimPaintColors;
  ui.ColorFilter? _cachedColorFilter;
  double? _cachedSaturation;
  double? _cachedBlackScrim;
  double? _cachedContrast;

  // 参数没变就复用上一帧的矩阵，颜色和上一帧相同。
  ui.ColorFilter _colorFilterFor(
    double saturation,
    double blackScrim,
    double contrast,
  ) {
    final cached = _cachedColorFilter;
    if (cached != null &&
        _cachedSaturation == saturation &&
        _cachedBlackScrim == blackScrim &&
        _cachedContrast == contrast) {
      return cached;
    }
    _cachedSaturation = saturation;
    _cachedBlackScrim = blackScrim;
    _cachedContrast = contrast;
    return _cachedColorFilter = _flowingLightColorFilter(
      saturation,
      blackScrim,
      contrast,
    );
  }

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
    final low = audioReactiveFlow ? audio.low : 0.0;
    final high = audioReactiveFlow ? audio.high : 0.0;
    _coverPaint.colorFilter = _colorFilterFor(
      style.artworkSaturation +
          (audioReactiveFlow ? audioReactiveFlowSaturationBoost(high) : 0.0),
      style.blackScrim,
      audioReactiveFlow ? audioReactiveFlowContrast(low) : 1.0,
    );
    final previous = previousCoverImage;
    if (previous != null) {
      _drawFrame(
        canvas,
        size,
        previous,
        previousCoverBaseColor,
        previousMotionTime,
        1.0,
      );
    }
    _drawFrame(
      canvas,
      size,
      coverImage,
      coverBaseColor,
      _motionTime,
      _transitionProgress,
    );
    canvas.drawRect(Offset.zero & size, _scrimPaintFor(size));
  }

  void _drawFrame(
    Canvas canvas,
    Size size,
    ui.Image? image,
    Color baseColor,
    double time,
    double opacity,
  ) {
    if (image == null || opacity <= 0) return;
    final low = audioReactiveFlow ? audio.low : 0.0;
    final mid = audioReactiveFlow ? audio.mid : 0.0;
    final high = audioReactiveFlow ? audio.high : 0.0;
    final zoom = audioReactiveFlow
        ? (audioReactiveFlowSpectrumScale(low, mid) + audio.onset * 0.08)
              .clamp(1.0, 1.48)
              .toDouble()
        : 1.0;
    final cycle2 = time / _kCoverPeriod2 * 2 * pi;
    final secondaryOffset = Offset(
      _kSecondaryOffset.dx + cos(-cycle2 * 0.5) * _kSecondaryOrbit - mid * 0.02,
      _kSecondaryOffset.dy +
          sin(-cycle2 * 0.5) * _kSecondaryOrbit +
          low * 0.015,
    );
    _compositePaint.color = const Color(
      0xFFFFFFFF,
    ).withValues(alpha: opacity.clamp(0.0, 1.0));
    canvas.saveLayer(Offset.zero & size, _compositePaint);
    canvas.drawColor(baseColor, BlendMode.src);
    canvas.save();
    if (zoom != 1.0) {
      canvas
        ..translate(size.width / 2, size.height / 2)
        ..scale(zoom)
        ..translate(-size.width / 2, -size.height / 2);
    }
    _drawCoverLayer(
      canvas,
      size,
      image,
      time: time,
      period: _kCoverPeriod1,
      offset: Offset(
        _kPrimaryOffset.dx + low * 0.01,
        _kPrimaryOffset.dy - low * 0.008,
      ),
      alpha: _kPrimaryLayerAlpha,
      scaleMul: _kPrimaryScaleMul,
    );
    _drawCoverLayer(
      canvas,
      size,
      image,
      time: time,
      period: _kCoverPeriod2,
      offset: secondaryOffset,
      alpha: _kSecondaryLayerAlpha,
      scaleMul: _kSecondaryScaleMul,
    );
    _drawCoverLayer(
      canvas,
      size,
      image,
      time: time,
      period: _kCoverPeriod3,
      offset: Offset(
        _kLightOffset.dx + high * 0.015,
        _kLightOffset.dy - low * 0.02,
      ),
      alpha: _kLightLayerAlpha,
      scaleMul: _kLightScaleMul,
      phase: pi,
    );
    canvas.restore();
    if (style.washPrimary.a > 0) {
      canvas.drawColor(style.washPrimary, BlendMode.srcOver);
    }
    if (style.washSecondary.a > 0) {
      canvas.drawColor(style.washSecondary, BlendMode.srcOver);
    }
    canvas.restore();
  }

  void _drawCoverLayer(
    Canvas canvas,
    Size size,
    ui.Image image, {
    required double time,
    required double period,
    required Offset offset,
    required int alpha,
    required double scaleMul,
    double phase = 0.0,
  }) {
    final cycle = time / period * 2 * pi;
    final imageW = image.width.toDouble();
    final imageH = image.height.toDouble();
    final longest = max(size.width, size.height);
    final coverScale =
        longest / max(max(imageW, imageH), 1.0) * scaleMul * _kOverscan;
    final center = Offset(
      size.width * 0.5 + size.width * offset.dx,
      size.height * 0.5 + size.height * offset.dy,
    );
    _coverPaint.color = Color.fromARGB(alpha, 255, 255, 255);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(cycle + phase);
    canvas.scale(coverScale);
    canvas.drawImage(image, Offset(-imageW / 2, -imageH / 2), _coverPaint);
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
        oldDelegate.coverBaseColor != coverBaseColor ||
        oldDelegate.previousCoverBaseColor != previousCoverBaseColor ||
        oldDelegate.previousMotionTime != previousMotionTime ||
        oldDelegate.audioReactiveFlow != audioReactiveFlow ||
        !identical(oldDelegate.audio, audio) ||
        oldDelegate.style != style ||
        !identical(oldDelegate.blurHandle, blurHandle);
  }

  @override
  bool? hitTest(Offset position) => null;
}
