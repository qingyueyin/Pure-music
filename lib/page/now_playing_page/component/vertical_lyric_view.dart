import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/route_visibility.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/native/bass/bass_player.dart' show PlayerState;
import 'package:pure_music/page/now_playing_page/component/collapsible_lyric_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_stagger_motion.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_viewport_strategy.dart';
import 'package:pure_music/page/now_playing_page/component/value_transition.dart';
import 'package:pure_music/play_service/lyric_service.dart'
    show lyricHighlightDeadlineMsForLine;
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
const _backgroundVocalStaggerHold = Duration(milliseconds: 600);

bool alwaysShowLyricViewControls = false;

bool shouldForceLyricScrollForPositionSync(PlayerState state) =>
    state == PlayerState.playing;

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
  Timer? _backgroundVocalReleaseTimer;
  bool _didIdleCleanup = false;
  LyricScrollState _scrollState = LyricScrollState.idle;
  int _mainLine = 0;
  int _jumpTriggerId = 0;
  double _jumpDeltaY = 0.0;
  int _staggerVisibleStartIndex = 0;
  bool _pendingStaggerScroll = false;
  bool _postDragSkipPending = false;

  /// TTML 当前并行组；[_mainLine] 仍只负责主行布局。
  final Set<int> _parallelGroupLines = {};
  int? _tailHighlightCatchUpLine;
  int? _departingBackgroundVocalLine;
  double _backgroundVocalReflowOffset = 0.0;
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
  int _lastPositionResyncMs = 0;
  int _positionResyncExtensionCount = 0;
  static const int _maxPositionResyncExtensions = 5;

  final Map<int, GlobalKey> _lineKeys = {};
  static const int _lineKeyRetainRadius = 4;

  GlobalKey? _keyForLine(int index) {
    if ((index - _mainLine).abs() > _lineKeyRetainRadius &&
        !_parallelGroupLines.contains(index)) {
      return null;
    }
    return _lineKeys[index] ??= GlobalKey();
  }

  void _pruneLineKeys() {
    _lineKeys.removeWhere(
      (index, _) =>
          (index - _mainLine).abs() > _lineKeyRetainRadius &&
          !_parallelGroupLines.contains(index),
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

  @override
  void initState() {
    super.initState();
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
    );
    lyricLineStreamSubscription = lyricService.lyricLineStream.listen(
      _updateNextLyricLine,
    );
    _contentResyncListener = _queueContentResync;
    _positionResyncListener = _queuePositionResync;
    playbackService.nowPlayingNotifier.addListener(_contentResyncListener);
    playbackService.positionSyncNotifier.addListener(_positionResyncListener);
    lyricService.addListener(_contentResyncListener);
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
    _LyricOffsetCacheKey? cacheKey;
    _LyricOffsetCacheEntry? cached;
    for (final entry in _offsetCache.entries.toList().reversed) {
      if (identical(entry.key.lyric, widget.lyric) &&
          entry.key.config == config &&
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

    final lineIndex = _mainLine.clamp(0, cached.offsets.length - 1);
    final viewport = cached.viewportHeight;
    final alignment = widget.currentLineAlignment;
    final topPadding = widget.centerVertically
        ? viewport / 2.0
        : widget.enableEdgeSpacer
        ? viewport
        : viewport * alignment;
    return max(
      0.0,
      topPadding +
          cached.offsets[lineIndex] +
          cached.heights[lineIndex] / 2.0 -
          viewport * alignment,
    );
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
      ),
    );
  }

  void _queuePlaybackResync({required bool forceScroll}) {
    if (_disposed || !mounted) return;
    if (forceScroll) {
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
      _collapseDepartingBackgroundVocal();
    }
  }

  void _collapseDepartingBackgroundVocal() {
    _backgroundVocalReleaseTimer?.cancel();
    _backgroundVocalReleaseTimer = null;
    if (_departingBackgroundVocalLine == null || _disposed || !mounted) return;
    if (_backgroundVocalExitController.isAnimating) return;
    final line = _departingBackgroundVocalLine;
    final generation = ++_backgroundVocalExitGeneration;
    _backgroundVocalExitController
        .animateTo(
          0.0,
          duration: lyricBackgroundVocalExitDuration,
          curve: Curves.easeInCubic,
        )
        .whenCompleteOrCancel(() {
          if (_disposed ||
              !mounted ||
              generation != _backgroundVocalExitGeneration ||
              line != _departingBackgroundVocalLine) {
            return;
          }
          setState(() {
            _departingBackgroundVocalLine = null;
            _backgroundVocalReflowOffset = 0.0;
          });
        });
  }

  void _discardDepartingBackgroundVocal() {
    _backgroundVocalReleaseTimer?.cancel();
    _backgroundVocalReleaseTimer = null;
    _backgroundVocalExitGeneration++;
    _backgroundVocalExitController
      ..stop()
      ..value = 0.0;
    _departingBackgroundVocalLine = null;
    _backgroundVocalReflowOffset = 0.0;
  }

  void _scheduleDepartingBackgroundVocalRelease() {
    _backgroundVocalReleaseTimer?.cancel();
    if (_departingBackgroundVocalLine == null) return;
    _backgroundVocalReleaseTimer = Timer(_backgroundVocalStaggerHold, () {
      _collapseDepartingBackgroundVocal();
    });
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
      _cachedBackgroundVocalHeights = cached.backgroundVocalHeights;
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
    final mainTransSize = config.translationFontSize(isMainLine: true);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fontFamily =
        theme.textTheme.bodyMedium?.fontFamily ??
        theme.textTheme.bodySmall?.fontFamily;

    final painter = LyricsLinePainter.obtainTextPainter();

    double measureSyncLine(SyncLyricLine line, bool isMain) {
      if (line.words.isEmpty) {
        return isMain && line.length > const Duration(seconds: 3) ? 40.0 : 0.0;
      }
      return LyricsLinePainter(
        line: line,
        currentTimeMs: 0.0,
        blurSigma: 0.0,
        config: config,
        scheme: scheme,
        isMainLine: isMain,
        useMaterialYouColor: AppSettings.instance.useMaterialYouForLyrics,
        fontFamily: fontFamily,
        agent: line.agent,
        lineMedianWordDuration: Duration.zero,
      ).measureHeight(maxWidth, reserveBackgroundVocalHeight: false);
    }

    double measureLine(LyricLine line, bool isMain) {
      final isLineByLine =
          line is SyncLyricLine &&
          config.displayMode == LyricDisplayMode.lineByLine;
      if (isMain) {
        if (line is SyncLyricLine && !isLineByLine) {
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

      if (line is SyncLyricLine && !isLineByLine) {
        if (line.words.isEmpty) return 0.0;
      } else if (line is LrcLine) {
        if (line.isBlank) return 0.0;
      }

      final primarySize = mainSize;
      final transSize = mainTransSize;
      final contentWidth = maxWidth - 24.0;

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
              style: TextStyle(
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
                style: TextStyle(
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
                style: TextStyle(
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
                  style: TextStyle(
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
                style: TextStyle(
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
          style: TextStyle(
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
          style: TextStyle(
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
          style: TextStyle(
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
      backgroundVocalHeights.add(measureBackgroundVocalHeight(lines[i]));
      final hAsSub = preciseSyncMeasure
          ? measureSyncLine(lines[i] as SyncLyricLine, false)
          : measureLine(lines[i], false);
      currentOffset += hAsSub;
    }

    _cachedOffsets = offsets;
    _cachedHeights = heights;
    _cachedBackgroundVocalHeights = backgroundVocalHeights;
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
    _userScrollTracker.end();
    _userScrollHoldTimer?.cancel();
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

      // 切歌时取消所有待处理的 Timer/Ticker，避免泄漏
      _stopScrollTicker();
      _ensureVisibleTimer?.cancel();
      _ensureVisibleTimer = null;
      _userScrollHoldTimer?.cancel();
      _userScrollHoldTimer = null;
      _userScrollTracker.end();
      _sizeChangeTimer?.cancel();
      _sizeChangeTimer = null;

      _cachedMaxWidth = 0.0;
      _cachedOffsets = null;
      _cachedHeights = null;
      _cachedBackgroundVocalHeights = null;
      _cachedViewportHeight = 0.0;
      _needsInitialScroll = true;
      _displayPositionMs = playbackService.position * 1000.0;
      _pendingScrollRetries = 0;
      _mainLine = 0;
      _pendingStaggerScroll = false;
      _postDragSkipPending = false;
      _jumpDeltaY = 0;
      _jumpTriggerId++;
      _parallelGroupLines.clear();
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

  void _staggerScrollTo(double targetOffset) {
    if (!scrollController.hasClients) return;
    _pendingStaggerScroll = false;
    final from = scrollController.offset;
    final to = targetOffset.clamp(
      scrollController.position.minScrollExtent,
      scrollController.position.maxScrollExtent,
    );
    _jumpDeltaY = to - from;
    if (_jumpDeltaY.abs() > 0.5) {
      _jumpTriggerId++;
      setState(() {});
      scrollController.jumpTo(to);
      _userScrollHoldTimer?.cancel();
      _userScrollHoldTimer = null;
      _scrollTransition.jumpTo(to);
      _stopScrollTicker();
      _needsInitialScroll = false;
      _positionResyncExtensionCount = 0;
      _scheduleDepartingBackgroundVocalRelease();
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
      _collapseDepartingBackgroundVocal();
      return;
    }

    // 重用现有 transition，避免创建新对象
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
    _needsInitialScroll = false;
    _positionResyncExtensionCount = 0;

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
      RenderBox? targetObject;
      try {
        targetObject = targetContext.findRenderObject() as RenderBox?;
      } catch (_) {}
      if (targetObject != null) {
        final viewport = RenderAbstractViewport.of(targetObject);
        final alignment = widget.currentLineAlignment;
        final revealed = viewport.getOffsetToReveal(targetObject, alignment);
        if (_pendingStaggerScroll) {
          _staggerScrollTo(revealed.offset);
          _scrollState = LyricScrollState.idle;
        } else {
          _animateTo(revealed.offset, duration: duration);
        }
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

      if (_pendingStaggerScroll) {
        _staggerScrollTo(targetScrollOffset);
        _scrollState = LyricScrollState.idle;
      } else {
        _animateTo(targetScrollOffset, duration: duration);
      }
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

  int? _tailHighlightCatchUpLineFor(Set<int> candidates) {
    if (candidates.length <= 1) return null;
    final viewportHeight = _cachedViewportHeight > 0
        ? _cachedViewportHeight
        : scrollController.hasClients
        ? scrollController.position.viewportDimension
        : 0.0;
    if (viewportHeight <= 0) return null;

    final availableBelowMain =
        viewportHeight * (1.0 - widget.currentLineAlignment);
    final heightBudget = availableBelowMain * 0.82;

    double heightFor(int index) {
      final lineHeight =
          _cachedHeights != null && index >= 0 && index < _cachedHeights!.length
          ? _cachedHeights![index]
          : 96.0;
      final backgroundHeight =
          _cachedBackgroundVocalHeights != null &&
              index >= 0 &&
              index < _cachedBackgroundVocalHeights!.length
          ? _cachedBackgroundVocalHeights![index]
          : 0.0;
      return lineHeight + backgroundHeight;
    }

    final totalHeight = candidates.fold<double>(
      0.0,
      (total, index) => total + heightFor(index),
    );
    return totalHeight > heightBudget ? candidates.reduce(max) : null;
  }

  ({int primaryIndex, Set<int> groupLines, int? tailCatchUpLine})
  _displayLineUpdate(LyricLineUpdate update) {
    final lines = widget.lyric.lines;
    final layoutLines = _renderableLineIndices(update.layoutIndices);
    final activeLines = _renderableLineIndices(update.activeIndices);
    final groupLines = layoutLines.isNotEmpty ? layoutLines : activeLines;
    final primaryIndex = lyricDisplayPrimaryIndex(
      fallbackPrimaryIndex: update.primaryIndex,
      lineCount: lines.length,
      groupedLines: groupLines,
    );
    return (
      primaryIndex: primaryIndex,
      groupLines: groupLines,
      tailCatchUpLine: _tailHighlightCatchUpLineFor(groupLines),
    );
  }

  bool _hasBackgroundVocal(LyricLine line) {
    if (line is! SyncLyricLine) return false;
    return line.bgText?.isNotEmpty == true ||
        (LyricViewController.instance.renderConfig.showRoman &&
            line.bg?.romanLyric?.isNotEmpty == true) ||
        line.bgTranslation?.isNotEmpty == true ||
        line.bgWords.isNotEmpty;
  }

  bool _hasStartedBackgroundVocal(LyricLine line) {
    if (!_hasBackgroundVocal(line)) return false;
    final syncLine = line as SyncLyricLine;
    final start = (syncLine.bgStart ?? syncLine.bg?.start ?? syncLine.start)
        .inMilliseconds
        .toDouble();
    final positionMs = playbackService.position * 1000.0;
    return positionMs >= start;
  }

  double _backgroundVocalReflowOffsetFor(int lineIndex) {
    final heights = _cachedBackgroundVocalHeights;
    if (heights == null || lineIndex < 0 || lineIndex >= heights.length) {
      return 0.0;
    }
    final line = widget.lyric.lines[lineIndex];
    if (line is! SyncLyricLine) return 0.0;
    final start = (line.bgStart ?? line.bg?.start ?? line.start).inMilliseconds
        .toDouble();
    final elapsed = playbackService.position * 1000.0 - start;
    final entryProgress =
        (elapsed / lyricBackgroundVocalEntryDuration.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble();
    final visibleFactor = Curves.easeOutBack
        .transform(entryProgress)
        .clamp(0.0, 1.0)
        .toDouble();
    return heights[lineIndex] * visibleFactor;
  }

  int? _departingBackgroundVocalLineFor(
    List<LyricLine> lines,
    int previousMainLine,
    int nextMainLine,
    bool mainLineChanged,
  ) {
    if (!mainLineChanged) return _departingBackgroundVocalLine;
    final previousGroupLines = _parallelGroupLines.toList()
      ..sort((a, b) => b.compareTo(a));
    for (final index in previousGroupLines) {
      if (index != nextMainLine && _hasStartedBackgroundVocal(lines[index])) {
        return index;
      }
    }
    return _hasStartedBackgroundVocal(lines[previousMainLine])
        ? previousMainLine
        : null;
  }

  void _syncToPlaybackPosition({Duration? duration, bool forceScroll = true}) {
    if (_disposed || !mounted) return;
    final update = lyricService.lineUpdateForLyric(
      widget.lyric,
      playbackService.position,
    );
    if (update == null) {
      lyricService.forceEmitCurrentLine();
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
    if (_disposed || !mounted) return;
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
        _tailHighlightCatchUpLine == displayUpdate.tailCatchUpLine &&
        (playbackService.playerState == PlayerState.playing ||
            !positionChanged)) {
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

    final displayUpdate = _displayLineUpdate(update);
    final positionMs = playbackService.position * 1000.0;
    final positionChanged = (_displayPositionMs - positionMs).abs() > 0.5;
    final nextGroupLines = displayUpdate.groupLines;
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
        _tailHighlightCatchUpLine == nextTailHighlightCatchUpLine) {
      if (positionChanged &&
          playbackService.playerState != PlayerState.playing) {
        setState(() {
          _displayPositionMs = positionMs;
        });
      }
      if (forceScroll || _needsInitialScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed || !mounted) return;
          _scrollToCurrent(duration);
        });
      }
      return;
    }
    final previousMainLine = _mainLine;
    final mainLineChanged = previousMainLine != renderableMainLine;
    final departingBackgroundVocalLine = forceScroll
        ? null
        : _departingBackgroundVocalLineFor(
            lines,
            previousMainLine,
            renderableMainLine,
            mainLineChanged,
          );
    final startBackgroundVocalExit =
        departingBackgroundVocalLine != null &&
        departingBackgroundVocalLine != _departingBackgroundVocalLine;
    final backgroundVocalReflowOffset = departingBackgroundVocalLine == null
        ? 0.0
        : _backgroundVocalReflowOffsetFor(departingBackgroundVocalLine);
    if (departingBackgroundVocalLine != _departingBackgroundVocalLine) {
      _backgroundVocalReleaseTimer?.cancel();
      _backgroundVocalReleaseTimer = null;
      _backgroundVocalExitGeneration++;
      _backgroundVocalExitController
        ..stop()
        ..value = departingBackgroundVocalLine == null ? 0.0 : 1.0;
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
    final shouldScroll =
        forceScroll || _needsInitialScroll || followDecision.shouldScroll;
    _pendingStaggerScroll = shouldScroll && shouldStagger;

    if (forceScroll) {
      _pendingScrollRetries = 0;
      _userScrollHoldTimer?.cancel();
      _userScrollTracker.end();
      _stopScrollTicker();
      _postDragSkipPending = false;
    }

    setState(() {
      _mainLine = renderableMainLine;
      _displayPositionMs = positionMs;
      _departingBackgroundVocalLine = departingBackgroundVocalLine;
      _backgroundVocalReflowOffset = backgroundVocalReflowOffset;
      _parallelGroupLines
        ..clear()
        ..addAll(nextGroupLines);
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

    if (startBackgroundVocalExit) {
      _collapseDepartingBackgroundVocal();
    }

    if (shouldScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
        _scrollToCurrent(duration);
      });
    } else {
      _pendingStaggerScroll = false;
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
    final freezeParallelGroup = _parallelGroupLines.length > 1;
    return LayoutBuilder(
      builder: (context, constraints) {
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
        final viewportHeightChanged =
            viewportHeight.isFinite &&
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
        final extraBottomPadding = widget.enableEdgeSpacer
            ? viewportHeight
            : 0.0;
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
                    if (notification is ScrollStartNotification &&
                        notification.dragDetails != null) {
                      _handleUserScrollPhase(_userScrollTracker.start());
                    } else if (notification is ScrollUpdateNotification &&
                        notification.dragDetails != null) {
                      _handleUserScrollPhase(_userScrollTracker.update());
                    } else if (notification is UserScrollNotification) {
                      _handleUserScrollPhase(
                        notification.direction == ScrollDirection.idle
                            ? _userScrollTracker.end()
                            : _userScrollTracker.update(),
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
                        top:
                            (widget.centerVertically ? spacerHeight : 0) +
                            extraTopPadding +
                            alignTopPadding,
                        bottom:
                            (widget.centerVertically ? spacerHeight : 0) +
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
                        final isGroupLine = _parallelGroupLines.contains(i);
                        final highlightDeadlineMs = _highlightDeadlineForLine(
                          i,
                        );
                        final opacity = dist == 0 || isGroupLine
                            ? 1.0
                            : pow(_opacityBase, dist).toDouble().clamp(
                                _opacityMinClamp,
                                _opacityMaxClamp,
                              );
                        final staggerDelay = Duration(
                          milliseconds:
                              _lyricViewController
                                      ?.renderConfig
                                      .enableStaggeredAnimation ==
                                  true
                              ? _lyricViewController
                                            ?.renderConfig
                                            .staggerStyle ==
                                        LyricStaggerStyle.spring
                                    ? lyricStaggerDelayMs(
                                        itemIndex: i,
                                        visibleStartIndex:
                                            _staggerVisibleStartIndex,
                                      )
                                    : ((30 * (dist + 1) * (5 + dist) ~/ 5)
                                          .clamp(0, _staggerMaxMs))
                              : 0,
                        );
                        Widget lineWidget = SizedBox(
                          key: _keyForLine(i),
                          child: LyricsLineWidget(
                            key: ValueKey(
                              'lyric_line_${identityHashCode(widget.lyric)}_$i',
                            ),
                            line: line,
                            opacity: opacity,
                            distance: dist,
                            positionMs: _displayPositionMs,
                            isHighlightActive: isGroupLine,
                            accelerateTailHighlight:
                                i == _tailHighlightCatchUpLine,
                            lineOffsetY:
                                _departingBackgroundVocalLine != null &&
                                    i > _departingBackgroundVocalLine!
                                ? _backgroundVocalReflowOffset
                                : 0.0,
                            lineOffsetProgressListenable:
                                _departingBackgroundVocalLine != null &&
                                    i > _departingBackgroundVocalLine!
                                ? _backgroundVocalExitController
                                : null,
                            staggerDelay: staggerDelay,
                            jumpTriggerId: _jumpTriggerId,
                            jumpDeltaY: _jumpDeltaY,
                            isUserScrolling: userIsDragging,
                            freezeHeight: freezeParallelGroup && isGroupLine,
                            reserveBackgroundVocalHeight:
                                (i == _mainLine || isGroupLine) &&
                                i != _departingBackgroundVocalLine,
                            highlightDeadlineMs: highlightDeadlineMs,
                            backgroundVocalVisibilityListenable:
                                i == _departingBackgroundVocalLine
                                ? _backgroundVocalExitController
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
      },
    );
  }

  @override
  void dispose() {
    _disposed = true;
    if (_cachedOffsets != null &&
        _cachedHeights != null &&
        _cachedBackgroundVocalHeights != null &&
        _cachedMaxWidth > 0 &&
        _cachedViewportHeight > 0) {
      final cacheKey = _LyricOffsetCacheKey(
        lyric: widget.lyric,
        widthPx: _cachedMaxWidth.round(),
        config: LyricViewController.instance.renderConfig,
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
    _backgroundVocalReleaseTimer?.cancel();
    _backgroundVocalExitController.dispose();
    _lyricViewController?.removeListener(_scheduleEnsureCurrentVisible);
    routeVisibilityObserver.unsubscribe(this);
    playbackService.nowPlayingNotifier.removeListener(_contentResyncListener);
    playbackService.positionSyncNotifier.removeListener(
      _positionResyncListener,
    );
    lyricService.removeListener(_contentResyncListener);
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
