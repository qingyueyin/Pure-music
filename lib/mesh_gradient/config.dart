/// Configuration for AMLL mesh gradient animation system.
///
/// Provides resolution presets, animation parameters, and tunable sensitivity values
/// for frequency-reactive mesh deformation.
library mesh_gradient_config;

enum MeshResolution {
  /// High quality: 64x64 subdivisions per patch, ~10,000 triangles
  /// Performance: ~60 FPS on desktop
  high(64),

  /// Medium quality: 32x32 subdivisions per patch, ~2,500 triangles
  /// Performance: ~60 FPS on mobile
  medium(32),

  /// Low quality: 16x16 subdivisions per patch, ~625 triangles
  /// Performance: ~120 FPS on low-end devices
  low(16);

  final int subdivisionsPerPatch;

  const MeshResolution(this.subdivisionsPerPatch);

  /// Total vertices in a single patch mesh
  int get vertexCount {
    final count = subdivisionsPerPatch + 1;
    return count * count;
  }

  /// Total triangles in a single patch mesh
  int get triangleCount {
    return subdivisionsPerPatch * subdivisionsPerPatch * 2;
  }
}

/// Configuration parameters for mesh gradient animation.
class MeshGradientConfig {
  /// Mesh resolution quality preset
  final MeshResolution resolution;

  /// Animation frame rate target (typically 60 FPS)
  final int targetFps;

  /// Frequency sensitivity for mesh deformation (0.0 - 1.0)
  /// Higher values cause more dramatic mesh movement
  final double frequencySensitivity;

  /// Smooth interpolation factor for control point deformation (0.0 - 1.0)
  /// Higher values = smoother transitions, more lag
  final double smoothingFactor;

  /// Minimum frequency band energy to trigger deformation
  final double frequencyThreshold;

  /// Number of frequency bands to sample from spectrum
  final int frequencyBands;

  /// Maximum deformation distance from original position (relative to screen size)
  final double maxDeformationScale;

  /// Enable automatic theme color updates from album art
  final bool autoThemeFromAlbum;

  /// Blending mode name for canvas rendering
  final String blendMode;

  /// Opacity of the mesh gradient background (0.0 - 1.0)
  final double opacity;

  const MeshGradientConfig({
    this.resolution = MeshResolution.high,
    this.targetFps = 60,
    this.frequencySensitivity = 0.8,
    this.smoothingFactor = 0.15,
    this.frequencyThreshold = 0.01,
    this.frequencyBands = 16,
    this.maxDeformationScale = 0.15,
    this.autoThemeFromAlbum = true,
    this.blendMode = 'screen',
    this.opacity = 0.8,
  });

  /// Creates a copy with optional parameter overrides
  MeshGradientConfig copyWith({
    MeshResolution? resolution,
    int? targetFps,
    double? frequencySensitivity,
    double? smoothingFactor,
    double? frequencyThreshold,
    int? frequencyBands,
    double? maxDeformationScale,
    bool? autoThemeFromAlbum,
    String? blendMode,
    double? opacity,
  }) {
    return MeshGradientConfig(
      resolution: resolution ?? this.resolution,
      targetFps: targetFps ?? this.targetFps,
      frequencySensitivity: frequencySensitivity ?? this.frequencySensitivity,
      smoothingFactor: smoothingFactor ?? this.smoothingFactor,
      frequencyThreshold: frequencyThreshold ?? this.frequencyThreshold,
      frequencyBands: frequencyBands ?? this.frequencyBands,
      maxDeformationScale: maxDeformationScale ?? this.maxDeformationScale,
      autoThemeFromAlbum: autoThemeFromAlbum ?? this.autoThemeFromAlbum,
      blendMode: blendMode ?? this.blendMode,
      opacity: opacity ?? this.opacity,
    );
  }

  /// Low-performance preset (mobile, low-end devices)
  static const lowPerformance = MeshGradientConfig(
    resolution: MeshResolution.low,
    targetFps: 30,
    frequencySensitivity: 0.6,
    smoothingFactor: 0.25,
    maxDeformationScale: 0.1,
    opacity: 0.6,
  );

  /// Balanced preset (default, most devices)
  static const balanced = MeshGradientConfig(
    resolution: MeshResolution.medium,
    targetFps: 60,
    frequencySensitivity: 0.8,
    smoothingFactor: 0.15,
    maxDeformationScale: 0.15,
    opacity: 0.8,
  );

  /// High-performance preset (desktop, high-end devices)
  static const highPerformance = MeshGradientConfig(
    resolution: MeshResolution.high,
    targetFps: 60,
    frequencySensitivity: 1.0,
    smoothingFactor: 0.1,
    maxDeformationScale: 0.2,
    opacity: 0.9,
  );
}
