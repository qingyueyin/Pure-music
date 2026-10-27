import 'package:flutter/material.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/window_render_gate.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';
import 'package:pure_music/page/now_playing_page/component/mesh_gradient_background.dart';
import 'package:pure_music/page/now_playing_page/component/flowing_light_background.dart';

export 'now_playing_background_inputs.dart';

/// 窗口刚回来时先画纯色，下一帧再挂上着色器，避免表面未恢复就进显卡。
class _DeferredPlayingBackground extends StatefulWidget {
  const _DeferredPlayingBackground({
    required this.mode,
    required this.inputs,
    required this.fallbackColor,
  });

  final NowPlayingBackgroundMode mode;
  final NowPlayingBackgroundInputs inputs;
  final Color fallbackColor;

  @override
  State<_DeferredPlayingBackground> createState() =>
      _DeferredPlayingBackgroundState();
}

class _DeferredPlayingBackgroundState extends State<_DeferredPlayingBackground> {
  var _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !WindowRenderGate.instance.framesEnabled.value) return;
      setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return ColoredBox(color: widget.fallbackColor);
    return switch (widget.mode) {
      NowPlayingBackgroundMode.meshGradient => MeshGradientBackground(
        inputs: widget.inputs,
        fallbackColor: widget.fallbackColor,
      ),
      NowPlayingBackgroundMode.flowingCover => FlowingLightBackground(
        inputs: widget.inputs,
      ),
    };
  }
}

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

  static Future<void> precache() {
    return Future.wait([
      MeshGradientBackground.precache(),
      FlowingLightBackground.precache(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: WindowRenderGate.instance.framesEnabled,
      builder: (context, framesEnabled, _) {
        // 窗口看不见时卸掉两档背景，显存才放得掉。看得见时照常画。
        if (!framesEnabled) return ColoredBox(color: fallbackColor);
        return _DeferredPlayingBackground(
          mode: mode,
          inputs: inputs,
          fallbackColor: fallbackColor,
        );
      },
    );
  }
}
