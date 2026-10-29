// ignore_for_file: camel_case_types

import 'dart:io';
import 'dart:ui';

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/window_render_gate.dart';
import 'package:pure_music/component/mini_now_playing.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/component/side_nav.dart';
import 'package:pure_music/component/title_bar.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return ResponsiveBuilder(
      builder: (context, screenType) {
        switch (screenType) {
          case ScreenType.small:
            return _AppShell_Small(navigationShell: navigationShell);
          case ScreenType.medium:
          case ScreenType.large:
            return _AppShell_Large(navigationShell: navigationShell);
        }
      },
    );
  }
}

Color _resolveDynamicColor(ColorScheme scheme) {
  return Color.alphaBlend(
    scheme.primary.withAlpha(20),
    scheme.surfaceContainerLow,
  );
}

final Map<String, double> _backgroundLuminanceCache = {};
const _backgroundLuminanceCacheLimit = 24;

void _cacheBackgroundLuminance(String path, double luminance) {
  _backgroundLuminanceCache.remove(path);
  _backgroundLuminanceCache[path] = luminance;
  if (_backgroundLuminanceCache.length > _backgroundLuminanceCacheLimit) {
    _backgroundLuminanceCache.remove(_backgroundLuminanceCache.keys.first);
  }
}

Future<double> _resolveBackgroundLuminance(String path) async {
  final cached = _backgroundLuminanceCache[path];
  if (cached != null) {
    _cacheBackgroundLuminance(path, cached);
    return cached;
  }
  Codec? codec;
  try {
    final bytes = await File(path).readAsBytes();
    codec = await instantiateImageCodec(bytes, targetWidth: 64);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ImageByteFormat.rawRgba);
      if (data == null) return 0.5;
      final pixels = data.buffer.asUint8List();
      var sum = 0.0;
      for (var i = 0; i < pixels.length; i += 4) {
        final r = pixels[i] / 255;
        final g = pixels[i + 1] / 255;
        final b = pixels[i + 2] / 255;
        sum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
      }
      final luminance = sum / (pixels.length / 4);
      _cacheBackgroundLuminance(path, luminance);
      return luminance;
    } finally {
      image.dispose();
    }
  } catch (_) {
    _cacheBackgroundLuminance(path, 0.5);
    return 0.5;
  } finally {
    codec?.dispose();
  }
}

final Map<double, ImageFilter> _downsampledBlurCache = {};

/// 整窗高斯先缩到 1/4 再模糊，观感半径不变，采样量降到 1/16。
ImageFilter _downsampledBlurFilter(double sigma) {
  final cached = _downsampledBlurCache[sigma];
  if (cached != null) return cached;
  const scale = 0.25;
  final scaleDown = Matrix4.diagonal3Values(scale, scale, 1).storage;
  final scaleUp = Matrix4.diagonal3Values(1 / scale, 1 / scale, 1).storage;
  final filter = ImageFilter.compose(
    inner: ImageFilter.compose(
      inner: ImageFilter.matrix(scaleDown, filterQuality: FilterQuality.low),
      outer: ImageFilter.blur(
        sigmaX: sigma * scale,
        sigmaY: sigma * scale,
        tileMode: TileMode.clamp,
      ),
    ),
    outer: ImageFilter.matrix(scaleUp, filterQuality: FilterQuality.low),
  );
  return _downsampledBlurCache[sigma] = filter;
}

class _AppBackground extends StatefulWidget {
  const _AppBackground({
    required this.fallbackColor,
    required this.imagePath,
    required this.child,
  });

  final Color fallbackColor;
  final String? imagePath;
  final Widget child;

  @override
  State<_AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<_AppBackground> {
  double _imageLuminance = 0.5;

  @override
  void initState() {
    super.initState();
    _resolveLuminance();
  }

  @override
  void didUpdateWidget(_AppBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _resolveLuminance();
    }
  }

  Future<void> _resolveLuminance() async {
    final imagePath = widget.imagePath;
    if (imagePath == null) {
      if (mounted) setState(() => _imageLuminance = 0.5);
      return;
    }
    final luminance = await _resolveBackgroundLuminance(imagePath);
    if (!mounted || imagePath != widget.imagePath) return;
    setState(() => _imageLuminance = luminance);
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final maskColor = isDark ? Colors.black : Colors.white;
    final maskAlpha = isDark
        ? 0.25 + 0.2 * _imageLuminance
        : 0.25 + 0.2 * (1 - _imageLuminance);
    return ValueListenableBuilder<bool>(
      valueListenable: WindowRenderGate.instance.framesEnabled,
      builder: (context, windowVisible, _) {
        if (settings.appWindowTransparent) {
          return _transparentShell(settings, windowVisible);
        }
        return _imageShell(settings, maskColor, maskAlpha, windowVisible);
      },
    );
  }

