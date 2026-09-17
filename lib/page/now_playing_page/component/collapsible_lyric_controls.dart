import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';

class CollapsibleLyricControls extends StatefulWidget {
  const CollapsibleLyricControls({super.key});

  @override
  State<CollapsibleLyricControls> createState() =>
      _CollapsibleLyricControlsState();
}

class _CollapsibleLyricControlsState extends State<CollapsibleLyricControls>
    with SingleTickerProviderStateMixin {
  bool _isExpanded = false;
  bool _showControls = false;
  bool _reduceMotion = false;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: MotionDuration.base,
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: MotionCurve.emphasized,
    );
    _slideAnimation = Tween<double>(begin: 8.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: MotionCurve.entrance,
      ),
    );
    _animationController.addStatusListener(_handleAnimationStatus);
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion && !_reduceMotion) {
      _animationController
        ..stop()
        ..value = _isExpanded ? 1.0 : 0.0;
      _showControls = _isExpanded;
    }
    _reduceMotion = reduceMotion;
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed ||
        _isExpanded ||
        !_showControls ||
        !mounted) {
      return;
    }
    setState(() => _showControls = false);
  }

  void _toggleExpanded() {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _showControls = true;
        if (reduceMotion) {
          _animationController
            ..stop()
            ..value = 1.0;
        } else {
          _animationController.forward();
        }
      } else if (reduceMotion) {
        _animationController
          ..stop()
          ..value = 0.0;
        _showControls = false;
      } else {
        _animationController.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    const radius = 28.0;

    return Container(
      constraints: const BoxConstraints(maxHeight: 500),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (_showControls) ...[
                  AnimatedBuilder(
                    animation: _animationController,
                    builder: (context, child) {
                      return Opacity(
                        opacity: _fadeAnimation.value,
                        child: Transform.translate(
                          offset: Offset(0, _slideAnimation.value),
                          filterQuality: FilterQuality.low,
                          child: const LyricViewControls(),
                        ),
                      );
                    },
                  ),
                ],
                IconButton(
                  tooltip: _isExpanded ? '收起设置' : '歌词设置',
                  onPressed: _toggleExpanded,
                  color: scheme.onSecondaryContainer,
                  icon: AnimatedRotation(
                    turns: _isExpanded ? 0.5 : 0,
                    duration: reduceMotion
                        ? Duration.zero
                        : MotionDuration.base,
                    curve: MotionCurve.emphasized,
                    child: const Icon(Symbols.expand_more, size: 22),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
