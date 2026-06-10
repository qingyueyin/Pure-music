import 'dart:async';
import 'dart:math';

import 'package:pure_music/core/utils.dart' as utils;
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/collapsible_lyric_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_viewport_strategy.dart';
import 'package:pure_music/page/now_playing_page/component/value_transition.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
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
                future: PlayService.instance.lyricService.currLyricFuture,
                builder: (context, snapshot) {
                  final lyricNullable = snapshot.data;
                  if (lyricNullable != null) {
                    utils.logger.d(
                        'FutureBuilder: lines=${lyricNullable.lines.length} state=${snapshot.connectionState}');
                  } else {
                    utils.logger.d(
                        'FutureBuilder: data=null state=${snapshot.connectionState}');
                  }
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
    with TickerProviderStateMixin {
  final playbackService = PlayService.instance.playbackService;
  final lyricService = PlayService.instance.lyricService;
  late StreamSubscription lyricLineStreamSubscription;
  final scrollController = ScrollController();
  LyricViewController? _lyricViewController;
  bool _disposed = false;
  Timer? _ensureVisibleTimer;
  Timer? _userScrollHoldTimer;
  Timer? _sizeChangeTimer;
  LyricScrollState _scrollState = LyricScrollState.idle;
  int _mainLine = 0;
  int _pendingScrollRetries = 0;
  LyricViewportRange _viewportRange =
      const LyricViewportRange(start: 0, end: 0);

  final currentLyricTileKey = GlobalKey();

  /// HQ Player 风格: 悬停歌词行高亮遮罩
  int _hoveredLineIndex = -1;

  /// HQ Player 风格: ValueTransition 驱动的平滑滚动
  late ValueTransition<double> _scrollTransition;
  Ticker? _scrollTicker;
  bool _scrollTickerActive = false;
  Duration _lastTickElapsed = Duration.zero;

  List<double>? _cachedOffsets;
  List<double>? _cachedHeights;
  double _cachedMaxWidth = 0.0;

  @override
  void initState() {
    super.initState();
    _scrollTransition = ValueTransition<double>(
      begin: 0,
      interpolator: _sineOutInterpolator,
      duration: const Duration(milliseconds: 300),
    );
    _initLyricView();
    lyricLineStreamSubscription =
        lyricService.lyricLineStream.listen(_updateNextLyricLine);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      lyricService.findCurrLyricLineAt(playbackService.position);
    });
  }

  /// HQ Player 风格: Sine Out 缓动函数
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

  /// HQ Player 风格: 启动 ValueTransition 驱动的滚动 Ticker
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

      final primarySize = isMain ? mainSize : subSize;
      final transSize = isMain ? mainTransSize : subTransSize;
      final contentWidth = maxWidth - 24.0;

      double h = 0.0;

      final double vertPad;
      if (line is SyncLyricLine) {
        vertPad = config.syncVerticalPadding(isMainLine: isMain);
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
          final parts = line.content.split('┃');
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
    if (lines.isNotEmpty) {
      utils.logger.d(
          '_computeOffsets: ${lines.length} lines totalOffset=${currentOffset.toStringAsFixed(1)}px');
      for (int i = 0; i < lines.length && i < 3; i++) {
        utils.logger.d(
            '  line[$i] hMain=${heights[i].toStringAsFixed(1)} hSub=${measureLine(lines[i], false).toStringAsFixed(1)} offset=${offsets[i].toStringAsFixed(1)}');
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<LyricViewController>();
    if (_lyricViewController == controller) return;

    _lyricViewController?.removeListener(_scheduleEnsureCurrentVisible);
    _lyricViewController = controller;
    _lyricViewController?.addListener(_scheduleEnsureCurrentVisible);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToCurrent(const Duration(milliseconds: 100));
    });
  }

  @override
  void didUpdateWidget(covariant _VerticalLyricScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyric != widget.lyric) {
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
      _mainLine = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _initLyricView();
        }
      });
    }
  }

  void _scheduleEnsureCurrentVisible() {
    _ensureVisibleTimer?.cancel();
    _ensureVisibleTimer = Timer(const Duration(milliseconds: 150), () {
      if (_disposed || !mounted) return;
      _cachedMaxWidth = 0.0;
      final oldMainLine = _mainLine;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
        if (_mainLine >= widget.lyric.lines.length) {
          _mainLine = oldMainLine.clamp(0, widget.lyric.lines.length - 1);
        }
        _scrollToCurrent();
      });
    });
  }

  /// HQ Player 风格: ValueTransition 驱动的丝滑滚动
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
      if (_scrollState == LyricScrollState.programScrolling) {
        _scrollState = LyricScrollState.idle;
      }
      return;
    }

    _scrollTransition = ValueTransition<double>(
      begin: from,
      interpolator: _sineOutInterpolator,
      duration: duration ?? _scrollDurationForDistance(dist),
    );
    _scrollTransition.start(to);
    _startScrollTicker();

    if (_scrollState != LyricScrollState.userDragging) {
      _scrollState = LyricScrollState.programScrolling;
    }
  }

  void _markUserScrolling() {
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
      if (_pendingScrollRetries < 4) {
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

    final targetContext = currentLyricTileKey.currentContext;
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

    if (_pendingScrollRetries < 4) {
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
    final lines = widget.lyric.lines;
    utils.logger.d('_initLyricView: lines=${lines.length} mainLine=$_mainLine');
    if (lines.isNotEmpty) {
      for (int i = 0; i < lines.length && i < 3; i++) {
        final l = lines[i];
        utils.logger.d(
            '  line[$i] start=${l.start.inMilliseconds}ms length=${l.length.inMilliseconds}ms type=${l.runtimeType} blank=${l is LrcLine ? l.isBlank : 'N/A'} trans=${l.translation}');
      }
    }
    final next = lines.indexWhere(
      (element) =>
          element.start.inMilliseconds / 1000 > playbackService.position,
    );
    final nextLyricLine = next == -1 ? lines.length : next;
    int candidate = max(nextLyricLine - 1, 0);
    // 跳过空白行：如果当前行是空白/元数据行，跳到下一个非空白行
    while (candidate < lines.length && _isLineBlankFiltered(lines[candidate])) {
      candidate++;
    }
    _mainLine = candidate.clamp(0, lines.length - 1);
    _updateViewportRange(force: true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      _ensureCurrentLineVisible();
    });
  }

  void _ensureCurrentLineVisible() {
    if (_disposed || !mounted) return;
    if (_cachedOffsets == null && _cachedMaxWidth > 0) {
      _computeOffsets(_cachedMaxWidth);
    }
    _scrollToCurrent(const Duration(milliseconds: 320));
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
      // words 为空且长度 <= 3秒 → 纯空白短行，不渲染
      return line.words.isEmpty && line.length <= const Duration(seconds: 3);
    } else if (line is LrcLine) {
      return line.isBlank &&
          (line.length <= const Duration(seconds: 3) ||
              line.start > Duration.zero);
    }
    return false;
  }

  void _updateNextLyricLine(int lyricLine) {
    if (_disposed) return;
    if (_mainLine == lyricLine) {
      return;
    }

    final lines = widget.lyric.lines;
    // 跳过空白行：服务可能发出元数据行索引
    if (lyricLine < lines.length && _isLineBlankFiltered(lines[lyricLine])) {
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
      totalLines: lines.length,
    );

    setState(() {
      _mainLine = lyricLine;
      _viewportRange = followDecision.nextRange;
      if (_hoveredLineIndex != -1) {
        _hoveredLineIndex = -1;
      }
    });

    if (followDecision.shouldScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrent();
      });
    }
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
      if (constraints.maxWidth != _cachedMaxWidth) {
        _cachedMaxWidth = constraints.maxWidth;
        // 延迟精确偏移量到首帧后，避免阻塞初始渲染
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed || !mounted) return;
          _computeOffsets(constraints.maxWidth);
          // 精确偏移量算完后重定位到当前行
          _scrollToCurrent(const Duration(milliseconds: 150));
        });
      }

      final spacerHeight = constraints.maxHeight / 2.0;
      final viewportHeight = constraints.maxHeight;
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
                    return const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black,
                        Colors.black,
                        Colors.transparent
                      ],
                      stops: [0.0, 0.2, 0.8, 1.0],
                    ).createShader(bounds);
                  },
                  blendMode: BlendMode.dstIn,
                  child: ListView.builder(
                    key: const ValueKey('lyric_list_view_inner'),
                    controller: scrollController,
                    addAutomaticKeepAlives: false,
                    addRepaintBoundaries: false,
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
                      final opacity = dist == 0
                          ? 1.0
                          : pow(0.88, dist).toDouble().clamp(0.30, 0.90);
                      final staggerDelay = Duration(
                          milliseconds: _lyricViewController
                                      ?.renderConfig.enableStaggeredAnimation ==
                                  true
                              ? ((dist + 1) * 60).clamp(0, 600)
                              : 0);
                      final isHovered =
                          widget.enableSeekOnTap && i == _hoveredLineIndex;

                      return LyricsLineWidget(
                          key: dist == 0 ? currentLyricTileKey : null,
                          line: line,
                          opacity: isHovered ? 1.0 : opacity,
                          distance: dist,
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
                        );
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
    super.dispose();
    _ensureVisibleTimer?.cancel();
    _userScrollHoldTimer?.cancel();
    _sizeChangeTimer?.cancel();
    _lyricViewController?.removeListener(_scheduleEnsureCurrentVisible);
    lyricLineStreamSubscription.cancel();
    scrollController.dispose();
  }
}
