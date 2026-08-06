import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_shaders/flutter_shaders.dart';
import 'package:mesh_gradient/mesh_gradient.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

class MeshGradientBackground extends StatelessWidget {
  final NowPlayingBackgroundMode mode;
  final NowPlayingBackgroundInputs inputs;
  final Color fallbackColor;

  const MeshGradientBackground({
    super.key,
    required this.mode,
    required this.inputs,
    required this.fallbackColor,
  });

  @override
  Widget build(BuildContext context) {
    return switch (mode) {
      NowPlayingBackgroundMode.meshGradient => MeshGradientBackgroundInternal(
          inputs: inputs,
          fallbackColor: fallbackColor,
        ),
      _ => MeshGradientBackgroundInternal(
          inputs: inputs,
          fallbackColor: fallbackColor,
        ),
    };
  }
}

class MeshGradientBackgroundInternal extends StatefulWidget {
  final NowPlayingBackgroundInputs inputs;
  final Color fallbackColor;
  final void Function(String)? onError;

  const MeshGradientBackgroundInternal({
    super.key,
    required this.inputs,
    required this.fallbackColor,
    this.onError,
  });

  @override
  State<MeshGradientBackgroundInternal> createState() =>
      _MeshGradientBackgroundInternalState();
}

class _MeshGradientBackgroundInternalState
    extends State<MeshGradientBackgroundInternal>
    with TickerProviderStateMixin {
  List<Color> _paletteColors = [];
  bool _isPlaying = false;
  double _breathScale = 1.0;
  final ValueNotifier<double> _breathScaleNotifier = ValueNotifier(1.0);
  double _targetBreathScale = 1.0;
  double _smoothedEnergy = 0.0;
  StreamSubscription<Float32List>? _spectrumSubscription;

  double _transitionValue = 0.0;
  final ValueNotifier<double> _transitionValueNotifier = ValueNotifier(0.0);
  Ticker? _transitionTicker;
  List<Color> _prevPaletteColors = [];
  List<Color> _targetPaletteColors = [];
  bool _isTransitioning = false;
  bool _disposed = false;

  Timer? _decayTimer;
  Timer? _fallbackPaletteTimer;

  static const Duration _paletteTransitionDuration = Duration(
    milliseconds: 1800,
  );

  /// Controls the mesh gradient's internal Ticker.
  /// Stopped when paused or not visible to avoid idle CPU/GPU overhead.
  final AnimatedMeshGradientController _meshController =
      AnimatedMeshGradientController();

  int? _lastCoverHash;
  int? _lastPaletteSignature;
  int _lastSpectrumUpdateMs = 0;
  final Stopwatch _spectrumClock = Stopwatch()..start();

  static final _playOptions = AnimatedMeshGradientOptions(
    frequency: 4.4,
    amplitude: 48,
    speed: 3.6,
    grain: 0,
  );
  static final _pauseOptions = AnimatedMeshGradientOptions(
    frequency: 4.4,
    amplitude: 52,
    speed: 0.28,
    grain: 0,
  );

  @override
  void initState() {
    super.initState();
    _syncPaletteFromInputs(animate: false);
    _isPlaying = widget.inputs.playerState == PlayerState.playing;
    _listenSpectrum();
    _syncMeshController();
  }

  void _completePaletteTransition() {
    if (_disposed || !mounted) return;
    setState(() {
      _transitionValue = 1.0;
      _transitionValueNotifier.value = 1.0;
      _paletteColors = List.from(_targetPaletteColors);
      _prevPaletteColors = [];
      _targetPaletteColors = [];
      _isTransitioning = false;
    });
    _syncMeshController();
  }

  @override
  void didUpdateWidget(covariant MeshGradientBackgroundInternal oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newBytes = widget.inputs.albumCoverBytes;
    if (!identical(newBytes, oldWidget.inputs.albumCoverBytes)) {
      _coverBytesChanged(newBytes);
    } else if (!identical(
      widget.inputs.preExtractedColors,
      oldWidget.inputs.preExtractedColors,
    )) {
      if (!_syncPaletteFromInputs(animate: true)) {
        _scheduleFallbackPalette();
      }
    }

    final wasVisible = oldWidget.inputs.isVisible;
    final isVisible = widget.inputs.isVisible;
    final nowPlaying = widget.inputs.playerState == PlayerState.playing;

    if (nowPlaying != _isPlaying) {
      setState(() => _isPlaying = nowPlaying);
      _targetBreathScale = nowPlaying ? 1.0 : 0.98;
      _startDecayTimer();
    }

    if (wasVisible != isVisible) {
      _syncMeshController();
      if (!wasVisible && isVisible) {
        if (nowPlaying) {
          _syncSpectrumSubscription();
        }
        _syncPaletteFromInputs(animate: true);
      } else if (wasVisible && !isVisible) {
        _spectrumSubscription?.cancel();
        _spectrumSubscription = null;
      }
    } else if (_isPlaying !=
        (oldWidget.inputs.playerState == PlayerState.playing)) {
      _syncMeshController();
      _syncSpectrumSubscription();
    }
  }

  /// Sync spectrum subscription based on playing and visibility state.
  /// Ensures only one active subscription at any time.
  void _syncSpectrumSubscription() {
    final shouldListen = _isPlaying && widget.inputs.isVisible;

    if (shouldListen && _spectrumSubscription == null) {
      _listenSpectrum();
    } else if (!shouldListen) {
      _spectrumSubscription?.cancel();
      _spectrumSubscription = null;
    }
  }

  void _startDecayTimer() {
    _decayTimer?.cancel();
    const step = Duration(milliseconds: 100);
    const totalSteps = 40;
    var count = 0;

    _decayTimer = Timer.periodic(step, (_) {
      if (_disposed || !mounted || count >= totalSteps) {
        _decayTimer?.cancel();
        _decayTimer = null;
        return;
      }
      count++;
      if (_isPlaying) {
        _decayTimer?.cancel();
        _decayTimer = null;
        return;
      }
      final decay = 1.0 - count / totalSteps;
      final newScale = 1.0 + (_breathScale - 1.0) * decay;
      if ((newScale - _breathScale).abs() > 0.005) {
        _setBreathScale(newScale);
      }
    });
  }

  void _coverBytesChanged(Uint8List? newBytes) {
    if (newBytes == null || newBytes.isEmpty) {
      _lastCoverHash = null;
      if (!_syncPaletteFromInputs(animate: true)) {
        _scheduleFallbackPalette();
      }
      return;
    }
    _fallbackPaletteTimer?.cancel();
    final newHash = _computeHash(newBytes);
    if (_lastCoverHash == newHash) return;
    _lastCoverHash = newHash;

    _syncPaletteFromInputs(animate: true);
  }

  bool _syncPaletteFromInputs({required bool animate}) {
    if (!widget.inputs.isVisible || _disposed) return false;
    final colors = widget.inputs.preExtractedColors;
    if (colors == null || colors.isEmpty) return false;
    _fallbackPaletteTimer?.cancel();

    final target = _padToFour(colors);
    final signature = _paletteSignature(target);
    if (_lastPaletteSignature == signature) return true;
    _lastPaletteSignature = signature;

    if (animate) {
      _applyPaletteColors(target);
    } else {
      _setPaletteColors(target);
    }
    return true;
  }

  void _setPaletteColors(List<Color> colors) {
    final target = _padToFour(colors);
    _transitionTicker?.dispose();
    _transitionTicker = null;
    _transitionValue = 0.0;
    _transitionValueNotifier.value = 0.0;
    _paletteColors = target;
    _prevPaletteColors = [];
    _targetPaletteColors = [];
    _isTransitioning = false;
  }

  void _scheduleFallbackPalette() {
    _fallbackPaletteTimer?.cancel();
    if (_currentDisplayedPalette().isNotEmpty) return;
    _fallbackPaletteTimer = Timer(const Duration(milliseconds: 900), () {
      if (_disposed || !mounted) return;
      final colors = widget.inputs.preExtractedColors;
      if (colors != null && colors.isNotEmpty) return;
      if (_currentDisplayedPalette().isNotEmpty) return;
      _applyPaletteColors(List.filled(4, widget.fallbackColor));
    });
  }

  void _applyPaletteColors(List<Color> colors) {
    final target = _padToFour(colors);
    final displayedColors = _currentDisplayedPalette();
    _lastPaletteSignature = _paletteSignature(target);
    _transitionTicker?.dispose();
    _transitionTicker = null;
    _transitionValue = 0.0;
    _transitionValueNotifier.value = 0.0;

    setState(() {
      _prevPaletteColors = displayedColors.isEmpty
          ? List.filled(4, widget.fallbackColor)
          : _padToFour(displayedColors);
      _targetPaletteColors = target;
      _isTransitioning = true;
    });
    _syncMeshController();

    _transitionTicker = createTicker((elapsed) {
      if (_disposed || !mounted) {
        _transitionTicker?.dispose();
        _transitionTicker = null;
        return;
      }
      final value =
          (elapsed.inMicroseconds / _paletteTransitionDuration.inMicroseconds)
              .clamp(0.0, 1.0);
      if (value >= 1.0) {
        _transitionTicker?.dispose();
        _transitionTicker = null;
        _completePaletteTransition();
        return;
      }
      _transitionValue = value;
      _transitionValueNotifier.value = value;
    });
    _transitionTicker?.start();
  }

  int _computeHash(Uint8List bytes) {
    var hash = bytes.length;
    final step = (bytes.length / 512).ceil();
    for (var i = 0; i < bytes.length; i += step) {
      hash = 0x1fffffff & (hash * 31 + bytes[i]);
    }
    return hash;
  }

  void _listenSpectrum() {
    _spectrumSubscription?.cancel();
    final stream = widget.inputs.spectrumStream;
    if (stream == null ||
        !_isPlaying ||
        !widget.inputs.shouldAnimate ||
        !widget.inputs.isVisible) {
      return;
    }

    _spectrumSubscription = stream.listen((spectrum) {
      if (!mounted || !_isPlaying || !widget.inputs.isVisible) return;

      final now = _spectrumClock.elapsedMilliseconds;
      if (now - _lastSpectrumUpdateMs < 66) return;
      _lastSpectrumUpdateMs = now;

      final lowFreq = spectrum.isNotEmpty ? spectrum[0] : 0.0;
      final subBass = spectrum.length > 1 ? spectrum[1] : 0.0;
      final raw = (lowFreq * 0.7 + subBass * 0.3).clamp(0.0, 1.0);

      // EMA 平滑，α=0.25：足够跟上节拍，但过滤掉高频抖动
      _smoothedEnergy = _smoothedEnergy * 0.75 + raw * 0.25;

      _targetBreathScale = 1.0 +
          _smoothedEnergy * 0.038 * widget.inputs.intensity;

      if ((_targetBreathScale - _breathScale).abs() > 0.006) {
        _setBreathScale(
          _breathScale + (_targetBreathScale - _breathScale) * 0.45,
        );
      }
    });
  }

  void _setBreathScale(double scale) {
    _breathScale = scale;
    _breathScaleNotifier.value = scale;
  }

  List<Color> _padToFour(List<Color> colors) {
    if (colors.isEmpty) {
      final fallback = widget.fallbackColor;
      return List.filled(4, fallback);
    }
    final padded = [...colors];
    while (padded.length < 4) {
      padded.add(colors[padded.length % colors.length]);
    }
    return padded;
  }

  int _paletteSignature(List<Color> colors) {
    var hash = 0x1fffffff & colors.length;
    for (final color in colors) {
      hash = 0x1fffffff & (hash * 31 + color.toARGB32());
    }
    return hash;
  }

  /// Smoothstep interpolation for smoother color transitions.
  /// Smoothstep: t²(3-2t)
  static double _smoothstep(double t) {
    return t * t * (3.0 - 2.0 * t);
  }

  List<Color> _interpolateColors(double t) {
    if (_prevPaletteColors.isEmpty || _targetPaletteColors.isEmpty) {
      return _paletteColors.isEmpty
          ? List.filled(4, widget.fallbackColor)
          : _paletteColors;
    }
    final count =
        _prevPaletteColors.length.clamp(0, _targetPaletteColors.length);
    if (count <= 0) {
      return _targetPaletteColors;
    }
    final smoothedT = _smoothstep(t);
    return List.generate(count, (i) {
      final prev = _prevPaletteColors[i];
      final target = _targetPaletteColors[i];
      return Color.lerp(prev, target, smoothedT)!;
    });
  }

  List<Color> _currentDisplayedPalette() {
    if (_isTransitioning &&
        _prevPaletteColors.isNotEmpty &&
        _targetPaletteColors.isNotEmpty) {
      return _interpolateColors(_transitionValue);
    }
    if (_paletteColors.isNotEmpty) return _paletteColors;
    return const [];
  }

  List<Color> _softenMeshColors(List<Color> colors, Color surface) {
    if (colors.isEmpty) return colors;

    var sumR = 0.0;
    var sumG = 0.0;
    var sumB = 0.0;
    for (final color in colors) {
      sumR += color.r;
      sumG += color.g;
      sumB += color.b;
    }
    final avgR = sumR / colors.length;
    final avgG = sumG / colors.length;
    final avgB = sumB / colors.length;
    int channel(double value) => (value * 255.0).round().clamp(0, 255).toInt();
    final average = Color.fromARGB(
      255,
      channel(avgR),
      channel(avgG),
      channel(avgB),
    );

    final isDark = surface.computeLuminance() < 0.5;
    final surfaceMix = isDark ? 0.02 : 0.04;
    const maxSaturation = 0.72;
    final softened = List<Color>.filled(colors.length, colors.first);
    for (var i = 0; i < colors.length; i++) {
      final color = colors[i];
      final toward = Color.lerp(color, average, 0.22)!;
      final hsl = HSLColor.fromColor(toward);
      final lightness = isDark
          ? (hsl.lightness * 0.86).clamp(0.12, 0.42)
          : (hsl.lightness * 0.75 + 0.20).clamp(0.42, 0.78);
      final ambient = hsl
          .withSaturation(hsl.saturation.clamp(0.0, maxSaturation))
          .withLightness(lightness)
          .toColor();
      softened[i] = Color.lerp(ambient, surface, surfaceMix)!;
    }
    return softened;
  }

  /// Sync the mesh gradient controller based on current play/visibility state.
  /// When stopped, the mesh gradient's internal Ticker is fully halted.
  void _syncMeshController() {
    final shouldRun =
        widget.inputs.isVisible && (_isPlaying || _isTransitioning);
    if (shouldRun) {
      _meshController.start();
    } else {
      _meshController.stop();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _meshController.dispose();
    _decayTimer?.cancel();
    _fallbackPaletteTimer?.cancel();
    _transitionTicker?.dispose();
    _spectrumSubscription?.cancel();
    _paletteColors = const [];
    _prevPaletteColors = const [];
    _targetPaletteColors = const [];
    _breathScaleNotifier.dispose();
    _transitionValueNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surface = scheme.surface;
    final transitionFromColors = _isTransitioning
        ? _softenMeshColors(_prevPaletteColors, surface)
        : null;
    final transitionToColors = _isTransitioning
        ? _softenMeshColors(_targetPaletteColors, surface)
        : null;
    final meshColors = transitionToColors ??
        _softenMeshColors(
          _currentDisplayedPalette(),
          surface,
        );

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: surface),
        // Note: no AnimatedSwitcher wrapping the mesh — removing it avoids
        // double-rendering two mesh gradients during play/pause transitions.
        // The mesh controller stops the internal Ticker when paused.
        RepaintBoundary(
          child: _buildMesh(
            meshColors,
            transitionFromColors: transitionFromColors,
            transitionToColors: transitionToColors,
          ),
        ),
        Container(
          color: surface.withValues(alpha: 0.14),
        ),
      ],
    );
  }

  Widget _buildMesh(
    List<Color> colors, {
    List<Color>? transitionFromColors,
    List<Color>? transitionToColors,
  }) {
    if (colors.length != 4) {
      return Container(color: widget.fallbackColor);
    }
    return RepaintBoundary(
      child: _LowOverheadMeshGradient(
        colors: colors,
        transitionFromColors: transitionFromColors,
        transitionToColors: transitionToColors,
        colorTransition: _isTransitioning ? _transitionValueNotifier : null,
        audioPulse: _breathScaleNotifier,
        options: _isPlaying ? _playOptions : _pauseOptions,
        controller: _meshController,
      ),
    );
  }
}

