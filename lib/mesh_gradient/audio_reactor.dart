// Audio-reactive spectrum processing for mesh deformation.
//
// Processes frequency spectrum data from the audio stream and maps it to
// control point deformations for audio-reactive mesh animation.
//
// Features:
// - Frequency band sampling and smoothing
// - Control point deformation mapping
// - Configurable sensitivity and thresholds

import 'dart:typed_data';
import 'dart:math' as math;
import 'package:pure_music/mesh_gradient/config.dart';

/// Represents processed frequency band energy data
class FrequencyBandData {
  /// Energy level for each frequency band (0.0-1.0)
  final List<double> energies;

  /// Peak energy across all bands
  final double peakEnergy;

  /// Average energy across all bands
  final double averageEnergy;

  FrequencyBandData({
    required this.energies,
    required this.peakEnergy,
    required this.averageEnergy,
  });
}

/// Processes audio spectrum data and generates mesh deformations.
///
/// Maps frequency bands to control point movements for audio-reactive effects.
/// Includes smoothing and hysteresis to prevent jittery motion.
class AudioReactor {
  /// Configuration settings
  final MeshGradientConfig config;

  /// Smoothed frequency band energies from previous frame
  late List<double> smoothedEnergies;

  /// Previous deformation state for smoothing
  late Float32List previousDeformations;

  /// Scaling factor for deformation amplitude based on max screen dimension
  double deformationScale = 1.0;

  /// Pre-computed frequency band center frequencies (0.0-1.0)
  late List<double> bandCenterFrequencies;

  AudioReactor({required this.config}) {
    _initialize();
  }

  void _initialize() {
    smoothedEnergies = List<double>.filled(config.frequencyBands, 0.0);
    previousDeformations = Float32List(32);
    _computeBandCenterFrequencies();
  }

  /// Pre-computes normalized center frequencies for each band.
  ///
  /// Uses logarithmic spacing to match human hearing (lower frequencies
  /// more sensitive than higher).
  void _computeBandCenterFrequencies() {
    bandCenterFrequencies = <double>[];

    for (int i = 0; i < config.frequencyBands; i++) {
      // Logarithmic distribution: lower bands dense, higher bands sparse
      final t = i / (config.frequencyBands - 1);
      final logFreq = math.pow(2, t * 4) / 16; // 2^(0-4) range
      bandCenterFrequencies.add(math.min(logFreq.toDouble(), 1.0));
    }
  }

  /// Sets the deformation scale based on viewport size.
  ///
  /// Args:
  ///   maxScreenDimension: Larger of width/height (used to scale deformations)
  void setViewportSize(double maxScreenDimension) {
    deformationScale = maxScreenDimension * config.maxDeformationScale;
  }

  /// Processes raw spectrum data and returns frequency band energies.
  ///
  /// Args:
  ///   spectrumData: Raw FFT data from audio (typically 256-2048 values)
  ///
  /// Returns: Processed frequency bands with energy levels
  FrequencyBandData processSpectrum(Float32List spectrumData) {
    if (spectrumData.isEmpty) {
      return FrequencyBandData(
        energies: List<double>.filled(config.frequencyBands, 0.0),
        peakEnergy: 0.0,
        averageEnergy: 0.0,
      );
    }

    final bandEnergies = <double>[];
    final spectrumLength = spectrumData.length;
    double peakEnergy = 0.0;
    double totalEnergy = 0.0;

    for (int i = 0; i < config.frequencyBands; i++) {
      final centerFreq = bandCenterFrequencies[i];

      // Map frequency to spectrum index range
      final startIdx = (centerFreq * 0.4 * spectrumLength).toInt();
      final endIdx = (centerFreq * 0.6 * spectrumLength).toInt();
      final clampedEnd = math.min(endIdx, spectrumLength - 1);

      if (startIdx >= clampedEnd) {
        bandEnergies.add(0.0);
        continue;
      }

      // Average energy in this band
      double bandSum = 0.0;
      int sampleCount = 0;

      for (int j = startIdx; j <= clampedEnd; j++) {
        bandSum += spectrumData[j].abs();
        sampleCount++;
      }

      final bandEnergy = sampleCount > 0 ? bandSum / sampleCount : 0.0;

      // Apply threshold and smoothing
      final smoothedEnergy = (bandEnergy > config.frequencyThreshold)
          ? bandEnergy * config.frequencySensitivity
          : 0.0;

      smoothedEnergies[i] = smoothedEnergies[i] * (1.0 - config.smoothingFactor) +
          smoothedEnergy * config.smoothingFactor;

      final clampedEnergy = math.min(smoothedEnergies[i], 1.0);
      bandEnergies.add(clampedEnergy);

      peakEnergy = math.max(peakEnergy, clampedEnergy);
      totalEnergy += clampedEnergy;
    }

    final averageEnergy = totalEnergy / config.frequencyBands;

    return FrequencyBandData(
      energies: bandEnergies,
      peakEnergy: peakEnergy,
      averageEnergy: averageEnergy,
    );
  }

  /// Generates mesh deformation vectors from frequency bands.
  ///
  /// Maps frequency bands to control point movements in a circular pattern
  /// around the mesh center.
  ///
  /// Args:
  ///   frequencyData: Processed frequency band data
  ///
  /// Returns: Deformation array [dx0, dy0, dx1, dy1, ..., dx15, dy15]
  Float32List generateDeformations(FrequencyBandData frequencyData) {
    final deformations = Float32List(32);

    // Map 16 frequency bands to 16 control points
    for (int i = 0; i < 16; i++) {
      final bandIndex = (i * config.frequencyBands) ~/ 16;
      final clampedBandIndex = math.min(bandIndex, config.frequencyBands - 1);
      final energy = frequencyData.energies[clampedBandIndex];

      // Control points are in 4x4 grid, map to circular pattern
      final x = i % 4;
      final y = i ~/ 4;

      // Normalize to center (2x2 grid)
      final cx = (x - 1.5) / 1.5; // -1.0 to 1.0
      final cy = (y - 1.5) / 1.5; // -1.0 to 1.0

      // Calculate radial direction from center
      final angle = math.atan2(cy, cx);

      // Deform along radial direction
      final deformAmount = energy * deformationScale;
      deformations[i * 2] = math.cos(angle) * deformAmount;
      deformations[i * 2 + 1] = math.sin(angle) * deformAmount;
    }

    return deformations;
  }

  /// Generates deformations with smoother transitions using interpolation.
  ///
  /// Interpolates between previous and current deformations to create
  /// smoother motion that isn't too jittery.
  Float32List generateSmoothDeformations(FrequencyBandData frequencyData) {
    final newDeformations = generateDeformations(frequencyData);

    // Interpolate with previous frame
    for (int i = 0; i < 32; i++) {
      newDeformations[i] = previousDeformations[i] * (1.0 - config.smoothingFactor) +
          newDeformations[i] * config.smoothingFactor;
    }

    // Store for next frame
    previousDeformations = Float32List.fromList(newDeformations);

    return newDeformations;
  }

  /// Resets audio reactor to initial state.
  ///
  /// Clears smoothed energies and deformation history.
  void reset() {
    smoothedEnergies.fillRange(0, config.frequencyBands, 0.0);
    previousDeformations.fillRange(0, 32, 0.0);
  }
}