  Widget _transparentShell(AppSettings settings, bool windowVisible) {
    final bgColor = widget.fallbackColor.withValues(
      alpha: settings.appWindowOpacity,
    );
    final windowBlur = settings.appWindowBlur;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: bgColor),
        if (windowBlur > 0 && windowVisible)
          BackdropFilter(
            filter: _downsampledBlurFilter(windowBlur),
            child: widget.child,
          )
        else
          widget.child,
      ],
    );
  }

  Widget _imageShell(
    AppSettings settings,
    Color maskColor,
    double maskAlpha,
    bool windowVisible,
  ) {
    final imagePath = widget.imagePath;
    final blur = settings.appBackgroundImageBlur;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: widget.fallbackColor),
        if (imagePath != null) ...[
          Opacity(
            opacity: settings.appBackgroundImageOpacity,
            child: blur > 0 && windowVisible
                ? _blurredBackground(context, imagePath, blur)
                : _backgroundImage(imagePath),
          ),
          AnimatedContainer(
            duration: MotionDuration.fast,
            curve: MotionCurve.standard,
            color: maskColor.withValues(alpha: maskAlpha),
          ),
        ],
        widget.child,
      ],
    );
  }

  Widget _blurredBackground(
    BuildContext context,
    String imagePath,
    double blur,
  ) {
    final downsample = blur >= 16
        ? 4
        : blur >= 8
        ? 2
        : 1;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return ImageFiltered(
      imageFilter: _downsampledBlurFilter(blur),
      child: Image.file(
        File(imagePath),
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
        cacheWidth: (viewportWidth * devicePixelRatio / downsample).round(),
      ),
    );
  }

  Widget _backgroundImage(String imagePath) => Image.file(
    File(imagePath),
    fit: BoxFit.cover,
    filterQuality: FilterQuality.medium,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => const SizedBox.shrink(),
  );
}

class _AppShell_Small extends StatefulWidget {
  const _AppShell_Small({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<_AppShell_Small> createState() => _AppShell_SmallState();
}

class _AppShell_SmallState extends State<_AppShell_Small> {
  late Color _backgroundColor;
  late final VoidCallback _onNowPlayingChanged;

  @override
  void initState() {
    super.initState();
    _onNowPlayingChanged = () {
      final newColor = _resolveDynamicColor(Theme.of(context).colorScheme);
      if (newColor != _backgroundColor) {
        setState(() => _backgroundColor = newColor);
      }
    };
    PlayService.instance.playbackService.nowPlayingNotifier.addListener(
      _onNowPlayingChanged,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _backgroundColor = _resolveDynamicColor(Theme.of(context).colorScheme);
  }

  @override
  void dispose() {
    PlayService.instance.playbackService.nowPlayingNotifier.removeListener(
      _onNowPlayingChanged,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.backgroundNotifier,
      builder: (context, _) => _AppBackground(
        fallbackColor: _backgroundColor,
        imagePath: AppSettings.instance.appBackgroundImagePath,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: const PreferredSize(
            preferredSize: Size.fromHeight(48.0),
            child: TitleBar(),
          ),
          drawer: SizedBox(
            width: SideNav.expandedWidth,
            child: SideNav(navigationShell: widget.navigationShell),
          ),
          body: Stack(
            children: [widget.navigationShell, const MiniNowPlaying()],
          ),
        ),
      ),
    );
  }
}

class _AppShell_Large extends StatefulWidget {
  const _AppShell_Large({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<_AppShell_Large> createState() => _AppShell_LargeState();
}

class _AppShell_LargeState extends State<_AppShell_Large> {
  late Color _backgroundColor;
  late final VoidCallback _onNowPlayingChanged;
  late final ValueNotifier<bool> _sidebarExpanded;

  @override
  void initState() {
    super.initState();
    _sidebarExpanded = ValueNotifier(AppPreference.instance.sidebarExpanded);
    _onNowPlayingChanged = () {
      final newColor = _resolveDynamicColor(Theme.of(context).colorScheme);
      if (newColor != _backgroundColor) {
        setState(() => _backgroundColor = newColor);
      }
    };
    PlayService.instance.playbackService.nowPlayingNotifier.addListener(
      _onNowPlayingChanged,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _backgroundColor = _resolveDynamicColor(Theme.of(context).colorScheme);
  }

  @override
  void dispose() {
    PlayService.instance.playbackService.nowPlayingNotifier.removeListener(
      _onNowPlayingChanged,
    );
    _sidebarExpanded.dispose();
    super.dispose();
  }

  void _handleSidebarExpandedChanged(bool expanded) {
    if (_sidebarExpanded.value == expanded) return;
    _sidebarExpanded.value = expanded;
  }

  Widget _railScaffold(double t, Widget rail, Widget body, bool expanded) {
    return SpringRailScaffold(
      progress: t,
      targetProgress: expanded ? 1.0 : 0.0,
      collapsedWidth: SideNav.collapsedWidth,
      expandedWidth: SideNav.expandedWidth,
      rail: rail,
      body: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.backgroundNotifier,
      builder: (context, _) => _AppBackground(
        fallbackColor: _backgroundColor,
        imagePath: AppSettings.instance.appBackgroundImagePath,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: const PreferredSize(
            preferredSize: Size.fromHeight(48.0),
            child: TitleBar(),
          ),
          body: ValueListenableBuilder<bool>(
            valueListenable: _sidebarExpanded,
            builder: (context, expanded, pages) {
              return TweenAnimationBuilder<double>(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : MotionDuration.sidebar,
                curve: MotionCurve.sidebar,
                tween: Tween<double>(end: expanded ? 1.0 : 0.0),
                builder: (context, t, rail) =>
                    _railScaffold(t, rail!, pages!, expanded),
                child: ClipRect(
                  child: SideNav(
                    navigationShell: widget.navigationShell,
                    onExpandedChanged: _handleSidebarExpandedChanged,
                  ),
                ),
              );
            },
            child: RepaintBoundary(
              child: Stack(
                children: [widget.navigationShell, const MiniNowPlaying()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