/// 替代 AnimatedMeshGradient，去掉 willChange: true 避免每帧分配独立 GPU 图层。
/// 其他逻辑与原包一致。
class _LowOverheadMeshGradient extends StatefulWidget {
  final List<Color> colors;
  final List<Color>? transitionFromColors;
  final List<Color>? transitionToColors;
  final ValueListenable<double>? colorTransition;
  final ValueListenable<double>? audioPulse;
  final AnimatedMeshGradientOptions options;
  final AnimatedMeshGradientController? controller;

  const _LowOverheadMeshGradient({
    required this.colors,
    this.transitionFromColors,
    this.transitionToColors,
    this.colorTransition,
    this.audioPulse,
    required this.options,
    this.controller,
  });

  @override
  State<_LowOverheadMeshGradient> createState() =>
      _LowOverheadMeshGradientState();
}

class _LowOverheadMeshGradientState extends State<_LowOverheadMeshGradient>
    with TickerProviderStateMixin {
  static const _shaderAssetPath =
      'packages/mesh_gradient/shaders/animated_mesh_gradient.frag';
  static const Duration _meshFrameInterval = Duration.zero;
  static const double _timeScale = 1.0;

  Ticker? _ticker;
  late final ValueNotifier<double> _time;
  Duration? _lastPaintElapsed;
  VoidCallback? _controllerListener;

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    if (widget.controller != null && !widget.controller!.isAnimating.value) {
      return;
    }
    final lastPaintElapsed = _lastPaintElapsed;
    if (lastPaintElapsed != null &&
        elapsed - lastPaintElapsed < _meshFrameInterval) {
      return;
    }
    final delta = lastPaintElapsed == null
        ? _meshFrameInterval
        : elapsed - lastPaintElapsed;
    _lastPaintElapsed = elapsed;
    _time.value +=
        delta.inMicroseconds / Duration.microsecondsPerSecond * _timeScale;
  }

  void _syncTicker() {
    final shouldRun =
        widget.controller == null || widget.controller!.isAnimating.value;
    if (shouldRun && !(_ticker?.isActive ?? false)) {
      _lastPaintElapsed = null;
      _ticker?.start();
    } else if (!shouldRun && (_ticker?.isActive ?? false)) {
      _ticker?.stop();
      _lastPaintElapsed = null;
    }
  }

  void _bindController() {
    final controller = widget.controller;
    if (controller == null || _controllerListener != null) return;
    _controllerListener = () {
      if (!mounted) return;
      _syncTicker();
    };
    controller.isAnimating.addListener(_controllerListener!);
  }

  void _unbindController(AnimatedMeshGradientController? controller) {
    final listener = _controllerListener;
    if (controller != null && listener != null) {
      controller.isAnimating.removeListener(listener);
    }
    _controllerListener = null;
  }

  @override
  void initState() {
    super.initState();
    _time = ValueNotifier(0);
    _ticker = createTicker(_onTick);
    _bindController();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _LowOverheadMeshGradient oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _unbindController(oldWidget.controller);
      _bindController();
    }
    _syncTicker();
  }

  @override
  void dispose() {
    _unbindController(widget.controller);
    _ticker?.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShaderBuilder(
      assetKey: _shaderAssetPath,
      (context, shader, child) {
        return CustomPaint(
          painter: _AnimatedMeshGradientRepaintPainter(
            shader: shader,
            time: _time,
            colors: widget.colors,
            transitionFromColors: widget.transitionFromColors,
            transitionToColors: widget.transitionToColors,
            colorTransition: widget.colorTransition,
            audioPulse: widget.audioPulse,
            options: widget.options,
          ),
          // 不设 willChange，让合成器自行决定是否创建独立图层
          child: child,
        );
      },
      child: Container(),
    );
  }
}

