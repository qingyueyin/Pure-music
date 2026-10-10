import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:pure_music/core/app_fonts.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/route_visibility.dart';
import 'package:pure_music/core/window_render_gate.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/ttml.dart';
import 'package:pure_music/native/bass/bass_player.dart' show PlayerState;
import 'package:pure_music/page/now_playing_page/component/collapsible_lyric_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_stagger_motion.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_tile.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_painter_params.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_viewport_strategy.dart';
import 'package:pure_music/page/now_playing_page/component/value_transition.dart';
import 'package:pure_music/play_service/lyric_service.dart'
    show lyricHighlightDeadlineMsForLine, lyricWordPreSwitchMs;
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

const _opacityBase = 0.88;
const _opacityMinClamp = 0.30;
const _opacityMaxClamp = 0.90;
const _staggerMaxMs = 600;
const _shaderFadeInWithBlur = 0.05;
const _shaderFadeInWithoutBlur = 0.05;
const _shaderFadeOutWithBlur = 0.80;
const _shaderFadeOutWithoutBlur = 0.95;
const _lyricOffsetCacheCapacity = 6;

bool alwaysShowLyricViewControls = false;

bool shouldForceLyricScrollForPositionSync(
  PlayerState state, {
  bool needsInitialScroll = false,
}) {
  // 播放中的位置校准不能强行跟唱，否则用户翻歌词会被立刻拽回当前句。
  return needsInitialScroll;
}

bool shouldIgnoreLyricFollowWhileUserScrolling({
  required bool isUserDragging,
}) => isUserDragging;

bool shouldForceLyricScrollForViewportChange({
  bool needsInitialScroll = false,
}) => needsInitialScroll;

@visibleForTesting
bool shouldEnqueuePlayingLyricResync({
  required bool forceScroll,
  required bool needsInitialScroll,
  required bool isPlaying,
}) {
  return !forceScroll && !needsInitialScroll && isPlaying;
}

double lyricStaggerJumpDeltaY({required double from, required double to}) {
  final delta = to - from;
  return delta.abs() - 0.2 > 1e-6 ? delta : 0;
}

double lyricLineLayoutWidth(double viewportWidth) {
  final width = viewportWidth - transitionTileMargin * 2;
  return width < 1.0 ? 1.0 : width;
}

/// 滚动停在半像素上时，所有行会一起抖。
double lyricSnapScrollOffset(double offset, double devicePixelRatio) {
  final scale = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
  return (offset * scale).round() / scale;
}

/// 往下一句时不允许把列表往上拽（画面上就是所有行先向下推）。
double lyricClampScrollForLineAdvance({
  required double from,
  required double to,
  required int fromIndex,
  required int toIndex,
}) {
  if (toIndex > fromIndex && to < from) return from;
  if (toIndex < fromIndex && to > from) return from;
  return to;
}

/// 与 ListView padding 同一套，避免跟唱少算一段把整列拽下去。
double lyricListTopPadding({
  required double viewportHeight,
  required bool centerVertically,
  required bool enableEdgeSpacer,
  required double alignment,
}) {
  final spacer = centerVertically ? viewportHeight / 2.0 : 0.0;
  final extraTop = enableEdgeSpacer ? viewportHeight : 0.0;
  final alignTop = (!centerVertically && !enableEdgeSpacer)
      ? viewportHeight * alignment.clamp(0.0, 1.0)
      : 0.0;
  return spacer + extraTop + alignTop;
}

double lyricListBottomPadding({
  required double viewportHeight,
  required bool centerVertically,
  required bool enableEdgeSpacer,
  required double alignment,
}) {
  final spacer = centerVertically ? viewportHeight / 2.0 : 0.0;
  final extraBottom = enableEdgeSpacer ? viewportHeight : 0.0;
  final alignBottom = (!centerVertically && !enableEdgeSpacer)
      ? viewportHeight * (1.0 - alignment.clamp(0.0, 1.0))
      : 0.0;
  return spacer + extraBottom + alignBottom;
}

/// 与 getOffsetToReveal(alignment) 一致：用行上 alignment 那一点，不用行中心。
double lyricScrollOffsetToAlignLine({
  required double topPadding,
  required double lineTop,
  required double lineHeight,
  required double viewportHeight,
  required double alignment,
}) {
  final a = alignment.clamp(0.0, 1.0);
  return topPadding + lineTop + lineHeight * a - viewportHeight * a;
}

/// 跟唱只按缓存行高往前加。切句时去问当前布局，行高还在变，整列就会先被拽下去。
double lyricFollowScrollOffset({
  required double currentOffset,
  required int fromIndex,
  required int toIndex,
  required List<double> offsets,
  required List<double> heights,
  required double alignment,
}) {
  if (fromIndex == toIndex) return currentOffset;
  if (fromIndex < 0 ||
      toIndex < 0 ||
      fromIndex >= offsets.length ||
      toIndex >= offsets.length ||
      fromIndex >= heights.length ||
      toIndex >= heights.length) {
    return currentOffset;
  }
  final a = alignment.clamp(0.0, 1.0);
  final fromPoint = offsets[fromIndex] + heights[fromIndex] * a;
  final toPoint = offsets[toIndex] + heights[toIndex] * a;
  return currentOffset + (toPoint - fromPoint);
}

/// 往下一句时，滚动位置不能比出发时更小，否则整列会先被拽下去。
double lyricScrollOffsetWithoutRetreat({
  required double from,
  required double candidate,
  required bool advancing,
}) {
  if (advancing && candidate < from) return from;
  if (!advancing && candidate > from) return from;
  return candidate;
}

/// 弹簧切行只按缓存行距跳，避开切句时行高还在变把补偿拉大。
double lyricStaggerScrollTarget({
  required double currentOffset,
  required int fromIndex,
  required int toIndex,
  required List<double> offsets,
  required List<double> heights,
  required double alignment,
}) {
  return lyricClampScrollForLineAdvance(
    from: currentOffset,
    to: lyricFollowScrollOffset(
      currentOffset: currentOffset,
      fromIndex: fromIndex,
      toIndex: toIndex,
      offsets: offsets,
      heights: heights,
      alignment: alignment,
    ),
    fromIndex: fromIndex,
    toIndex: toIndex,
  );
}

const lyricScrollSettlePx = 2.0;

bool shouldSnapLyricScroll({
  required double distancePx,
  required bool forceJump,
  required bool animatingToSameTarget,
  bool isAnimating = false,
}) {
  if (distancePx < lyricScrollSettlePx) {
    if (isAnimating && !animatingToSameTarget) return false;
    return true;
  }
  if (forceJump && !animatingToSameTarget) return true;
  return false;
}

bool shouldFollowLyricLineScroll({
  required bool forceScroll,
  required bool needsInitialScroll,
  required bool mainLineChanged,
}) {
  return forceScroll || needsInitialScroll || mainLineChanged;
}

@visibleForTesting
bool shouldForceLyricScrollAfterOffsetsComputed({
  required bool needsInitialScroll,
  required bool isUserDragging,
}) {
  return needsInitialScroll && !isUserDragging;
}

@visibleForTesting
bool shouldFinishInitialLyricScroll({
  required bool hasContentDimensions,
  required double viewportDimension,
  required double targetHeight,
  required double requestedOffset,
  required double appliedOffset,
}) {
  return hasContentDimensions &&
      viewportDimension.isFinite &&
      viewportDimension > 1 &&
      targetHeight.isFinite &&
      targetHeight > 0 &&
      requestedOffset.isFinite &&
      appliedOffset.isFinite &&
      (requestedOffset - appliedOffset).abs() < lyricScrollSettlePx;
}

bool shouldRestartLyricScroll({
  required bool animatingToSameTarget,
  required bool forceJump,
  bool isAnimating = false,
  double distancePx = 0,
}) {
  if (animatingToSameTarget) return false;
  if (isAnimating && distancePx < lyricScrollSettlePx) return false;
  return true;
}

bool shouldApplyPlaybackLyricResync({
  required int currentIndex,
  required int resyncIndex,
  required bool isPlaying,
  bool usesAuthoredTiming = false,
}) {
  if (usesAuthoredTiming) return true;
  if (resyncIndex == currentIndex) return true;
  if (!isPlaying) return true;
  if (resyncIndex < currentIndex) return false;
  return resyncIndex == currentIndex + 1;
}

bool shouldScheduleQueuedLyricLineUpdate({
  required bool awaitingAppliedUpdateFrame,
  required bool alreadyScheduledForGeneration,
}) {
  if (awaitingAppliedUpdateFrame || alreadyScheduledForGeneration) {
    return false;
  }
  return true;
}

@visibleForTesting
List<LyricLineUpdate> lyricLineUpdateQueueAfterEnqueue({
  required Iterable<LyricLineUpdate> queued,
  required LyricLineUpdate update,
  required int currentIndex,
  required bool isPlaying,
  int? currentPositionMs,
  int? currentGeneration,
}) {
  final next = List<LyricLineUpdate>.of(queued);
  if (update.usesAuthoredTiming) {
    final last = next.isEmpty ? null : next.last;
    final queuedGeneration = last?.generation;
    final generation = currentGeneration == null
        ? queuedGeneration
        : queuedGeneration == null
        ? currentGeneration
        : max(currentGeneration, queuedGeneration);
    if (generation != null && update.generation != null) {
      if (update.generation! < generation) return next;
      if (update.generation! > generation) return [update];
    }
    final position =
        last != null && (generation == null || last.generation == generation)
        ? last.positionMs
        : currentPositionMs;
    if (isPlaying &&
        position != null &&
        update.positionMs != null &&
        update.positionMs! < position) {
      return next;
    }
    return [update];
  }
  if (isPlaying && update.primaryIndex < currentIndex) return next;
  if (next.isEmpty) {
    next.add(update);
    return next;
  }

  final last = next.last;
  if (update.primaryIndex < last.primaryIndex) return next;
  if (update.primaryIndex == last.primaryIndex) {
    final lastPosition = last.positionMs;
    final updatePosition = update.positionMs;
    if (lastPosition != null &&
        updatePosition != null &&
        updatePosition < lastPosition) {
      return next;
    }
    next[next.length - 1] = update;
    return next;
  }

  next.add(update);
  return next;
}

bool shouldDiscardQueuedLyricUpdatesForResync({
  required bool forceScroll,
  required int currentIndex,
  required int resyncIndex,
}) {
  if (!forceScroll) return false;
  return (resyncIndex - currentIndex).abs() > 1;
}

@visibleForTesting
int lyricDisplayPrimaryIndex({
  required int fallbackPrimaryIndex,
  required int lineCount,
  required Set<int> groupedLines,
}) {
  if (lineCount <= 0) return 0;
  if (groupedLines.isNotEmpty) {
    return groupedLines.reduce(min);
  }
  return fallbackPrimaryIndex.clamp(0, lineCount - 1).toInt();
}

/// 滚动锚点仍冻在组首句；组内已显示的句子用主行距离，才能切到主行缩放和重要性。
@visibleForTesting
int lyricLineVisualDistance({
  required int index,
  required int mainLine,
  required Set<int> parallelGroupLines,
}) {
  if (parallelGroupLines.contains(index)) return 0;
  return (index - mainLine).abs();
}

