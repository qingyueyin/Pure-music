import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pure_music/page/now_playing_page/component/audio_reactive_flow.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

const _kDecodeSize = 256;
const _kGaussianShaderAssetPath = 'assets/shaders/pulse_gaussian.frag';
const _kOverscan = 1.3;
const _kDownsampleLow = 8.0;
const _kDownsampleHigh = 12.0;
const _kHighDpiThreshold = 2.625;
const _kMinCropLongest = 128.0;
const _kBlurChromaBoost = 1.16;
const _kDarkNeutralBackground = Color(0xFF171717);
const _kLightNeutralBackground = Color(0xFFF0F0F0);
const _kArtworkTransitionDuration = Duration(milliseconds: 300);
const _kPlaybackSpeedTransitionDuration = Duration(milliseconds: 650);
const _kFrameInterval = Duration(milliseconds: 66);

const _kCoverPeriod1 = 75.0;
const _kCoverPeriod2 = 55.0;
const _kCoverPeriod3 = 62.0;
const _kPrefilterPadding = 32;
// 1280×720 参考窗口下的预模糊 sigma；其他尺寸按画布大小换算。
const _kReferencePrimarySigma = 12.6;
const _kReferenceSoftSigma = 11.5;

typedef _PrefilterSigmas = ({double primary, double soft});

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

