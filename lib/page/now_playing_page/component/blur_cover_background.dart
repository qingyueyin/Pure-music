import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

/// Decode size for the source cover before blurring.
/// 200x200 已足够覆盖全屏模糊，相比 400x400 节省 75% 纹理内存。
const int _kDecodeSize = 200;

const int _kBlurOutputSize = 200;

const _kBlurSigma = 20.0;

const _kFadeStops = <double>[0.0, 0.3, 1.0];
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
  int _blurRequestId = 0;
  int? _currentCoverFingerprint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _decodeAndBlur();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(covariant BlurCoverBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newBytes = widget.inputs.albumCoverBytes;
    final oldBytes = oldWidget.inputs.albumCoverBytes;
    if (!identical(newBytes, oldBytes)) {
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
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  int _coverFingerprint(Uint8List bytes) {
    var hash = bytes.length;
    final step = (bytes.length / 512).ceil();
    for (var i = 0; i < bytes.length; i += step) {
      hash = 0x1fffffff & (hash * 31 + bytes[i]);
    }
    return hash;
  }

  bool _isCurrentRequest(int requestId, int fingerprint) {
    return !_disposed &&
        mounted &&
        requestId == _blurRequestId &&
        _currentCoverFingerprint == fingerprint;
  }

  void _clearImage() {
    _blurRequestId++;
    _currentCoverFingerprint = null;
    final old = _blurredImage;
    _blurredImage = null;
    old?.dispose();
    if (!_disposed && mounted) setState(() => _isLoading = false);
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

    final fingerprint = _coverFingerprint(bytes);
    _currentCoverFingerprint = fingerprint;
    final requestId = ++_blurRequestId;

    const sigma = _kBlurSigma;

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

      if (!_isCurrentRequest(requestId, fingerprint)) {
        frame.image.dispose();
        return;
      }

      // 2. Apply Gaussian blur once via an off‑screen recording canvas.
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final blurPaint = ui.Paint()
        ..imageFilter = ui.ImageFilter.blur(
            sigmaX: sigma, sigmaY: sigma, tileMode: ui.TileMode.clamp);
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

      if (!_isCurrentRequest(requestId, fingerprint)) {
        blurred.dispose();
        return;
      }

      final old = _blurredImage;
      _blurredImage = blurred;
      old?.dispose();

      if (!mounted) return;
      setState(() => _isLoading = false);
    } catch (_) {
      if (_isCurrentRequest(requestId, fingerprint) && mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _blurredImage?.dispose();
    _blurredImage = null;
    super.dispose();
  }

  /// 叠加 tint 用画面均值色，而非单个 dominant 强调色，避免背景被带偏。
  Color _tintColor() {
    final colors = widget.inputs.preExtractedColors;
    if (colors == null || colors.isEmpty) return widget.fallbackColor;
    var r = 0.0, g = 0.0, b = 0.0;
    for (final c in colors) {
      r += c.r;
      g += c.g;
      b += c.b;
    }
    final n = colors.length;
    return Color.from(alpha: 1.0, red: r / n, green: g / n, blue: b / n);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = scheme.brightness;
    final blurredImage = _blurredImage;
    final tintColor = _tintColor();

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
          ColoredBox(color: tintColor),
        Container(
          color: tintColor.withValues(
            alpha: brightness == Brightness.dark ? 0.25 : 0.10,
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
