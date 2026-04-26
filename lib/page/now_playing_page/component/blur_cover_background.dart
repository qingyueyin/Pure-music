import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

const int _coverBigRenderSize = 800;

class BlurCoverBackground extends StatefulWidget {
  final NowPlayingBackgroundInputs inputs;
  final Color fallbackColor;

  const BlurCoverBackground({
    super.key,
    required this.inputs,
    required this.fallbackColor,
  });

  @override
  State<BlurCoverBackground> createState() => _BlurCoverBackgroundState();
}

class _BlurCoverBackgroundState extends State<BlurCoverBackground> {
  Uint8List? _currentCoverBytes;
  bool _isLoading = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _loadCover();
  }

  @override
  void didUpdateWidget(covariant BlurCoverBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newBytes = widget.inputs.albumCoverBytes;
    final oldBytes = oldWidget.inputs.albumCoverBytes;
    if (newBytes != null && !identical(newBytes, oldBytes)) {
      _coverBytesChanged(newBytes, oldBytes);
    }
  }

  void _coverBytesChanged(Uint8List? newBytes, Uint8List? oldBytes) {
    if (newBytes == null || newBytes.isEmpty) {
      if (_currentCoverBytes != null && !_disposed) {
        setState(() => _currentCoverBytes = null);
      }
      return;
    }
    if (oldBytes != null && _isSameCoverBytes(newBytes, oldBytes)) return;
    _loadCover();
  }

  bool _isSameCoverBytes(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    if (a.length > 65536) return true;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _loadCover() async {
    final bytes = widget.inputs.albumCoverBytes;
    if (bytes == null || bytes.isEmpty) {
      if (_currentCoverBytes != null) {
        setState(() => _currentCoverBytes = null);
      }
      return;
    }

    if (_disposed) return;

    setState(() {
      _currentCoverBytes = bytes;
      _isLoading = false;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = scheme.brightness;
    final coverBytes = _currentCoverBytes;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: scheme.surface),

        RepaintBoundary(
          child: AnimatedOpacity(
            opacity: _isLoading ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeInOut,
            child: coverBytes != null
                ? _BlurredCover(
                    coverBytes: coverBytes,
                    brightness: brightness,
                  )
                : ColoredBox(color: widget.fallbackColor),
          ),
        ),

        Container(
          color: widget.fallbackColor.withValues(
            alpha: brightness == Brightness.dark ? 0.35 : 0.15,
          ),
        ),
      ],
    );
  }
}

class _BlurredCover extends StatelessWidget {
  final Uint8List coverBytes;
  final Brightness brightness;

  const _BlurredCover({
    required this.coverBytes,
    required this.brightness,
  });

  Widget get _cover => SizedBox.expand(
        child: Image.memory(
          coverBytes,
          cacheWidth: _coverBigRenderSize,
          cacheHeight: _coverBigRenderSize,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: brightness == Brightness.dark ? 0.9 : 0.6,
      child: ClipRRect(
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: 80,
            sigmaY: 80,
            tileMode: ui.TileMode.clamp,
          ),
          child: ShaderMask(
            blendMode: BlendMode.modulate,
            shaderCallback: (Rect bounds) {
              return const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                ],
                stops: [0.0, 0.3, 1.0],
              ).createShader(bounds);
            },
            child: _cover,
          ),
        ),
      ),
    );
  }
}
