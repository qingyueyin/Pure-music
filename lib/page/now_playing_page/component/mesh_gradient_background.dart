import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_shaders/flutter_shaders.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

const _kDarkMeshScrim = Color(0x2E171717);
const _kLightMeshScrim = Color(0x24F0F0F0);
const _kMeshRenderExtent = 360.0;
const _kMeshColorCount = 4;
const _kShaderColorCount = 4;

Size _meshRenderSize(Size viewport) {
  if (viewport.isEmpty) return Size.zero;
  if (viewport.width >= viewport.height) {
    return Size(_kMeshRenderExtent, _kMeshRenderExtent / viewport.aspectRatio);
  }
  return Size(_kMeshRenderExtent * viewport.aspectRatio, _kMeshRenderExtent);
}

class _MeshAnimationController {
  final ValueNotifier<bool> isAnimating = ValueNotifier(false);

  void start() {
    if (!isAnimating.value) isAnimating.value = true;
  }

  void stop() {
    if (isAnimating.value) isAnimating.value = false;
  }

  void dispose() => isAnimating.dispose();
}

List<Color> _adjustMeshColors(List<Color> colors, Brightness brightness) {
  if (colors.isEmpty) return colors;

  final isDark = brightness == Brightness.dark;
  if (isDark && colors.every((color) => color.computeLuminance() <= 0.008)) {
    const levels = <double>[0.10, 0.19, 0.14, 0.07];
    return levels
        .map(
          (level) => Color.from(
            alpha: 1.0,
            red: level,
            green: level,
            blue: level,
          ),
        )
        .toList(growable: false);
  }
  const darkLuminanceLimit = <double>[0.13, 0.22, 0.17, 0.20];
  return colors.indexed.map((entry) {
    final (index, color) = entry;
    final hsl = HSLColor.fromColor(color);
    const maxSaturation = 0.78;
    final adjusted =
        hsl.withSaturation(hsl.saturation.clamp(0.0, maxSaturation)).toColor();
    if (isDark) {
      return _capMeshLuminance(adjusted, darkLuminanceLimit[index]);
    }
    return HSLColor.fromColor(adjusted)
        .withLightness((hsl.lightness * 0.82 + 0.12).clamp(0.34, 0.82))
        .toColor();
  }).toList(growable: false);
}

Color _capMeshLuminance(Color color, double limit) {
  if (color.computeLuminance() <= limit) return color;
  var lower = 0.0;
  var upper = 1.0;
  for (var attempt = 0; attempt < 9; attempt++) {
    final scale = (lower + upper) * 0.5;
    final candidate = color.withValues(
      red: color.r * scale,
      green: color.g * scale,
      blue: color.b * scale,
    );
    if (candidate.computeLuminance() > limit) {
      upper = scale;
    } else {
      lower = scale;
    }
  }
  return color.withValues(
    red: color.r * lower,
    green: color.g * lower,
    blue: color.b * lower,
  );
}

List<Color> _meshShaderColors(List<Color> colors) {
  return colors.length == _kShaderColorCount ? colors : const [];
}

class MeshGradientBackground extends StatelessWidget {
  final NowPlayingBackgroundInputs inputs;
  final Color fallbackColor;

  const MeshGradientBackground({
    super.key,
    required this.inputs,
    required this.fallbackColor,
  });

  @override
  Widget build(BuildContext context) {
    return MeshGradientBackgroundInternal(
      inputs: inputs,
      fallbackColor: fallbackColor,
    );
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

  double _transitionValue = 0.0;
  final ValueNotifier<double> _transitionValueNotifier = ValueNotifier(0.0);
  Ticker? _transitionTicker;
  List<Color> _prevPaletteColors = [];
  List<Color> _targetPaletteColors = [];
  bool _isTransitioning = false;
  bool _disposed = false;

  static const Duration _paletteTransitionDuration = Duration(
    milliseconds: 360,
  );

  final _MeshAnimationController _meshController = _MeshAnimationController();

  int? _lastCoverHash;
  int? _lastPaletteSignature;

  @override
  void initState() {
    super.initState();
    _syncPaletteFromInputs(animate: false);
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
        _showFallbackPalette();
      }
    }

    final wasVisible = oldWidget.inputs.isVisible;
    final isVisible = widget.inputs.isVisible;

    if (wasVisible && !isVisible && _isTransitioning) {
      _transitionTicker?.dispose();
      _transitionTicker = null;
      _transitionValue = 1;
      _transitionValueNotifier.value = 1;
      _paletteColors = List<Color>.from(_targetPaletteColors);
      _prevPaletteColors = [];
      _targetPaletteColors = [];
      _isTransitioning = false;
    } else if (!wasVisible && isVisible) {
      _syncPaletteFromInputs(animate: true);
    }