/// 按画布尺寸换算预模糊 sigma，复现旧版「6px 预模糊 + 运行时整屏模糊」的合成效果。
@visibleForTesting
({double primary, double soft}) flowingLightPrefilterSigmas(Size overscanSize) {
  if (overscanSize.isEmpty) {
    return (primary: _kReferencePrimarySigma, soft: _kReferenceSoftSigma);
  }
  final runtimeCanvas = (overscanSize.shortestSide * 0.10).clamp(8.0, 16.0);
  final coverScale =
      max(overscanSize.width, overscanSize.height) * _kOverscan / _kDecodeSize;
  final runtimeTexture = runtimeCanvas / max(coverScale, 0.0001);
  return (
    primary: sqrt(36 + runtimeTexture * runtimeTexture),
    soft: sqrt(9 + runtimeTexture * runtimeTexture),
  );
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

/// 预模糊好的封面纹理：主层用原尺寸，副层只按半尺寸显示，单独生成以免放大后变糊。
class _CoverTextures {
  const _CoverTextures(
    this.primary,
    this.soft, {
    this.padding = _kPrefilterPadding,
    this.owned = true,
  });

  final ui.Image primary;
  final ui.Image soft;
  // 纹理四周的透明边，缩放时按去掉边距后的内容尺寸算。
  final int padding;
  // 回退路径直接复用封面原图，所有权仍归 _DecodedCover。
  final bool owned;

  void dispose() {
    if (!owned) return;
    primary.dispose();
    if (!identical(primary, soft)) soft.dispose();
  }
}

class FlowingLightBackground extends StatefulWidget {
  final NowPlayingBackgroundInputs inputs;

  const FlowingLightBackground({super.key, required this.inputs});

  static Future<void> precache() => _FlowingLightBackgroundState.precache();

  @override
  State<FlowingLightBackground> createState() => _FlowingLightBackgroundState();
}

class _FlowingLightBackgroundState extends State<FlowingLightBackground> {
  _DecodedCover? _cover;
  _DecodedCover? _previousCover;
  _DecodedCover? _pendingCover;
  double _previousMotionTime = 0;
  Size? _overscanSize;
  Timer? _prefilterDebounce;
  int _prefilterGeneration = 0;

  late final Stopwatch _transitionClock;
  final Stopwatch _paintClock = Stopwatch();
  Timer? _paintTimer;
  late final _FlowingLightPainter _painter;
  final _FlowMotionState _motion = _FlowMotionState();
  Duration _lastTickElapsed = Duration.zero;
  Duration? _lastSpectrumElapsed;

  final ValueNotifier<int> _frameNotifier = ValueNotifier(0);
  final AudioReactiveFlowEngine _engine = AudioReactiveFlowEngine();
  final _FlowAudioState _audio = _FlowAudioState();
  StreamSubscription<Float32List>? _spectrumSubscription;
  DateTime? _spectrumPausedAt;
  int _decodeGeneration = 0;
  bool _disposed = false;
  bool _tickerModeEnabled = true;
  Animation<double>? _routeAnimation;
  bool _routeTransitionSettled = true;

  static const double _kIdleSpeed = 0.0;
  static const double _kActiveSpeed = 1.0;
  static ui.FragmentProgram? _cachedGaussianProgram;
  static Future<ui.FragmentProgram?>? _gaussianProgramFuture;

  /// 预模糊在解码封面时用着色器，启动时先把资产加载好。
  static Future<void> precache() async {
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
    _painter = _FlowingLightPainter(
      motion: _motion,
      transitionClock: _transitionClock,
      audio: _audio,
      repaint: _frameNotifier,
    );
    _scheduleCoverDecode();
    _syncSpectrumSubscription();
    _bindPlayerStateListenable();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncAnimationState();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindRouteAnimation();
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
    if (widget.inputs.trackId != oldWidget.inputs.trackId) {
      // 切歌只重建鼓点检测，慢电平和连续量程从上一首接续。
      _engine.resetForTrackChange();
      _audio.resetForTrackChange();
      _lastSpectrumElapsed = null;
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
        _routeTransitionSettled &&
        _tickerModeEnabled &&
        _cover != null &&
        widget.inputs.enableAnimation &&
        widget.inputs.audioReactiveFlow &&
        widget.inputs.isVisible &&
        widget.inputs.isPlaybackActive;
    if (shouldListen) {
      if (_spectrumSubscription == null) {
        final pausedAt = _spectrumPausedAt;
        final pausedFor = pausedAt == null
            ? Duration.zero
            : DateTime.now().difference(pausedAt);
        // 断流恢复保留慢电平，并让脉冲按暂停时长退场；首次订阅才重置。
        if (audioReactiveFlowShouldResetAfterPause(
          pausedFor: pausedAt == null ? null : pausedFor,
        )) {
          _engine.reset();
          _resetAudioVisual();
        } else {
          _engine.resumeFromPause(
            elapsedSeconds:
                pausedFor.inMicroseconds / Duration.microsecondsPerSecond,
          );
        }
        _lastSpectrumElapsed = null;
        _audio.markListenStarted();
        _spectrumPausedAt = null;
        _spectrumSubscription = stream.listen(_handleSpectrum);
      }
      return;
    }
    if (_spectrumSubscription != null || _spectrumPausedAt == null) {
      _spectrumPausedAt = DateTime.now();
    }
    _lastSpectrumElapsed = null;
    _spectrumSubscription?.cancel();
    _spectrumSubscription = null;
  }

  void _bindRouteAnimation() {
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _routeAnimation)) return;
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _routeAnimation = animation;
    _routeAnimation?.addStatusListener(_onRouteAnimationStatus);
    final settled =
        animation == null || animation.status == AnimationStatus.completed;
    if (settled == _routeTransitionSettled) return;
    _routeTransitionSettled = settled;
    _syncAnimationState();
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (!mounted) return;
    final settled = status == AnimationStatus.completed;
    if (settled == _routeTransitionSettled) return;
    _routeTransitionSettled = settled;
    // 离开播放页的同一帧断掉频谱，包络停在当前值；过渡结束才重新接。
    _syncAnimationState();
  }

  void _handleSpectrum(Float32List bands) {
    if (_disposed) return;
    if (!widget.inputs.audioReactiveFlow) return;
    final response = AudioReactiveFlowResponse.fromBands(bands);
    final elapsed = _transitionClock.elapsed;
    final previous = _lastSpectrumElapsed;
    _lastSpectrumElapsed = elapsed;
    final dtSeconds = previous == null
        ? null
        : (elapsed - previous).inMicroseconds / Duration.microsecondsPerSecond;
    // 离开播放页或过渡中不写色场，包络停在离开时的值。
    _audio.awaitingPlaybackSpectrum = audioReactiveFlowWriteSpectrum(
      pageSettled: _routeTransitionSettled,
      awaitingPlaybackSpectrum: _audio.awaitingPlaybackSpectrum,
      incoming: response,
      engine: _engine,
      dtSeconds: dtSeconds,
    );
  }

  void _resetAudioVisual() {
    _audio.reset();
  }

  void _resetAudioResponse() {
    _engine.reset();
    _lastSpectrumElapsed = null;
    _resetAudioVisual();
  }

  void _syncAnimationState() {
    if (_disposed) return;
    _syncSpectrumSubscription();
    final canMove =
        _cover != null &&
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
        _tickerModeEnabled && _previousCover != null && widget.inputs.isVisible;

    if (shouldTransition) {
      _transitionClock.start();
    } else {
      _transitionClock.stop();
    }

    final shouldTick = shouldMove || shouldTransition;
    if (shouldTick && _paintTimer == null) {
      _startPaintTimer();
    } else if (!shouldTick && _paintTimer != null) {
      _stopPaintTimer();
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

  void _startPaintTimer() {
    _paintClock
      ..stop()
      ..reset()
      ..start();
    _lastTickElapsed = Duration.zero;
    // 按 15fps 出帧，避免空闲帧跟着屏幕刷新率空转。
    _paintTimer = Timer.periodic(_kFrameInterval, (_) => _onPaintTick());
  }

  void _stopPaintTimer() {
    _paintTimer?.cancel();
    _paintTimer = null;
    _paintClock.stop();
    _lastTickElapsed = Duration.zero;
  }

  void _onPaintTick() {
    if (_disposed || !mounted) return;

    final elapsed = _paintClock.elapsed;
    final deltaSeconds =
        (elapsed - _lastTickElapsed).inMicroseconds /
        Duration.microsecondsPerSecond;
    _lastTickElapsed = elapsed;
    final averageSpeed = _updatePlaybackSpeed(deltaSeconds);
    _updateAudio(deltaSeconds);
    final audioSpeed = widget.inputs.audioReactiveFlow
        ? _audio.motionSpeed
        : 1.0;
    _motion.time +=
        deltaSeconds * widget.inputs.flowSpeed * averageSpeed * audioSpeed;

    if (_previousCover != null &&
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
    final env = _engine.value;
    _audio.low = audioReactiveFlowLevel(env.low);
    _audio.mid = audioReactiveFlowLevel(env.mid);
    _audio.high = audioReactiveFlowLevel(env.high);
    _audio.followSlow(
      low: audioReactiveFlowLevel(_engine.levelLow),
      mid: audioReactiveFlowLevel(_engine.levelMid),
      high: audioReactiveFlowLevel(_engine.levelHigh),
      deltaSeconds: deltaSeconds,
    );
    _audio.beat = audioReactiveFlowFollowBeat(
      current: _audio.beat,
      target: _engine.beatPulse,
      dtSeconds: deltaSeconds,
    );
    _audio.followSpeed(deltaSeconds);
    _audio.followFast(deltaSeconds);
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
      // 把模糊烤进封面纹理，运行时不再对整屏做高斯。
      final source = image;
      image = null;
      final sigmas = flowingLightPrefilterSigmas(_overscanSize ?? Size.zero);
      _CoverTextures textures;
      try {
        textures = await _prefilterCoverTextures(source, sigmas);
      } catch (_) {
        // 预模糊失败时退回未模糊封面，至少保留背景。
        textures = _CoverTextures(source, source, padding: 0, owned: false);
      }
      final decoded = _DecodedCover(source, textures, baseColor, sigmas);
      if (_disposed || !mounted || generation != _decodeGeneration) {
        decoded.dispose();
        return;
      }
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

  Future<_CoverTextures> _prefilterCoverTextures(
    ui.Image source,
    _PrefilterSigmas sigmas,
  ) async {
    final primary = await _prefilterCoverImage(source, sigmas.primary);
    ui.Image? softSource;
    try {
      softSource = await _downscaleCover(source);
      final soft = await _prefilterCoverImage(softSource, sigmas.soft);
      return _CoverTextures(primary, soft);
    } catch (_) {
      primary.dispose();
      rethrow;
    } finally {
      softSource?.dispose();
    }
  }

  Future<ui.Image> _downscaleCover(ui.Image source) async {
    final width = max(1, source.width ~/ 2);
    final height = max(1, source.height ~/ 2);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  }

  Future<ui.Image> _prefilterCoverImage(ui.Image source, double sigma) async {
    final width = source.width + _kPrefilterPadding * 2;
    final height = source.height + _kPrefilterPadding * 2;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // 留出透明边，模糊后边缘自然淡出，和整屏模糊时的层间过渡一致。
    canvas.drawImage(
      source,
      Offset(_kPrefilterPadding.toDouble(), _kPrefilterPadding.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final padded = recorder.endRecording();
    ui.Image? paddedImage;
    ui.Image? blurred;
    final program = ui.ImageFilter.isShaderFilterSupported
        ? await _gaussianProgram()
        : null;
    final horizontal = program?.fragmentShader();
    final vertical = program?.fragmentShader();
    try {
      paddedImage = await padded.toImage(width, height);
      ui.ImageFilter filter;
      if (horizontal != null && vertical != null) {
        _configureSeparableBlurShader(
          horizontal,
          horizontal: true,
          sigma: sigma,
        );
        _configureSeparableBlurShader(
          vertical,
          horizontal: false,
          sigma: sigma,
        );
        filter = ui.ImageFilter.compose(
          inner: ui.ImageFilter.shader(horizontal),
          outer: ui.ImageFilter.shader(vertical),
        );
      } else {
        filter = _fallbackBlurFilter(sigma);
      }
      final blurRecorder = ui.PictureRecorder();
      final blurCanvas = Canvas(blurRecorder);
      blurCanvas.drawImage(
        paddedImage,
        Offset.zero,
        Paint()
          ..filterQuality = FilterQuality.medium
          ..imageFilter = filter,
      );
      final blurPicture = blurRecorder.endRecording();
      try {
        blurred = await blurPicture.toImage(width, height);
      } finally {
        blurPicture.dispose();
      }
      return blurred;
    } catch (_) {
      blurred?.dispose();
      rethrow;
    } finally {
      padded.dispose();
      paddedImage?.dispose();
      horizontal?.dispose();
      vertical?.dispose();
    }
  }

  ui.ImageFilter _fallbackBlurFilter(double sigma) {
    return ui.ImageFilter.blur(
      sigmaX: sigma,
      sigmaY: sigma,
      tileMode: TileMode.clamp,
    );
  }

  void _configureSeparableBlurShader(
    ui.FragmentShader shader, {
    required bool horizontal,
    required double sigma,
  }) {
    final inv2s2 = 1.0 / (2.0 * sigma * sigma);
    shader
      ..setFloat(2, horizontal ? 1.0 : 0.0)
      ..setFloat(3, horizontal ? 0.0 : 1.0)
      ..setFloat(4, inv2s2)
      ..setFloat(5, horizontal ? 1.0 : _kBlurChromaBoost);
  }

  void _acceptDecodedCover(_DecodedCover decoded) {
    if (_previousCover != null) {
      _pendingCover?.dispose();
      _pendingCover = decoded;
      return;
    }
    if (_cover == null) {
      setState(() {
        _cover = decoded;
      });
      _syncAnimationState();
      _schedulePrefilterCheck();
      return;
    }
    _startArtworkTransition(decoded);
  }

  void _startArtworkTransition(_DecodedCover decoded) {
    final currentTime = _motion.time;
    setState(() {
      _previousCover = _cover;
      _previousMotionTime = currentTime;
      _cover = decoded;
      _transitionClock
        ..stop()
        ..reset();
    });
    _syncAnimationState();
  }

  void _finishArtworkTransition() {
    final completedPrevious = _previousCover;
    final pending = _pendingCover;
    _pendingCover = null;
    if (pending == null) {
      setState(() {
        _previousCover = null;
        _transitionClock
          ..stop()
          ..reset();
      });
    } else {
      final currentTime = _motion.time;
      setState(() {
        _previousCover = _cover;
        _previousMotionTime = currentTime;
        _cover = pending;
        _transitionClock
          ..stop()
          ..reset();
      });
      _schedulePrefilterCheck();
    }
    _disposeCoversAfterFrame([completedPrevious]);
    _syncAnimationState();
  }

  void _clearArtwork() {
    final current = _cover;
    final previous = _previousCover;
    final pending = _pendingCover;
    _cover = null;
    _previousCover = null;
    _pendingCover = null;
    _prefilterGeneration++;
    _prefilterDebounce?.cancel();
    _prefilterDebounce = null;
    _transitionClock
      ..stop()
      ..reset();
    // 图片下一帧就销毁，先解除引用，避免淡出期间画到已释放的图。
    _painter
      ..cover = null
      ..previousCover = null;
    if (mounted && !_disposed) {
      setState(() {});
      _disposeCoversAfterFrame([current, previous, pending]);
    } else {
      current?.dispose();
      previous?.dispose();
      pending?.dispose();
    }
    _syncAnimationState();
  }

  void _disposeCoversAfterFrame(Iterable<_DecodedCover?> covers) {
    final disposable = covers.whereType<_DecodedCover>().toList(
      growable: false,
    );
    if (disposable.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final cover in disposable) {
        cover.dispose();
      }
    });
  }

  void _disposeTexturesAfterFrame(Iterable<_CoverTextures?> textures) {
    final disposable = textures.whereType<_CoverTextures>().toList(
      growable: false,
    );
    if (disposable.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final texture in disposable) {
        texture.dispose();
      }
    });
  }

  void _schedulePrefilterCheck() {
    if (_disposed) return;
    _prefilterDebounce?.cancel();
    _prefilterDebounce = Timer(const Duration(milliseconds: 200), () {
      _prefilterDebounce = null;
      _maybeReprefilter();
    });
  }

  void _maybeReprefilter() {
    if (_disposed || !mounted) return;
    final cover = _cover;
    final overscanSize = _overscanSize;
    if (cover == null || overscanSize == null || overscanSize.isEmpty) return;
    final sigmas = flowingLightPrefilterSigmas(overscanSize);
    if (_sigmaCloseEnough(sigmas.primary, cover.sigmas.primary)) return;
    _reprefilter(cover, sigmas);
  }

  static bool _sigmaCloseEnough(double a, double b) {
    return (a - b).abs() <= b * 0.08;
  }

  Future<void> _reprefilter(
    _DecodedCover cover,
    _PrefilterSigmas sigmas,
  ) async {
    final generation = ++_prefilterGeneration;
    try {
      final textures = await _prefilterCoverTextures(cover.source, sigmas);
      final overscanSize = _overscanSize;
      if (_disposed ||
          generation != _prefilterGeneration ||
          !identical(_cover, cover) ||
          overscanSize == null ||
          !_sigmaCloseEnough(
            flowingLightPrefilterSigmas(overscanSize).primary,
            sigmas.primary,
          )) {
        textures.dispose();
        return;
      }
      final oldTextures = cover.textures;
      cover
        ..textures = textures
        ..sigmas = sigmas;
      if (identical(_painter.cover, oldTextures)) {
        _painter.cover = textures;
      }
      if (identical(_painter.previousCover, oldTextures)) {
        _painter.previousCover = textures;
      }
      _disposeTexturesAfterFrame([oldTextures]);
      _frameNotifier.value++;
    } catch (_) {
      // 预模糊失败时保留现有纹理。
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _decodeGeneration++;
    _prefilterGeneration++;
    _prefilterDebounce?.cancel();
    _stopPaintTimer();
    _transitionClock.stop();
    _cover?.dispose();
    _previousCover?.dispose();
    _pendingCover?.dispose();
    _frameNotifier.dispose();
    _spectrumSubscription?.cancel();
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
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
    required _DecodedCover cover,
    required _FlowingLightVisualStyle style,
    required bool audioReactiveFlow,
  }) {
    final previous = _previousCover;
    final changed =
        !identical(_painter.cover, cover.textures) ||
        !identical(_painter.previousCover, previous?.textures) ||
        _painter.coverBaseColor != cover.baseColor ||
        _painter.previousCoverBaseColor !=
            (previous?.baseColor ?? _kDarkNeutralBackground) ||
        _painter.previousMotionTime != _previousMotionTime ||
        _painter.audioReactiveFlow != audioReactiveFlow ||
        _painter.style != style;
    _painter
      ..cover = cover.textures
      ..previousCover = previous?.textures
      ..coverBaseColor = cover.baseColor
      ..previousCoverBaseColor = previous?.baseColor ?? _kDarkNeutralBackground
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
    final cover = _cover;
    final style = isDark ? _kDarkFlowingLightStyle : _kLightFlowingLightStyle;
    final backgroundColor = isDark
        ? _kDarkNeutralBackground
        : _kLightNeutralBackground;
    if (cover != null) {
      _syncPainter(
        cover: cover,
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
            if (overscanSize != _overscanSize) {
              _overscanSize = overscanSize;
              _schedulePrefilterCheck();
            }
            // 无效/缺失封面立刻卸掉绘制层，避免还画着上一首的图。
            if (cover == null) {
              return const SizedBox.shrink();
            }
            final layer = SizedBox.fromSize(
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
            );
            return FittedBox(
              fit: BoxFit.fill,
              // 小尺寸绘制后由 FittedBox 放大；不再单独成层（见 MEM_LOOP）
              child: layer,
            );
          },
        ),
      ],
    );
  }
}