/// 并行已经很多、或组高度超出预算时，先收已有 bg，把位置让给主行。
@visibleForTesting
Set<int> lyricBackgroundLinesToEvict({
  required Set<int> groupLines,
  required Set<int> mainActiveLines,
  required Set<int> backgroundLines,
  required double Function(int index) lineHeight,
  double? heightBudget,
  int crowdedCount = 3,
}) {
  if (groupLines.length < 2) return const <int>{};
  final withBg = groupLines.where(backgroundLines.contains).toList()..sort();
  if (withBg.isEmpty) return const <int>{};
  final crowded = groupLines.length >= crowdedCount;
  final overBudget =
      heightBudget != null &&
      groupLines.fold<double>(
            0.0,
            (total, index) => total + lineHeight(index),
          ) >
          heightBudget;
  if (!crowded && !overBudget) return const <int>{};
  final keep = mainActiveLines.isEmpty
      ? groupLines.reduce(max)
      : mainActiveLines.reduce(max);
  return {
    for (final index in withBg)
      if (index != keep) index,
  };
}

class _LyricOffsetCacheKey {
  const _LyricOffsetCacheKey({
    required this.lyric,
    required this.widthPx,
    required this.config,
    required this.fontFamily,
  });

  final Lyric lyric;
  final int widthPx;
  final LyricRenderConfig config;
  final String? fontFamily;

  @override
  bool operator ==(Object other) {
    return other is _LyricOffsetCacheKey &&
        identical(other.lyric, lyric) &&
        other.widthPx == widthPx &&
        other.config == config &&
        other.fontFamily == fontFamily;
  }

  @override
  int get hashCode =>
      Object.hash(identityHashCode(lyric), widthPx, config, fontFamily);
}

class _LyricOffsetCacheEntry {
  _LyricOffsetCacheEntry({
    required this.offsets,
    required this.heights,
    required this.backgroundVocalHeights,
    required this.maxWidth,
    required this.viewportHeight,
  });

  final List<double> offsets;
  final List<double> heights;
  final List<double> backgroundVocalHeights;
  final double maxWidth;
  double viewportHeight;
}

class _LyricScrollRequest {
  const _LyricScrollRequest({
    required this.lineIndex,
    required this.useStagger,
    required this.duration,
    required this.updateGeneration,
  });

  final int lineIndex;
  final bool useStagger;
  final Duration? duration;
  final int updateGeneration;
}

