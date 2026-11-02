import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/transition_snapshot.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/now_playing_overlay_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/page/now_playing_page/now_playing_visibility.dart';

class NowPlayingRouterHost extends StatefulWidget {
  const NowPlayingRouterHost({
    super.key,
    required this.child,
    required this.router,
    required this.page,
  });

  final Widget child;
  final GoRouter router;
  final Widget page;

  @override
  State<NowPlayingRouterHost> createState() => _NowPlayingRouterHostState();
}

class _NowPlayingRouterHostState extends State<NowPlayingRouterHost> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    widget.router.routerDelegate.addListener(_readRoute);
    _visible = _isNowPlaying(widget.router);
  }

  @override
  void didUpdateWidget(covariant NowPlayingRouterHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.router, widget.router)) return;
    oldWidget.router.routerDelegate.removeListener(_readRoute);
    widget.router.routerDelegate.addListener(_readRoute);
    _readRoute();
  }

  bool _isNowPlaying(GoRouter router) {
    final configuration = router.routerDelegate.currentConfiguration;
    if (configuration.isEmpty) return false;
    return configuration.uri.path == app_paths.NOW_PLAYING_PAGE;
  }

  void _readRoute() {
    final visible = _isNowPlaying(widget.router);
    if (visible == _visible) return;
    // 路由 delegate 正在通知期间直接 setState 会重入 build，导致卡死。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final next = _isNowPlaying(widget.router);
      if (next != _visible) {
        setState(() => _visible = next);
      }
    });
  }

  @override
  void dispose() {
    widget.router.routerDelegate.removeListener(_readRoute);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NowPlayingSessionHost(
      visible: _visible,
      page: widget.page,
      child: widget.child,
    );
  }
}

class NowPlayingSessionHost extends StatefulWidget {
  const NowPlayingSessionHost({
    super.key,
    required this.visible,
    required this.child,
    required this.page,
  });

  final bool visible;
  final Widget child;
  final Widget page;

  @override
  State<NowPlayingSessionHost> createState() => _NowPlayingSessionHostState();
}

class _NowPlayingSessionHostState extends State<NowPlayingSessionHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;
  late final Animation<double> _libraryFade;
  bool _opened = false;
  bool _dormant = true;
  bool _libraryDormant = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: MotionDuration.medium,
      reverseDuration: MotionDuration.medium,
    );
    _curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _libraryFade = Tween<double>(begin: 1, end: 0).animate(_curved);
    _controller.addStatusListener(_onMotionStatus);
    if (widget.visible) {
      _opened = true;
      _dormant = false;
      _libraryDormant = true;
      nowPlayingOverlayShown.value = true;
      _controller.value = 1;
    }
  }

  void _onMotionStatus(AnimationStatus _) {
    if (!mounted) return;
    final libraryDormant =
        widget.visible && _controller.status == AnimationStatus.completed;
    nowPlayingOverlayShown.value = libraryDormant;
    setState(() => _libraryDormant = libraryDormant);
  }

  @override
  void didUpdateWidget(covariant NowPlayingSessionHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      _syncVisibility();
    }
  }

  bool get _motionEnabled {
    return AppSettings.instance.enableContentTransitionMotion &&
        !MediaQuery.disableAnimationsOf(context);
  }

  void _syncVisibility() {
    if (widget.visible) {
      _opened = true;
      if (_dormant) setState(() => _dormant = false);
      if (_libraryDormant) setState(() => _libraryDormant = false);
      nowPlayingOverlayShown.value = false;
      if (!_motionEnabled) {
        _controller.value = 1;
        setState(() => _libraryDormant = true);
        nowPlayingOverlayShown.value = true;
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.visible) return;
        _controller.forward();
      });
      return;
    }
    if (!_opened) return;
    if (_libraryDormant) setState(() => _libraryDormant = false);
    nowPlayingOverlayShown.value = false;
    void coverThenSleep() {
      if (!mounted || widget.visible) return;
      setState(() => _dormant = true);
    }

    if (!_motionEnabled) {
      _controller.value = 0;
      coverThenSleep();
      return;
    }
    _controller.reverse().whenComplete(coverThenSleep);
  }

  @override
  void dispose() {
    nowPlayingOverlayShown.value = false;
    _controller.removeStatusListener(_onMotionStatus);
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final libraryFreezing = widget.visible || _controller.isAnimating;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_opened)
          NowPlayingVisibility(
            shown: !_dormant,
            child: TickerMode(
              enabled: !_dormant,
              child: Offstage(
                offstage: _dormant,
                child: IgnorePointer(
                  ignoring: !widget.visible,
                  child: widget.page,
                ),
              ),
            ),
          ),
        Offstage(
          offstage: _libraryDormant,
          child: IgnorePointer(
            ignoring: widget.visible,
            child: FadeTransition(
              opacity: _libraryFade,
              child: TransitionSnapshot(
                freezing: libraryFreezing,
                child: widget.child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