class _DecodedCover {
  _DecodedCover(this.source, this.textures, this.baseColor, this.sigmas);

  final ui.Image source;
  _CoverTextures textures;
  final Color baseColor;
  _PrefilterSigmas sigmas;

  void dispose() {
    final ownsTextures = textures.owned;
    textures.dispose();
    if (!ownsTextures || !identical(source, textures.primary)) {
      source.dispose();
    }
  }
}

class _FlowMotionState {
  double time = 0.0;
}

class _FlowAudioState {
  double low = 0.0;
  double mid = 0.0;
  double high = 0.0;
  double motionSpeed = 1.0;

  /// 慢通道：几秒级平均，用来决定整体缩放、层位移和颜色；鼓点只加脉冲。
  double slowLow = 0.0;
  double slowMid = 0.0;
  double slowHigh = 0.0;

  /// 鼓点脉冲由引擎按事件算出，和显示帧率解耦。
  double beat = 0.0;

  /// 快通道：只推光带和副层这些柔性元素，主封面层不用它。
  double fastLow = 0.0;
  double fastMid = 0.0;
  double fastHigh = 0.0;

  bool _seedFast = false;
  bool awaitingPlaybackSpectrum = false;

  void markListenStarted() {
    _seedFast = true;
    awaitingPlaybackSpectrum = true;
  }

