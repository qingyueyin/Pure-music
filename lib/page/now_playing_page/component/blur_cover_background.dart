import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

const int _coverBigRenderSize = 400;

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
  ui.Image? _decodedImage;
  Uint8List? _loadedBytes;
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
      if (_decodedImage != null && !_disposed) {
        _decodedImage!.dispose();
        _decodedImage = null;
        _loadedBytes = null;
        setState(() {});
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
      if (_decodedImage != null) {
        final old = _decodedImage;
        _decodedImage = null;
        _loadedBytes = null;
        old!.dispose();
        setState(() {});
      }
      return;
    }

    if (_disposed) return;

    if (identical(bytes, _loadedBytes) && _decodedImage != null) return;

    setState(() => _isLoading = true);

    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _coverBigRenderSize,
        targetHeight: _coverBigRenderSize,
      );
      final frame = await codec.getNextFrame();
      final newImage = frame.image;

      if (_disposed || !mounted) {
        newImage.dispose();
        return;
      }

      final oldImage = _decodedImage;
      _decodedImage = newImage;
      _loadedBytes = bytes;
      oldImage?.dispose();

      setState(() => _isLoading = false);
    } catch (_) {
      if (!_disposed && mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _decodedImage?.dispose();
    _decodedImage = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = scheme.brightness;
    final decodedImage = _decodedImage;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: scheme.surface),

        RepaintBoundary(
          child: AnimatedOpacity(
            opacity: _isLoading ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeInOut,
            child: decodedImage != null
                ? _BlurredCover(
                    image: decodedImage,
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
  final ui.Image image;
  final Brightness brightness;

  const _BlurredCover({
    required this.image,
    required this.brightness,
  });

  static final _blurFilter = ui.ImageFilter.blur(
    sigmaX: 80,
    sigmaY: 80,
    tileMode: ui.TileMode.clamp,
  );

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: brightness == Brightness.dark ? 0.9 : 0.6,
      child: ClipRRect(
        child: ImageFiltered(
          imageFilter: _blurFilter,
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
            child: SizedBox.expand(
              child: RawImage(
                image: image,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
