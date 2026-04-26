import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:mesh_gradient/mesh_gradient.dart';
import 'package:pure_music/core/hsl_color_sampler.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

const int _coverRenderSize = 600;

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
  Uint8List? _currentCoverBytes;
  List<Color> _paletteColors = [];
  bool _isPlaying = false;
  double _breathScale = 1.0;
  double _meshOpacity = 0.40;
  StreamSubscription<Float32List>? _spectrumSubscription;

  late AnimationController _transitionController;
  List<Color> _prevPaletteColors = [];
  List<Color> _targetPaletteColors = [];
  bool _isTransitioning = false;
  bool _disposed = false;

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
      setState(() => _isPlaying = nowPlaying);
      if (nowPlaying) {
        _listenSpectrum();
      } else {
        _spectrumSubscription?.cancel();
        _spectrumSubscription = null;
        _breathScale = 1.0;
        _meshOpacity = 0.40;
      }
    } else if (nowPlaying && _spectrumSubscription == null) {
      _listenSpectrum();
    }
  }

  void _coverBytesChanged(Uint8List? newBytes, Uint8List? oldBytes) {
    if (newBytes == null || newBytes.isEmpty) {
      if (_currentCoverBytes != null) {
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

      final lowFreq = spectrum.isNotEmpty ? spectrum[0] : 0.0;
      final subBass = spectrum.length > 1 ? spectrum[1] : 0.0;
      final energy = (lowFreq * 0.7 + subBass * 0.3).clamp(0.0, 1.0);

      final targetScale = 1.0 + energy * 0.04 * widget.inputs.intensity;
      final targetOpacity = 0.40 + energy * 0.12 * widget.inputs.intensity;

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
        setState(() => _currentCoverBytes = null);
      }
      return;
    }

    if (_disposed) return;

    setState(() {
      _currentCoverBytes = bytes;
    });

    _extractPaletteWithTransition(bytes);
  }

  Future<void> _extractPaletteWithTransition(Uint8List bytes) async {
    if (_disposed) return;

    try {
      final sampler = HslColorSampler();
      final analysis = await sampler.analyzeCover(bytes);
      final newColors = sampler.generateHarmoniousPalette(analysis);
      final targetColors = newColors.length >= 4
          ? newColors.sublist(0, 4)
          : _padToFour(newColors);

      if (_disposed || !mounted) return;

      if (_isTransitioning) {
        _transitionController.stop();
        _transitionController.value = 0.0;
      }

      setState(() {
        _prevPaletteColors = _paletteColors.isEmpty
            ? List.filled(4, widget.fallbackColor)
            : _padToFour(List.from(_paletteColors));
        _targetPaletteColors = _padToFour(List.from(targetColors));
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
    return List.generate(count, (i) {
      final prev = _prevPaletteColors[i];
      final target = _targetPaletteColors[i];
      return Color.lerp(prev, target, t)!;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _transitionController.removeStatusListener(_onTransitionStatusChanged);
    _transitionController.dispose();
    _spectrumSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = scheme.brightness;
    final coverBytes = _currentCoverBytes;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: scheme.surface),

        if (coverBytes != null)
          RepaintBoundary(
            child: _BlurredCover(
              coverBytes: coverBytes,
              brightness: brightness,
            ),
          ),

        AnimatedOpacity(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut,
          opacity: _isPlaying ? _meshOpacity : 0.30,
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
                      frequency: 3,
                      amplitude: 50,
                      speed: _isPlaying ? 0.5 : 0.0,
                      grain: 0,
                    ),
                    child: Container(),
                  ),
                ),
              );
            },
          ),
        ),

        Container(
          color: scheme.surface.withValues(alpha: 0.12),
        ),
      ],
    );
  }
}

class _BlurredCover extends StatelessWidget {
  final Uint8List coverBytes;
  final Brightness brightness;

  const _BlurredCover({
    required this.coverBytes,
    required this.brightness,
  });

  Widget get _cover => SizedBox.expand(
        child: Image.memory(
          coverBytes,
          cacheWidth: _coverRenderSize,
          cacheHeight: _coverRenderSize,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: brightness == Brightness.dark ? 0.75 : 0.55,
      child: ClipRRect(
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: 90,
            sigmaY: 90,
            tileMode: ui.TileMode.clamp,
          ),
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
            child: _cover,
          ),
        ),
      ),
    );
  }
}
