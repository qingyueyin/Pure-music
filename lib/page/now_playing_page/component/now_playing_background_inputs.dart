import 'package:flutter/foundation.dart';
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
  final ValueListenable<PlayerState>? playerStateListenable;
  final double flowSpeed;
  final double intensity;
  final bool audioReactiveFlow;

  /// true 用旧版（AGC + 峰值保持），false 用新版（底噪 + 门限）。
  final bool legacyAudioReactiveFlow;

  /// 当前曲目的稳定标识，用于切歌时重置律动包络。
  final String? trackId;

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
    this.playerStateListenable,
    this.flowSpeed = 1.0,
    this.intensity = 1.0,
    this.audioReactiveFlow = false,
    this.legacyAudioReactiveFlow = true,
    this.trackId,
    this.preExtractedColors,
  });

  bool get shouldAnimate => enableAnimation && isVisible && isPlaybackActive;

  PlayerState get resolvedPlayerState =>
      playerStateListenable?.value ?? playerState;

  bool get isPlaybackActive {
    final state = resolvedPlayerState;
    return state == PlayerState.playing || state == PlayerState.stalled;
  }

  NowPlayingBackgroundInputs copyWith({
    Uint8List? albumCoverBytes,
    Color? dominantColor,
    Stream<Float32List>? spectrumStream,
    bool? enableAnimation,
    bool? isVisible,
    PlayerState? playerState,
    ValueListenable<PlayerState>? playerStateListenable,
    double? flowSpeed,
    double? intensity,
    bool? audioReactiveFlow,
    bool? legacyAudioReactiveFlow,
    String? trackId,
    List<Color>? preExtractedColors,
  }) {
    return NowPlayingBackgroundInputs(
      albumCoverBytes: albumCoverBytes ?? this.albumCoverBytes,
      dominantColor: dominantColor ?? this.dominantColor,
      spectrumStream: spectrumStream ?? this.spectrumStream,
      enableAnimation: enableAnimation ?? this.enableAnimation,
      isVisible: isVisible ?? this.isVisible,
      playerState: playerState ?? this.playerState,
      playerStateListenable:
          playerStateListenable ?? this.playerStateListenable,
      flowSpeed: flowSpeed ?? this.flowSpeed,
      intensity: intensity ?? this.intensity,
      audioReactiveFlow: audioReactiveFlow ?? this.audioReactiveFlow,
      legacyAudioReactiveFlow:
          legacyAudioReactiveFlow ?? this.legacyAudioReactiveFlow,
      trackId: trackId ?? this.trackId,
      preExtractedColors: preExtractedColors ?? this.preExtractedColors,
    );
  }
}
