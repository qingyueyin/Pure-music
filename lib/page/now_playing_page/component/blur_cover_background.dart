import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

/// Decode size for the source cover before blurring.
const int _kDecodeSize = 256;

/// Output size of the blurred snapshot.  The Gaussian blur destroys all
/// high‑frequency detail, so a modest output resolution looks identical to
/// a full‑res blur while using a fraction of the GPU texture memory.
const int _kBlurOutputSize = 200;

/// Blur sigma for the one‑time pre‑render, chosen per brightness.
/// Dark themes benefit from a stronger blur (depth / atmosphere); light
/// themes look muddy with too much blur.
double _blurSigmaFor(Brightness brightness) =>
    brightness == Brightness.dark ? 55.0 : 30.0;

const _kFadeStops = <double>[0.0, 0.5, 1.0];
const _kFadeColors = <Color>[
  Colors.white,
  Colors.white,
  Colors.transparent,
];

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
  /// Pre‑rendered blurred snapshot — computed ONCE per cover / theme change,
  /// then drawn as a static texture with zero per‑frame GPU compositor work.
  ui.Image? _blurredImage;
  bool _isLoading = false;
  bool _disposed = false;
  Brightness? _lastBrightness;

  @override
  void initState() {
    super.initState();
    // _decodeAndBlur 内部用 Theme.of(context)，不能在 initState 里直接调
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _decodeAndBlur();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).colorScheme.brightness;
    if (_lastBrightness != null && _lastBrightness != brightness) {
      _lastBrightness = brightness;
      _decodeAndBlur();
    } else {
      _lastBrightness = brightness;
    }
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
      _clearImage();
      return;
    }
    if (oldBytes != null && _isSameCoverBytes(newBytes, oldBytes)) return;
    _decodeAndBlur();
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

  void _clearImage() {
    final old = _blurredImage;
    _blurredImage = null;
    old?.dispose();
    if (!_disposed) setState(() {});
  }

  /// Decode the cover → apply Gaussian blur ONCE via an off‑screen
  /// PictureRecorder → store the result as a static GPU texture.
  ///
  /// The blur runs once per cover / theme change, NOT every frame.
  Future<void> _decodeAndBlur() async {
    final bytes = widget.inputs.albumCoverBytes;
    if (bytes == null || bytes.isEmpty) {
      _clearImage();
      return;
    }
    if (_disposed) return;

    final brightness = Theme.of(context).colorScheme.brightness;
    final sigma = _blurSigmaFor(brightness);

    setState(() => _isLoading = true);

    try {
      // 1. Decode at a moderate size.
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _kDecodeSize,
        targetHeight: _kDecodeSize,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();

      if (_disposed || !mounted) {
        frame.image.dispose();
        return;
      }

      // 2. Apply Gaussian blur once via an off‑screen recording canvas.
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final blurPaint = ui.Paint()
        ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
      final srcRect = ui.Rect.fromLTWH(
        0,
        0,
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
      canvas.saveLayer(srcRect, blurPaint);
      canvas.drawImageRect(
        frame.image,
        srcRect,
        ui.Rect.fromLTWH(
          0,
          0,
          _kBlurOutputSize.toDouble(),
          _kBlurOutputSize.toDouble(),
        ),
        ui.Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
      final picture = recorder.endRecording();
      frame.image.dispose();

      final blurred = await picture.toImage(_kBlurOutputSize, _kBlurOutputSize);
      picture.dispose();

      if (_disposed || !mounted) {
        blurred.dispose();
        return;
      }

      final old = _blurredImage;
      _blurredImage = blurred;
      old?.dispose();

      setState(() => _isLoading = false);
    } catch (_) {
      if (!_disposed && mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _blurredImage?.dispose();
    _blurredImage = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = scheme.brightness;
    final blurredImage = _blurredImage;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: scheme.surface),

        if (blurredImage != null)
          RepaintBoundary(
            child: AnimatedOpacity(
              opacity: _isLoading ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeInOut,
              child: _BlurredCover(
                image: blurredImage,
                brightness: brightness,
              ),
            ),
          )
        else
          ColoredBox(color: widget.fallbackColor),

        Container(
          color: widget.fallbackColor.withValues(
            alpha: brightness == Brightness.dark ? 0.35 : 0.15,
          ),
        ),
      ],
    );
  }
}

/// Displays the pre‑blurred static texture.  No ImageFilter, no per‑frame
/// compositor work — just a single texture sample per output pixel.
class _BlurredCover extends StatelessWidget {
  final ui.Image image;
  final Brightness brightness;

  const _BlurredCover({
    required this.image,
    required this.brightness,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: brightness == Brightness.dark ? 0.9 : 0.6,
      child: ClipRRect(
        child: ShaderMask(
          blendMode: BlendMode.modulate,
          shaderCallback: (Rect bounds) {
            return const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: _kFadeColors,
              stops: _kFadeStops,
            ).createShader(bounds);
          },
          child: SizedBox.expand(
            child: RawImage(
              image: image,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
            ),
          ),
        ),
      ),
    );
  }
}
