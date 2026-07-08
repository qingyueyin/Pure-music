import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/route_visibility.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/collapsible_lyric_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_viewport_strategy.dart';
import 'package:pure_music/page/now_playing_page/component/value_transition.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

const _opacityBase = 0.88;
const _opacityMinClamp = 0.30;
const _opacityMaxClamp = 0.90;
const _staggerBaseMs = 60;
const _staggerMaxMs = 600;
const _shaderFadeInWithBlur = 0.05;
const _shaderFadeInWithoutBlur = 0.05;
const _shaderFadeOutWithBlur = 0.80;
const _shaderFadeOutWithoutBlur = 0.95;
const _lyricOffsetCacheCapacity = 6;

bool alwaysShowLyricViewControls = false;

class _LyricOffsetCacheKey {
  const _LyricOffsetCacheKey({
    required this.lyric,
    required this.widthPx,
    required this.config,
  });

  final Lyric lyric;
  final int widthPx;
  final LyricRenderConfig config;

  @override
  bool operator ==(Object other) {
    return other is _LyricOffsetCacheKey &&
        identical(other.lyric, lyric) &&
        other.widthPx == widthPx &&
        other.config == config;
  }

  @override
  int get hashCode => Object.hash(identityHashCode(lyric), widthPx, config);
}

class _LyricOffsetCacheEntry {
  const _LyricOffsetCacheEntry({
    required this.offsets,
    required this.heights,
  });

  final List<double> offsets;
  final List<double> heights;
}

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
    this.currentLineAlignment = 0.35,
    this.enableEdgeSpacer = false,
  });

  final bool showControls;
  final bool enableSeekOnTap;
  final bool centerVertically;
  final double currentLineAlignment;
  final bool enableEdgeSpacer;

  @override
  State<VerticalLyricView> createState() => _VerticalLyricViewState();
}

class _VerticalLyricViewState extends State<VerticalLyricView>
    with AutomaticKeepAliveClientMixin {
  bool isHovering = false;
  final lyricViewController = LyricViewController.instance;

  /// 仅当正在播放且有歌词时保持存活，避免无歌词时占用内存
  @override
  bool get wantKeepAlive {
    final playing = PlayService.instance.playbackService.nowPlaying != null;
    final hasLyric = PlayService.instance.lyricService.hasLyric;
    return playing && hasLyric;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
              listenable: Listenable.merge([
                PlayService.instance.lyricService,
                lyricViewController,
              ]),
              builder: (context, _) => FutureBuilder(
                key:
                    ValueKey(PlayService.instance.lyricService.currLyricFuture),
                future: PlayService.instance.lyricService.currLyricFuture,
                builder: (context, snapshot) {
                  final lyricNullable = snapshot.data;
                  final scheme = Theme.of(context).colorScheme;
                  final noLyricWidget = Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '无歌词',
                          style: TextStyle(fontSize: 22),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '试试右下角菜单切换网络来源',
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
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
                                currentLineAlignment:
                                    widget.currentLineAlignment,
                                enableEdgeSpacer: widget.enableEdgeSpacer,
                              ),
                      },
                      if (widget.showControls &&
                          (isHovering || alwaysShowLyricViewControls))
                        const Align(
                          key: ValueKey('lyric_controls'),
                          alignment: Alignment.bottomRight,
                          child: CollapsibleLyricControls(),
                        ),
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
    required this.currentLineAlignment,
    required this.enableEdgeSpacer,
  });

  final Lyric lyric;
  final bool enableSeekOnTap;
  final bool centerVertically;
  final double currentLineAlignment;
  final bool enableEdgeSpacer;

  @override
  State<_VerticalLyricScrollView> createState() =>
      _VerticalLyricScrollViewState();
}

