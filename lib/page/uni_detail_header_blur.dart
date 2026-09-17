import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

const int kDetailHeaderBlurOutputSize = 200;
const double kDetailHeaderBlurSigma = 28;

/// Decode a cover, blur it once, and keep a static texture.
///
/// The Gaussian blur runs off-screen, not as a per-frame [ImageFilter].
class DetailHeaderBlurredCover extends StatefulWidget {
  const DetailHeaderBlurredCover({super.key, required this.pic});

  final Future<ImageProvider?> pic;

  @override
  State<DetailHeaderBlurredCover> createState() =>
      _DetailHeaderBlurredCoverState();
}

class _DetailHeaderBlurredCoverState extends State<DetailHeaderBlurredCover> {
  ImageProvider? _provider;
  ui.Image? _blurred;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant DetailHeaderBlurredCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.pic, oldWidget.pic)) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _requestId++;
    _blurred?.dispose();
    _blurred = null;
    super.dispose();
  }

  Future<void> _load() async {
    final requestId = ++_requestId;
    final provider = await widget.pic;
    if (!mounted || requestId != _requestId) return;
    if (identical(provider, _provider) && _blurred != null) return;

    _provider = provider;
    if (provider == null) {
      _replaceBlurred(null);
      return;
    }

    final blurred = await resolveAndBlurCover(provider);
    if (!mounted || requestId != _requestId) {
      blurred?.dispose();
      return;
    }
    _replaceBlurred(blurred);
  }

  void _replaceBlurred(ui.Image? next) {
    final old = _blurred;
    _blurred = next;
    old?.dispose();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final blurred = _blurred;
    if (blurred == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    // Same frost family as the title bar (surface ~12%), slightly thicker
    // because this surface is larger. Bottom dissolves so the page shows through.
    final frost = scheme.surface.withValues(alpha: isDark ? 0.16 : 0.22);

    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: [0.62, 1.0],
        colors: [Colors.white, Colors.transparent],
      ).createShader(bounds),
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: RawImage(
              image: blurred,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [frost, frost.withValues(alpha: 0)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<ui.Image?> resolveAndBlurCover(ImageProvider provider) async {
  final completer = Completer<ImageInfo>();
  final stream = provider.resolve(const ImageConfiguration());
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!completer.isCompleted) completer.complete(info.clone());
    },
    onError: (error, stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
  );
  stream.addListener(listener);
  try {
    final info = await completer.future;
    try {
      return await blurCoverImage(info.image);
    } finally {
      info.dispose();
    }
  } catch (_) {
    return null;
  } finally {
    stream.removeListener(listener);
  }
}

Future<ui.Image> blurCoverImage(
  ui.Image source, {
  int size = kDetailHeaderBlurOutputSize,
  double sigma = kDetailHeaderBlurSigma,
}) {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final dst = ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
  final blurPaint = ui.Paint()
    ..imageFilter = ui.ImageFilter.blur(
      sigmaX: sigma,
      sigmaY: sigma,
      tileMode: ui.TileMode.clamp,
    );
  canvas.saveLayer(dst, blurPaint);
  canvas.drawImageRect(
    source,
    ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    dst,
    ui.Paint()..filterQuality = FilterQuality.medium,
  );
  canvas.restore();
  final picture = recorder.endRecording();
  return picture.toImage(size, size).whenComplete(picture.dispose);
}
