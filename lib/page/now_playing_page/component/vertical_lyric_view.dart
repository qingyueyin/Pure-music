import 'dart:async';
import 'dart:math';

import 'package:pure_music/core/interlude_detector.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_tile.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_viewport_strategy.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/widget/breathing_dots.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

bool alwaysShowLyricViewControls = false;

enum LyricScrollState {
  idle,
  userDragging,
  programScrolling,
}

class VerticalLyricView extends StatefulWidget {
  const VerticalLyricView({
    super.key,
    this.showControls = true,
    this.enableSeekOnTap = true,
    this.centerVertically = true,
  });

  final bool showControls;
  final bool enableSeekOnTap;
  final bool centerVertically;

  @override
  State<VerticalLyricView> createState() => _VerticalLyricViewState();
}

class _VerticalLyricViewState extends State<VerticalLyricView> {
  bool isHovering = false;
  final lyricViewController = LyricViewController.instance;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    const loadingWidget = Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(),
      ),
    );

    return MouseRegion(
      onEnter: (_) {
        setState(() {
          isHovering = true;
        });
      },
      onExit: (_) {
        setState(() {
          isHovering = false;
        });
      },
      child: Material(
        type: MaterialType.transparency,
        child: ScrollConfiguration(
          behavior: const ScrollBehavior().copyWith(scrollbars: false),
          child: ChangeNotifierProvider.value(
            value: lyricViewController,
            child: ListenableBuilder(
              listenable: PlayService.instance.lyricService,
              builder: (context, _) => FutureBuilder(
                future: PlayService.instance.lyricService.currLyricFuture,
                builder: (context, snapshot) {
                  final lyricNullable = snapshot.data;
                  final noLyricWidget = Center(
                    child: Text(
                      "无歌词",
                      style: TextStyle(
                        fontSize: 22,
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  );

                  return Stack(
                    children: [
                      switch (snapshot.connectionState) {
                        ConnectionState.none => loadingWidget,
                        ConnectionState.waiting => loadingWidget,
                        ConnectionState.active => loadingWidget,
                        ConnectionState.done => lyricNullable == null
                            ? noLyricWidget
                            : _VerticalLyricScrollView(
                                lyric: lyricNullable,
                                enableSeekOnTap: widget.enableSeekOnTap,
                                centerVertically: widget.centerVertically,
                              ),
                      },
                      if (widget.showControls &&
                          (isHovering || alwaysShowLyricViewControls))
                        const Align(
                          alignment: Alignment.bottomRight,
                          child: LyricViewControls(),
                        )
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VerticalLyricScrollView extends StatefulWidget {
  const _VerticalLyricScrollView({
    required this.lyric,
    required this.enableSeekOnTap,
    required this.centerVertically,
  });

  final Lyric lyric;
  final bool enableSeekOnTap;
  final bool centerVertically;

  @override
  State<_VerticalLyricScrollView> createState() =>
      _VerticalLyricScrollViewState();
}

class _VerticalLyricScrollViewState extends State<_VerticalLyricScrollView>
    with SingleTickerProviderStateMixin {
  final playbackService = PlayService.instance.playbackService;
  final lyricService = PlayService.instance.lyricService;
  late StreamSubscription lyricLineStreamSubscription;
  final scrollController = ScrollController();
  LyricViewController? _lyricViewController;
  Timer? _ensureVisibleTimer;
  Timer? _userScrollHoldTimer;
  Timer? _afterScrollRetryTimer;
  Timer? _sizeChangeTimer;
  LyricScrollState _scrollState = LyricScrollState.idle;
  int _mainLine = 0;
  int _pendingScrollRetries = 0;
  bool _isInInterlude = false;
  LyricViewportRange _viewportRange =
      const LyricViewportRange(start: 0, end: 0);
  late AnimationController _interludeFadeController;
  late AnimationController _interludeDotsController;
  late Animation<double> _interludeFadeAnimation;

  /// 用来定位到当前歌词
  final currentLyricTileKey = GlobalKey();

  List<double>? _cachedOffsets;
  List<double>? _cachedHeights; // Store heights to center current line
  double _cachedMaxWidth = 0.0;

  @override
  void initState() {
    super.initState();

    _interludeFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _interludeDotsController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _interludeFadeAnimation = CurvedAnimation(
      parent: _interludeFadeController,
      curve: Curves.easeInOut,
    );

    _initLyricView();
    lyricLineStreamSubscription =
        lyricService.lyricLineStream.listen(_updateNextLyricLine);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      lyricService.findCurrLyricLineAt(playbackService.position);
    });
  }

  void _computeOffsets(double maxWidth) {
    if (maxWidth <= 0) return;

    // Get style config
    final controller = context.read<LyricViewController>();
    final config = controller.renderConfig;
    final baseSize = config.baseFontSize;
    final showTrans = config.showTranslation;
    final showRoman = config.showRoman;
    final weight = config.fontWeight;
    final primaryHeight = config.primaryLineHeight(weight);
    final translationHeight = config.translationLineHeight(weight);
    final letterSpacing =
        config.letterSpacing(fontSize: baseSize, weight: weight);
    final discreteWeight = config.discreteFontWeight(weight);

    final subSize = config.primaryFontSize(isMainLine: false);
    final subTransSize = config.translationFontSize(isMainLine: false);
    final mainSize = config.primaryFontSize(isMainLine: true);
    final mainTransSize = config.translationFontSize(isMainLine: true);

    final painter = TextPainter(textDirection: TextDirection.ltr);

    double measureLine(LyricLine line, bool isMain) {
      // Check for TransitionTile condition
      if (isMain) {
        if (line is SyncLyricLine) {
          if (line.words.isEmpty && line.length > const Duration(seconds: 5)) {
            return 40.0;
          }
        } else if (line is LrcLine) {
          if (line.isBlank && line.length > const Duration(seconds: 5)) {
            return 40.0;
          }
        }
      }

      // Check for empty/shrink condition
      if (line is SyncLyricLine) {
        if (line.words.isEmpty) return 0.0;
      } else if (line is LrcLine) {
        if (line.isBlank) return 0.0;
      }

      final primarySize = isMain ? mainSize : subSize;
      final transSize = isMain ? mainTransSize : subTransSize;
      // LyricViewTile has an outer horizontal padding (12 * 2) and most
      // content blocks also have an inner horizontal padding (12 * 2).
      final contentWidth = maxWidth - 48.0;

      double h = 0.0;

      // Determine vertical padding based on line type
      final double vertPad;
      if (line is SyncLyricLine) {
        vertPad = config.syncVerticalPadding(isMainLine: isMain);
      } else {
        vertPad = config.lrcVerticalPadding();
      }

      // Primary text
      String text = "";
      if (line is SyncLyricLine) {
        text = line.content;
      } else if (line is LrcLine) {
        text = line.content.split("┃").first;
      }

      painter.text = TextSpan(
        text: text,
        style: TextStyle(
          fontSize: primarySize,
          fontVariations: [FontVariation('wght', weight.toDouble())],
          fontWeight: discreteWeight,
          height: primaryHeight,
          letterSpacing: letterSpacing,
        ),
      );
      painter.layout(maxWidth: contentWidth);
      h += painter.height;

      // Translation
      if (showTrans) {
        if (line is SyncLyricLine && line.translation != null) {
          h += config.syncTranslationGap(isMainLine: isMain);
          painter.text = TextSpan(
            text: line.translation!,
            style: TextStyle(
              fontSize: transSize,
              fontVariations: [
                FontVariation('wght', (weight - 50).clamp(100, 900).toDouble())
              ],
              fontWeight: FontWeight.values[
                  (((weight - 50).clamp(100, 900) / 100).round() - 1)
                      .clamp(0, 8)],
              height: translationHeight,
              letterSpacing: letterSpacing,
            ),
          );
          painter.layout(maxWidth: contentWidth);
          h += painter.height;
        } else if (line is LrcLine) {
          final parts = line.content.split("┃");
          for (int i = 1; i < parts.length; i++) {
            h += config.lrcTranslationGap(
              isMainLine: isMain,
              translationIndex: i - 1,
            );
            painter.text = TextSpan(
              text: parts[i],
              style: TextStyle(
                fontSize: transSize,
                fontVariations: [
                  FontVariation(
                    'wght',
                    (weight - 50).clamp(100, 900).toDouble(),
                  )
                ],
                fontWeight: FontWeight.values[
                    (((weight - 50).clamp(100, 900) / 100).round() - 1)
                        .clamp(0, 8)],
                height: translationHeight,
                letterSpacing: letterSpacing,
              ),
            );
            painter.layout(maxWidth: contentWidth);
            h += painter.height;
          }
        }
      }

      // Romanization
      if (showRoman) {
        String? roman;
        if (line is SyncLyricLine) {
          roman = line.romanLyric;
        } else if (line is LrcLine) {
          roman = line.romanLyric;
        }

        if (roman != null && roman.isNotEmpty) {
          h += 4.0;

          final romanWeight = (weight - 150).clamp(100, 900);
          painter.text = TextSpan(
            text: roman,
            style: TextStyle(
              fontSize: transSize * 0.85,
              fontVariations: [FontVariation('wght', romanWeight.toDouble())],
              fontWeight: FontWeight
                  .values[(((romanWeight / 100).round() - 1).clamp(0, 8))],
              height: translationHeight,
              letterSpacing: letterSpacing,
            ),
          );
          painter.layout(maxWidth: contentWidth);
          h += painter.height;
        }
      }

      // Vertical padding (top + bottom)
      h += vertPad * 2;
      return h;
    }

    final offsets = <double>[];
    final heights = <double>[];
    double currentOffset = 0.0;

    for (int i = 0; i < widget.lyric.lines.length; i++) {
      offsets.add(currentOffset);
      // We assume all previous lines are NOT main lines (sub style)
      // The current line will be rendered as Main, but for offset calculation of *next* lines,
      // this line (when it becomes previous) will be Sub.
      // So cachedOffsets[i] represents the top position of line i.

      // We also need the height of line i IF it is Main, to center it.
      final hAsMain = measureLine(widget.lyric.lines[i], true);
      heights.add(hAsMain);

      // Advance offset by its Sub height (for next items)
      final hAsSub = measureLine(widget.lyric.lines[i], false);
      currentOffset += hAsSub;
    }

    _cachedOffsets = offsets;
    _cachedHeights = heights;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<LyricViewController>();
    if (_lyricViewController == controller) return;

    _lyricViewController?.removeListener(_scheduleEnsureCurrentVisible);
    _lyricViewController = controller;
    _lyricViewController?.addListener(_scheduleEnsureCurrentVisible);

    // Clear cache to recompute on next layout (font size might change)
    _cachedMaxWidth = 0.0;
    _cachedOffsets = null;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToCurrent(const Duration(milliseconds: 100));
    });
  }

  void _scheduleEnsureCurrentVisible() {
    _cachedMaxWidth = 0.0; // Force recompute
    _ensureVisibleTimer?.cancel();
    _ensureVisibleTimer = Timer(const Duration(milliseconds: 60), () {
      if (!mounted) return;
      if (mounted) setState(() {}); // Trigger rebuild to recompute
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    });
  }

  void _animateTo(double targetOffset, {Duration? duration}) {
    if (!scrollController.hasClients) return;
    final minExtent = scrollController.position.minScrollExtent;
    final maxExtent = scrollController.position.maxScrollExtent;
    final to = targetOffset.clamp(minExtent, maxExtent);

    if (duration != null && duration.inMilliseconds <= 16) {
      scrollController.jumpTo(to);
      if (_scrollState == LyricScrollState.programScrolling) {
        _scrollState = LyricScrollState.idle;
      }
      return;
    }

    final from = scrollController.offset;
    final dist = (to - from).abs();
    if (dist < 0.5) {
      if (_scrollState == LyricScrollState.programScrolling) {
        _scrollState = LyricScrollState.idle;
      }
      return;
    }

    final computed = duration ??
        Duration(
          milliseconds: (280 + dist * 0.22).round().clamp(320, 650),
        );
    scrollController
        .animateTo(to, duration: computed, curve: Curves.easeOutQuart)
        .then((_) {
      if (_scrollState == LyricScrollState.programScrolling) {
        _scrollState = LyricScrollState.idle;
      }
    });
  }

  void _markUserScrolling() {
    final renderConfig = context.read<LyricViewController>().renderConfig;
    final viewportStrategy = LyricViewportStrategy(
      leadingLines: renderConfig.viewportLeadingLines,
      trailingLines: renderConfig.viewportTrailingLines,
      overscanScreens: renderConfig.viewportOverscanScreens,
      userScrollHoldDuration: renderConfig.userScrollHoldDuration,
    );
    _userScrollHoldTimer?.cancel();
    _scrollState = LyricScrollState.userDragging;
    _userScrollHoldTimer = Timer(viewportStrategy.userScrollHoldDuration, () {
      if (!mounted) return;
      _scrollState = LyricScrollState.idle;
      _updateViewportRange(force: true);
      _scrollToCurrent();
    });
  }

  void _updateViewportRange({bool force = false}) {
    final renderConfig = context.read<LyricViewController>().renderConfig;
    final viewportStrategy = LyricViewportStrategy(
      leadingLines: renderConfig.viewportLeadingLines,
      trailingLines: renderConfig.viewportTrailingLines,
      overscanScreens: renderConfig.viewportOverscanScreens,
      userScrollHoldDuration: renderConfig.userScrollHoldDuration,
    );
    if (!force && !viewportStrategy.shouldRealign(_viewportRange, _mainLine)) {
      return;
    }
    _viewportRange = viewportStrategy.rangeForMainLine(
      mainLine: _mainLine,
      totalLines: widget.lyric.lines.length,
    );
  }

  void _scrollToCurrent([Duration? duration]) {
    if (_scrollState == LyricScrollState.userDragging) return;
    if (!scrollController.hasClients) {
      if (_pendingScrollRetries < 4) {
        _pendingScrollRetries++;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _scrollToCurrent(duration);
        });
      }
      return;
    }
    _pendingScrollRetries = 0;

    _scrollState = LyricScrollState.programScrolling;

    // 1. Try to use the actual rendered object (most accurate)
    final targetContext = currentLyricTileKey.currentContext;
    if (targetContext != null && targetContext.mounted) {
      final targetObject = targetContext.findRenderObject();
      if (targetObject is RenderBox) {
        final viewport = RenderAbstractViewport.of(targetObject);
        final alignment = widget.centerVertically ? 0.5 : 0.25;
        final revealed = viewport.getOffsetToReveal(targetObject, alignment);
        _animateTo(revealed.offset, duration: duration);
        return;
      }
    }

    // 2. Fallback to cached offsets (approximation)
    if (_cachedOffsets != null &&
        _cachedHeights != null &&
        _mainLine < _cachedOffsets!.length) {
      final viewport = scrollController.position.viewportDimension;
      final spacer = widget.centerVertically ? viewport / 2.0 : 0.0;
      final alignment = widget.centerVertically ? 0.5 : 0.25;

      final lineTop = _cachedOffsets![_mainLine];
      final lineHeight = _cachedHeights![_mainLine];

      final targetScrollOffset =
          (spacer + lineTop + lineHeight / 2) - (viewport * alignment);

      _animateTo(targetScrollOffset, duration: duration);
      _afterScrollRetryTimer?.cancel();
      _afterScrollRetryTimer = Timer(const Duration(milliseconds: 220), () {
        if (!mounted) return;
        _scrollToCurrent(const Duration(milliseconds: 180));
      });
      return;
    }
  }

  void _initLyricView() {
    final next = widget.lyric.lines.indexWhere(
      (element) =>
          element.start.inMilliseconds / 1000 > playbackService.position,
    );
    final nextLyricLine = next == -1 ? widget.lyric.lines.length : next;
    _mainLine = max(nextLyricLine - 1, 0);
    _updateViewportRange(force: true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrent(const Duration(milliseconds: 320));
    });
  }

  void _seekToLyricLine(int i) {
    playbackService.seek(widget.lyric.lines[i].start.inMilliseconds / 1000);
    setState(() {
      _mainLine = i;
      _updateViewportRange(force: true);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrent();
    });
  }

  void _updateNextLyricLine(int lyricLine) {
    if (_mainLine == lyricLine) {
      _checkInterlude();
      return;
    }

    final renderConfig = context.read<LyricViewController>().renderConfig;
    final viewportStrategy = LyricViewportStrategy(
      leadingLines: renderConfig.viewportLeadingLines,
      trailingLines: renderConfig.viewportTrailingLines,
      overscanScreens: renderConfig.viewportOverscanScreens,
      userScrollHoldDuration: renderConfig.userScrollHoldDuration,
    );
    final followDecision = viewportStrategy.followDecision(
      currentRange: _viewportRange,
      nextMainLine: lyricLine,
      totalLines: widget.lyric.lines.length,
    );

    setState(() {
      _mainLine = lyricLine;
      _viewportRange = followDecision.nextRange;
    });

    _checkInterlude();

    if (followDecision.shouldScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrent();
      });
    }
  }

  void _checkInterlude() {
    final wasInInterlude = _isInInterlude;
    _isInInterlude = InterludeDetector.isInInterlude(
      widget.lyric,
      Duration(milliseconds: (playbackService.position * 1000).round()),
    );

    if (_isInInterlude && !wasInInterlude) {
      _interludeFadeController.forward();
    } else if (!_isInInterlude && wasInInterlude) {
      _interludeFadeController.reverse();
    }
  }

  void _onInterludeTap() {
    final nextTime = InterludeDetector.getNextLyricTime(
      widget.lyric,
      Duration(milliseconds: (playbackService.position * 1000).round()),
    );
    if (nextTime != null) {
      playbackService.seek(nextTime.inMilliseconds / 1000);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final renderConfig = context.watch<LyricViewController>().renderConfig;
    final viewportStrategy = LyricViewportStrategy(
      leadingLines: renderConfig.viewportLeadingLines,
      trailingLines: renderConfig.viewportTrailingLines,
      overscanScreens: renderConfig.viewportOverscanScreens,
      userScrollHoldDuration: renderConfig.userScrollHoldDuration,
    );
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth != _cachedMaxWidth) {
        _cachedMaxWidth = constraints.maxWidth;
        _computeOffsets(constraints.maxWidth);
      }

      final spacerHeight = constraints.maxHeight / 2.0;
      return Stack(
        children: [
          RepaintBoundary(
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) {
                return LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: const [
                    Colors.transparent,
                    Colors.white,
                    Colors.white,
                    Colors.transparent,
                  ],
                  stops: renderConfig.viewportMaskStops(),
                ).createShader(bounds);
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is ScrollStartNotification &&
                      notification.dragDetails != null) {
                    _markUserScrolling();
                  } else if (notification is ScrollUpdateNotification &&
                      notification.dragDetails != null) {
                    _markUserScrolling();
                  }
                  return false;
                },
                child: ListView.builder(
                  key: ValueKey(widget.lyric.hashCode),
                  controller: scrollController,
                  cacheExtent:
                      viewportStrategy.cacheExtent(constraints.maxHeight),
                  padding: EdgeInsets.symmetric(
                    vertical: widget.centerVertically ? spacerHeight : 0,
                  ),
                  itemCount: widget.lyric.lines.length,
                  itemBuilder: (context, i) {
                    final dist = (i - _mainLine).abs();
                    final opacity = dist == 0
                        ? 1.0
                        : pow(0.72, dist).toDouble().clamp(0.16, 0.78);
                    return LyricViewTile(
                      key: dist == 0 ? currentLyricTileKey : null,
                      line: widget.lyric.lines[i],
                      opacity: opacity,
                      distance: dist,
                      onTap: widget.enableSeekOnTap
                          ? () => _seekToLyricLine(i)
                          : null,
                    );
                  },
                ),
              ),
            ),
          ),
          if (_scrollState == LyricScrollState.userDragging)
            Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '拖动歌词查看，松开后自动回到当前行',
                    style: TextStyle(
                      color: scheme.onSecondaryContainer,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          if (_isInInterlude)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: 0,
              child: Center(
                child: FadeTransition(
                  opacity: _interludeFadeAnimation,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 30, vertical: 20),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '间奏',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                        const SizedBox(height: 12),
                        BreathingDots(
                          key: const ValueKey('interlude_breathing_dots'),
                          dotSize: 10,
                          dotColor: Colors.white,
                          breathDuration: const Duration(seconds: 2),
                          controller: _interludeDotsController,
                          onTap: _onInterludeTap,
                        ),
                        Builder(builder: (context) {
                          final remaining =
                              InterludeDetector.getInterludeRemaining(
                            widget.lyric,
                            Duration(
                                milliseconds:
                                    (playbackService.position * 1000).round()),
                          ).inSeconds;
                          if (remaining > 0) {
                            return Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                '剩余 $remaining 秒',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  fontSize: 12,
                                ),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        }),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }

  @override
  void dispose() {
    super.dispose();
    _ensureVisibleTimer?.cancel();
    _userScrollHoldTimer?.cancel();
    _afterScrollRetryTimer?.cancel();
    _sizeChangeTimer?.cancel();
    _lyricViewController?.removeListener(_scheduleEnsureCurrentVisible);
    lyricLineStreamSubscription.cancel();
    scrollController.dispose();
    _interludeFadeController.dispose();
    _interludeDotsController.dispose();
  }
}
