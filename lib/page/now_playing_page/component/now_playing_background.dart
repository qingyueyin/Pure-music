import 'package:flutter/material.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';
import 'package:pure_music/page/now_playing_page/component/mesh_gradient_background.dart';
import 'package:pure_music/page/now_playing_page/component/blur_cover_background.dart';
import 'package:pure_music/page/now_playing_page/component/hybrid_background.dart';

export 'now_playing_background_inputs.dart';

class NowPlayingBackground extends StatelessWidget {
  final NowPlayingBackgroundMode mode;
  final NowPlayingBackgroundInputs inputs;
  final Color fallbackColor;

  const NowPlayingBackground({
    super.key,
    required this.mode,
    required this.inputs,
    required this.fallbackColor,
  });

  @override
  Widget build(BuildContext context) {
    return switch (mode) {
      NowPlayingBackgroundMode.meshGradient => MeshGradientBackground(
          mode: mode,
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
