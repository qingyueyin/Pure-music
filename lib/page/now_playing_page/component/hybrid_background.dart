import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:mesh_gradient/mesh_gradient.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/native/rust/api/color_extraction.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

const int _coverRenderSize = 400;

class HybridBackground extends StatefulWidget {
  final NowPlayingBackgroundInputs inputs;
  final Color fallbackColor;

  const HybridBackground({
    super.key,
    required this.inputs,
    required this.fallbackColor,
  });

  @override
  State<HybridBackground> createState() => _HybridBackgroundState();
}

class _HybridBackgroundState extends State<HybridBackground>
    with SingleTickerProviderStateMixin {
  ui.Image? _decodedImage;
  Uint8List? _currentCoverBytes;
  List<Color> _paletteColors = [];
  bool _isPlaying = false;
  double _breathScale = 1.0;
  double _meshOpacity = 0.55;
  StreamSubscription<Float32List>? _spectrumSubscription;
  int _lastSpectrumUpdateMs = 0;
  static const _spectrumThrottleMs = 250;

  late AnimationController _transitionController;
  List<Color> _prevPaletteColors = [];
  List<Color> _targetPaletteColors = [];
  bool _isTransitioning = false;
  bool _disposed = false;

  final AnimatedMeshGradientController _meshController =
      AnimatedMeshGradientController();

  @override
  void initState() {
    super.initState();
    _transitionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..addStatusListener(_onTransitionStatusChanged);
    _loadCover();
    _isPlaying = widget.inputs.playerState == PlayerState.playing;
    _listenSpectrum();
    _syncMeshController();
  }

  void _onTransitionStatusChanged(AnimationStatus status) {
    if (_disposed || !mounted) return;
    if (status == AnimationStatus.completed) {
      setState(() {
        _paletteColors = List.from(_targetPaletteColors);
        _prevPaletteColors = [];
        _targetPaletteColors = [];
        _isTransitioning = false;
      });
    }
  }

  @override
  void didUpdateWidget(covariant HybridBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newBytes = widget.inputs.albumCoverBytes;
    final oldBytes = oldWidget.inputs.albumCoverBytes;
    if (newBytes != null && !identical(newBytes, oldBytes)) {
      _coverBytesChanged(newBytes, oldBytes);
    }

    final nowPlaying = widget.inputs.playerState == PlayerState.playing;
    if (nowPlaying != _isPlaying) {
      setState(() {
        _isPlaying = nowPlaying;
        if (!nowPlaying) {
          _breathScale = 1.0;
          _meshOpacity = 0.55;
        }
      });
      _syncMeshController();
      _syncSpectrumSubscription();
    }

    final wasVisible = oldWidget.inputs.isVisible;
    final isVisible = widget.inputs.isVisible;
    if (wasVisible != isVisible) {
      if (!wasVisible && isVisible && nowPlaying) {
        _syncSpectrumSubscription();
      } else if (wasVisible && !isVisible) {
        _spectrumSubscription?.cancel();
        _spectrumSubscription = null;
      }
      _syncMeshController();
    }
  }

  /// Sync spectrum subscription based on playing and visibility state.
  /// Ensures only one active subscription at any time.
  void _syncSpectrumSubscription() {
    final shouldListen = _isPlaying && widget.inputs.isVisible && widget.inputs.shouldAnimate;

    if (shouldListen && _spectrumSubscription == null) {
      _listenSpectrum();
    } else if (!shouldListen) {
      _spectrumSubscription?.cancel();
      _spectrumSubscription = null;
    }
  }

  void _coverBytesChanged(Uint8List? newBytes, Uint8List? oldBytes) {
    if (newBytes == null || newBytes.isEmpty) {
      if (_currentCoverBytes != null) {
        _decodedImage?.dispose();
        _decodedImage = null;
        setState(() => _currentCoverBytes = null);
      }
      return;
    }
    if (oldBytes != null && _isSameCoverBytes(newBytes, oldBytes)) return;
    _loadCover();
  }

  bool _isSameCoverBytes(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    if (a.length > 65536) return true;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _listenSpectrum() {
    _spectrumSubscription?.cancel();
    final stream = widget.inputs.spectrumStream;
    if (stream == null || !widget.inputs.shouldAnimate) return;

    _spectrumSubscription = stream.listen((spectrum) {
      if (!mounted || !_isPlaying) return;

      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastSpectrumUpdateMs < _spectrumThrottleMs) return;
      _lastSpectrumUpdateMs = now;

      final lowFreq = spectrum.isNotEmpty ? spectrum[0] : 0.0;
      final subBass = spectrum.length > 1 ? spectrum[1] : 0.0;
      final energy = (lowFreq * 0.7 + subBass * 0.3).clamp(0.0, 1.0);

      final targetScale = 1.0 + energy * 0.05 * widget.inputs.intensity;
      final targetOpacity = 0.55 + energy * 0.15 * widget.inputs.intensity;

      if ((targetScale - _breathScale).abs() > 0.001 ||
          (targetOpacity - _meshOpacity).abs() > 0.005) {
        setState(() {
          _breathScale = targetScale;
          _meshOpacity = targetOpacity;
        });
      }
    });
  }

  void _loadCover() {
    final bytes = widget.inputs.albumCoverBytes;
    if (bytes == null || bytes.isEmpty) {
      if (_currentCoverBytes != null) {
        _decodedImage?.dispose();
        _decodedImage = null;
        setState(() => _currentCoverBytes = null);
      }
      return;
    }

    if (_disposed) return;

    if (identical(bytes, _currentCoverBytes) && _decodedImage != null) return;

    final oldImage = _decodedImage;
    _decodedImage = null;

    setState(() {
      _currentCoverBytes = bytes;
    });

    _extractPaletteWithTransition(bytes);

    _decodeCover(bytes).then((newImage) {
      if (_disposed || !mounted) {
        newImage?.dispose();
        return;
      }
      oldImage?.dispose();
      _decodedImage = newImage;
      if (mounted) setState(() {});
    });
  }

  Future<ui.Image?> _decodeCover(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _coverRenderSize,
        targetHeight: _coverRenderSize,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  Future<void> _extractPaletteWithTransition(Uint8List bytes) async {
    if (_disposed) return;

    try {
      final rustColors = await extractColorsFromImage(
        imageBytes: bytes,
        numColors: 4,
      );

      if (rustColors.isEmpty || _disposed || !mounted) return;

      final targetColors = _padToFour(rustColors.map((argb) => Color(argb)).toList());

      if (_isTransitioning) {
        _transitionController.stop();
        _transitionController.value = 0.0;
      }

      setState(() {
        _prevPaletteColors = _paletteColors.isEmpty
            ? List.filled(4, widget.fallbackColor)
            : _padToFour(List.from(_paletteColors));
        _targetPaletteColors = targetColors;
        _isTransitioning = true;
      });

      _transitionController.forward();
    } catch (_) {}
  }

  List<Color> _padToFour(List<Color> colors) {
    if (colors.isEmpty) {
      return List.filled(4, widget.fallbackColor);
    }
    final padded = [...colors];
    while (padded.length < 4) {
      padded.add(colors[padded.length % colors.length]);
    }
    return padded;
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
    final count = _prevPaletteColors.length.clamp(0, _targetPaletteColors.length);
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

  void _syncMeshController() {
    final shouldRun =
        widget.inputs.playerState == PlayerState.playing &&
        widget.inputs.isVisible;
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
    _transitionController.removeStatusListener(_onTransitionStatusChanged);
    _transitionController.dispose();
    _spectrumSubscription?.cancel();
    _decodedImage?.dispose();
    _decodedImage = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = scheme.brightness;
    final decodedImage = _decodedImage;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: scheme.surface),

        if (decodedImage != null)
          RepaintBoundary(
            child: _BlurredCover(
              image: decodedImage,
              brightness: brightness,
            ),
          ),

        AnimatedOpacity(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut,
          opacity: _isPlaying ? _meshOpacity : 0.45,
          child: AnimatedBuilder(
            animation: _transitionController,
            builder: (context, child) {
              final colors = _interpolateColors(_transitionController.value);
              return AnimatedScale(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                scale: _breathScale,
                child: RepaintBoundary(
                  child: AnimatedMeshGradient(
                    colors: colors,
                    options: AnimatedMeshGradientOptions(
                      frequency: 7,
                      amplitude: 80,
                      speed: _isPlaying ? 2.5 : 0.01,
                      grain: 0,
                    ),
                    controller: _meshController,
                    child: Container(),
                  ),
                ),
              );
            },
          ),
        ),

        Container(
          color: scheme.surface.withValues(alpha: 0.10),
        ),
      ],
    );
  }
}

class _BlurredCover extends StatelessWidget {
  final ui.Image image;
  final Brightness brightness;

  const _BlurredCover({
    required this.image,
    required this.brightness,
  });

  static final _blurFilter = ui.ImageFilter.blur(
    sigmaX: 80,
    sigmaY: 80,
    tileMode: ui.TileMode.clamp,
  );

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: brightness == Brightness.dark ? 0.60 : 0.40,
      child: ClipRRect(
        child: ImageFiltered(
          imageFilter: _blurFilter,
          child: ShaderMask(
            blendMode: BlendMode.modulate,
            shaderCallback: (Rect bounds) {
              return const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                ],
                stops: [0.0, 0.25, 1.0],
              ).createShader(bounds);
            },
            child: SizedBox.expand(
              child: RawImage(
                image: image,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