enum LyricScrollState { idle, userDragging, programScrolling }

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
                key: ValueKey(
                  PlayService.instance.lyricService.currLyricFuture,
                ),
                future: PlayService.instance.lyricService.currLyricFuture,
                builder: (context, snapshot) {
                  final lyricNullable = snapshot.data;
                  final scheme = Theme.of(context).colorScheme;
                  final noLyricWidget = Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('无歌词', style: TextStyle(fontSize: 22)),
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
                        ConnectionState.done =>
                          lyricNullable == null
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
  final _userScrollTracker = LyricUserScrollTracker();
  late final ValueNotifier<double> _sharedLyricPositionMs;
  Ticker? _sharedLyricPositionTicker;
  Duration _sharedLyricLastTick = Duration.zero;
  bool _resumeSharedLyricFromFrozen = false;
  late StreamSubscription lyricLineStreamSubscription;
  Timer? _positionResyncTimer;
  Timer? _positionResyncStopTimer;
  Timer? _playbackResyncTimer;
  late final ScrollController scrollController;
  LyricViewController? _lyricViewController;
  PageRoute<dynamic>? _route;
  late final VoidCallback _contentResyncListener;
  late final VoidCallback _positionResyncListener;
  bool _disposed = false;
  Timer? _ensureVisibleTimer;
  Timer? _userScrollHoldTimer;
  Timer? _sizeChangeTimer;
  Timer? _idleCleanupTimer;
  bool _didIdleCleanup = false;
  LyricScrollState _scrollState = LyricScrollState.idle;
  int _mainLine = 0;
  int _jumpTriggerId = 0;
  double _jumpDeltaY = 0.0;
  int _staggerVisibleStartIndex = 0;
  int _staggerFromIndex = -1;
  bool _pendingStaggerScroll = false;
  bool _postDragSkipPending = false;
  int _programmaticScrollDepth = 0;

  // 同一帧只应用一条普通行更新，保留连续换行的视觉状态。
  final Queue<LyricLineUpdate> _pendingLyricLineUpdates = Queue();
  int _lyricLineUpdateGeneration = 0;
  int? _scheduledLyricLineUpdateGeneration;
  int _lyricLineUpdateFrameToken = 0;
  int? _awaitingLyricLineUpdateFrameToken;

  /// TTML 当前并行组；[_mainLine] 仍只负责主行布局。
  final Set<int> _parallelGroupLines = {};
  final Set<int> _mainActiveLyricLines = {};
  final Set<int> _backgroundActiveLyricLines = {};
  final Set<int> _activeLyricLines = {};
  int? _tailHighlightCatchUpLine;
  final Set<int> _departingBackgroundVocalLines = {};
  final Map<int, ValueNotifier<double>> _backgroundExitValues = {};
  final Map<int, int> _backgroundExitStartedMs = {};
  final Stopwatch _backgroundExitClock = Stopwatch();
  late final AnimationController _backgroundVocalExitController;
  int _backgroundVocalExitGeneration = 0;
  int _pendingScrollRetries = 0;
  static const int _maxPendingScrollRetries = 90;
  LyricViewportRange _viewportRange = const LyricViewportRange(
    start: 0,
    end: 0,
  );

  /// 标记是否需要执行首次进入页面时的定位滚动。
  /// forceEmitCurrentLine 与 _scrollToCurrent 不在同一时机就绪，
  /// 需要在收到歌词行更新后补一次滚动。
  bool _needsInitialScroll = true;
  double _displayPositionMs = 0.0;
  int? _lastTtmlGeneration;
  int _lastPositionResyncMs = 0;
  int _positionResyncExtensionCount = 0;
  static const int _maxPositionResyncExtensions = 5;

  final Map<int, GlobalKey> _lineKeys = {};
  static const int _lineKeyRetainRadius = 80;

  GlobalKey _keyForLine(int index) {
    // 切句时不能把已建行的 key 拿掉，否则上面的行会拆掉重建，整列先往下跳。
    return _lineKeys[index] ??= GlobalKey();
  }

  void _pruneLineKeys() {
    _lineKeys.removeWhere(
      (index, _) =>
          (index - _mainLine).abs() > _lineKeyRetainRadius &&
          !_parallelGroupLines.contains(index) &&
          !_activeLyricLines.contains(index),
    );
  }

  /// ValueTransition 驱动的平滑滚动
  late ValueTransition<double> _scrollTransition;
  Ticker? _scrollTicker;
  bool _scrollTickerActive = false;
  Duration _lastTickElapsed = Duration.zero;

  List<double>? _cachedOffsets;
  List<double>? _cachedHeights;
  List<double>? _cachedBackgroundVocalHeights;
  double _cachedMaxWidth = 0.0;
  double _cachedViewportHeight = 0.0;
  String? _cachedLyricFontFamily;

  @override
  void initState() {
    super.initState();
    _displayPositionMs = playbackService.position * 1000.0;
    _sharedLyricPositionMs = ValueNotifier(_displayPositionMs);
    final initialOffset = _restoreCachedInitialPosition();
    scrollController = ScrollController(initialScrollOffset: initialOffset);
    _scrollTransition = ValueTransition<double>(
      begin: 0,
      interpolator: lyricSmoothTransitionInterpolator,
      duration: const Duration(milliseconds: 300),
    );
    _backgroundVocalExitController = AnimationController(
      vsync: this,
      duration: lyricBackgroundVocalExitDuration,
    )..addListener(_updateBackgroundExitValues);
    lyricLineStreamSubscription = lyricService.lyricLineStream.listen(
      _updateNextLyricLine,
    );
    WindowRenderGate.instance.framesEnabled.addListener(_onWindowFramesEnabled);
    _contentResyncListener = _queueContentResync;
    _positionResyncListener = _queuePositionResync;
    playbackService.nowPlayingNotifier.addListener(_contentResyncListener);
    playbackService.positionSyncNotifier.addListener(_positionResyncListener);
    playbackService.playerStateNotifier.addListener(_syncSharedLyricTicker);
    lyricService.addListener(_contentResyncListener);
    _syncSharedLyricTicker();
    _startPositionResyncWindow();
    _initLyricView();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      lyricService.forceEmitCurrentLine();
      _syncToPlaybackPosition(duration: Duration.zero);
    });

    // 启动空闲检测（一次性定时器，活动时重置）
    _scheduleIdleCleanup();
  }

  bool get _needsSharedLyricPosition =>
      widget.lyric.isWordByWord && widget.lyric.lines.isNotEmpty;

  void _syncSharedLyricTicker() {
    if (_disposed ||
        !_needsSharedLyricPosition ||
        playbackService.playerState != PlayerState.playing) {
      if (_sharedLyricPositionTicker?.isActive == true) {
        _resumeSharedLyricFromFrozen = true;
      }
      _sharedLyricPositionTicker?.stop();
      _sharedLyricLastTick = Duration.zero;
      return;
    }
    _sharedLyricPositionTicker ??= createTicker(_onSharedLyricTick);
    if (!_sharedLyricPositionTicker!.isActive) {
      _sharedLyricLastTick = Duration.zero;
      _sharedLyricPositionTicker!.start();
    }
  }

  void _onSharedLyricTick(Duration elapsed) {
    if (_disposed || !mounted) return;
    if (_resumeSharedLyricFromFrozen) {
      _resumeSharedLyricFromFrozen = false;
      _sharedLyricLastTick = elapsed;
      return;
    }
    final delta = _sharedLyricLastTick == Duration.zero
        ? Duration.zero
        : elapsed - _sharedLyricLastTick;
    _sharedLyricLastTick = elapsed;
    final previousMs = _sharedLyricPositionMs.value;
    final predictedMs =
        previousMs + delta.inMicroseconds / 1000.0 * playbackService.rate.value;
    final nativeMs = playbackService.position * 1000.0;
    final nextMs = lyricMonotonicPlaybackMs(
      previousMs: previousMs,
      predictedMs: predictedMs,
      nativeMs: nativeMs,
    );
    if (nextMs == previousMs) return;
    if (!_sharedLyricVisualNeedsFrame(nextMs) &&
        (nextMs - previousMs).abs() < 100) {
      return;
    }
    _sharedLyricPositionMs.value = nextMs;
  }

  bool _sharedLyricVisualNeedsFrame(double nowMs) {
    final lines = widget.lyric.lines;
    final indices = <int>{
      _mainLine,
      ..._mainActiveLyricLines,
      ..._backgroundActiveLyricLines,
    };
    final config =
        _lyricViewController?.renderConfig ??
        LyricViewController.instance.renderConfig;
    final liftActive = config.liftStyle == LyricLiftStyle.vertical;
    final liftPeak = config.liftPeak;
    final enableGlow = config.enableGlow;
    for (final i in indices) {
      if (i < 0 || i >= lines.length) continue;
      final line = lines[i];
      if (line is! SyncLyricLine) continue;
      if (lyricLineEffectsNeedFrame(
        words: [...line.words, ...line.bgWords],
        nowMs: nowMs,
        lineMedianDuration: lyricMedianWordDuration(line.words),
        enableGlow: enableGlow,
        liftActive: liftActive && i == _mainLine,
        liftPeak: liftPeak,
      )) {
        return true;
      }
    }
    return false;
  }

  double _restoreCachedInitialPosition() {
    final update = lyricService.lineUpdateForLyric(
      widget.lyric,
      playbackService.position,
    );
    if (update != null) {
      _mainLine =
          _nearestRenderableLineIndex(
            update.primaryIndex,
            preferForward: true,
          ) ??
          0;
    }

    final config = LyricViewController.instance.renderConfig;
    final fontFamily = ThemeProvider.instance.resolvedLyricFontFamily;
    _LyricOffsetCacheKey? cacheKey;
    _LyricOffsetCacheEntry? cached;
    for (final entry in _offsetCache.entries.toList().reversed) {
      if (identical(entry.key.lyric, widget.lyric) &&
          entry.key.config == config &&
          entry.key.fontFamily == fontFamily &&
          entry.value.viewportHeight > 0) {
        cacheKey = entry.key;
        cached = entry.value;
        break;
      }
    }
    if (cacheKey == null || cached == null || cached.offsets.isEmpty) {
      return 0.0;
    }

    _offsetCache.remove(cacheKey);
    _offsetCache[cacheKey] = cached;
    _cachedOffsets = cached.offsets;
    _cachedHeights = cached.heights;
    _cachedBackgroundVocalHeights = cached.backgroundVocalHeights;
    _cachedMaxWidth = cached.maxWidth;
    _cachedViewportHeight = cached.viewportHeight;
    _cachedLyricFontFamily = cacheKey.fontFamily;

    final lineIndex = _mainLine.clamp(0, cached.offsets.length - 1);
    final viewport = cached.viewportHeight;
    final alignment = widget.currentLineAlignment;
    return max(
      0.0,
      lyricScrollOffsetToAlignLine(
        topPadding: lyricListTopPadding(
          viewportHeight: viewport,
          centerVertically: widget.centerVertically,
          enableEdgeSpacer: widget.enableEdgeSpacer,
          alignment: alignment,
        ),
        lineTop: cached.offsets[lineIndex],
        lineHeight: cached.heights[lineIndex],
        viewportHeight: viewport,
        alignment: alignment,
      ),
    );
  }

  @override
  void activate() {
    super.activate();
    _discardPendingLyricLineUpdates();
    _needsInitialScroll = true;
    _startPositionResyncWindow();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      _syncToPlaybackPosition(duration: Duration.zero);
    });
  }

  /// 标记活动时间（切歌、滚动、行变化），重置空闲检测
  void _markActivity() {
    _didIdleCleanup = false;
    _scheduleIdleCleanup();
  }

  void _scheduleIdleCleanup() {
    _idleCleanupTimer?.cancel();
    _idleCleanupTimer = Timer(const Duration(seconds: 5), () {
      if (!_disposed && mounted && !_didIdleCleanup) {
        _didIdleCleanup = true;
        LyricsLinePainter.trimPool();
        LyricsLineWidget.clearBlurFilterCache();
      }
    });
  }

  void _queueContentResync() {
    _queuePlaybackResync(forceScroll: true);
  }

  void _queuePositionResync() {
    _queuePlaybackResync(
      forceScroll: shouldForceLyricScrollForPositionSync(
        playbackService.playerState,
        needsInitialScroll: _needsInitialScroll,
      ),
    );
  }

  void _queuePlaybackResync({required bool forceScroll}) {
    if (_disposed || !mounted) return;
    _sharedLyricPositionMs.value = playbackService.position * 1000.0;
    _syncSharedLyricTicker();
    if (!shouldAcceptLyricUiUpdate(
      windowFramesEnabled: WindowRenderGate.instance.shouldRender,
    )) {
      _discardPendingLyricLineUpdates();
      return;
    }
    if (forceScroll) {
      _discardPendingLyricLineUpdates();
      _needsInitialScroll = true;
    }
    _pendingScrollRetries = 0;
    _startPositionResyncWindow();
    _playbackResyncTimer?.cancel();
    _playbackResyncTimer = Timer(const Duration(milliseconds: 16), () {
      if (_disposed || !mounted) return;
      _syncToPlaybackPosition(
        duration: Duration.zero,
        forceScroll: forceScroll,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
        _syncToPlaybackPosition(
          duration: Duration.zero,
          forceScroll: forceScroll,
        );
      });
    });
  }

  bool get _hasPendingLyricLineUpdates =>
      _pendingLyricLineUpdates.isNotEmpty ||
      _awaitingLyricLineUpdateFrameToken != null;

  void _discardPendingLyricLineUpdates() {
    _pendingLyricLineUpdates.clear();
    _awaitingLyricLineUpdateFrameToken = null;
    _lyricLineUpdateGeneration++;
  }

  void _onWindowFramesEnabled() {
    if (!shouldAcceptLyricUiUpdate(
      windowFramesEnabled: WindowRenderGate.instance.shouldRender,
    )) {
      _discardPendingLyricLineUpdates();
      return;
    }
    if (_disposed || !mounted) return;
    lyricService.forceEmitCurrentLine();
    _syncToPlaybackPosition(duration: Duration.zero, forceScroll: true);
  }

  void _enqueueLyricLineUpdate(LyricLineUpdate update) {
    if (update.sourceLyric != null &&
        !identical(update.sourceLyric, widget.lyric)) {
      return;
    }
    if (!shouldAcceptLyricUiUpdate(
      windowFramesEnabled: WindowRenderGate.instance.shouldRender,
    )) {
      _discardPendingLyricLineUpdates();
      return;
    }
    final queued = lyricLineUpdateQueueAfterEnqueue(
      queued: _pendingLyricLineUpdates,
      update: update,
      currentIndex: _mainLine,
      isPlaying: playbackService.playerState == PlayerState.playing,
      currentPositionMs: _displayPositionMs.round(),
      currentGeneration: _lastTtmlGeneration,
    );
    _pendingLyricLineUpdates
      ..clear()
      ..addAll(queued);
    _scheduleNextLyricLineUpdate();
  }

  void _ensureFrameScheduled() {
    if (!SchedulerBinding.instance.hasScheduledFrame) {
      SchedulerBinding.instance.scheduleFrame();
    }
  }

  void _scheduleNextLyricLineUpdate() {
    final generation = _lyricLineUpdateGeneration;
    if (!shouldScheduleQueuedLyricLineUpdate(
      awaitingAppliedUpdateFrame: _awaitingLyricLineUpdateFrameToken != null,
      alreadyScheduledForGeneration:
          _scheduledLyricLineUpdateGeneration == generation,
    )) {
      return;
    }
    _scheduledLyricLineUpdateGeneration = generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scheduledLyricLineUpdateGeneration == generation) {
        _scheduledLyricLineUpdateGeneration = null;
      }
      if (_disposed || !mounted || generation != _lyricLineUpdateGeneration) {
        return;
      }
      if (_pendingLyricLineUpdates.isEmpty) return;
      if (_awaitingLyricLineUpdateFrameToken != null) return;

      final update = _pendingLyricLineUpdates.removeFirst();
      _applyLyricLineUpdate(update, forceScroll: false);
      final frameToken = ++_lyricLineUpdateFrameToken;
      _awaitingLyricLineUpdateFrameToken = frameToken;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_awaitingLyricLineUpdateFrameToken == frameToken) {
          _awaitingLyricLineUpdateFrameToken = null;
        }
        if (_disposed || !mounted || generation != _lyricLineUpdateGeneration) {
          return;
        }
        if (_pendingLyricLineUpdates.isNotEmpty) {
          _scheduleNextLyricLineUpdate();
        }
      });
      _ensureFrameScheduled();
    });
    _ensureFrameScheduled();
  }

  static double _sineOutInterpolator(double t, double start, double end) {
    return start + (end - start) * sin(t * 3.141592653589793 / 2);
  }

  static Duration _scrollDurationForDistance(double distPx) {
    return Duration(
      milliseconds: ((440.0 + (distPx / 1200.0).clamp(0.0, 1.0) * 160.0))
          .round()
          .clamp(440, 600),
    );
  }

  double _snappedScrollOffset(double offset) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    return lyricSnapScrollOffset(offset, dpr);
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
      _runProgrammaticScroll(
        () => scrollController.jumpTo(_scrollTransition.value),
      );
    }
    if (!_scrollTransition.isActive) {
      _stopScrollTicker();
      _collapseDepartingBackgroundVocal();
    }
  }

  void _runProgrammaticScroll(void Function() action) {
    _programmaticScrollDepth++;
    try {
      action();
    } finally {
      _programmaticScrollDepth--;
    }
  }

  void _collapseDepartingBackgroundVocal() {
    if (_departingBackgroundVocalLines.isEmpty || _disposed || !mounted) {
      return;
    }
    if (_backgroundVocalExitController.isAnimating) return;
    final lines = Set<int>.of(_departingBackgroundVocalLines);
    final generation = ++_backgroundVocalExitGeneration;
    _backgroundVocalExitController.value = 0;
    _backgroundVocalExitController
        .animateTo(
          1.0,
          duration: lyricBackgroundVocalExitDuration,
          curve: Curves.linear,
        )
        .whenCompleteOrCancel(() {
          if (_disposed ||
              !mounted ||
              generation != _backgroundVocalExitGeneration ||
              !setEquals(lines, _departingBackgroundVocalLines)) {
            return;
          }
          setState(() {
            _finishDepartingBackgroundVocal();
          });
        });
  }

  void _discardDepartingBackgroundVocal() {
    _backgroundVocalExitGeneration++;
    _backgroundVocalExitController.stop();
    for (final value in _backgroundExitValues.values) {
      value.dispose();
    }
    _backgroundExitValues.clear();
    _backgroundExitStartedMs.clear();
    _backgroundExitClock
      ..stop()
      ..reset();
    _departingBackgroundVocalLines.clear();
  }

  void _finishDepartingBackgroundVocal() {
    final keep = _departingBackgroundVocalLines.intersection(
      _parallelGroupLines,
    );
    if (keep.isEmpty) {
      _discardDepartingBackgroundVocal();
      return;
    }
    for (final index in _backgroundExitValues.keys.toList()) {
      if (keep.contains(index)) {
        _backgroundExitValues[index]!.value = 0;
        continue;
      }
      _backgroundExitValues.remove(index)!.dispose();
      _backgroundExitStartedMs.remove(index);
    }
    _departingBackgroundVocalLines
      ..clear()
      ..addAll(keep);
    _backgroundVocalExitController.stop();
    _backgroundVocalExitController.value = 1;
  }

  double _backgroundVocalFactorForLine(int index) {
    final lines = widget.lyric.lines;
    if (index < 0 || index >= lines.length) return 0.0;
    final line = lines[index];
    if (line is! SyncLyricLine) return 0.0;
    return lyricBackgroundHeightFactor(
      currentTimeMs: _displayPositionMs,
      startMs: lyricBackgroundStartMs(line),
      endMs: lyricBackgroundEndMs(line),
      isMainLine: index == _mainLine || _parallelGroupLines.contains(index),
      isBackgroundActive: _backgroundActiveLyricLines.contains(index),
      isBackgroundVisible: widget.lyric is Ttml
          ? _parallelGroupLines.contains(index)
          : null,
      exitVisibility: _backgroundExitValues[index]?.value,
    );
  }

  void _prepareBackgroundExitValues(Set<int> next) {
    _backgroundVocalExitGeneration++;
    _backgroundVocalExitController.stop();
    final previousNow = _backgroundExitClock.isRunning
        ? _backgroundExitClock.elapsedMilliseconds
        : 0;
    for (final index in _backgroundExitValues.keys.toList()) {
      if (!next.contains(index)) {
        _backgroundExitValues.remove(index)!.dispose();
        _backgroundExitStartedMs.remove(index);
      }
    }
    if (next.isEmpty) {
      _backgroundExitClock
        ..stop()
        ..reset();
      return;
    }
    if (!_backgroundExitClock.isRunning) {
      _backgroundExitClock.start();
    }
    final now = _backgroundExitClock.elapsedMilliseconds;
    if (previousNow != now) {
      for (final index in _backgroundExitStartedMs.keys.toList()) {
        if (!_backgroundExitValues.containsKey(index)) continue;
        final elapsed = previousNow - _backgroundExitStartedMs[index]!;
        _backgroundExitStartedMs[index] = now - elapsed;
      }
    }
    for (final index in next) {
      if (_backgroundExitValues.containsKey(index)) continue;
      final startVisibility = _backgroundVocalFactorForLine(index);
      if (startVisibility <= 0.001) continue;
      final elapsed = lyricBackgroundExitElapsedMs(startVisibility);
      _backgroundExitValues[index] = ValueNotifier(startVisibility);
      _backgroundExitStartedMs[index] = now - elapsed.round();
    }
  }

  void _updateBackgroundExitValues() {
    final now = _backgroundExitClock.elapsedMilliseconds;
    for (final entry in _backgroundExitValues.entries) {
      final elapsed = now - _backgroundExitStartedMs[entry.key]!;
      entry.value.value = lyricBackgroundExitVisibility(elapsed.toDouble());
    }
  }

  void _computeOffsets(double maxWidth) {
    if (maxWidth <= 0) return;

    final lines = widget.lyric.lines;

    final controller = context.read<LyricViewController>();
    final config = controller.renderConfig;
    final fontFamily = ThemeProvider.instance.resolvedLyricFontFamily;
    final cacheKey = _LyricOffsetCacheKey(
      lyric: widget.lyric,
      widthPx: maxWidth.round(),
      config: config,
      fontFamily: fontFamily,
    );
    final cached = _offsetCache.remove(cacheKey);
    if (cached != null) {
      _offsetCache[cacheKey] = cached;
      _cachedOffsets = cached.offsets;
      _cachedHeights = cached.heights;
      _cachedBackgroundVocalHeights = cached.backgroundVocalHeights;
      _cachedLyricFontFamily = fontFamily;
      _markOffsetsComputed();
      return;
    }

    final baseSize = config.baseFontSize;
    final weight = config.fontWeight;
    final primaryHeight = config.primaryLineHeight(weight);
    final translationHeight = config.translationLineHeight(weight);
    final letterSpacing = config.letterSpacing(
      fontSize: baseSize,
      weight: weight,
    );
    final discreteWeight = config.discreteFontWeight(weight);

    final mainSize = config.primaryFontSize(isMainLine: true);
    final mainTransSize = lyricLayoutFontSize(
      mainFontSize: config.translationFontSize(isMainLine: true),
      subFontSize: config.translationFontSize(isMainLine: false),
    );
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    TextStyle measureTextStyle({
      required double fontSize,
      required FontWeight fontWeight,
      required double height,
      required double letterSpacing,
      List<FontVariation>? fontVariations,
    }) {
      return TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: appFontFamilyFallback(fontFamily),
        fontSize: fontSize,
        fontWeight: fontWeight,
        height: height,
        letterSpacing: letterSpacing,
        fontVariations: fontVariations,
      );
    }

    final painter = LyricsLinePainter.obtainTextPainter();

    final lineLayoutWidth = lyricLineLayoutWidth(maxWidth);

    double measureSyncLine(SyncLyricLine line, bool isMain) {
      if (line.words.isEmpty) {
        return lyricTransitionLayoutHeight(line, isMain: isMain);
      }
      return LyricsLinePainter(
        params: LyricPainterParams(
          line: line,
          currentTimeMs: 0.0,
          blurSigma: 0.0,
          config: config,
          isMainLine: isMain,
          isHighlightActive: false,
          accelerateTailHighlight: false,
          useMaterialYouColor: AppSettings.instance.useMaterialYouForLyrics,
          fontFamily: fontFamily,
          agent: line.agent,
          opacity: 1.0,
          lineMedianWordDuration: Duration.zero,
        ),
        scheme: scheme,
      ).measureHeight(
        lineLayoutWidth,
        reserveBackgroundVocalHeight: lyricLineHasBackgroundVocal(line),
      );
    }

    double measureLine(LyricLine line, bool isMain) {
      final isLineByLine =
          line is SyncLyricLine &&
          config.displayMode == LyricDisplayMode.lineByLine;
      final transitionHeight = lyricTransitionLayoutHeight(
        line,
        isMain: isMain,
      );
      if (transitionHeight > 0) return transitionHeight;

      if (line is SyncLyricLine && !isLineByLine) {
        if (line.words.isEmpty) return 0.0;
      } else if (line is LrcLine) {
        if (line.isBlank) return 0.0;
      }

      final primarySize = mainSize;
      final transSize = mainTransSize;
      final contentWidth = lineLayoutWidth - 24.0;

      double h = 0.0;

      final double vertPad;
      if (line is SyncLyricLine && !isLineByLine) {
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
        style: measureTextStyle(
          fontSize: primarySize,
          fontVariations: [FontVariation('wght', weight.toDouble())],
          fontWeight: discreteWeight,
          height: primaryHeight,
          letterSpacing: letterSpacing,
        ),
      );
      painter.layout(maxWidth: contentWidth);
      h += painter.height;

      final hasTranslation = line is SyncLyricLine && !isLineByLine
          ? line.translation != null
          : (line is LrcLine || (line is SyncLyricLine && isLineByLine)) &&
                line.translation != null &&
                line.translation!.trim().isNotEmpty;
      final hasRoman = line.romanLyric != null && line.romanLyric!.isNotEmpty;
      final vvActiveTracks = config.normalizedLineOrder.where((t) {
        switch (t) {
          case LyricLineTrack.original:
            return true;
          case LyricLineTrack.translation:
            return config.showTranslation && hasTranslation;
          case LyricLineTrack.romanization:
            return config.showRoman && hasRoman;
        }
      }).toList();
      final vvPreTracks = vvActiveTracks
          .takeWhile((t) => t != LyricLineTrack.original)
          .toList();
      final vvPostTracks = vvActiveTracks
          .skipWhile((t) => t != LyricLineTrack.original)
          .skip(1)
          .toList();

      // pre-original tracks
      double vvPreBase = h;
      for (final track in vvPreTracks) {
        if (h > vvPreBase) h += 2.0;
        if (track == LyricLineTrack.translation) {
          final translationWeight = (weight - 50).clamp(100, 900);
          if (line is SyncLyricLine &&
              !isLineByLine &&
              line.translation != null) {
            painter.text = TextSpan(
              text: line.translation!,
              style: measureTextStyle(
                fontSize: transSize,
                fontVariations: [
                  FontVariation('wght', translationWeight.toDouble()),
                ],
                fontWeight:
                    FontWeight.values[(((translationWeight / 100).round() - 1)
                        .clamp(0, 8))],
                height: translationHeight,
                letterSpacing: letterSpacing,
              ),
            );
            painter.layout(maxWidth: contentWidth);
            h += painter.height;
          } else if (line is LrcLine) {
            final parts = line.content.split('┃');
            for (int i = 1; i < parts.length; i++) {
              painter.text = TextSpan(
                text: parts[i],
                style: measureTextStyle(
                  fontSize: transSize,
                  fontVariations: [
                    FontVariation('wght', translationWeight.toDouble()),
                  ],
                  fontWeight:
                      FontWeight.values[(((translationWeight / 100).round() - 1)
                          .clamp(0, 8))],
                  height: translationHeight,
                  letterSpacing: letterSpacing,
                ),
              );
              painter.layout(maxWidth: contentWidth);
              h += painter.height;
            }
          }
        } else if (track == LyricLineTrack.romanization) {
          final String? roman;
          if (line is SyncLyricLine) {
            roman = line.romanLyric;
          } else if (line is LrcLine) {
            roman = line.romanLyric;
          } else {
            roman = null;
          }
          if (roman != null && roman.isNotEmpty) {
            final romanWeight = (weight - 150).clamp(100, 900);
            painter.text = TextSpan(
              text: roman,
              style: measureTextStyle(
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
      }

      // post-original tracks
      if (vvPostTracks.isNotEmpty) {
        final gap = line is SyncLyricLine && !isLineByLine
            ? config.syncTranslationGap(isMainLine: true)
            : config.lrcTranslationGap(isMainLine: true, translationIndex: 0);
        h += gap;
        var vvPostPrev = false;
        for (final track in vvPostTracks) {
          if (vvPostPrev) h += 4.0;
          vvPostPrev = true;
          if (track == LyricLineTrack.translation) {
            final translationWeight = (weight - 50).clamp(100, 900);
            if (line is SyncLyricLine &&
                !isLineByLine &&
                line.translation != null) {
              painter.text = TextSpan(
                text: line.translation!,
                style: measureTextStyle(
                  fontSize: transSize,
                  fontVariations: [
                    FontVariation('wght', translationWeight.toDouble()),
                  ],
                  fontWeight:
                      FontWeight.values[(((translationWeight / 100).round() - 1)
                          .clamp(0, 8))],
                  height: translationHeight,
                  letterSpacing: letterSpacing,
                ),
              );
              painter.layout(maxWidth: contentWidth);
              h += painter.height;
            } else if (line is LrcLine ||
                (line is SyncLyricLine && isLineByLine)) {
              final parts = line is LrcLine
                  ? line.content.split('┃')
                  : <String>[];
              if (line.translation != null &&
                  line.translation!.trim().isNotEmpty &&
                  !parts.contains(line.translation!)) {
                parts.add(line.translation!);
              }
              for (int i = 1; i < parts.length; i++) {
                painter.text = TextSpan(
                  text: parts[i],
                  style: measureTextStyle(
                    fontSize: transSize,
                    fontVariations: [
                      FontVariation('wght', translationWeight.toDouble()),
                    ],
                    fontWeight:
                        FontWeight.values[(((translationWeight / 100).round() -
                                1)
                            .clamp(0, 8))],
                    height: translationHeight,
                    letterSpacing: letterSpacing,
                  ),
                );
                painter.layout(maxWidth: contentWidth);
                h += painter.height;
              }
            }
          } else if (track == LyricLineTrack.romanization) {
            final String? roman;
            if (line is SyncLyricLine) {
              roman = line.romanLyric;
            } else if (line is LrcLine) {
              roman = line.romanLyric;
            } else {
              roman = null;
            }
            if (roman != null && roman.isNotEmpty) {
              final romanWeight = (weight - 150).clamp(100, 900);
              painter.text = TextSpan(
                text: roman,
                style: measureTextStyle(
                  fontSize: transSize * 0.85,
                  fontVariations: [
                    FontVariation('wght', romanWeight.toDouble()),
                  ],
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
        }
      }

      h += vertPad * 2;
      return h;
    }

    double measureBackgroundVocalHeight(LyricLine line) {
      if (line is! SyncLyricLine) return 0.0;
      final hasText = line.bgText != null && line.bgText!.isNotEmpty;
      final bgRomanLyric = line.bg?.romanLyric;
      final hasRoman =
          config.showRoman && bgRomanLyric != null && bgRomanLyric.isNotEmpty;
      final hasTranslation =
          line.bgTranslation != null && line.bgTranslation!.isNotEmpty;
      if (!hasText && !hasRoman && !hasTranslation && line.bgWords.isEmpty) {
        return 0.0;
      }

      final bgFontSize = mainSize * 0.60;
      final bgWeight = config.discreteFontWeight(
        (config.fontWeight - 150).clamp(100, 900),
      );
      var height = 0.0;
      if (hasText || line.bgWords.isNotEmpty) {
        painter.text = TextSpan(
          text: hasText
              ? line.bgText!
              : line.bgWords.map((word) => word.content).join(),
          style: measureTextStyle(
            fontSize: bgFontSize,
            fontWeight: bgWeight,
            height: primaryHeight,
            letterSpacing: config.letterSpacing(fontSize: bgFontSize),
          ),
        );
        painter.layout(maxWidth: maxWidth);
        height += bgFontSize * 0.80 + painter.height;
      }
      if (hasRoman) {
        painter.text = TextSpan(
          text: bgRomanLyric,
          style: measureTextStyle(
            fontSize: bgFontSize * 0.85,
            fontWeight: bgWeight,
            height: primaryHeight,
            letterSpacing: config.letterSpacing(fontSize: bgFontSize * 0.85),
          ),
        );
        painter.layout(maxWidth: maxWidth);
        height += bgFontSize * 0.45 + painter.height;
      }
      if (hasTranslation) {
        painter.text = TextSpan(
          text: line.bgTranslation!,
          style: measureTextStyle(
            fontSize: bgFontSize * 0.90,
            fontWeight: bgWeight,
            height: primaryHeight,
            letterSpacing: config.letterSpacing(fontSize: bgFontSize * 0.90),
          ),
        );
        painter.layout(maxWidth: maxWidth);
        height += bgFontSize * 0.45 + painter.height;
      }
      return height;
    }

    final offsets = <double>[];
    final heights = <double>[];
    final backgroundVocalHeights = <double>[];
    double currentOffset = 0.0;

    for (int i = 0; i < lines.length; i++) {
      offsets.add(currentOffset);
      final preciseSyncMeasure =
          lines[i] is SyncLyricLine &&
          config.displayMode != LyricDisplayMode.lineByLine;
      final hAsMain = preciseSyncMeasure
          ? measureSyncLine(lines[i] as SyncLyricLine, true)
          : measureLine(lines[i], true);
      heights.add(hAsMain);
      final hAsSub = preciseSyncMeasure
          ? measureSyncLine(lines[i] as SyncLyricLine, false)
          : measureLine(lines[i], false);
      backgroundVocalHeights.add(measureBackgroundVocalHeight(lines[i]));
      currentOffset += hAsSub;
    }

    _cachedOffsets = offsets;
    _cachedHeights = heights;
    _cachedBackgroundVocalHeights = backgroundVocalHeights;
    _cachedLyricFontFamily = fontFamily;
    _offsetCache[cacheKey] = _LyricOffsetCacheEntry(
      offsets: offsets,
      heights: heights,
      backgroundVocalHeights: backgroundVocalHeights,
      maxWidth: maxWidth,
      viewportHeight: _cachedViewportHeight,
    );
    while (_offsetCache.length > _lyricOffsetCacheCapacity) {
      _offsetCache.remove(_offsetCache.keys.first);
    }
    LyricsLinePainter.recycleTextPainter(painter);

    _markOffsetsComputed();
  }

  void _markOffsetsComputed() {
    _pendingScrollRetries = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      final forceScroll = shouldForceLyricScrollAfterOffsetsComputed(
        needsInitialScroll: _needsInitialScroll,
        isUserDragging: _scrollState == LyricScrollState.userDragging,
      );
      _syncToPlaybackPosition(
        duration: Duration.zero,
        forceScroll: forceScroll,
      );
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
    _discardPendingLyricLineUpdates();
    _userScrollTracker.end();
    _userScrollHoldTimer?.cancel();
    _userScrollHoldTimer = null;
    _scrollState = LyricScrollState.idle;
    _needsInitialScroll = true;
    setState(() {
      _pendingStaggerScroll = false;
      _jumpDeltaY = 0;
      _jumpTriggerId++;
    });
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
      _discardPendingLyricLineUpdates();

      // 切歌时取消所有待处理的 Timer/Ticker，避免泄漏
      _stopScrollTicker();
      _ensureVisibleTimer?.cancel();
      _ensureVisibleTimer = null;
      _userScrollHoldTimer?.cancel();
      _userScrollHoldTimer = null;
      _userScrollTracker.end();
      _scrollState = LyricScrollState.idle;
      _sizeChangeTimer?.cancel();
      _sizeChangeTimer = null;

      _cachedMaxWidth = 0.0;
      _cachedOffsets = null;
      _cachedHeights = null;
      _cachedBackgroundVocalHeights = null;
      _cachedViewportHeight = 0.0;
      _cachedLyricFontFamily = null;
      _needsInitialScroll = true;
      _displayPositionMs = playbackService.position * 1000.0;
      _pendingScrollRetries = 0;
      _mainLine = 0;
      _pendingStaggerScroll = false;
      _postDragSkipPending = false;
      _jumpDeltaY = 0;
      _jumpTriggerId++;
      _parallelGroupLines.clear();
      _mainActiveLyricLines.clear();
      _backgroundActiveLyricLines.clear();
      _lastTtmlGeneration = null;
      _activeLyricLines.clear();
      _tailHighlightCatchUpLine = null;
      _discardDepartingBackgroundVocal();
      _viewportRange = const LyricViewportRange(start: 0, end: 0);
      _lineKeys.clear();
      _startPositionResyncWindow();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
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
      _cachedBackgroundVocalHeights = null;
      final oldMainLine = _mainLine;
      setState(() {
        _pendingStaggerScroll = false;
        _jumpDeltaY = 0;
        _jumpTriggerId++;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
        if (_mainLine >= widget.lyric.lines.length) {
          _mainLine = oldMainLine.clamp(0, widget.lyric.lines.length - 1);
        }
        _syncToPlaybackPosition(duration: Duration.zero);
      });
    });
  }

  int _firstVisibleLineIndex() {
    if (!scrollController.hasClients) return _viewportRange.start;
    final viewportContext =
        scrollController.position.context.notificationContext;
    final viewportBox = viewportContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) {
      return _viewportRange.start;
    }

    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportBox.size.height;
    int? firstVisible;
    for (final entry in _lineKeys.entries) {
      final lineContext = entry.value.currentContext;
      final lineBox = lineContext?.findRenderObject() as RenderBox?;
      if (lineBox == null || !lineBox.hasSize) continue;
      final lineTop = lineBox.localToGlobal(Offset.zero).dy;
      final lineBottom = lineTop + lineBox.size.height;
      if (lineBottom > viewportTop && lineTop < viewportBottom) {
        firstVisible = firstVisible == null
            ? entry.key
            : min(firstVisible, entry.key);
      }
    }
    return firstVisible ?? _viewportRange.start;
  }

  double? _staggerTargetOffset(int toIndex) {
    if (!scrollController.hasClients) return null;
    final offsets = _cachedOffsets;
    final heights = _cachedHeights;
    final fromIndex = _staggerFromIndex;
    if (offsets == null ||
        heights == null ||
        fromIndex < 0 ||
        toIndex < 0 ||
        fromIndex >= offsets.length ||
        toIndex >= offsets.length ||
        fromIndex >= heights.length ||
        toIndex >= heights.length) {
      return null;
    }
    return _snappedScrollOffset(
      lyricStaggerScrollTarget(
        currentOffset: scrollController.offset,
        fromIndex: fromIndex,
        toIndex: toIndex,
        offsets: offsets,
        heights: heights,
        alignment: widget.currentLineAlignment,
      ),
    );
  }

  double? _targetScrollOffsetFor(int lineIndex) {
    if (!scrollController.hasClients) return null;
    if (_cachedOffsets == null ||
        _cachedHeights == null ||
        lineIndex < 0 ||
        lineIndex >= _cachedOffsets!.length ||
        lineIndex >= _cachedHeights!.length) {
      return null;
    }
    final viewport = scrollController.position.viewportDimension;
    final alignment = widget.currentLineAlignment;
    final topPadding = _snappedScrollOffset(
      lyricListTopPadding(
        viewportHeight: viewport,
        centerVertically: widget.centerVertically,
        enableEdgeSpacer: widget.enableEdgeSpacer,
        alignment: alignment,
      ),
    );
    final lineTop = _cachedOffsets![lineIndex];
    final lineHeight = _cachedHeights![lineIndex];
    return _snappedScrollOffset(
      lyricScrollOffsetToAlignLine(
        topPadding: topPadding,
        lineTop: lineTop,
        lineHeight: lineHeight,
        viewportHeight: viewport,
        alignment: alignment,
      ),
    );
  }

  void _markInitialScrollFinished({
    required double requestedOffset,
    required double targetHeight,
  }) {
    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    if (!shouldFinishInitialLyricScroll(
      hasContentDimensions: position.hasContentDimensions,
      viewportDimension: position.viewportDimension,
      targetHeight: targetHeight,
      requestedOffset: requestedOffset,
      appliedOffset: position.pixels,
    )) {
      return;
    }
    _needsInitialScroll = false;
    _positionResyncExtensionCount = 0;
  }

  void _prepareForcedLyricFollow() {
    _pendingScrollRetries = 0;
    _userScrollHoldTimer?.cancel();
    _userScrollHoldTimer = null;
    _userScrollTracker.end();
    _stopScrollTicker();
    _postDragSkipPending = false;
    _pendingStaggerScroll = false;
    if (_scrollState == LyricScrollState.userDragging) {
      _scrollState = LyricScrollState.idle;
    }
  }

  void _staggerScrollTo(
    double targetOffset, {
    bool clearPendingStagger = true,
  }) {
    if (!scrollController.hasClients) return;
    if (clearPendingStagger) {
      _pendingStaggerScroll = false;
    }
    final from = scrollController.offset;
    final to = targetOffset.clamp(
      scrollController.position.minScrollExtent,
      scrollController.position.maxScrollExtent,
    );
    _jumpDeltaY = lyricStaggerJumpDeltaY(from: from, to: to);
    if (_jumpDeltaY != 0) {
      _jumpTriggerId++;
      final triggerId = _jumpTriggerId;
      setState(() {});
      _runProgrammaticScroll(() => scrollController.jumpTo(to));
      _userScrollHoldTimer?.cancel();
      _userScrollHoldTimer = null;
      _scrollTransition.jumpTo(to);
      _stopScrollTicker();
      _collapseDepartingBackgroundVocal();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
        if (_jumpTriggerId != triggerId || _jumpDeltaY == 0) return;
        setState(() => _jumpDeltaY = 0);
      });
    } else {
      _jumpDeltaY = 0;
      _collapseDepartingBackgroundVocal();
    }
  }

  /// ValueTransition 驱动的丝滑滚动
  void _animateTo(double targetOffset, {Duration? duration}) {
    if (!scrollController.hasClients) return;
    final minExtent = scrollController.position.minScrollExtent;
    final maxExtent = scrollController.position.maxScrollExtent;
    final to = _snappedScrollOffset(targetOffset.clamp(minExtent, maxExtent));
    final from = scrollController.offset;
    final dist = (to - from).abs();
    final forceJump = duration != null && duration.inMilliseconds <= 16;
    final isAnimating = _scrollTransition.isActive;
    final animatingToSameTarget =
        isAnimating &&
        (to - _scrollTransition.target).abs() < lyricScrollSettlePx;
    if (shouldSnapLyricScroll(
      distancePx: dist,
      forceJump: forceJump,
      animatingToSameTarget: animatingToSameTarget,
      isAnimating: isAnimating,
    )) {
      _runProgrammaticScroll(() => scrollController.jumpTo(to));
      _scrollTransition.jumpTo(to);
      _stopScrollTicker();
      if (_scrollState == LyricScrollState.programScrolling) {
        _scrollState = LyricScrollState.idle;
      }
      _collapseDepartingBackgroundVocal();
      return;
    }
    if (!shouldRestartLyricScroll(
      animatingToSameTarget: animatingToSameTarget,
      forceJump: forceJump,
      isAnimating: isAnimating,
      distancePx: dist,
    )) {
      return;
    }

    _scrollTransition.begin = from;
    final style = context.read<LyricViewController>().renderConfig.staggerStyle;
    _scrollTransition.interpolator = style == LyricStaggerStyle.smooth
        ? lyricSmoothTransitionInterpolator
        : _sineOutInterpolator;
    _scrollTransition.duration =
        duration ??
        (style == LyricStaggerStyle.smooth
            ? lyricSmoothTransitionDuration
            : _scrollDurationForDistance(dist));
    _scrollTransition.start(to);
    _startScrollTicker();

    if (_scrollState != LyricScrollState.userDragging) {
      _scrollState = LyricScrollState.programScrolling;
    }
  }

  void _handleUserScrollPhase(LyricUserScrollPhase phase) {
    switch (phase) {
      case LyricUserScrollPhase.ignored:
        return;
      case LyricUserScrollPhase.started:
        _beginUserScrolling();
      case LyricUserScrollPhase.updated:
        _markActivity();
        _userScrollHoldTimer?.cancel();
      case LyricUserScrollPhase.ended:
        _scheduleUserScrollRelease();
    }
  }

  void _beginUserScrolling() {
    _markActivity();
    _userScrollHoldTimer?.cancel();
    if (_scrollState != LyricScrollState.userDragging) {
      _stopScrollTicker();
      _discardDepartingBackgroundVocal();
      setState(() {
        _scrollState = LyricScrollState.userDragging;
        _pendingStaggerScroll = false;
        _postDragSkipPending = true;
        _jumpDeltaY = 0;
        _jumpTriggerId++;
      });
    }
  }

  void _scheduleUserScrollRelease() {
    final renderConfig = context.read<LyricViewController>().renderConfig;
    final viewportStrategy = LyricViewportStrategy(
      leadingLines: renderConfig.viewportLeadingLines,
      trailingLines: renderConfig.viewportTrailingLines,
      overscanScreens: renderConfig.viewportOverscanScreens,
      userScrollHoldDuration: renderConfig.userScrollHoldDuration,
    );
    final holdDuration = renderConfig.staggerStyle == LyricStaggerStyle.spring
        ? const Duration(seconds: 3)
        : viewportStrategy.userScrollHoldDuration;
    _userScrollHoldTimer?.cancel();
    _userScrollHoldTimer = Timer(holdDuration, () {
      if (!mounted || _userScrollTracker.isActive) return;
      setState(() {
        _scrollState = LyricScrollState.idle;
        _pendingStaggerScroll = false;
        _postDragSkipPending = false;
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

  void _scheduleScrollToLine(_LyricScrollRequest request) {
    if (_disposed || request.updateGeneration != _lyricLineUpdateGeneration) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      _scrollToLine(request);
    });
    _ensureFrameScheduled();
  }

  void _scrollToCurrent([Duration? duration]) {
    _scrollToLine(
      _LyricScrollRequest(
        lineIndex: _mainLine,
        useStagger: _pendingStaggerScroll,
        duration: duration,
        updateGeneration: _lyricLineUpdateGeneration,
      ),
    );
  }

  void _scrollToLine(_LyricScrollRequest request) {
    if (_disposed || request.updateGeneration != _lyricLineUpdateGeneration) {
      return;
    }
    if (shouldIgnoreLyricFollowWhileUserScrolling(
      isUserDragging: _scrollState == LyricScrollState.userDragging,
    )) {
      return;
    }
    if (!scrollController.hasClients) {
      if (_pendingScrollRetries < _maxPendingScrollRetries) {
        _pendingScrollRetries++;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed || !mounted) return;
          _scrollToLine(request);
        });
      }
      return;
    }
    _pendingScrollRetries = 0;

    _scrollState = LyricScrollState.programScrolling;

    final useStagger = request.useStagger && !_needsInitialScroll;
    final duration = _needsInitialScroll ? Duration.zero : request.duration;
    if (useStagger) {
      final staggerTarget =
          _staggerTargetOffset(request.lineIndex) ??
          _targetScrollOffsetFor(request.lineIndex);
      if (staggerTarget != null) {
        _staggerScrollTo(
          staggerTarget,
          clearPendingStagger: request.lineIndex == _mainLine,
        );
        _scrollState = LyricScrollState.idle;
        return;
      }
    }
    final targetContext = _lineKeys[request.lineIndex]?.currentContext;
    if (targetContext != null && targetContext.mounted) {
      RenderBox? targetObject;
      try {
        targetObject = targetContext.findRenderObject() as RenderBox?;
      } catch (_) {}
      if (targetObject != null &&
          targetObject.hasSize &&
          targetObject.size.height > 0) {
        final viewport = RenderAbstractViewport.of(targetObject);
        final revealed = viewport.getOffsetToReveal(
          targetObject,
          widget.currentLineAlignment,
        );
        _animateTo(revealed.offset, duration: duration);
        if (request.lineIndex == _mainLine) {
          _markInitialScrollFinished(
            requestedOffset: revealed.offset,
            targetHeight: targetObject.size.height,
          );
        }
        return;
      }
    }

    final cachedTarget = _targetScrollOffsetFor(request.lineIndex);
    if (cachedTarget != null) {
      _animateTo(cachedTarget, duration: duration);
      return;
    }

    if (_pendingScrollRetries < _maxPendingScrollRetries) {
      _pendingScrollRetries++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
        if (_cachedOffsets == null && _cachedMaxWidth > 0) {
          _computeOffsets(_cachedMaxWidth);
        }
        _scrollToLine(request);
      });
    }
  }

  void _initLyricView() {
    _updateViewportRange(force: true);
  }

  void _seekToLyricLine(int i) {
    _discardPendingLyricLineUpdates();
    _pendingStaggerScroll = false;
    _jumpDeltaY = 0;
    _jumpTriggerId++;
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

  double? _highlightDeadlineForLine(int lineIndex) {
    return lyricHighlightDeadlineMsForLine(widget.lyric, lineIndex)?.toDouble();
  }

  Set<int> _renderableLineIndices(List<int> indices) {
    final lines = widget.lyric.lines;
    if (lines.isEmpty || indices.isEmpty) return const <int>{};
    return indices
        .where(
          (i) => i >= 0 && i < lines.length && !_isLineBlankFiltered(lines[i]),
        )
        .toSet();
  }

  double _lineHeightFor(int index) {
    final lineContext = _lineKeys[index]?.currentContext;
    final lineBox = lineContext != null && lineContext.mounted
        ? lineContext.findRenderObject() as RenderBox?
        : null;
    if (lineBox != null && lineBox.hasSize && lineBox.size.height > 0) {
      return lineBox.size.height;
    }
    final lineHeight =
        _cachedHeights != null && index >= 0 && index < _cachedHeights!.length
        ? _cachedHeights![index]
        : 96.0;
    return lineHeight;
  }

  double? _parallelLineHeightBudget() {
    final viewportHeight = _cachedViewportHeight > 0
        ? _cachedViewportHeight
        : scrollController.hasClients
        ? scrollController.position.viewportDimension
        : 0.0;
    if (viewportHeight <= 0) return null;
    final alignment = widget.currentLineAlignment.clamp(0.0, 1.0).toDouble();
    final availableBelow = viewportHeight * (1.0 - alignment);
    return availableBelow * 0.90;
  }

  int? _tailHighlightCatchUpLineFor(
    Set<int> candidates, {
    Set<int>? visibleCandidates,
  }) {
    if (candidates.length <= 1) return null;
    final heightBudget = _parallelLineHeightBudget();
    if (heightBudget == null) return null;

    final totalHeight = candidates.fold<double>(
      0.0,
      (total, index) => total + _lineHeightFor(index),
    );
    if (totalHeight <= heightBudget) return null;
    final tail = candidates.reduce(max);
    if (visibleCandidates == null || visibleCandidates.contains(tail)) {
      return tail;
    }
    return visibleCandidates.isEmpty ? null : visibleCandidates.reduce(max);
  }

  Set<int> _fitParallelLines(Set<int> candidates, Set<int> activeLines) {
    if (candidates.length <= 1) return candidates;
    final heightBudget = _parallelLineHeightBudget();
    if (heightBudget == null) return candidates;

    final sorted = candidates.toList()..sort();
    final totalHeight = sorted.fold<double>(
      0.0,
      (total, index) => total + _lineHeightFor(index),
    );
    if (totalHeight <= heightBudget) return candidates;

    final activeCandidates = activeLines.where(candidates.contains).toSet();
    final anchor = activeCandidates.isEmpty
        ? sorted.last
        : activeCandidates.reduce(max);
    final selected = <int>{};
    var usedHeight = 0.0;

    final priority = sorted.toList()
      ..sort((a, b) {
        if (a == anchor) return -1;
        if (b == anchor) return 1;
        final aActive = activeCandidates.contains(a);
        final bActive = activeCandidates.contains(b);
        if (aActive != bActive) return aActive ? -1 : 1;
        final distance = (a - anchor).abs().compareTo((b - anchor).abs());
        return distance != 0 ? distance : a.compareTo(b);
      });
    for (final index in priority) {
      final lineHeight = _lineHeightFor(index);
      if (selected.isNotEmpty && usedHeight + lineHeight > heightBudget) {
        continue;
      }
      selected.add(index);
      usedHeight += lineHeight;
    }
    if (selected.isEmpty) selected.add(anchor);
    return selected;
  }

  ({
    int primaryIndex,
    Set<int> groupLines,
    Set<int> mainActiveLines,
    Set<int> backgroundActiveLines,
    Set<int> activeLines,
    int? tailCatchUpLine,
  })
  _displayLineUpdate(LyricLineUpdate update) {
    final lines = widget.lyric.lines;
    final positionMs =
        update.positionMs?.toDouble() ?? playbackService.position * 1000.0;
    final layoutLines = _renderableLineIndices(update.layoutIndices);
    final mainActiveLines = _renderableLineIndices(update.mainActiveIndices);
    final backgroundActiveLines = _renderableLineIndices(
      update.backgroundActiveIndices,
    );
    final activeLines = <int>{...mainActiveLines, ...backgroundActiveLines};
    final groupCandidates = layoutLines;
    final groupLines = update.usesAuthoredTiming
        ? groupCandidates
        : _fitParallelLines(groupCandidates, mainActiveLines);
    final primaryIndex = lyricDisplayPrimaryIndex(
      fallbackPrimaryIndex: update.primaryIndex,
      lineCount: lines.length,
      groupedLines: groupLines,
    );
    if (update.usesAuthoredTiming) {
      return (
        primaryIndex: primaryIndex,
        groupLines: groupLines,
        mainActiveLines: mainActiveLines,
        backgroundActiveLines: backgroundActiveLines,
        activeLines: activeLines,
        tailCatchUpLine: null,
      );
    }
    var tailCatchUp = _tailHighlightCatchUpLineFor(
      groupCandidates,
      visibleCandidates: groupLines,
    );
    if (tailCatchUp == null && groupLines.length > 1) {
      final nextTriggerMs = _nextNonGroupLineTriggerMs(lines, groupCandidates);
      if (nextTriggerMs != null && positionMs >= nextTriggerMs) {
        tailCatchUp = groupLines.reduce(max);
      }
    }
    return (
      primaryIndex: primaryIndex,
      groupLines: groupLines,
      mainActiveLines: mainActiveLines,
      backgroundActiveLines: backgroundActiveLines,
      activeLines: activeLines,
      tailCatchUpLine: tailCatchUp,
    );
  }

  double? _nextNonGroupLineTriggerMs(
    List<LyricLine> lines,
    Set<int> groupLines,
  ) {
    final lastIndex = groupLines.reduce(max);
    for (var i = lastIndex + 1; i < lines.length; i++) {
      if (_isLineBlankFiltered(lines[i])) continue;
      final line = lines[i];
      if (line is SyncLyricLine && line.words.isNotEmpty) {
        return (line.words.first.start.inMilliseconds - lyricWordPreSwitchMs)
            .toDouble();
      }
      return line.start.inMilliseconds.toDouble();
    }
    return null;
  }

  void _syncToPlaybackPosition({Duration? duration, bool forceScroll = true}) {
    if (_disposed || !mounted) return;
    final update = lyricService.lineUpdateForLyric(
      widget.lyric,
      playbackService.position,
    );
    if (update == null) {
      if (forceScroll) _discardPendingLyricLineUpdates();
      lyricService.forceEmitCurrentLine();
      return;
    }
    if (forceScroll && update.usesAuthoredTiming) {
      _discardPendingLyricLineUpdates();
    }
    if (shouldEnqueuePlayingLyricResync(
      forceScroll: forceScroll,
      needsInitialScroll: _needsInitialScroll,
      isPlaying: playbackService.playerState == PlayerState.playing,
    )) {
      _enqueueLyricLineUpdate(update);
      return;
    }
    final resyncIndex =
        _nearestRenderableLineIndex(
          _displayLineUpdate(update).primaryIndex,
          preferForward: forceScroll || _needsInitialScroll,
        ) ??
        _mainLine;
    if (shouldDiscardQueuedLyricUpdatesForResync(
      forceScroll: forceScroll,
      currentIndex: _mainLine,
      resyncIndex: resyncIndex,
    )) {
      _discardPendingLyricLineUpdates();
    } else if (_hasPendingLyricLineUpdates) {
      return;
    }
    _applyLyricLineUpdate(update, forceScroll: forceScroll, duration: duration);
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
    if (!shouldAcceptLyricUiUpdate(
      windowFramesEnabled: WindowRenderGate.instance.shouldRender,
    )) {
      return;
    }
    if (_disposed || !mounted) return;
    if (_hasPendingLyricLineUpdates) {
      if (_needsInitialScroll &&
          !shouldIgnoreLyricFollowWhileUserScrolling(
            isUserDragging: _scrollState == LyricScrollState.userDragging,
          )) {
        _scrollToCurrent(Duration.zero);
      }
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastPositionResyncMs < 200) return;
    _lastPositionResyncMs = nowMs;
    final preferUpcoming = _needsInitialScroll;
    final update = lyricService.lineUpdateForLyric(widget.lyric, position);
    if (update == null) return;
    final displayUpdate = _displayLineUpdate(update);
    final nextMainLine = _nearestRenderableLineIndex(
      displayUpdate.primaryIndex,
      preferForward: preferUpcoming,
    );
    if (nextMainLine == null) return;
    final positionMs = position * 1000.0;
    final positionChanged = (_displayPositionMs - positionMs).abs() > 0.5;
    if (nextMainLine == _mainLine &&
        setEquals(_parallelGroupLines, displayUpdate.groupLines) &&
        setEquals(_mainActiveLyricLines, displayUpdate.mainActiveLines) &&
        setEquals(
          _backgroundActiveLyricLines,
          displayUpdate.backgroundActiveLines,
        ) &&
        setEquals(_activeLyricLines, displayUpdate.activeLines) &&
        _tailHighlightCatchUpLine == displayUpdate.tailCatchUpLine &&
        (playbackService.playerState == PlayerState.playing ||
            !positionChanged)) {
      if (_needsInitialScroll &&
          !shouldIgnoreLyricFollowWhileUserScrolling(
            isUserDragging: _scrollState == LyricScrollState.userDragging,
          )) {
        _scrollToCurrent(Duration.zero);
      }
      return;
    }
    if (_needsInitialScroll) {
      if (shouldIgnoreLyricFollowWhileUserScrolling(
        isUserDragging: _scrollState == LyricScrollState.userDragging,
      )) {
        return;
      }
      _syncToPlaybackPosition(duration: Duration.zero, forceScroll: true);
      return;
    }
    if (!shouldApplyPlaybackLyricResync(
      currentIndex: _mainLine,
      resyncIndex: nextMainLine,
      isPlaying: playbackService.playerState == PlayerState.playing,
      usesAuthoredTiming: update.usesAuthoredTiming,
    )) {
      return;
    }
    _enqueueLyricLineUpdate(update);
  }

  void _applyLyricLineUpdate(
    LyricLineUpdate update, {
    bool forceScroll = false,
    Duration? duration,
  }) {
    if (_disposed || !mounted) return;
    var resetVoiceLayout = forceScroll;
    if (update.sourceLyric != null &&
        !identical(update.sourceLyric, widget.lyric)) {
      return;
    }
    if (update.usesAuthoredTiming && update.generation != null) {
      if (_lastTtmlGeneration != null &&
          update.generation! < _lastTtmlGeneration!) {
        return;
      }
      if (update.generation != _lastTtmlGeneration) {
        resetVoiceLayout = true;
        _discardDepartingBackgroundVocal();
      }
      _lastTtmlGeneration = update.generation;
    }
    if (forceScroll) _discardDepartingBackgroundVocal();
    final lines = widget.lyric.lines;
    if (lines.isEmpty) return;

    final positionMs =
        update.positionMs?.toDouble() ?? playbackService.position * 1000.0;
    final displayUpdate = _displayLineUpdate(update);
    final positionChanged = (_displayPositionMs - positionMs).abs() > 0.5;
    final nextGroupLines = displayUpdate.groupLines;
    final nextMainActiveLines = displayUpdate.mainActiveLines;
    final nextBackgroundActiveLines = displayUpdate.backgroundActiveLines;
    final nextActiveLines = displayUpdate.activeLines;
    final nextTailHighlightCatchUpLine = displayUpdate.tailCatchUpLine;
    final nextMainLine = displayUpdate.primaryIndex;
    final preferForward = forceScroll || _needsInitialScroll;
    final renderableMainLine = _nearestRenderableLineIndex(
      nextMainLine,
      preferForward: preferForward,
    );
    if (renderableMainLine == null) return;
    if (renderableMainLine == _mainLine &&
        setEquals(_parallelGroupLines, nextGroupLines) &&
        setEquals(_mainActiveLyricLines, nextMainActiveLines) &&
        setEquals(_backgroundActiveLyricLines, nextBackgroundActiveLines) &&
        setEquals(_activeLyricLines, nextActiveLines) &&
        _tailHighlightCatchUpLine == nextTailHighlightCatchUpLine) {
      if (resetVoiceLayout ||
          positionChanged &&
              (_needsInitialScroll ||
                  playbackService.playerState != PlayerState.playing)) {
        setState(() {
          _displayPositionMs = positionMs;
        });
      }
      if (forceScroll || _needsInitialScroll) {
        if (forceScroll) {
          _prepareForcedLyricFollow();
        }
        _scheduleScrollToLine(
          _LyricScrollRequest(
            lineIndex: renderableMainLine,
            useStagger: false,
            duration: duration,
            updateGeneration: _lyricLineUpdateGeneration,
          ),
        );
      }
      return;
    }
    final previousMainLine = _mainLine;
    final mainLineChanged = previousMainLine != renderableMainLine;
    bool hasBackgroundVocal(int index) {
      final line = lines[index];
      return line is SyncLyricLine && lyricLineHasBackgroundVocal(line);
    }

    final leftGroupBg = _parallelGroupLines
        .difference(nextGroupLines)
        .where(hasBackgroundVocal);
    final crowdedBg = update.usesAuthoredTiming
        ? lyricBackgroundLinesToEvict(
            groupLines: nextGroupLines,
            mainActiveLines: nextMainActiveLines,
            backgroundLines: {
              for (final index in nextGroupLines)
                if (hasBackgroundVocal(index)) index,
            },
            lineHeight: _lineHeightFor,
            heightBudget: _parallelLineHeightBudget(),
          )
        : const <int>{};
    final nextDepartingBackgroundVocalLines = resetVoiceLayout
        ? <int>{}
        : <int>{
            ..._departingBackgroundVocalLines.where(nextGroupLines.contains),
            ...leftGroupBg,
            ...crowdedBg,
          };
    final startBackgroundVocalExit = !setEquals(
      _departingBackgroundVocalLines,
      nextDepartingBackgroundVocalLines,
    );
    if (startBackgroundVocalExit) {
      _prepareBackgroundExitValues(nextDepartingBackgroundVocalLines);
    }

    final renderConfig = context.read<LyricViewController>().renderConfig;
    final shouldStagger = canStartLyricStagger(
      enabled:
          !forceScroll &&
          renderConfig.enableStaggeredAnimation &&
          renderConfig.staggerStyle == LyricStaggerStyle.spring,
      previousIndex: _mainLine,
      nextIndex: renderableMainLine,
      isUserDragging: _scrollState == LyricScrollState.userDragging,
      skipNextAfterDrag: _postDragSkipPending,
    );
    if (shouldStagger) {
      _staggerFromIndex = previousMainLine;
      _staggerVisibleStartIndex = _firstVisibleLineIndex();
    }
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
    final shouldScroll = shouldFollowLyricLineScroll(
      forceScroll: forceScroll,
      needsInitialScroll: _needsInitialScroll,
      mainLineChanged: mainLineChanged,
    );
    _pendingStaggerScroll = shouldScroll && shouldStagger;

    if (forceScroll) {
      _prepareForcedLyricFollow();
    }

    setState(() {
      _mainLine = renderableMainLine;
      _displayPositionMs = positionMs;
      _sharedLyricPositionMs.value = positionMs.toDouble();
      _departingBackgroundVocalLines
        ..clear()
        ..addAll(nextDepartingBackgroundVocalLines);
      _parallelGroupLines
        ..clear()
        ..addAll(nextGroupLines);
      _mainActiveLyricLines
        ..clear()
        ..addAll(nextMainActiveLines);
      _backgroundActiveLyricLines
        ..clear()
        ..addAll(nextBackgroundActiveLines);
      _activeLyricLines
        ..clear()
        ..addAll(nextActiveLines);
      _tailHighlightCatchUpLine = nextTailHighlightCatchUpLine;
      _pruneLineKeys();
      _viewportRange = forceScroll
          ? viewportStrategy.rangeForMainLine(
              mainLine: renderableMainLine,
              totalLines: lines.length,
            )
          : followDecision.nextRange;
      if (forceScroll && _scrollState == LyricScrollState.userDragging) {
        _scrollState = LyricScrollState.idle;
      }
    });

    if (startBackgroundVocalExit && _departingBackgroundVocalLines.isNotEmpty) {
      _collapseDepartingBackgroundVocal();
    }

    if (shouldScroll) {
      _scheduleScrollToLine(
        _LyricScrollRequest(
          lineIndex: renderableMainLine,
          useStagger: shouldStagger,
          duration: duration,
          updateGeneration: _lyricLineUpdateGeneration,
        ),
      );
    } else {
      _pendingStaggerScroll = false;
    }
  }

  void _updateNextLyricLine(LyricLineUpdate update) {
    if (_disposed || !mounted) return;
    if (widget.lyric.lines.isEmpty ||
        update.primaryIndex < 0 ||
        update.primaryIndex >= widget.lyric.lines.length) {
      _syncToPlaybackPosition(forceScroll: false);
      return;
    }
    // 播放中的回退行只可能来自用户拖动进度条，防抖队列会把它丢弃，
    // 这里直接强制定位回目标行。
    if (playbackService.playerState == PlayerState.playing &&
        update.primaryIndex < _mainLine) {
      _queuePlaybackResync(forceScroll: true);
      return;
    }
    _enqueueLyricLineUpdate(update);
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
    final usesAuthoredTiming = widget.lyric is Ttml;
    final freezeParallelGroup =
        !usesAuthoredTiming && _parallelGroupLines.length > 1;
    final lyricFontFamily = context
        .watch<ThemeProvider>()
        .resolvedLyricFontFamily;
    return LayoutBuilder(
      builder: (context, constraints) {
        final needsOffsets =
            _cachedOffsets == null ||
            constraints.maxWidth != _cachedMaxWidth ||
            _cachedLyricFontFamily != lyricFontFamily;
        if (needsOffsets) {
          _cachedMaxWidth = constraints.maxWidth;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_disposed || !mounted) return;
            _computeOffsets(constraints.maxWidth);
          });
        }

        final viewportHeight = constraints.maxHeight;
        final viewportHeightChanged =
            viewportHeight.isFinite &&
            viewportHeight > 0 &&
            (viewportHeight - _cachedViewportHeight).abs() > 0.5;
        if (viewportHeightChanged) {
          _cachedViewportHeight = viewportHeight;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_disposed || !mounted) return;
            _syncToPlaybackPosition(
              duration: Duration.zero,
              forceScroll: shouldForceLyricScrollForViewportChange(
                needsInitialScroll: _needsInitialScroll,
              ),
            );
          });
        }
        final extraTopPadding = lyricListTopPadding(
          viewportHeight: viewportHeight,
          centerVertically: widget.centerVertically,
          enableEdgeSpacer: widget.enableEdgeSpacer,
          alignment: widget.currentLineAlignment,
        );
        final extraBottomPadding = lyricListBottomPadding(
          viewportHeight: viewportHeight,
          centerVertically: widget.centerVertically,
          enableEdgeSpacer: widget.enableEdgeSpacer,
          alignment: widget.currentLineAlignment,
        );
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
                    if (_programmaticScrollDepth > 0) return false;
                    if (notification is ScrollStartNotification &&
                        notification.dragDetails != null) {
                      _handleUserScrollPhase(_userScrollTracker.start());
                    } else if (notification is ScrollUpdateNotification &&
                        notification.dragDetails != null) {
                      _handleUserScrollPhase(_userScrollTracker.update());
                    } else if (notification is UserScrollNotification) {
                      _handleUserScrollPhase(
                        lyricPhaseForUserScrollNotification(
                          tracker: _userScrollTracker,
                          idle: notification.direction == ScrollDirection.idle,
                        ),
                      );
                    } else if (notification is ScrollEndNotification) {
                      _handleUserScrollPhase(_userScrollTracker.end());
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
                          Colors.transparent,
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
                        viewportStrategy.cacheExtent(constraints.maxHeight),
                      ),
                      padding: EdgeInsets.only(
                        top: _snappedScrollOffset(extraTopPadding),
                        bottom: _snappedScrollOffset(extraBottomPadding),
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
                        final isGroupLine = _parallelGroupLines.contains(i);
                        final isMainActiveLine = _mainActiveLyricLines.contains(
                          i,
                        );
                        final isBackgroundActiveLine =
                            _backgroundActiveLyricLines.contains(i);
                        final isActiveLine =
                            isMainActiveLine || isBackgroundActiveLine;
                        final usesSharedLyricPosition = usesAuthoredTiming
                            ? isActiveLine
                            : i == _mainLine &&
                                  line is SyncLyricLine &&
                                  line.words.isNotEmpty;
                        final highlightDeadlineMs = _highlightDeadlineForLine(
                          i,
                        );
                        final opacity = dist == 0 || isGroupLine || isActiveLine
                            ? 1.0
                            : pow(_opacityBase, dist).toDouble().clamp(
                                _opacityMinClamp,
                                _opacityMaxClamp,
                              );
                        final staggerDelay =
                            _lyricViewController
                                    ?.renderConfig
                                    .enableStaggeredAnimation ==
                                true
                            ? _lyricViewController?.renderConfig.staggerStyle ==
                                      LyricStaggerStyle.spring
                                  ? lyricSpringItemDelay(
                                      itemIndex: i,
                                      visibleStartIndex:
                                          _staggerVisibleStartIndex,
                                    )
                                  : Duration(
                                      milliseconds:
                                          ((30 * (dist + 1) * (5 + dist) ~/ 5)
                                              .clamp(0, _staggerMaxMs)),
                                    )
                            : Duration.zero;
                        Widget lineWidget = SizedBox(
                          key: _keyForLine(i),
                          child: LyricsLineWidget(
                            key: ValueKey(
                              'lyric_line_${identityHashCode(widget.lyric)}_$i',
                            ),
                            line: line,
                            opacity: opacity,
                            distance: lyricLineVisualDistance(
                              index: i,
                              mainLine: _mainLine,
                              parallelGroupLines: _parallelGroupLines,
                            ),
                            positionMs: _displayPositionMs,
                            positionListenable: usesSharedLyricPosition
                                ? _sharedLyricPositionMs
                                : null,
                            isHighlightActive: usesAuthoredTiming
                                ? isGroupLine
                                : isGroupLine || isMainActiveLine,
                            isMainVocalActive: usesAuthoredTiming
                                ? isMainActiveLine
                                : null,
                            isBackgroundActive: isBackgroundActiveLine,
                            usesAuthoredTiming: usesAuthoredTiming,
                            isBackgroundVisible: usesAuthoredTiming
                                ? isGroupLine
                                : null,
                            accelerateTailHighlight:
                                i == _tailHighlightCatchUpLine,
                            staggerDelay: staggerDelay,
                            jumpTriggerId: _jumpTriggerId,
                            jumpDeltaY: _jumpDeltaY,
                            isUserScrolling: userIsDragging,
                            freezeHeight: freezeParallelGroup && isGroupLine,
                            reserveBackgroundVocalHeight:
                                lyricLineHasBackgroundVocal(line),
                            highlightDeadlineMs: highlightDeadlineMs,
                            backgroundVocalVisibilityListenable:
                                _backgroundExitValues[i],
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
      },
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _discardPendingLyricLineUpdates();
    if (_cachedOffsets != null &&
        _cachedHeights != null &&
        _cachedBackgroundVocalHeights != null &&
        _cachedMaxWidth > 0 &&
        _cachedViewportHeight > 0) {
      final cacheKey = _LyricOffsetCacheKey(
        lyric: widget.lyric,
        widthPx: _cachedMaxWidth.round(),
        config: LyricViewController.instance.renderConfig,
        fontFamily: ThemeProvider.instance.resolvedLyricFontFamily,
      );
      final cached = _offsetCache[cacheKey];
      if (cached != null) {
        cached.viewportHeight = _cachedViewportHeight;
      }
    }
    _stopScrollTicker();
    _lineKeys.clear();
    _ensureVisibleTimer?.cancel();
    _userScrollHoldTimer?.cancel();
    _sizeChangeTimer?.cancel();
    _playbackResyncTimer?.cancel();
    _idleCleanupTimer?.cancel(); // 取消空闲检测
    _discardDepartingBackgroundVocal();
    _backgroundVocalExitController.dispose();
    _lyricViewController?.removeListener(_scheduleEnsureCurrentVisible);
    routeVisibilityObserver.unsubscribe(this);
    playbackService.nowPlayingNotifier.removeListener(_contentResyncListener);
    playbackService.positionSyncNotifier.removeListener(
      _positionResyncListener,
    );
    playbackService.playerStateNotifier.removeListener(_syncSharedLyricTicker);
    lyricService.removeListener(_contentResyncListener);
    WindowRenderGate.instance.framesEnabled.removeListener(
      _onWindowFramesEnabled,
    );
    lyricLineStreamSubscription.cancel();
    _sharedLyricPositionTicker?.dispose();
    _sharedLyricPositionMs.dispose();
    _positionResyncTimer?.cancel();
    _positionResyncStopTimer?.cancel();
    scrollController.dispose();

    // 清空 TextPainter 对象池，释放内存
    LyricsLinePainter.clearPool();
    LyricsLineWidget.clearBlurFilterCache();
    super.dispose();
  }
}
