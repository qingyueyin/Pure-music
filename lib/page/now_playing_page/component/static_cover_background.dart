import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';

const _shaderAssetPath = 'assets/shaders/static_cover_background.frag';
const _gaussianShaderAssetPath = 'assets/shaders/pulse_gaussian.frag';
const _coverDecodeSize = 128;
const _backdropDownsampleScale = 0.07;
const _backdropBlurRadius = 80.0;
const _minimumBackdropDimension = 24.0;
const _maximumBackdropDimension = 480.0;
const _backdropBlurSigma = _backdropDownsampleScale * 2.0 * _backdropBlurRadius;
const _darkBlackScrimAlpha = 0.22;
const _lightBlackScrimAlpha = 0.30;
const _whiteScrimAlpha = 0.06;
const _coverTransitionMs = 300.0;

class StaticCoverBackground extends StatefulWidget {
  const StaticCoverBackground({
    super.key,
    required this.inputs,
    required this.fallbackColor,
  });

  final NowPlayingBackgroundInputs inputs;
  final Color fallbackColor;

  @override
  State<StaticCoverBackground> createState() => _StaticCoverBackgroundState();
}

class _StaticCoverBackgroundState extends State<StaticCoverBackground>
    with TickerProviderStateMixin {
  ui.Image? _coverTexture;
  ui.Image? _previousCoverTexture;
  ui.FragmentShader? _shader;
  ui.FragmentShader? _gaussianHorizontal;
  ui.FragmentShader? _gaussianVertical;
  int _coverRequestId = 0;
  int? _currentCoverFingerprint;
  double _coverMix = 1.0;
  bool _disposed = false;
  Ticker? _transitionTicker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadShader());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_decodeCoverTexture());
    });
  }

  @override
  void didUpdateWidget(covariant StaticCoverBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newBytes = widget.inputs.albumCoverBytes;
    final oldBytes = oldWidget.inputs.albumCoverBytes;
    if (!identical(newBytes, oldBytes) &&
        !_sameCoverBytes(newBytes, oldBytes)) {
      if (newBytes == null || newBytes.isEmpty) {
        _clearCover();
      } else {
        unawaited(_decodeCoverTexture());
      }
    }
  }

  bool _sameCoverBytes(Uint8List? first, Uint8List? second) {
    if (identical(first, second)) return true;
    if (first == null || second == null || first.length != second.length) {
      return false;
    }
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  int _coverFingerprint(Uint8List bytes) {
    var hash = bytes.length;
    final step = (bytes.length / 512).ceil();
    for (var index = 0; index < bytes.length; index += step) {
      hash = 0x1fffffff & (hash * 31 + bytes[index]);
    }
    return hash;
  }

  bool _isCurrentRequest(int requestId, int fingerprint) {
    return !_disposed &&
        mounted &&
        requestId == _coverRequestId &&
        _currentCoverFingerprint == fingerprint;
  }

  Future<void> _loadShader() async {
    ui.FragmentShader? shader;
    ui.FragmentShader? horizontal;
    ui.FragmentShader? vertical;
    try {
      final program = await ui.FragmentProgram.fromAsset(_shaderAssetPath);
      shader = program.fragmentShader();
      try {
        final gaussianProgram =
            await ui.FragmentProgram.fromAsset(_gaussianShaderAssetPath);
        horizontal = gaussianProgram.fragmentShader();
        vertical = gaussianProgram.fragmentShader();
        const inverseTwoSigmaSquared =
            1.0 / (2.0 * _backdropBlurSigma * _backdropBlurSigma);
        horizontal
          ..setFloat(2, 1.0)
          ..setFloat(3, 0.0)
          ..setFloat(4, inverseTwoSigmaSquared);
        vertical
          ..setFloat(2, 0.0)
          ..setFloat(3, 1.0)
          ..setFloat(4, inverseTwoSigmaSquared);
      } catch (_) {
        horizontal?.dispose();
        vertical?.dispose();
        horizontal = null;
        vertical = null;
      }
      if (_disposed || !mounted) {
        shader.dispose();
        horizontal?.dispose();
        vertical?.dispose();
        return;
      }
      final loaded = shader;
      shader = null;
      setState(() {
        _shader = loaded;
        _gaussianHorizontal = horizontal;
        _gaussianVertical = vertical;
      });
      horizontal = null;
      vertical = null;
    } catch (_) {
    } finally {
      shader?.dispose();
      horizontal?.dispose();
      vertical?.dispose();
    }
  }

  Future<void> _decodeCoverTexture() async {
    final bytes = widget.inputs.albumCoverBytes;
    if (bytes == null || bytes.isEmpty) {
      _clearCover();
      return;
    }
    if (_disposed) return;

    final fingerprint = _coverFingerprint(bytes);
    final requestId = ++_coverRequestId;
    _currentCoverFingerprint = fingerprint;

    ui.Codec? codec;
    ui.Image? decoded;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _coverDecodeSize,
        targetHeight: _coverDecodeSize,
      );
      if (!_isCurrentRequest(requestId, fingerprint)) return;

      final frame = await codec.getNextFrame();
      decoded = frame.image;
      if (!_isCurrentRequest(requestId, fingerprint)) return;
      if (!mounted) return;

      final next = decoded;
      decoded = null;
      _replaceCoverTexture(next);
    } catch (_) {
      if (_isCurrentRequest(requestId, fingerprint)) _clearCover();
    } finally {
      decoded?.dispose();
      codec?.dispose();
    }
  }

  void _replaceCoverTexture(ui.Image next) {
    final current = _coverTexture;
    final stalePrevious = _previousCoverTexture;

    if (current == null) {
      _coverTexture = next;
      _previousCoverTexture = null;
      _coverMix = 1.0;
      setState(() {});
      _disposeImagesAfterFrame([stalePrevious]);
      return;
    }

    _previousCoverTexture = current;
    _coverTexture = next;
    _coverMix = 0.0;
    setState(() {});
    _disposeImagesAfterFrame([stalePrevious]);
    _beginCoverTransition();
  }

  void _beginCoverTransition() {
    _transitionTicker?.stop();
    _transitionTicker?.dispose();
    final start = DateTime.now();
    _transitionTicker = createTicker((Duration elapsed) {
      if (!mounted || _disposed) {
        _transitionTicker?.stop();
        return;
      }
      final ms = DateTime.now().difference(start).inMilliseconds.toDouble();
      final raw = ms / _coverTransitionMs;
      _coverMix = raw >= 1.0 ? 1.0 : raw;
      if (_coverMix >= 1.0) {
        _transitionTicker?.stop();
        _transitionTicker?.dispose();
        _transitionTicker = null;
        _finishCoverTransition();
        return;
      }
      setState(() {});
    });
    _transitionTicker!.start();
  }

  void _finishCoverTransition() {
    final previous = _previousCoverTexture;
    _previousCoverTexture = null;
    _coverMix = 1.0;
    if (!_disposed && mounted) {
      setState(() {});
      _disposeImagesAfterFrame([previous]);
    } else {
      previous?.dispose();
    }
  }

  void _disposeImagesAfterFrame(Iterable<ui.Image?> images) {
    final disposable = images.whereType<ui.Image>().toList(growable: false);
    if (disposable.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final image in disposable) {
        image.dispose();
      }
    });
  }

  void _clearCover() {
    _coverRequestId++;
    _currentCoverFingerprint = null;
    _transitionTicker?.stop();
    _transitionTicker?.dispose();
    _transitionTicker = null;
    final previous = _coverTexture;
    final transitionSource = _previousCoverTexture;
    _coverTexture = null;
    _previousCoverTexture = null;
    _coverMix = 1.0;
    if (!_disposed && mounted && (previous != null || transitionSource != null)) {
      setState(() {});
      _disposeImagesAfterFrame([transitionSource, previous]);
    } else {
      transitionSource?.dispose();
      previous?.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _coverRequestId++;
    _transitionTicker?.stop();
    _transitionTicker?.dispose();
    _transitionTicker = null;
    _shader?.dispose();
    _shader = null;
    _gaussianHorizontal?.dispose();
    _gaussianHorizontal = null;
    _gaussianVertical?.dispose();
    _gaussianVertical = null;
    _previousCoverTexture?.dispose();
    _previousCoverTexture = null;
    _coverTexture?.dispose();
    _coverTexture = null;
    super.dispose();
  }

  ui.ImageFilter _createBackdropBlurFilter() {
    final horizontal = _gaussianHorizontal;
    final vertical = _gaussianVertical;
    if (horizontal != null &&
        vertical != null &&
        ui.ImageFilter.isShaderFilterSupported) {
      try {
        return ui.ImageFilter.compose(
          outer: ui.ImageFilter.shader(vertical),
          inner: ui.ImageFilter.shader(horizontal),
        );
      } catch (_) {
      }
    }
    return ui.ImageFilter.blur(
      sigmaX: _backdropBlurSigma,
      sigmaY: _backdropBlurSigma,
      tileMode: ui.TileMode.clamp,
    );
  }

  double _backdropDimension(double value) {
    return (value * _backdropDownsampleScale)
        .clamp(_minimumBackdropDimension, _maximumBackdropDimension)
        .toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final image = _coverTexture;
    final shader = _shader;
    final brightness = Theme.of(context).brightness;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: widget.fallbackColor),
        if (image != null && shader != null)
          LayoutBuilder(
            builder: (context, constraints) {
              final width = _backdropDimension(constraints.maxWidth);
              final height = _backdropDimension(constraints.maxHeight);
              return RepaintBoundary(
                child: FittedBox(
                  fit: BoxFit.fill,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: ImageFiltered(
                      imageFilter: _createBackdropBlurFilter(),
                      child: CustomPaint(
                        painter: _StaticCoverShaderPainter(
                          shader: shader,
                          cover: image,
                          previousCover: _previousCoverTexture,
                          coverMix: _coverMix,
                          blackScrimAlpha: brightness == Brightness.dark
                              ? _darkBlackScrimAlpha
                              : _lightBlackScrimAlpha,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

final class _StaticCoverShaderPainter extends CustomPainter {
  _StaticCoverShaderPainter({
    required this.shader,
    required this.cover,
    required this.previousCover,
    required this.coverMix,
    required this.blackScrimAlpha,
  });

  final ui.FragmentShader shader;
  final ui.Image cover;
  final ui.Image? previousCover;
  final double coverMix;
  final double blackScrimAlpha;
  final ui.Paint _paint = ui.Paint();

  @override
  void paint(ui.Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, coverMix)
      ..setFloat(3, blackScrimAlpha)
      ..setFloat(4, _whiteScrimAlpha)
      ..setImageSampler(0, previousCover ?? cover)
      ..setImageSampler(1, cover);

    _paint.shader = shader;
    canvas.drawRect(ui.Offset.zero & size, _paint);
  }

  @override
  bool shouldRepaint(_StaticCoverShaderPainter oldDelegate) {
    return oldDelegate.coverMix != coverMix ||
        oldDelegate.blackScrimAlpha != blackScrimAlpha ||
        !identical(oldDelegate.cover, cover) ||
        !identical(oldDelegate.previousCover, previousCover);
  }
}
