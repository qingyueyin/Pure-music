import 'package:flutter/material.dart';

const nowPlayingOpenCurve = Curves.easeOutCubic;
const nowPlayingCloseCurve = Curves.easeInCubic;

class NowPlayingBarBounds {
  static final barKey = GlobalKey();
  static Rect? captured;

  static Rect? globalRect() {
    final box = barKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  static void capture() {
    captured = globalRect();
  }
}

class NowPlayingOpenTransition extends StatefulWidget {
  const NowPlayingOpenTransition({
    super.key,
    required this.animation,
    required this.motionEnabled,
    required this.child,
  });

  final Animation<double> animation;
  final bool motionEnabled;
  final Widget child;

  @override
  State<NowPlayingOpenTransition> createState() =>
      _NowPlayingOpenTransitionState();
}

class _NowPlayingOpenTransitionState extends State<NowPlayingOpenTransition> {
  Rect? _barRect;
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: widget.animation,
    curve: nowPlayingOpenCurve,
    reverseCurve: nowPlayingCloseCurve,
  );

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.motionEnabled) return widget.child;
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, child) {
        if (widget.animation.status == AnimationStatus.completed) {
          return child!;
        }
        _barRect ??=
            NowPlayingBarBounds.captured ?? NowPlayingBarBounds.globalRect();
        final bar = _barRect;
        final box = context.findRenderObject() as RenderBox?;
        if (bar == null || box == null || !box.hasSize || !box.attached) {
          return _NowPlayingFadeSlide(animation: widget.animation, child: child!);
        }
        final full = Offset.zero & box.size;
        final begin = Rect.fromPoints(
          box.globalToLocal(bar.topLeft),
          box.globalToLocal(bar.bottomRight),
        );
        final t = _curved.value;
        final rect = Rect.lerp(begin, full, t)!;
        final radius = 8.0 * (1 - t);
        // 内容从 18% 进度开始渐显、72% 收尾，全程能看见内容随卡片放大揭开；
        // 阴影独立于内容透明度，从头就有，卡片始终有浮起感。
        final veil = const Interval(
          0.18,
          0.72,
          curve: Curves.easeOutCubic,
        ).transform(t);
        final scheme = Theme.of(context).colorScheme;
        final shade = (1 - t).clamp(0.0, 1.0);
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            Positioned.fromRect(
              rect: rect,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(radius),
                  // 两层近似材质 elevation 4：贴边小阴影保边缘层次，
                  // 大软阴影给悬浮感；中层阴影贡献最小，省掉它的模糊。
                  boxShadow: [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: 0.20 * shade),
                      offset: const Offset(0.0, 2.0),
                      blurRadius: 4.0,
                      spreadRadius: -1.0,
                    ),
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: 0.14 * shade),
                      offset: const Offset(0.0, 4.0),
                      blurRadius: 10.0,
                    ),
                  ],
                ),
              ),
            ),
            // ClipRRect 走 Skia 的解析式圆角裁剪；ClipPath 走抗锯齿路径裁剪，
            // 大窗口下要额外开遮罩层。
            ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: Opacity(opacity: veil, child: child!),
            ),
          ],
        );
      },
      child: widget.child,
    );
  }
}

class _NowPlayingFadeSlide extends StatefulWidget {
  const _NowPlayingFadeSlide({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  State<_NowPlayingFadeSlide> createState() => _NowPlayingFadeSlideState();
}

class _NowPlayingFadeSlideState extends State<_NowPlayingFadeSlide> {
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: widget.animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slide = Tween<Offset>(
      begin: const Offset(0.0, 0.06),
      end: Offset.zero,
    ).animate(_curved);
    return FadeTransition(
      opacity: _curved,
      child: SlideTransition(position: slide, child: widget.child),
    );
  }
}
