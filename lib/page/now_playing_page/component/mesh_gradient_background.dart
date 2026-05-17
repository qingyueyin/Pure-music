import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mesh_gradient/mesh_gradient.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/native/rust/api/color_extraction.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';
import 'package:pure_music/page/now_playing_page/component/blur_cover_background.dart';

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
  double _targetBreathScale = 1.0;
  StreamSubscription<Float32List>? _spectrumSubscription;

  late AnimationController _transitionController;
  List<Color> _prevPaletteColors = [];
  List<Color> _targetPaletteColors = [];
  bool _isTransitioning = false;
  bool _disposed = false;

  Timer? _decayTimer;

  int? _lastCoverHash;
  int _lastSpectrumUpdateMs = 0;






        static final _playOptions = AnimatedMeshGradientOptions(
    frequency: 8,
    amplitude: 80,
    speed: 2.5,
    grain: 0,
  );
  static final _pauseOptions = AnimatedMeshGradientOptions(
    frequency: 8,
    amplitude: 80,
    speed: 0.3,
    grain: 0,
  );







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

    final wasVisible = oldWidget.inputs.isVisible;
    final isVisible = widget.inputs.isVisible;
    if (!wasVisible && isVisible && widget.inputs.playerState == PlayerState.playing) {
      _listenSpectrum();
      if (newBytes != null && !identical(newBytes, oldBytes)) {
        _extractPaletteWithTransition();
      }
    } else if (wasVisible && !isVisible) {
      _spectrumSubscription?.cancel();
      _spectrumSubscription = null;
    }

    final nowPlaying = widget.inputs.playerState == PlayerState.playing;
    if (nowPlaying != _isPlaying) {
      setState(() => _isPlaying = nowPlaying);
      _targetBreathScale = nowPlaying ? 1.0 : 1.0;
      _startDecayTimer();
      // 先取消旧的 subscription，再决定是否重新订阅
      _spectrumSubscription?.cancel();
      _spectrumSubscription = null;
      if (nowPlaying && widget.inputs.isVisible) {
        _listenSpectrum();
      }
    } else if (nowPlaying && _spectrumSubscription == null && widget.inputs.isVisible) {
      _listenSpectrum();
    } else if (!nowPlaying) {
      // 非播放状态确保取消订阅
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
        setState(() => _breathScale = newScale);
      }
    });
  }

  void _coverBytesChanged(Uint8List? newBytes, Uint8List? oldBytes) {
    if (newBytes == null || newBytes.isEmpty) return;
    final newHash = _computeHash(newBytes);
    if (oldBytes != null && _lastCoverHash == newHash) return;
    _lastCoverHash = newHash;
    _extractPaletteWithTransition();
  }

  int _computeHash(Uint8List bytes) {
    int hash = 0;
    final step = (bytes.length / 256).ceil();
    for (int i = 0; i < bytes.length; i += step) {
      hash = hash * 31 + bytes[i];
    }
    return hash;
  }

  void _listenSpectrum() {
    _spectrumSubscription?.cancel();
    final stream = widget.inputs.spectrumStream;
    if (stream == null || !widget.inputs.shouldAnimate || !widget.inputs.isVisible) return;

    _spectrumSubscription = stream.listen((spectrum) {
      if (!mounted || !_isPlaying || !widget.inputs.isVisible) return;

      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastSpectrumUpdateMs < 400) return;
      _lastSpectrumUpdateMs = now;

      final lowFreq = spectrum.isNotEmpty ? spectrum[0] : 0.0;
      final subBass = spectrum.length > 1 ? spectrum[1] : 0.0;
      final energy = (lowFreq * 0.7 + subBass * 0.3).clamp(0.0, 1.0);

      _targetBreathScale = 1.0 + energy * 0.03 * widget.inputs.intensity;

      if ((_targetBreathScale - _breathScale).abs() > 0.005) {
        setState(() => _breathScale = _targetBreathScale);
      }
    });
  }

  Future<void> _extractPalette() async {
    if (!widget.inputs.isVisible) return;
    final bytes = widget.inputs.albumCoverBytes;
    if (bytes == null || bytes.isEmpty) return;
    if (_disposed) return;

    try {
      final rustColors = await extractColorsFromImage(
        imageBytes: bytes,
        numColors: 4,
      );
      if (rustColors.isEmpty || _disposed || !mounted || !widget.inputs.isVisible) {
        return;
      }
      final target = _padToFour(rustColors.map((argb) => Color(argb)).toList());
      _lastCoverHash ??= _computeHash(bytes);
      setState(() {
        _paletteColors = target;
      });
    } catch (_) {}
  }

  Future<void> _extractPaletteWithTransition() async {
    if (!widget.inputs.isVisible) return;
    final bytes = widget.inputs.albumCoverBytes;
    if (bytes == null || bytes.isEmpty) return;
    if (_disposed) return;

    try {
      final rustColors = await extractColorsFromImage(
        imageBytes: bytes,
        numColors: 4,
      );
      if (rustColors.isEmpty || _disposed || !mounted || !widget.inputs.isVisible) {
        return;
      }

      final target = _padToFour(rustColors.map((argb) => Color(argb)).toList());
      _lastCoverHash ??= _computeHash(bytes);

      if (_isTransitioning) {
        _transitionController.stop();
        _transitionController.value = 0.0;
      }

      setState(() {
        _prevPaletteColors = _paletteColors.isEmpty
            ? List.filled(4, widget.fallbackColor)
            : _padToFour(List.from(_paletteColors));
        _targetPaletteColors = target;
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
    _decayTimer?.cancel();
    _transitionController.removeStatusListener(_onTransitionStatusChanged);
    _transitionController.dispose();
    _spectrumSubscription?.cancel();
    _paletteColors = const [];
    _prevPaletteColors = const [];
    _targetPaletteColors = const [];
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
            child: RepaintBoundary(
              child: AnimatedScale(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                scale: _breathScale,
                child: AnimatedBuilder(
                  animation: _transitionController,
                  builder: (context, child) {
                    return _buildMesh(_interpolateColors(_transitionController.value));
                  },
                ),
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

  Widget _buildMesh(List<Color> colors) {
    return RepaintBoundary(
      child: AnimatedMeshGradient(
        colors: colors,
        options: _isPlaying ? _playOptions : _pauseOptions,
        child: Container(),
      ),
    );
  }
}