class _AnimatedMeshGradientRepaintPainter extends CustomPainter {
  _AnimatedMeshGradientRepaintPainter({
    required this.shader,
    required this.time,
    required this.colors,
    this.transitionFromColors,
    this.transitionToColors,
    this.colorTransition,
    this.audioPulse,
    required this.options,
  }) : super(repaint: time);

  final FragmentShader shader;
  final ValueListenable<double> time;
  final List<Color> colors;
  final List<Color>? transitionFromColors;
  final List<Color>? transitionToColors;
  final ValueListenable<double>? colorTransition;
  final ValueListenable<double>? audioPulse;
  final AnimatedMeshGradientOptions options;
  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, time.value);
    shader.setFloat(3, options.frequency);
    final pulse =
        (((audioPulse?.value ?? 1.0) - 1.0) * 8.0).clamp(0.0, 0.42).toDouble();
    shader.setFloat(4, options.amplitude * (1.0 + pulse));
    shader.setFloat(5, options.speed * (1.0 + pulse * 0.18));
    shader.setFloat(6, options.grain);

    var i = 7;
    final from = transitionFromColors;
    final to = transitionToColors;
    final transition = colorTransition;
    final t = transition == null ? 1.0 : _smoothstep(transition.value);
    final colorCount = from != null && to != null && from.length == to.length
        ? from.length
        : colors.length;
    for (var colorIndex = 0; colorIndex < colorCount; colorIndex++) {
      final color = colors[colorIndex];
      final r = from != null && to != null
          ? from[colorIndex].r + (to[colorIndex].r - from[colorIndex].r) * t
          : color.r;
      final g = from != null && to != null
          ? from[colorIndex].g + (to[colorIndex].g - from[colorIndex].g) * t
          : color.g;
      final b = from != null && to != null
          ? from[colorIndex].b + (to[colorIndex].b - from[colorIndex].b) * t
          : color.b;
      shader.setFloat(i, r);
      i++;
      shader.setFloat(i, g);
      i++;
      shader.setFloat(i, b);
      i++;
    }

    _paint.shader = shader;
    canvas.drawPaint(_paint);
  }

  @override
  bool shouldRepaint(
    covariant _AnimatedMeshGradientRepaintPainter oldDelegate,
  ) {
    return oldDelegate.shader != shader ||
        oldDelegate.time != time ||
        oldDelegate.colorTransition != colorTransition ||
        oldDelegate.audioPulse != audioPulse ||
        oldDelegate.transitionFromColors != transitionFromColors ||
        oldDelegate.transitionToColors != transitionToColors ||
        oldDelegate.options != options ||
        oldDelegate.colors != colors;
  }

  static double _smoothstep(double t) {
    return t * t * (3.0 - 2.0 * t);
  }
}