    _syncMeshController();
  }

  void _coverBytesChanged(Uint8List? newBytes) {
    if (newBytes == null || newBytes.isEmpty) {
      _lastCoverHash = null;
      if (!_syncPaletteFromInputs(animate: true)) {
        _showFallbackPalette();
      }
      return;
    }
    final newHash = _computeHash(newBytes);
    if (_lastCoverHash == newHash) return;
    _lastCoverHash = newHash;

    if (!_syncPaletteFromInputs(animate: true)) {
      _showFallbackPalette();
    }
  }

  void _showFallbackPalette() {
    _lastPaletteSignature = null;
    _setPaletteColors(List.filled(_kMeshColorCount, widget.fallbackColor));
  }

  bool _syncPaletteFromInputs({required bool animate}) {
    if (!widget.inputs.isVisible || _disposed) return false;
    final colors = widget.inputs.preExtractedColors;
    if (colors == null || colors.isEmpty) return false;

    final target = _padPalette(colors);
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
    final target = _padPalette(colors);
    _transitionTicker?.dispose();
    _transitionTicker = null;
    _transitionValue = 0.0;
    _transitionValueNotifier.value = 0.0;
    _paletteColors = target;
    _prevPaletteColors = [];
    _targetPaletteColors = [];
    _isTransitioning = false;
  }

  void _applyPaletteColors(List<Color> colors) {
    final target = _padPalette(colors);
    final displayedColors = _currentDisplayedPalette();
    _lastPaletteSignature = _paletteSignature(target);
    _transitionTicker?.dispose();
    _transitionTicker = null;
    _transitionValue = 0.0;
    _transitionValueNotifier.value = 0.0;

    setState(() {
      _prevPaletteColors = displayedColors.isEmpty
          ? List.filled(_kMeshColorCount, widget.fallbackColor)
          : _padPalette(displayedColors);
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

  List<Color> _padPalette(List<Color> colors) {
    if (colors.isEmpty) {
      final fallback = widget.fallbackColor;
      return List.filled(_kMeshColorCount, fallback);
    }
    final padded = colors.take(_kMeshColorCount).toList();
    while (padded.length < _kMeshColorCount) {
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

  static double _smoothstep(double t) {
    return t * t * (3.0 - 2.0 * t);
  }

  List<Color> _interpolateColors(double t) {
    if (_prevPaletteColors.isEmpty || _targetPaletteColors.isEmpty) {
      return _paletteColors.isEmpty
          ? List.filled(_kMeshColorCount, widget.fallbackColor)
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

  void _syncMeshController() {
    final shouldRun = widget.inputs.isVisible &&
        (widget.inputs.shouldAnimate || _isTransitioning);
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
    _transitionTicker?.dispose();
    _paletteColors = const [];
    _prevPaletteColors = const [];
    _targetPaletteColors = const [];
    _transitionValueNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!TickerMode.valuesOf(context).enabled) {
      return ColoredBox(color: widget.fallbackColor);
    }
    final brightness = Theme.of(context).brightness;
    final scrimColor =
        brightness == Brightness.dark ? _kDarkMeshScrim : _kLightMeshScrim;
    final transitionFromColors = _isTransitioning
        ? _meshShaderColors(
            _adjustMeshColors(_prevPaletteColors, brightness),
          )
        : null;
    final transitionToColors = _isTransitioning
        ? _meshShaderColors(
            _adjustMeshColors(_targetPaletteColors, brightness),
          )
        : null;
    final meshColors = transitionToColors ??
        _meshShaderColors(
          _adjustMeshColors(_currentDisplayedPalette(), brightness),
        );

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: widget.fallbackColor),
        RepaintBoundary(
          child: _buildMesh(
            meshColors,
            transitionFromColors: transitionFromColors,
            transitionToColors: transitionToColors,
            scrimColor: scrimColor,
          ),
        ),
      ],
    );
  }

  Widget _buildMesh(
    List<Color> colors, {
    List<Color>? transitionFromColors,
    List<Color>? transitionToColors,
    required Color scrimColor,
  }) {
    if (colors.length != _kShaderColorCount) {
      return Container(color: widget.fallbackColor);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final renderSize = _meshRenderSize(constraints.biggest);
        return FittedBox(
          fit: BoxFit.fill,
          child: SizedBox.fromSize(
            size: renderSize,
            child: _SoftMeshGradient(
              colors: colors,
              transitionFromColors: transitionFromColors,
              transitionToColors: transitionToColors,
              colorTransition:
                  _isTransitioning ? _transitionValueNotifier : null,
              controller: _meshController,
              scrimColor: scrimColor,
            ),
          ),
        );
      },
    );
  }
}

class _SoftMeshGradient extends StatefulWidget {
  final List<Color> colors;
  final List<Color>? transitionFromColors;
  final List<Color>? transitionToColors;
  final ValueListenable<double>? colorTransition;
  final _MeshAnimationController? controller;
  final Color scrimColor;

  const _SoftMeshGradient({
    required this.colors,
    this.transitionFromColors,
    this.transitionToColors,
    this.colorTransition,
    this.controller,
    required this.scrimColor,
  });

  @override
  State<_SoftMeshGradient> createState() => _SoftMeshGradientState();
}

class _SoftMeshGradientState extends State<_SoftMeshGradient> {
  static const _shaderAssetPath = 'assets/shaders/soft_mesh_gradient.frag';
  static const Duration _meshFrameInterval = Duration(milliseconds: 42);
  static const double _timeScale = 1.0;

  Timer? _frameTimer;
  late final ValueNotifier<double> _time;
  VoidCallback? _controllerListener;

  void _onFrame(Timer _) {
    if (!mounted ||
        (widget.controller != null && !widget.controller!.isAnimating.value)) {
      _syncFrameTimer();
      return;
    }
    _time.value += _meshFrameInterval.inMicroseconds /
        Duration.microsecondsPerSecond *
        _timeScale;
  }

  void _syncFrameTimer() {
    final shouldRun =
        widget.controller == null || widget.controller!.isAnimating.value;
    if (shouldRun && _frameTimer == null) {
      _frameTimer = Timer.periodic(_meshFrameInterval, _onFrame);
    } else if (!shouldRun && _frameTimer != null) {
      _frameTimer?.cancel();
      _frameTimer = null;
    }
  }

  void _stopFrameTimer() {
    _frameTimer?.cancel();
    _frameTimer = null;
  }

  void _onControllerChanged() {
    _syncFrameTimer();
  }

  void _bindController() {
    final controller = widget.controller;
    if (controller == null || _controllerListener != null) return;
    _controllerListener = _onControllerChanged;
    controller.isAnimating.addListener(_controllerListener!);
  }

  void _unbindController(_MeshAnimationController? controller) {
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
    _bindController();
    _syncFrameTimer();
  }

  @override
  void didUpdateWidget(covariant _SoftMeshGradient oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _unbindController(oldWidget.controller);
      _bindController();
    }
    _syncFrameTimer();
  }

  @override
  void dispose() {
    _unbindController(widget.controller);
    _stopFrameTimer();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShaderBuilder(
      assetKey: _shaderAssetPath,
      (context, shader, child) {
        return CustomPaint(
          painter: _SoftMeshGradientPainter(
            shader: shader,
            time: _time,
            colors: widget.colors,
            transitionFromColors: widget.transitionFromColors,
            transitionToColors: widget.transitionToColors,
            colorTransition: widget.colorTransition,
            scrimColor: widget.scrimColor,
          ),
          child: child,
        );
      },
      child: Container(),
    );
  }
}

