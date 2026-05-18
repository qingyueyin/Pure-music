import 'dart:async';
import 'dart:math';

import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/collapsible_lyric_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_tile.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_viewport_strategy.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

bool alwaysShowLyricViewControls = false;

enum LyricScrollState {
  idle,
  userDragging,
  programScrolling,
}

List<LyricLine> _filterEmptyLines(List<LyricLine> lines, bool removeEmpty) {
  if (!removeEmpty) return lines;
  return lines.where((line) {
    if (line is SyncLyricLine) {
      // 间奏行（words.isEmpty 但 length > 3秒）需要保留用于显示动画
      if (line.words.isEmpty) {
        return line.length > const Duration(seconds: 3);
      }
      return true;
    } else if (line is LrcLine) {
      return !line.isBlank || line.length > const Duration(seconds: 3);
    }
    return true;
  }).toList();
}

class VerticalLyricView extends StatefulWidget {
  const VerticalLyricView({
    super.key,
    this.showControls = true,
    this.enableSeekOnTap = true,
    this.centerVertically = true,
    this.currentLineAlignment = 0.5,
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
              listenable: PlayService.instance.lyricService,
              builder: (context, _) => FutureBuilder(
                future: PlayService.instance.lyricService.currLyricFuture,
                builder: (context, snapshot) {
                  final lyricNullable = snapshot.data;
                  const noLyricWidget = Center(
                    child: Text(
                      '无歌词',
                      style: TextStyle(
                        fontSize: 22,
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

class _VerticalLyricScrollViewState extends State<_VerticalLyricScrollView> {
  final playbackService = PlayService.instance.playbackService;
  final lyricService = PlayService.instance.lyricService;
  late StreamSubscription lyricLineStreamSubscription;
  final scrollController = ScrollController();
  LyricViewController? _lyricViewController;
  bool _disposed = false;
  Timer? _ensureVisibleTimer;
  Timer? _userScrollHoldTimer;
  Timer? _afterScrollRetryTimer;
  Timer? _sizeChangeTimer;
  LyricScrollState _scrollState = LyricScrollState.idle;
  int _mainLine = 0;
  int _pendingScrollRetries = 0;
  LyricViewportRange _viewportRange =
      const LyricViewportRange(start: 0, end: 0);

  final currentLyricTileKey = GlobalKey();

  List<double>? _cachedOffsets;
  List<double>? _cachedHeights;
  double _cachedMaxWidth = 0.0;
  List<LyricLine>? _filteredLines;
  Map<int, int>? _originalToFilteredIndexMap;

  void _rebuildFilteredLines() {
    final removeEmpty = _lyricViewController?.removeEmptyLines ?? true;
    _filteredLines = _filterEmptyLines(widget.lyric.lines, removeEmpty);
    _originalToFilteredIndexMap = {};

    if (_filteredLines!.isEmpty) return;

    // 为每个原始行建立到过滤后索引的映射
    // 被过滤掉的行：映射到下一个未过滤行的索引（若已是最后则映射到最后一行）
    int filteredIdx = 0;
    for (int origIdx = 0; origIdx < widget.lyric.lines.length; origIdx++) {
      final line = widget.lyric.lines[origIdx];

      // 在过滤后的列表中查找该行（相同对象引用）
      if (filteredIdx < _filteredLines!.length &&
          identical(_filteredLines![filteredIdx], line)) {
        _originalToFilteredIndexMap![origIdx] = filteredIdx;
        filteredIdx++;
      } else {
        // 该行被过滤掉了，映射到下一个有效的过滤索引
        // 使用当前 filteredIdx（即下一个未过滤行的索引）
        final mappedIdx = filteredIdx < _filteredLines!.length
            ? filteredIdx
            : _filteredLines!.length - 1;
        _originalToFilteredIndexMap![origIdx] = mappedIdx;
      }
    }
  }

  List<LyricLine> get _effectiveLines {
    if (_filteredLines == null) {
      _rebuildFilteredLines();
    }
    return _filteredLines!;
  }

  @override
  void initState() {
    super.initState();
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

    // 确保 _filteredLines 和 _originalToFilteredIndexMap 同步
    _rebuildFilteredLines();
    final lines = _filteredLines!;

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
          if (line.isBlank && line.length > const Duration(seconds: 3)) {
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
      // 切歌时取消所有待处理的 Timer，避免泄漏
      _ensureVisibleTimer?.cancel();
      _ensureVisibleTimer = null;
      _userScrollHoldTimer?.cancel();
      _userScrollHoldTimer = null;
      _afterScrollRetryTimer?.cancel();
      _afterScrollRetryTimer = null;
      _sizeChangeTimer?.cancel();
      _sizeChangeTimer = null;
      
      _cachedMaxWidth = 0.0;
      _cachedOffsets = null;
      _cachedHeights = null;
      _filteredLines = null;
      _originalToFilteredIndexMap = null;
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
      _filteredLines = null;
      _originalToFilteredIndexMap = null;
      final oldMainLine = _mainLine;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !mounted) return;
        if (_mainLine >= _effectiveLines.length) {
          _mainLine = oldMainLine.clamp(0, _effectiveLines.length - 1);
        }
        _scrollToCurrent();
      });
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
      if (_disposed) return;
      if (_scrollState == LyricScrollState.programScrolling) {
        _scrollState = LyricScrollState.idle;
      }
    });
  }

  void _markUserScrolling() {
    if (_scrollState != LyricScrollState.userDragging) {
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
      final spacer = 0.0; // padding already provides centering via spacerHeight
      final alignment = widget.currentLineAlignment;

      final lineTop = _cachedOffsets![_mainLine];
      final lineHeight = _cachedHeights![_mainLine];

      final targetScrollOffset =
          (spacer + lineTop + lineHeight / 2) - (viewport * alignment);

      _animateTo(targetScrollOffset, duration: duration);
      _afterScrollRetryTimer?.cancel();
      _afterScrollRetryTimer = Timer(const Duration(milliseconds: 220), () {
        if (_disposed || !mounted) return;
        _scrollToCurrent(const Duration(milliseconds: 180));
      });
      return;
    }
  }

  void _initLyricView() {
    final lines = _effectiveLines;
    final next = lines.indexWhere(
      (element) =>
          element.start.inMilliseconds / 1000 > playbackService.position,
    );
    final nextLyricLine = next == -1 ? lines.length : next;
    _mainLine = max(nextLyricLine - 1, 0);
    _updateViewportRange(force: true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
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

  int _originalIndexToFilteredIndex(int originalIndex) {
    if (_originalToFilteredIndexMap == null) {
      _rebuildFilteredLines();
    }
    final mapped = _originalToFilteredIndexMap![originalIndex] ?? originalIndex;
    // 确保映射后的索引在有效范围内
    if (_filteredLines == null || _filteredLines!.isEmpty) return 0;
    return mapped.clamp(0, _filteredLines!.length - 1);
  }

  void _updateNextLyricLine(int lyricLine) {
    if (_disposed) return;
    final filteredIndex = _originalIndexToFilteredIndex(lyricLine);
    if (_mainLine == filteredIndex) {
      return;
    }

    final lines = _effectiveLines;
    final renderConfig = context.read<LyricViewController>().renderConfig;
    final viewportStrategy = LyricViewportStrategy(
      leadingLines: renderConfig.viewportLeadingLines,
      trailingLines: renderConfig.viewportTrailingLines,
      overscanScreens: renderConfig.viewportOverscanScreens,
      userScrollHoldDuration: renderConfig.userScrollHoldDuration,
    );
    final followDecision = viewportStrategy.followDecision(
      currentRange: _viewportRange,
      nextMainLine: filteredIndex,
      totalLines: lines.length,
    );

    setState(() {
      _mainLine = filteredIndex;
      _viewportRange = followDecision.nextRange;
    });

    if (followDecision.shouldScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrent();
      });
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
      final viewportHeight = constraints.maxHeight;
      final extraTopPadding = widget.enableEdgeSpacer ? viewportHeight : 0.0;
      final extraBottomPadding = widget.enableEdgeSpacer ? viewportHeight : 0.0;
      final alignTopPadding = (!widget.centerVertically && !widget.enableEdgeSpacer)
          ? viewportHeight * widget.currentLineAlignment
          : 0.0;
      final alignBottomPadding = (!widget.centerVertically && !widget.enableEdgeSpacer)
          ? viewportHeight * (1.0 - widget.currentLineAlignment)
          : 0.0;
      final userIsDragging = _scrollState == LyricScrollState.userDragging;
      return Stack(
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
                  cacheExtent:
                      viewportStrategy.cacheExtent(constraints.maxHeight),
                  padding: EdgeInsets.only(
                    top: (widget.centerVertically ? spacerHeight : 0) + extraTopPadding + alignTopPadding,
                    bottom: (widget.centerVertically ? spacerHeight : 0) + extraBottomPadding + alignBottomPadding,
                  ),
                  itemCount: _effectiveLines.length,
                  itemBuilder: (context, i) {
                    final line = _effectiveLines[i];
                    final signedDist = i - _mainLine;
                    final dist = signedDist.abs();
                    final opacity = dist == 0
                        ? 1.0
                        : pow(0.88, dist).toDouble().clamp(0.30, 0.90);
                    final staggerDelay = Duration(
                        milliseconds: _lyricViewController?.renderConfig.enableStaggeredAnimation == true
                            ? ((dist + 1) * 60).clamp(0, 600)
                            : 0);
                    return LyricViewTile(
                      key: dist == 0 ? currentLyricTileKey : null,
                      line: line,
                      opacity: opacity,
                      distance: dist,
                      staggerDelay: staggerDelay,
                      isUserScrolling: userIsDragging,
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
    super.dispose();
    _ensureVisibleTimer?.cancel();
    _userScrollHoldTimer?.cancel();
    _afterScrollRetryTimer?.cancel();
    _sizeChangeTimer?.cancel();
    _lyricViewController?.removeListener(_scheduleEnsureCurrentVisible);
    lyricLineStreamSubscription.cancel();
    scrollController.dispose();
  }
}
