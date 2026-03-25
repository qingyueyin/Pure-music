// Stateful widget for AMLL mesh gradient background animation.
//
// Integrates the mesh gradient system with Pure Music's PlayService
// and theme system. Provides animation ticker and audio reactivity.

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pure_music/mesh_gradient/audio_reactor.dart';
import 'package:pure_music/mesh_gradient/config.dart';
import 'package:pure_music/mesh_gradient/core/bhp_mesh.dart';
import 'package:pure_music/mesh_gradient/core/control_point.dart';
import 'package:pure_music/mesh_gradient/render/mesh_canvas_renderer.dart';
import 'package:pure_music/play_service/play_service.dart';

/// Default 4×4 control point grid for mesh initialization.
///
/// Creates an evenly distributed grid with colors from current theme.
List<ControlPoint> _createDefaultControlPoints(ColorScheme colorScheme) {
  const points = [
    (0.1, 0.1, 0.8, 0.2),
    (0.3, 0.1, 0.9, 0.3),
    (0.6, 0.1, 0.8, 0.4),
    (0.9, 0.1, 0.7, 0.3),
    (0.1, 0.4, 0.7, 0.5),
    (0.3, 0.4, 0.8, 0.6),
    (0.6, 0.4, 0.9, 0.5),
    (0.9, 0.4, 0.8, 0.4),
    (0.1, 0.7, 0.8, 0.7),
    (0.3, 0.7, 0.9, 0.6),
    (0.6, 0.7, 0.8, 0.7),
    (0.9, 0.7, 0.7, 0.6),
    (0.1, 0.9, 0.7, 0.8),
    (0.3, 0.9, 0.8, 0.9),
    (0.6, 0.9, 0.9, 0.8),
    (0.9, 0.9, 0.8, 0.7),
  ];

  final controlPoints = <ControlPoint>[];
  // TODO: Use theme colors when available
  // final primaryColor = colorScheme.primary;
  // final secondaryColor = colorScheme.secondary;

  for (final (normX, normY, r, g) in points) {
    // Blend theme colors with parametric colors
    final blendedR =
        (0.5 * 0.5 + r * 0.5).clamp(0.0, 1.0); // Placeholder without theme
    final blendedG = (0.5 * 0.5 + g * 0.5).clamp(0.0, 1.0);
    final blendedB = (0.5 * 0.5 + 0.3).clamp(0.0, 1.0);

    controlPoints.add(
      ControlPoint(
        x: normX * 400, // Assuming 400px base width
        y: normY * 300, // Assuming 300px base height
        r: blendedR,
        g: blendedG,
        b: blendedB,
        uRot: 0.0,
        vRot: 0.0,
        uScale: 0.5,
        vScale: 0.5,
      ),
    );
  }

  return controlPoints;
}

/// AMLL Mesh Gradient Background Widget
///
/// Renders an animated mesh gradient background that responds to audio
/// frequency data from the PlayService. Integrates with the theme system
/// for color cohesion.
///
/// Usage:
/// ```dart
/// Stack(
///   children: [
///     AmllMeshBackgroundWidget(
///       config: MeshGradientConfig.balanced,
///     ),
///     // Your other widgets on top
///   ],
/// )
/// ```
class AmllMeshBackgroundWidget extends StatefulWidget {
  /// Configuration for mesh gradient animation
  final MeshGradientConfig config;

  /// Optional initial control points (uses defaults if null)
  final List<ControlPoint>? initialControlPoints;

  /// Whether to enable the background (can be toggled at runtime)
  final bool enabled;

  const AmllMeshBackgroundWidget({
    super.key,
    this.config = const MeshGradientConfig(),
    this.initialControlPoints,
    this.enabled = true,
  });

  @override
  State<AmllMeshBackgroundWidget> createState() =>
      _AmllMeshBackgroundWidgetState();
}

