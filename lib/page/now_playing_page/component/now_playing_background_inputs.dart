import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pure_music/core/advanced_color_extraction.dart';
import 'package:pure_music/native/bass/bass_player.dart';

@immutable
class NowPlayingBackgroundInputs {
  final Uint8List? albumCoverBytes;
  final Color? dominantColor;
  final MonetColorScheme? monetScheme;
  final Stream<Float32List>? spectrumStream;
  final bool enableAnimation;
  final bool isVisible;
  final PlayerState playerState;
  final double flowSpeed;
  final double intensity;

  const NowPlayingBackgroundInputs({
    this.albumCoverBytes,
    this.dominantColor,
    this.monetScheme,
    this.spectrumStream,
    required this.enableAnimation,
    required this.isVisible,
    required this.playerState,
    this.flowSpeed = 1.0,
    this.intensity = 1.0,
  });

  bool get shouldAnimate =>
      enableAnimation && isVisible && playerState == PlayerState.playing;

  NowPlayingBackgroundInputs copyWith({
    Uint8List? albumCoverBytes,
    Color? dominantColor,
    MonetColorScheme? monetScheme,
    Stream<Float32List>? spectrumStream,
    bool? enableAnimation,
    bool? isVisible,
    PlayerState? playerState,
    double? flowSpeed,
    double? intensity,
  }) {
    return NowPlayingBackgroundInputs(
      albumCoverBytes: albumCoverBytes ?? this.albumCoverBytes,
      dominantColor: dominantColor ?? this.dominantColor,
      monetScheme: monetScheme ?? this.monetScheme,
      spectrumStream: spectrumStream ?? this.spectrumStream,
      enableAnimation: enableAnimation ?? this.enableAnimation,
      isVisible: isVisible ?? this.isVisible,
      playerState: playerState ?? this.playerState,
      flowSpeed: flowSpeed ?? this.flowSpeed,
      intensity: intensity ?? this.intensity,
    );
  }
}
