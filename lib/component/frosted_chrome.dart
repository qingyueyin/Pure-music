import 'dart:ui';

import 'package:flutter/material.dart';

/// Shared frosted-glass chrome used by the title bar and sidebar.
///
/// When [enabled] is false the child sits on solid MD3 `surface`.
/// The blur layer is isolated from [child] so nav/title content can
/// repaint without re-running the backdrop blur.
class FrostedChrome extends StatelessWidget {
  static const double blurSigma = 5;
  static const double blurScale = 0.25;
  static const int fillAlpha = 31;

  /// Downsample to 1/4 before blurring so a tall sidebar does not
  /// Gaussian-blur every pixel. Visual radius stays near the old sigma 20.
  static final ImageFilter blurFilter = _downsampledBlur(
    sigma: blurSigma,
    scale: blurScale,
  );

  const FrostedChrome({
    super.key,
    required this.enabled,
    required this.child,
    this.borderRadius,
    this.height,
  });

  final bool enabled;
  final Widget child;
  final BorderRadius? borderRadius;
  final double? height;

  static ImageFilter _downsampledBlur({
    required double sigma,
    required double scale,
  }) {
    final scaleDown = Matrix4.diagonal3Values(scale, scale, 1).storage;
    final scaleUp = Matrix4.diagonal3Values(1 / scale, 1 / scale, 1).storage;
    return ImageFilter.compose(
      inner: ImageFilter.compose(
        inner: ImageFilter.matrix(scaleDown, filterQuality: FilterQuality.low),
        outer: ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.clamp,
        ),
      ),
      outer: ImageFilter.matrix(scaleUp, filterQuality: FilterQuality.low),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = enabled
        ? scheme.surface.withAlpha(fillAlpha)
        : scheme.surface;

    Widget content = child;
    if (height != null) {
      content = SizedBox(height: height, child: content);
    }

    if (!enabled) {
      final painted = ColoredBox(color: color, child: content);
      if (borderRadius != null) {
        return ClipRRect(borderRadius: borderRadius!, child: painted);
      }
      return painted;
    }

    final glass = Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: BackdropFilter(
              filter: blurFilter,
              child: ColoredBox(color: color),
            ),
          ),
        ),
        content,
      ],
    );

    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: glass);
    }
    return ClipRect(child: glass);
  }
}