class _VerticalLyricScrollViewState extends State<_VerticalLyricScrollView>
    with TickerProviderStateMixin, RouteAware {
  static final LinkedHashMap<_LyricOffsetCacheKey, _LyricOffsetCacheEntry>
      _offsetCache = LinkedHashMap();

  final playbackService = PlayService.instance.playbackService;
  final lyricService = PlayService.instance.lyricService;
  late StreamSubscription lyricLineStreamSubscription;
  Timer? _positionResyncTimer;
  Timer? _positionResyncStopTimer;
  Timer? _playbackResyncTimer;
  final scrollController = ScrollController();
  LyricViewController? _lyricViewController;
  PageRoute<dynamic>? _route;
  late final VoidCallback _playbackResyncListener;
  bool _disposed = false;
  Timer? _ensureVisibleTimer;
  Timer? _userScrollHoldTimer;
  Timer? _sizeChangeTimer;
  Timer? _idleCleanupTimer; // 空闲清理定时器
  DateTime _lastActivityTime = DateTime.now(); // 最后活动时间
  bool _didIdleCleanup = false;
  LyricScrollState _scrollState = LyricScrollState.idle;
  int _mainLine = 0;

  /// TTML 重叠行的额外透明度 boost，不决定“当前高亮行”。
  /// 唯一当前行来源是 [_mainLine]。
  final Set<int> _activeLines = {};
  int _pendingScrollRetries = 0;
  static const int _maxPendingScrollRetries = 90;
  LyricViewportRange _viewportRange =
      const LyricViewportRange(start: 0, end: 0);

  /// 标记是否需要执行首次进入页面时的定位滚动。
  /// forceEmitCurrentLine 与 _scrollToCurrent 不在同一时机就绪，
  /// 需要在收到歌词行更新后补一次滚动。
  bool _needsInitialScroll = true;
  int _lastPositionResyncMs = 0;
  int _positionResyncExtensionCount = 0;
  static const int _maxPositionResyncExtensions = 5;

  final Map<int, GlobalKey> _lineKeys = {};
  static const int _lineKeyRetainRadius = 4;

  GlobalKey? _keyForLine(int index) {
    if ((index - _mainLine).abs() > _lineKeyRetainRadius &&
        !_activeLines.contains(index) &&
        index != _hoveredLineIndex) {
      return null;
    }
    return _lineKeys[index] ??= GlobalKey();
  }

  void _pruneLineKeys() {
    _lineKeys.removeWhere((index, _) =>
        (index - _mainLine).abs() > _lineKeyRetainRadius &&
        !_activeLines.contains(index) &&
        index != _hoveredLineIndex);
  }

  /// 悬停歌词行高亮遮罩
  int _hoveredLineIndex = -1;

  /// ValueTransition 驱动的平滑滚动
  late ValueTransition<double> _scrollTransition;
  Ticker? _scrollTicker;
  bool _scrollTickerActive = false;
  Duration _lastTickElapsed = Duration.zero;

  List<double>? _cachedOffsets;
  List<double>? _cachedHeights;
  double _cachedMaxWidth = 0.0;
  double _cachedViewportHeight = 0.0;
  bool _initialOffsetsComputed = false;

  @override
  void initState() {
    super.initState();
    _scrollTransition = ValueTransition<double>(
      begin: 0,
      interpolator: _sineOutInterpolator,
      duration: const Duration(milliseconds: 300),
    );
    lyricLineStreamSubscription =
        lyricService.lyricLineStream.listen(_updateNextLyricLine);
    _playbackResyncListener = _queuePlaybackResync;
    playbackService.nowPlayingNotifier.addListener(_playbackResyncListener);
    playbackService.playerStateNotifier.addListener(_playbackResyncListener);
    playbackService.positionSyncNotifier.addListener(_playbackResyncListener);
    lyricService.addListener(_playbackResyncListener);
    _startPositionResyncWindow();
    _initLyricView();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      lyricService.forceEmitCurrentLine();
      _syncToPlaybackPosition(duration: Duration.zero);
    });

    // 启动空闲检测
    _idleCleanupTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_disposed && mounted) {
        final idleTime = DateTime.now().difference(_lastActivityTime);
        if (idleTime.inSeconds >= 5 && !_didIdleCleanup) {
          _didIdleCleanup = true;
          LyricsLinePainter.trimPool();
          LyricsLineWidget.clearBlurFilterCache();
        }
      }
    });
  }

  @override
  void activate() {
    super.activate();
    _startPositionResyncWindow();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      _syncToPlaybackPosition(duration: Duration.zero);
    });
  }

  /// 标记活动时间（切歌、滚动、行变化）
  void _markActivity() {
    _lastActivityTime = DateTime.now();
    _didIdleCleanup = false;
  }

  void _queuePlaybackResync() {
    if (_disposed || !mounted) return;
    _needsInitialScroll = true;
    _pendingScrollRetries = 0;
    _startPositionResyncWindow();
    _playbackResyncTimer?.cancel();
    _playbackResyncTimer = Timer(const Duration(milliseconds: 16), () {
      if (_disposed || !mounted) return;
      _syncToPlaybackPosition(duration: Duration.zero);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
        _syncToPlaybackPosition(duration: Duration.zero);
      });
    });
  }

  /// Sine Out 缓动函数
  static double _sineOutInterpolator(double t, double start, double end) {
    return start + (end - start) * sin(t * 3.141592653589793 / 2);
  }

  static Duration _scrollDurationForDistance(double distPx) {
    return Duration(
      milliseconds: ((300.0 + (distPx / 1200.0).clamp(0.0, 1.0) * 200.0))
          .round()
          .clamp(300, 500),
    );
  }

  /// 启动 ValueTransition 驱动的滚动 Ticker
  void _startScrollTicker() {
    if (_scrollTickerActive) return;
    _scrollTicker?.dispose();
    _lastTickElapsed = Duration.zero;
    _scrollTicker = createTicker(_onScrollTick);
    _scrollTicker!.start();
    _scrollTickerActive = true;
  }

  /// 停止滚动 Ticker
  void _stopScrollTicker() {
    _scrollTicker?.stop();
    _scrollTicker?.dispose();
    _scrollTicker = null;
    _scrollTickerActive = false;
  }

  /// 每帧回调: 更新 ValueTransition 并应用滚动位置
  void _onScrollTick(Duration elapsed) {
    if (_disposed || !mounted) return;
    final delta = elapsed - _lastTickElapsed;
    _lastTickElapsed = elapsed;
    _scrollTransition.update(delta);
    if (scrollController.hasClients) {
      scrollController.jumpTo(_scrollTransition.value);
    }
    if (!_scrollTransition.isActive) {
      _stopScrollTicker();
    }
  }

  void _computeOffsets(double maxWidth) {
    if (maxWidth <= 0) return;

    final lines = widget.lyric.lines;

    final controller = context.read<LyricViewController>();
    final config = controller.renderConfig;
    final cacheKey = _LyricOffsetCacheKey(
      lyric: widget.lyric,
      widthPx: maxWidth.round(),
      config: config,
    );
    final cached = _offsetCache.remove(cacheKey);
    if (cached != null) {
      _offsetCache[cacheKey] = cached;
      _cachedOffsets = cached.offsets;
      _cachedHeights = cached.heights;
      _markOffsetsComputed();
      return;
    }

    final baseSize = config.baseFontSize;
    final showTrans = config.showTranslation;
    final showRoman = config.showRoman;
    final weight = config.fontWeight;
    final primaryHeight = config.primaryLineHeight(weight);
    final translationHeight = config.translationLineHeight(weight);
    final letterSpacing =
        config.letterSpacing(fontSize: baseSize, weight: weight);
    final discreteWeight = config.discreteFontWeight(weight);

    final mainSize = config.primaryFontSize(isMainLine: true);
    final mainTransSize = config.translationFontSize(isMainLine: true);

    final painter = LyricsLinePainter.obtainTextPainter();

    double measureLine(LyricLine line, bool isMain) {
      if (isMain) {
        if (line is SyncLyricLine) {
          if (line.words.isEmpty && line.length > const Duration(seconds: 3)) {
            return 40.0;
          }
        } else if (line is LrcLine) {
          if (line.isBlank &&
              line.length > const Duration(seconds: 3) &&
              line.start == Duration.zero) {
            return 40.0;
          }
        }
      }

      if (line is SyncLyricLine) {
        if (line.words.isEmpty) return 0.0;
      } else if (line is LrcLine) {
        if (line.isBlank) return 0.0;
      }

      final primarySize = mainSize;
      final transSize = mainTransSize;
      final contentWidth = maxWidth - 24.0;

      double h = 0.0;

      final double vertPad;
      if (line is SyncLyricLine) {
        vertPad = config.syncVerticalPadding(isMainLine: true);
      } else {
        vertPad = config.lrcVerticalPadding();
      }

      String text = '';
      if (line is SyncLyricLine) {
        text = line.content;
      } else if (line is LrcLine) {
        text = line.content.split('┃').first;
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

      if (showTrans) {
        if (line is SyncLyricLine && line.translation != null) {
          h += config.syncTranslationGap(isMainLine: true);
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
          final parts = line.content.split('┃');
          for (int i = 1; i < parts.length; i++) {
            h += config.lrcTranslationGap(
              isMainLine: true,
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

      h += vertPad * 2;
      return h;
    }

    final offsets = <double>[];
    final heights = <double>[];
    double currentOffset = 0.0;

    for (int i = 0; i < lines.length; i++) {
      offsets.add(currentOffset);
      final hAsMain = measureLine(lines[i], true);
      heights.add(hAsMain);
      final hAsSub = measureLine(lines[i], false);
      currentOffset += hAsSub;
    }

    _cachedOffsets = offsets;
    _cachedHeights = heights;
    _offsetCache[cacheKey] = _LyricOffsetCacheEntry(
      offsets: offsets,
      heights: heights,
    );
    while (_offsetCache.length > _lyricOffsetCacheCapacity) {
      _offsetCache.remove(_offsetCache.keys.first);
    }
    LyricsLinePainter.recycleTextPainter(painter);

    // 首次进入页面时 offsets 可能晚于行号就绪，补一次定位
    if (!_initialOffsetsComputed) {
      _initialOffsetsComputed = true;
      _pendingScrollRetries = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
        _syncToPlaybackPosition(duration: Duration.zero);
      });
    }
  }

  void _markOffsetsComputed() {
    if (_initialOffsetsComputed) return;
    _initialOffsetsComputed = true;
    _pendingScrollRetries = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      _syncToPlaybackPosition(duration: Duration.zero);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route != route) {
      final oldRoute = _route;
      if (oldRoute != null) {
        routeVisibilityObserver.unsubscribe(this);
      }
      _route = route is PageRoute<dynamic> ? route : null;
      final pageRoute = _route;
      if (pageRoute != null) {
        routeVisibilityObserver.subscribe(this, pageRoute);
      }
    }

    final controller = context.read<LyricViewController>();
    if (_lyricViewController == controller) return;

    _lyricViewController?.removeListener(_scheduleEnsureCurrentVisible);
    _lyricViewController = controller;
    _lyricViewController?.addListener(_scheduleEnsureCurrentVisible);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncToPlaybackPosition(duration: Duration.zero);
    });
  }

  void _syncWhenRouteVisible() {
    if (_disposed || !mounted) return;
    lyricService.forceEmitCurrentLine();
    _startPositionResyncWindow();
    _syncToPlaybackPosition(duration: Duration.zero);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      _syncToPlaybackPosition(duration: Duration.zero);
    });
  }

  @override
  void didPush() {
    _syncWhenRouteVisible();
  }

  @override
  void didPopNext() {
    _syncWhenRouteVisible();
  }

  @override
  void didUpdateWidget(covariant _VerticalLyricScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyric != widget.lyric) {
      // 切歌时标记活动
      _markActivity();

      // 切歌时取消所有待处理的 Timer/Ticker，避免泄漏
      _stopScrollTicker();
      _ensureVisibleTimer?.cancel();
      _ensureVisibleTimer = null;
      _userScrollHoldTimer?.cancel();
      _userScrollHoldTimer = null;
      _sizeChangeTimer?.cancel();
      _sizeChangeTimer = null;

      _cachedMaxWidth = 0.0;
      _cachedOffsets = null;
      _cachedHeights = null;
      _cachedViewportHeight = 0.0;
      _initialOffsetsComputed = false;
      _needsInitialScroll = true;
      _pendingScrollRetries = 0;
      _mainLine = 0;
      _activeLines.clear();
      _hoveredLineIndex = -1;
      _viewportRange = const LyricViewportRange(start: 0, end: 0);
      _lineKeys.clear();
      _startPositionResyncWindow();

      // 延迟清空 TextPainter 对象池，避免在绘制过程中销毁正在使用的对象
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
        LyricsLinePainter.clearPool();
        LyricsLineWidget.clearBlurFilterCache();
        _initLyricView();
        _syncToPlaybackPosition(duration: Duration.zero);
      });
    }
  }

  void _scheduleEnsureCurrentVisible() {
    _ensureVisibleTimer?.cancel();
    _ensureVisibleTimer = Timer(const Duration(milliseconds: 150), () {
      if (_disposed || !mounted) return;
      _cachedMaxWidth = 0.0;
      _cachedViewportHeight = 0.0;
      final oldMainLine = _mainLine;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
        if (_mainLine >= widget.lyric.lines.length) {
          _mainLine = oldMainLine.clamp(0, widget.lyric.lines.length - 1);
        }
        _syncToPlaybackPosition(duration: Duration.zero);
      });
    });
  }

  /// ValueTransition 驱动的丝滑滚动
  void _animateTo(double targetOffset, {Duration? duration}) {
    if (!scrollController.hasClients) return;
    final minExtent = scrollController.position.minScrollExtent;
    final maxExtent = scrollController.position.maxScrollExtent;
    final to = targetOffset.clamp(minExtent, maxExtent);

    final from = scrollController.offset;
    final dist = (to - from).abs();

    if (dist < 0.5 || (duration != null && duration.inMilliseconds <= 16)) {
      scrollController.jumpTo(to);
      _scrollTransition.jumpTo(to);
      _stopScrollTicker();
      _needsInitialScroll = false;
      _positionResyncExtensionCount = 0;
      if (_scrollState == LyricScrollState.programScrolling) {
        _scrollState = LyricScrollState.idle;
      }
      return;
    }

    // 重用现有 transition，避免创建新对象
    _scrollTransition.begin = from;
    _scrollTransition.duration = duration ?? _scrollDurationForDistance(dist);
    _scrollTransition.start(to);
    _startScrollTicker();
    _needsInitialScroll = false;
    _positionResyncExtensionCount = 0;

    if (_scrollState != LyricScrollState.userDragging) {
      _scrollState = LyricScrollState.programScrolling;
    }
  }

  void _markUserScrolling() {
    _markActivity(); // 标记活动
    if (_hoveredLineIndex != -1) {
      _hoveredLineIndex = -1;
    }
    if (_scrollState != LyricScrollState.userDragging) {
      _stopScrollTicker();
      setState(() {
        _scrollState = LyricScrollState.userDragging;
      });
    }
    final renderConfig = context.read<LyricViewController>().renderConfig;
    final viewportStrategy = LyricViewportStrategy(
      leadingLines: renderConfig.viewportLeadingLines,
      trailingLines: renderConfig.viewportTrailingLines,
      overscanScreens: renderConfig.viewportOverscanScreens,
      userScrollHoldDuration: renderConfig.userScrollHoldDuration,
    );
    _userScrollHoldTimer?.cancel();
    _userScrollHoldTimer = Timer(viewportStrategy.userScrollHoldDuration, () {
      if (!mounted) return;
      setState(() {
        _scrollState = LyricScrollState.idle;
      });
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
    if (_disposed) return;
    if (_scrollState == LyricScrollState.userDragging) return;
    if (!scrollController.hasClients) {
      if (_pendingScrollRetries < _maxPendingScrollRetries) {
        _pendingScrollRetries++;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed || !mounted) return;
          _scrollToCurrent(duration);
        });
      }
      return;
    }
    _pendingScrollRetries = 0;

    _scrollState = LyricScrollState.programScrolling;

    final targetKey = _lineKeys[_mainLine];
    final targetContext = targetKey?.currentContext;
    if (targetContext != null && targetContext.mounted) {
      final targetObject = targetContext.findRenderObject();
      if (targetObject is RenderBox) {
        final viewport = RenderAbstractViewport.of(targetObject);
        final alignment = widget.currentLineAlignment;
        final revealed = viewport.getOffsetToReveal(targetObject, alignment);
        _animateTo(revealed.offset, duration: duration);
        return;
      }
    }

    if (_cachedOffsets != null &&
        _cachedHeights != null &&
        _mainLine < _cachedOffsets!.length) {
      final viewport = scrollController.position.viewportDimension;
      final alignment = widget.currentLineAlignment;

      // 计算与 ListView padding 匹配的顶部空间偏移量
      double topPadding;
      if (widget.centerVertically) {
        topPadding = viewport / 2.0;
      } else if (widget.enableEdgeSpacer) {
        topPadding = viewport;
      } else {
        topPadding = viewport * alignment;
      }

      final lineTop = _cachedOffsets![_mainLine];
      final lineHeight = _cachedHeights![_mainLine];

      final targetScrollOffset =
          (topPadding + lineTop + lineHeight / 2) - (viewport * alignment);

      _animateTo(targetScrollOffset, duration: duration);
      return;
    }

    if (_pendingScrollRetries < _maxPendingScrollRetries) {
      _pendingScrollRetries++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
        if (_cachedOffsets == null && _cachedMaxWidth > 0) {
          _computeOffsets(_cachedMaxWidth);
        }
        _scrollToCurrent(duration);
      });
    }
  }

  void _initLyricView() {
    _updateViewportRange(force: true);
  }

  void _seekToLyricLine(int i) {
    playbackService.seek(widget.lyric.lines[i].start.inMilliseconds / 1000);
    setState(() {
      _mainLine = i;
      _updateViewportRange(force: true);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      _scrollToCurrent();
    });
  }

  void _seekToLyricLineWithOriginalIndex(LyricLine line) {
    final originalIndex = widget.lyric.lines.indexOf(line);
    if (originalIndex >= 0) {
      _seekToLyricLine(originalIndex);
    }
  }

  /// 判断一行是否已被 blankMetadataLines 清空（不需要渲染）
  bool _isLineBlankFiltered(LyricLine line) {
    if (line is SyncLyricLine) {
      return line.words.isEmpty && line.length <= const Duration(seconds: 3);
    } else if (line is LrcLine) {
      return line.isBlank &&
          (line.length <= const Duration(seconds: 3) ||
              line.start > Duration.zero);
    }
    return false;
  }

  int? _nearestRenderableLineIndex(
    int lineIndex, {
    bool preferForward = false,
  }) {
    final lines = widget.lyric.lines;
    if (lines.isEmpty) return null;
    final clamped = lineIndex.clamp(0, lines.length - 1).toInt();
    if (!_isLineBlankFiltered(lines[clamped])) return clamped;
    if (preferForward) {
      for (int i = clamped + 1; i < lines.length; i++) {
        if (!_isLineBlankFiltered(lines[i])) return i;
      }
      for (int i = clamped - 1; i >= 0; i--) {
        if (!_isLineBlankFiltered(lines[i])) return i;
      }
    } else {
      for (int i = clamped - 1; i >= 0; i--) {
        if (!_isLineBlankFiltered(lines[i])) return i;
      }
      for (int i = clamped + 1; i < lines.length; i++) {
        if (!_isLineBlankFiltered(lines[i])) return i;
      }
    }
    return null;
  }

  Set<int> _renderableActiveLines(LyricLineUpdate update) {
    final lines = widget.lyric.lines;
    if (lines.isEmpty || update.activeIndices.isEmpty) return const <int>{};
    return update.activeIndices
        .where(
          (i) => i >= 0 && i < lines.length && !_isLineBlankFiltered(lines[i]),
        )
        .toSet();
  }

  void _syncToPlaybackPosition({
    Duration? duration,
    bool forceScroll = true,
  }) {
    if (_disposed || !mounted) return;
    final update = lyricService.lineUpdateForLyric(
      widget.lyric,
      playbackService.position,
      preferUpcomingInGap: forceScroll || _needsInitialScroll,
    );
    if (update == null) {
      lyricService.forceEmitCurrentLine();
      return;
    }
    _applyLyricLineUpdate(
      update,
      forceScroll: forceScroll,
      duration: duration ?? Duration.zero,
    );
  }

  void _startPositionResyncWindow() {
    if (_disposed) return;
    _positionResyncTimer ??= Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _resyncFromPositionTick(playbackService.position),
    );
    _positionResyncStopTimer?.cancel();
    _positionResyncStopTimer = Timer(const Duration(seconds: 4), () {
      _positionResyncTimer?.cancel();
      _positionResyncTimer = null;
      _positionResyncStopTimer = null;
      if (_needsInitialScroll &&
          mounted &&
          !_disposed &&
          _positionResyncExtensionCount < _maxPositionResyncExtensions) {
        _positionResyncExtensionCount++;
        _startPositionResyncWindow();
      }
    });
  }

  void _resyncFromPositionTick(double position) {
    if (_disposed || !mounted) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastPositionResyncMs < 200) return;
    _lastPositionResyncMs = nowMs;
    final preferUpcoming = _needsInitialScroll;
    final update = lyricService.lineUpdateForLyric(
      widget.lyric,
      position,
      preferUpcomingInGap: preferUpcoming,
    );
    if (update == null) return;
    final nextMainLine = _nearestRenderableLineIndex(
      update.primaryIndex,
      preferForward: preferUpcoming,
    );
    if (nextMainLine == null) return;
    final nextActiveLines = _renderableActiveLines(update);
    if (nextMainLine == _mainLine && setEquals(_activeLines, nextActiveLines)) {
      if (_needsInitialScroll) {
        _scrollToCurrent(Duration.zero);
      }
      return;
    }
    _applyLyricLineUpdate(update);
  }

  void _applyLyricLineUpdate(
    LyricLineUpdate update, {
    bool forceScroll = false,
    Duration? duration,
  }) {
    if (_disposed || !mounted) return;
    final lines = widget.lyric.lines;
    if (lines.isEmpty) return;

    final nextMainLine = update.primaryIndex.clamp(0, lines.length - 1).toInt();
    final preferForward = forceScroll || _needsInitialScroll;
    final renderableMainLine = _nearestRenderableLineIndex(
      nextMainLine,
      preferForward: preferForward,
    );
    if (renderableMainLine == null) return;
    final nextActiveLines = _renderableActiveLines(update);

    final renderConfig = context.read<LyricViewController>().renderConfig;
    final viewportStrategy = LyricViewportStrategy(
      leadingLines: renderConfig.viewportLeadingLines,
      trailingLines: renderConfig.viewportTrailingLines,
      overscanScreens: renderConfig.viewportOverscanScreens,
      userScrollHoldDuration: renderConfig.userScrollHoldDuration,
    );
    final followDecision = viewportStrategy.followDecision(
      currentRange: _viewportRange,
      nextMainLine: renderableMainLine,
      totalLines: lines.length,
    );
    final shouldScroll =
        forceScroll || _needsInitialScroll || followDecision.shouldScroll;

    if (forceScroll) {
      _pendingScrollRetries = 0;
      _userScrollHoldTimer?.cancel();
      _stopScrollTicker();
    }

    setState(() {
      _mainLine = renderableMainLine;
      _activeLines
        ..clear()
        ..addAll(nextActiveLines);
      _pruneLineKeys();
      _viewportRange = forceScroll
          ? viewportStrategy.rangeForMainLine(
              mainLine: renderableMainLine,
              totalLines: lines.length,
            )
          : followDecision.nextRange;
      if (_hoveredLineIndex != -1) {
        _hoveredLineIndex = -1;
      }
      if (forceScroll && _scrollState == LyricScrollState.userDragging) {
        _scrollState = LyricScrollState.idle;
      }
    });

    if (shouldScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
        _scrollToCurrent(duration);
      });
    }
  }

  void _updateNextLyricLine(LyricLineUpdate _) {
    _syncToPlaybackPosition(forceScroll: false);
  }

  @override
  Widget build(BuildContext context) {
    final renderConfig = context.watch<LyricViewController>().renderConfig;
    final viewportStrategy = LyricViewportStrategy(
      leadingLines: renderConfig.viewportLeadingLines,
      trailingLines: renderConfig.viewportTrailingLines,
      overscanScreens: renderConfig.viewportOverscanScreens,
      userScrollHoldDuration: renderConfig.userScrollHoldDuration,
    );
    return LayoutBuilder(builder: (context, constraints) {
      final needsOffsets =
          _cachedOffsets == null || constraints.maxWidth != _cachedMaxWidth;
      if (needsOffsets) {
        _cachedMaxWidth = constraints.maxWidth;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed || !mounted) return;
          _computeOffsets(constraints.maxWidth);
        });
      }

      final spacerHeight = constraints.maxHeight / 2.0;
      final viewportHeight = constraints.maxHeight;
      final viewportHeightChanged = viewportHeight.isFinite &&
          viewportHeight > 0 &&
          (viewportHeight - _cachedViewportHeight).abs() > 0.5;
      if (viewportHeightChanged) {
        _cachedViewportHeight = viewportHeight;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed || !mounted) return;
          _syncToPlaybackPosition(duration: Duration.zero);
        });
      }
      final extraTopPadding = widget.enableEdgeSpacer ? viewportHeight : 0.0;
      final extraBottomPadding = widget.enableEdgeSpacer ? viewportHeight : 0.0;
      final alignTopPadding =
          (!widget.centerVertically && !widget.enableEdgeSpacer)
              ? viewportHeight * widget.currentLineAlignment
              : 0.0;
      final alignBottomPadding =
          (!widget.centerVertically && !widget.enableEdgeSpacer)
              ? viewportHeight * (1.0 - widget.currentLineAlignment)
              : 0.0;
      final userIsDragging = _scrollState == LyricScrollState.userDragging;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          RepaintBoundary(
            key: const ValueKey('lyric_list_view'),
            child: Container(
              color: Colors.transparent,
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is UserScrollNotification) {
                    _markUserScrolling();
                  } else if (notification is ScrollStartNotification &&
                      notification.dragDetails != null) {
                    _markUserScrolling();
                  } else if (notification is ScrollUpdateNotification &&
                      notification.dragDetails != null) {
                    _markUserScrolling();
                  }
                  return false;
                },
                child: ShaderMask(
                  shaderCallback: (Rect bounds) {
                    // 开启了歌词模糊 → 加大边缘渐隐（和模糊效果协同）
                    // 关闭 → 仅保留很小的边缘淡出以免生硬裁切
                    final fadeIn = renderConfig.enableBlur
                        ? _shaderFadeInWithBlur
                        : _shaderFadeInWithoutBlur;
                    final fadeOut = renderConfig.enableBlur
                        ? _shaderFadeOutWithBlur
                        : _shaderFadeOutWithoutBlur;
                    return LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: const [
                        Colors.transparent,
                        Colors.black,
                        Colors.black,
                        Colors.transparent
                      ],
                      stops: [0.0, fadeIn, fadeOut, 1.0],
                    ).createShader(bounds);
                  },
                  blendMode: BlendMode.dstIn,
                  child: ListView.builder(
                    key: const ValueKey('lyric_list_view_inner'),
                    controller: scrollController,
                    addAutomaticKeepAlives: true, // 改为 true，保持 Widget 状态
                    addRepaintBoundaries: true, // 改为 true，每行独立重绘
                    scrollCacheExtent: ScrollCacheExtent.pixels(
                        viewportStrategy.cacheExtent(constraints.maxHeight)),
                    padding: EdgeInsets.only(
                      top: (widget.centerVertically ? spacerHeight : 0) +
                          extraTopPadding +
                          alignTopPadding,
                      bottom: (widget.centerVertically ? spacerHeight : 0) +
                          extraBottomPadding +
                          alignBottomPadding,
                    ),
                    itemCount: widget.lyric.lines.length,
                    itemBuilder: (context, i) {
                      final line = widget.lyric.lines[i];

                      // 空白行/元数据行：不渲染（已被 blankMetadataLines 清空）
                      if (_isLineBlankFiltered(line)) {
                        return const SizedBox.shrink();
                      }

                      final signedDist = i - _mainLine;
                      final dist = signedDist.abs();
                      final opacity = dist == 0 || _activeLines.contains(i)
                          ? 1.0
                          : pow(_opacityBase, dist)
                              .toDouble()
                              .clamp(_opacityMinClamp, _opacityMaxClamp);
                      final staggerDelay = Duration(
                          milliseconds: _lyricViewController
                                      ?.renderConfig.enableStaggeredAnimation ==
                                  true
                              ? ((dist + 1) * _staggerBaseMs)
                                  .clamp(0, _staggerMaxMs)
                              : 0);
                      final isHovered =
                          widget.enableSeekOnTap && i == _hoveredLineIndex;

                      Widget lineWidget = SizedBox(
                        key: _keyForLine(i),
                        child: LyricsLineWidget(
                          key: ValueKey(
                            'lyric_line_${identityHashCode(widget.lyric)}_$i',
                          ),
                          line: line,
                          opacity: isHovered ? 1.0 : opacity,
                          distance: _activeLines.contains(i) ? 0 : dist,
                          lineOffsetY: 0.0,
                          staggerDelay:
                              isHovered ? Duration.zero : staggerDelay,
                          isUserScrolling: userIsDragging,
                          isHovered: isHovered,
                          onHoverChanged: widget.enableSeekOnTap
                              ? (v) {
                                  setState(() {
                                    _hoveredLineIndex = v ? i : -1;
                                  });
                                }
                              : null,
                          onTap: widget.enableSeekOnTap
                              ? () => _seekToLyricLineWithOriginalIndex(line)
                              : null,
                        ),
                      );

                      return lineWidget;
                    },
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
    _disposed = true;
    _stopScrollTicker();
    _lineKeys.clear();
    _ensureVisibleTimer?.cancel();
    _userScrollHoldTimer?.cancel();
    _sizeChangeTimer?.cancel();
    _playbackResyncTimer?.cancel();
    _idleCleanupTimer?.cancel(); // 取消空闲检测
    _lyricViewController?.removeListener(_scheduleEnsureCurrentVisible);
    _lyricViewController?.removeListener(_scheduleEnsureCurrentVisible);
    routeVisibilityObserver.unsubscribe(this);
    playbackService.nowPlayingNotifier.removeListener(_playbackResyncListener);
    playbackService.playerStateNotifier.removeListener(_playbackResyncListener);
    playbackService.positionSyncNotifier
        .removeListener(_playbackResyncListener);
    lyricService.removeListener(_playbackResyncListener);
    lyricLineStreamSubscription.cancel();
    _positionResyncTimer?.cancel();
    _positionResyncStopTimer?.cancel();
    scrollController.dispose();

    // 清空 TextPainter 对象池，释放内存
    LyricsLinePainter.clearPool();
    LyricsLineWidget.clearBlurFilterCache();
    super.dispose();
  }
}
