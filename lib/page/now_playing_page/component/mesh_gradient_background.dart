import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mesh_gradient/mesh_gradient.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/hsl_color_sampler.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';
import 'package:pure_music/page/now_playing_page/component/blur_cover_background.dart';
import 'package:pure_music/page/now_playing_page/component/hybrid_background.dart';

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
      NowPlayingBackgroundMode.blurCover => BlurCoverBackground(
          inputs: inputs,
          fallbackColor: fallbackColor,
        ),
      NowPlayingBackgroundMode.hybrid => HybridBackground(
          inputs: inputs,
          fallbackColor: fallbackColor,
        ),
    };
  }
}

class MeshGradientBackgroundInternal extends StatefulWidget {
  final NowPlayingBackgroundInputs inputs;
  final Color fallbackColor;

  const MeshGradientBackgroundInternal({
    super.key,
    required this.inputs,
    required this.fallbackColor,
  });

  @override
  State<MeshGradientBackgroundInternal> createState() =>
      _MeshGradientBackgroundInternalState();
}

class _MeshGradientBackgroundInternalState
    extends State<MeshGradientBackgroundInternal>
    with SingleTickerProviderStateMixin {
  List<Color> _paletteColors = [];
  bool _isPlaying = false;
  double _breathScale = 1.0;
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
    _extractPalette();
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
  void didUpdateWidget(covariant MeshGradientBackgroundInternal oldWidget) {
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
      }
    } else if (nowPlaying && _spectrumSubscription == null) {
      _listenSpectrum();
    }
  }

  void _coverBytesChanged(Uint8List? newBytes, Uint8List? oldBytes) {
    if (newBytes == null || newBytes.isEmpty) return;
    if (oldBytes != null && _isSameCoverBytes(newBytes, oldBytes)) return;
    _extractPaletteWithTransition();
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

      final targetScale = 1.0 + energy * 0.06 * widget.inputs.intensity;

      if ((targetScale - _breathScale).abs() > 0.001) {
        setState(() => _breathScale = targetScale);
      }
    });
  }

  Future<void> _extractPalette() async {
    final bytes = widget.inputs.albumCoverBytes;
    if (bytes == null || bytes.isEmpty) return;

    if (_disposed) return;

    try {
      final sampler = HslColorSampler();
      final analysis = await sampler.analyzeCover(bytes);
      final colors = sampler.generateHarmoniousPalette(analysis);

      if (_disposed || !mounted) return;

      setState(() {
        _paletteColors = colors.length >= 4
            ? colors.sublist(0, 4)
            : _padToFour(colors);
      });
    } catch (_) {}
  }

  Future<void> _extractPaletteWithTransition() async {
    final bytes = widget.inputs.albumCoverBytes;
    if (bytes == null || bytes.isEmpty) return;

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
      final fallback = widget.fallbackColor;
      return List.filled(4, fallback);
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

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: scheme.surface),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 800),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          child: KeyedSubtree(
            key: ValueKey(_isPlaying),
            child: AnimatedScale(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              scale: _breathScale,
              child: AnimatedBuilder(
                animation: _transitionController,
                builder: (context, child) {
                  return _buildMesh(
                    _isPlaying ? 0.6 : 0.0,
                    _interpolateColors(_transitionController.value),
                  );
                },
              ),
            ),
          ),
        ),
        Container(
          color: scheme.surface.withValues(alpha: 0.15),
        ),
      ],
    );
  }

  Widget _buildMesh(double speed, List<Color> colors) {
    return RepaintBoundary(
      child: AnimatedMeshGradient(
        colors: colors,
        options: AnimatedMeshGradientOptions(
          frequency: 3,
          amplitude: 45,
          speed: speed,
          grain: 0,
        ),
        child: Container(),
      ),
    );
  }
}