class _SoftMeshGradientPainter extends CustomPainter {
  _SoftMeshGradientPainter({
    required this.shader,
    required this.time,
    required this.colors,
    this.transitionFromColors,
    this.transitionToColors,
    this.colorTransition,
    required this.scrimColor,
  })  : _paint = Paint()
          ..colorFilter = ColorFilter.mode(scrimColor, BlendMode.srcOver),
        super(repaint: time);

  final FragmentShader shader;
  final ValueListenable<double> time;
  final List<Color> colors;
  final List<Color>? transitionFromColors;
  final List<Color>? transitionToColors;
  final ValueListenable<double>? colorTransition;
  final Color scrimColor;
  final Paint _paint;

  @override
  void paint(Canvas canvas, Size size) {
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, time.value);

    var i = 3;
    final from = transitionFromColors;
    final to = transitionToColors;
    final transition = colorTransition;
    final t =
        transition == null ? 1.0 : _paletteTransitionCurve(transition.value);
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
    covariant _SoftMeshGradientPainter oldDelegate,
  ) {
    return oldDelegate.shader != shader ||
        oldDelegate.time != time ||
        oldDelegate.colorTransition != colorTransition ||
        oldDelegate.transitionFromColors != transitionFromColors ||
        oldDelegate.transitionToColors != transitionToColors ||
        oldDelegate.scrimColor != scrimColor ||
        oldDelegate.colors != colors;
  }

  static double _paletteTransitionCurve(double t) {
    final remaining = 1.0 - t;
    return 1.0 - remaining * remaining * remaining;
  }
}