  void followSlow({
    required double low,
    required double mid,
    required double high,
    required double deltaSeconds,
  }) {
    if (!deltaSeconds.isFinite || deltaSeconds <= 0) return;
    slowLow = _follow(slowLow, low, deltaSeconds, .22, .45);
    slowMid = _follow(slowMid, mid, deltaSeconds, .22, .45);
    slowHigh = _follow(slowHigh, high, deltaSeconds, .22, .45);
  }

  void followSpeed(double deltaSeconds) {
    final energy = audioReactiveFlowBeatEnergy(
      AudioReactiveFlowResponse(slowLow, slowMid, slowHigh),
    );
    final target = audioReactiveFlowMotionSpeedTarget(
      energy: energy,
      beat: beat,
      energyGain: .20,
      beatGain: .40,
    );
    if (!deltaSeconds.isFinite || deltaSeconds <= 0) return;
    final timeConstant = target > motionSpeed ? 0.07 : 0.18;
    final response = 1 - exp(-deltaSeconds / timeConstant);
    motionSpeed += (target - motionSpeed) * response;
  }

  /// 快通道用固定起音/回落，只给柔性元素；1% 级噪声到不了可见形变。
  void followFast(double deltaSeconds) {
    if (_seedFast) {
      fastLow = low;
      fastMid = mid;
      fastHigh = high;
      _seedFast = false;
      return;
    }
    if (!deltaSeconds.isFinite || deltaSeconds <= 0) return;
    fastLow = _follow(fastLow, low, deltaSeconds, .07, .28);
    fastMid = _follow(fastMid, mid, deltaSeconds, .07, .28);
    fastHigh = _follow(fastHigh, high, deltaSeconds, .07, .28);
  }

