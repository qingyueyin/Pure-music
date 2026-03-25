import 'package:flutter/material.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/page/now_playing_page/component/mesh_gradient_background.dart';
import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

export 'now_playing_background_inputs.dart';

class NowPlayingBackground extends StatefulWidget {
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
  State<NowPlayingBackground> createState() => _NowPlayingBackgroundState();
}

class _NowPlayingBackgroundState extends State<NowPlayingBackground> {
  bool _showMeshLayer = false;

  @override
  void initState() {
    super.initState();
    _showMeshLayer = widget.mode == NowPlayingBackgroundMode.meshGradient;
  }

  @override
  void didUpdateWidget(NowPlayingBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldShowMesh =
        widget.mode == NowPlayingBackgroundMode.meshGradient;
    if (shouldShowMesh != _showMeshLayer) {
      _showMeshLayer = shouldShowMesh;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: widget.fallbackColor),
        if (_showMeshLayer || widget.mode == NowPlayingBackgroundMode.meshGradient)
          _BackgroundLayer(
            visible: widget.mode == NowPlayingBackgroundMode.meshGradient,
            child: MeshGradientBackground(
              inputs: widget.inputs.copyWith(
                isVisible: widget.inputs.isVisible &&
                    widget.mode == NowPlayingBackgroundMode.meshGradient,
              ),
              fallbackColor: widget.fallbackColor,
            ),
          ),
      ],
    );
  }
}

class _BackgroundLayer extends StatelessWidget {
  final bool visible;
  final Widget child;

  const _BackgroundLayer({
    required this.visible,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: TickerMode(
        enabled: visible,
        child: AnimatedOpacity(
          opacity: visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeInOutCubic,
          child: child,
        ),
      ),
    );
  }
}