class _AmllMeshBackgroundWidgetState extends State<AmllMeshBackgroundWidget>
    with TickerProviderStateMixin {
  /// Animation controller for continuous updates
  late AnimationController _animationController;

  /// The mesh gradient instance
  late BHPMesh _mesh;

  /// Audio-reactive processor
  late AudioReactor _audioReactor;

  /// Canvas renderer
  late MeshCanvasRenderer _renderer;

  /// Subscription to audio spectrum stream
  dynamic _spectrumSubscription;

  @override
  void initState() {
    super.initState();

    // Initialize animation controller
    _animationController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1000 ~/ widget.config.targetFps),
    )..repeat();

    _animationController.addListener(_onAnimationFrame);

    // Initialize mesh and audio processor
    _initializeMesh();
    _initializeAudioReactor();

    // Connect to audio spectrum stream
    _connectAudioStream();
  }

  /// Initializes the mesh gradient with control points.
  void _initializeMesh() {
    final colorScheme = Theme.of(context).colorScheme;
    final controlPoints = widget.initialControlPoints ??
        _createDefaultControlPoints(colorScheme);

    _mesh = BHPMesh(
      initialControlPoints: controlPoints,
      config: widget.config,
    );

    _renderer = MeshCanvasRenderer(mesh: _mesh, config: widget.config);
  }

  /// Initializes the audio-reactive processor.
  void _initializeAudioReactor() {
    _audioReactor = AudioReactor(config: widget.config);

    // Set viewport size (assume 400x300 or get from layout)
    _audioReactor.setViewportSize(400);
  }

  /// Connects to PlayService audio spectrum stream.
  void _connectAudioStream() {
    try {
      _spectrumSubscription = PlayService.instance.playbackService.spectrumStream
          .listen((Float32List spectrumData) {
        _onSpectrumData(spectrumData);
      });
    } catch (e) {
      debugPrint('Failed to connect audio spectrum stream: $e');
    }
  }

  /// Processes incoming spectrum data and updates mesh deformation.
  void _onSpectrumData(Float32List spectrumData) {
    if (!widget.enabled) return;

    final frequencyData = _audioReactor.processSpectrum(spectrumData);
    final deformations =
        _audioReactor.generateSmoothDeformations(frequencyData);

    _mesh.applyDeformation(deformations, widget.config.smoothingFactor);
  }

  /// Animation frame callback for rendering updates.
  void _onAnimationFrame() {
    if (mounted) {
      setState(() {
        // Trigger repaint by rebuilding
      });
    }
  }

  @override
  void didUpdateWidget(AmllMeshBackgroundWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Reinitialize if configuration changed
    if (oldWidget.config != widget.config) {
      _mesh = BHPMesh(
        initialControlPoints:
            widget.initialControlPoints ?? _createDefaultControlPoints(
          Theme.of(context).colorScheme,
        ),
        config: widget.config,
      );
      _audioReactor = AudioReactor(config: widget.config);
      _renderer = MeshCanvasRenderer(mesh: _mesh, config: widget.config);
    }

    // Update enabled state
    if (!widget.enabled) {
      _mesh.resetDeformation();
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    _spectrumSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return const SizedBox.expand();
    }

    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        return CustomPaint(
          painter: _renderer,
          isComplex: true,
          willChange: true,
          child: Container(
            color: Colors.transparent,
          ),
        );
      },
    );
  }
}

/// Builder widget for easier integration with theme provider.
///
/// Usage:
/// ```dart
/// AmllMeshBackgroundBuilder(
///   builder: (context, colorScheme) => CustomPaint(...)
/// )
/// ```
class AmllMeshBackgroundBuilder extends StatelessWidget {
  final MeshGradientConfig config;
  final bool enabled;

  const AmllMeshBackgroundBuilder({
    super.key,
    this.config = const MeshGradientConfig(),
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return AmllMeshBackgroundWidget(
      config: config,
      enabled: enabled,
    );
  }
}