  static double _follow(
    double current,
    double target,
    double deltaSeconds,
    double attack,
    double release,
  ) {
    final tau = target > current ? attack : release;
    return current + (target - current) * (1 - exp(-deltaSeconds / tau));
  }

  /// 切歌保留慢电平、位移、速度和当前鼓点，只重建检测，避免画面从零重新爬。
  void resetForTrackChange() {
    awaitingPlaybackSpectrum = true;
  }

  void reset() {
    low = 0.0;
    mid = 0.0;
    high = 0.0;
    motionSpeed = 1.0;
    slowLow = 0.0;
    slowMid = 0.0;
    slowHigh = 0.0;
    fastLow = 0.0;
    fastMid = 0.0;
    fastHigh = 0.0;
    beat = 0.0;
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
    required ValueNotifier<int> repaint,
  }) : super(repaint: repaint);

  _CoverTextures? cover;
  _CoverTextures? previousCover;
  Color coverBaseColor = _kDarkNeutralBackground;
  Color previousCoverBaseColor = _kDarkNeutralBackground;
  double previousMotionTime = 0;
  final _FlowMotionState motion;
  final Stopwatch transitionClock;
  bool audioReactiveFlow = false;
  final _FlowAudioState audio;
  _FlowingLightVisualStyle style = _kDarkFlowingLightStyle;

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
    if (previousCover == null) return 1;
    final linear =
        transitionClock.elapsedMicroseconds /
        _kArtworkTransitionDuration.inMicroseconds;
    return _artworkCurve.transform(linear.clamp(0.0, 1.0));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final slowHigh = audioReactiveFlow ? audio.slowHigh : 0.0;
    _coverPaint.colorFilter = _colorFilterFor(
      style.artworkSaturation +
          (audioReactiveFlow
              ? audioReactiveFlowSaturationBoost(
                  slowHigh * .6 + audio.fastHigh * .4,
                )
              : 0.0),
      style.blackScrim,
      audioReactiveFlow ? audioReactiveFlowContrast(audio.slowLow) : 1.0,
    );
    final previous = previousCover;
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
      cover,
      coverBaseColor,
      _motionTime,
      _transitionProgress,
    );
    canvas.drawRect(Offset.zero & size, _scrimPaintFor(size));
  }

  void _drawFrame(
    Canvas canvas,
    Size size,
    _CoverTextures? textures,
    Color baseColor,
    double time,
    double opacity,
  ) {
    if (textures == null || opacity <= 0) return;
    final slowLow = audioReactiveFlow ? audio.slowLow : 0.0;
    final slowMid = audioReactiveFlow ? audio.slowMid : 0.0;
    final slowHigh = audioReactiveFlow ? audio.slowHigh : 0.0;
    // 主封面层的位移走慢电平。
    final motionLow = slowLow;
    final motionMid = slowMid;
    final motionHigh = slowHigh;
    // 快通道只推柔性层，主封面层继续走慢电平。
    final fastLow = audioReactiveFlow ? audio.fastLow : 0.0;
    final fastMid = audioReactiveFlow ? audio.fastMid : 0.0;
    final fastHigh = audioReactiveFlow ? audio.fastHigh : 0.0;
    final zoom = audioReactiveFlow
        ? audioReactiveFlowZoom(
            slowLow: slowLow,
            slowMid: slowMid,
            beat: audio.beat,
          )
        : 1.0;
    final localBeat = audioReactiveFlow ? audio.beat : 0.0;
    // 主封面只吃很小的一下，给视觉焦点一点张力，不做整屏鼓点缩放。
    final primaryBeatScale = audioReactiveFlowLayerScale(
      beat: localBeat,
      maximumIncrease: audioReactiveFlowPrimaryLayerMaxIncrease,
    );
    // 鼓点同时推两个柔性层的位移，和缩放一起把同一下铺开。
    final secondaryBeatOffset = audioReactiveFlowBeatOffset(
      beat: localBeat,
      maximumOffset: audioReactiveFlowSecondaryLayerBeatOffset,
    );
    final lightBeatOffset = audioReactiveFlowBeatOffset(
      beat: localBeat,
      maximumOffset: audioReactiveFlowLightLayerBeatOffset,
    );
    final cycle2 = time / _kCoverPeriod2 * 2 * pi;
    final secondaryOffset = Offset(
      _kSecondaryOffset.dx +
          cos(-cycle2 * 0.5) * _kSecondaryOrbit -
          motionMid * 0.02 -
          fastMid * 0.006 +
          secondaryBeatOffset,
      _kSecondaryOffset.dy +
          sin(-cycle2 * 0.5) * _kSecondaryOrbit +
          motionLow * 0.015 +
          fastLow * 0.006 -
          secondaryBeatOffset * 0.8,
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
      textures.primary,
      time: time,
      period: _kCoverPeriod1,
      offset: Offset(
        _kPrimaryOffset.dx + motionLow * 0.01,
        _kPrimaryOffset.dy - motionLow * 0.008,
      ),
      alpha: _kPrimaryLayerAlpha,
      scaleMul: _kPrimaryScaleMul * primaryBeatScale,
      padding: textures.padding,
    );
    _drawCoverLayer(
      canvas,
      size,
      textures.soft,
      time: time,
      period: _kCoverPeriod2,
      offset: secondaryOffset,
      alpha: _kSecondaryLayerAlpha,
      scaleMul:
          _kSecondaryScaleMul *
          audioReactiveFlowLayerScale(
            beat: localBeat,
            maximumIncrease: audioReactiveFlowSecondaryLayerMaxIncrease,
          ),
      padding: textures.padding,
    );
    _drawCoverLayer(
      canvas,
      size,
      textures.soft,
      time: time,
      period: _kCoverPeriod3,
      offset: Offset(
        _kLightOffset.dx +
            motionHigh * 0.015 +
            fastHigh * 0.015 -
            lightBeatOffset,
        _kLightOffset.dy -
            motionLow * 0.02 -
            fastLow * 0.015 +
            lightBeatOffset * 0.8,
      ),
      alpha: _kLightLayerAlpha,
      scaleMul:
          _kLightScaleMul *
          audioReactiveFlowLayerScale(
            beat: localBeat,
            maximumIncrease: audioReactiveFlowLightLayerMaxIncrease,
          ),
      padding: textures.padding,
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
    required int padding,
    double phase = 0.0,
  }) {
    final cycle = time / period * 2 * pi;
    final imageW = image.width.toDouble();
    final imageH = image.height.toDouble();
    // 纹理四周留了透明边，缩放要按去掉边距后的内容尺寸算。
    final contentW = imageW - padding * 2;
    final contentH = imageH - padding * 2;
    final longest = max(size.width, size.height);
    final coverScale =
        longest / max(max(contentW, contentH), 1.0) * scaleMul * _kOverscan;
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
    return !identical(oldDelegate.cover, cover) ||
        !identical(oldDelegate.previousCover, previousCover) ||
        oldDelegate.coverBaseColor != coverBaseColor ||
        oldDelegate.previousCoverBaseColor != previousCoverBaseColor ||
        oldDelegate.previousMotionTime != previousMotionTime ||
        oldDelegate.audioReactiveFlow != audioReactiveFlow ||
        !identical(oldDelegate.audio, audio) ||
        oldDelegate.style != style;
  }

  @override
  bool? hitTest(Offset position) => null;
}
