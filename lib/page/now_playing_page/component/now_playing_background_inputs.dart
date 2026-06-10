import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pure_music/native/bass/bass_player.dart';

@immutable
class NowPlayingBackgroundInputs {
  final Uint8List? albumCoverBytes;
  final Color? dominantColor;
  final Stream<Float32List>? spectrumStream;
  final bool enableAnimation;
  final bool isVisible;
  final PlayerState playerState;
  final double flowSpeed;
  final double intensity;

  /// Pre-extracted palette colors from Rust k-means.
  /// When non-null, backgrounds MUST use these instead of calling
  /// extractColorsFromImage again, avoiding duplicate native image decoding.
  final List<Color>? preExtractedColors;

  const NowPlayingBackgroundInputs({
    this.albumCoverBytes,
    this.dominantColor,
    this.spectrumStream,
    required this.enableAnimation,
    required this.isVisible,
    required this.playerState,
    this.flowSpeed = 1.0,
    this.intensity = 1.0,
    this.preExtractedColors,
  });

  bool get shouldAnimate =>
      enableAnimation && isVisible && playerState == PlayerState.playing;

  NowPlayingBackgroundInputs copyWith({
    Uint8List? albumCoverBytes,
    Color? dominantColor,
    Stream<Float32List>? spectrumStream,
    bool? enableAnimation,
    bool? isVisible,
    PlayerState? playerState,
    double? flowSpeed,
    double? intensity,
    List<Color>? preExtractedColors,
  }) {
    return NowPlayingBackgroundInputs(
      albumCoverBytes: albumCoverBytes ?? this.albumCoverBytes,
      dominantColor: dominantColor ?? this.dominantColor,
      spectrumStream: spectrumStream ?? this.spectrumStream,
      enableAnimation: enableAnimation ?? this.enableAnimation,
      isVisible: isVisible ?? this.isVisible,
      playerState: playerState ?? this.playerState,
      flowSpeed: flowSpeed ?? this.flowSpeed,
      intensity: intensity ?? this.intensity,
      preExtractedColors: preExtractedColors ?? this.preExtractedColors,
    );
  }
}
