import 'dart:async';

import 'package:pure_music/core/settings.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_tile.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';

class HorizontalLyricView extends StatelessWidget {
  final bool compact;
  const HorizontalLyricView({
    super.key,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16.0),
      ),
      child: ListenableBuilder(
        listenable: Listenable.merge([
          PlayService.instance.lyricService,
          LyricViewController.instance,
        ]),
        builder: (context, _) => FutureBuilder(
          future: PlayService.instance.lyricService.currLyricFuture,
          builder: (context, snapshot) {
            if (snapshot.data == null) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '快来播放音乐吧~',
                    style: TextStyle(color: scheme.onSecondaryContainer),
                  ),
                ),
              );
            }

            return _LyricHorizontalScrollArea(snapshot.data!, compact);
          },
        ),
      ),
    );
  }
}

class _LyricHorizontalScrollArea extends StatefulWidget {
  const _LyricHorizontalScrollArea(this.lyric, [this.compact = false]);

  final Lyric lyric;
  final bool compact;

  @override
  State<_LyricHorizontalScrollArea> createState() =>
      _LyricHorizontalScrollAreaState();
}

class _LyricHorizontalScrollAreaState
    extends State<_LyricHorizontalScrollArea> {
  /// 停留300ms后启动，提前300ms滚动到底
  final waitFor = const Duration(milliseconds: 300);
  final scrollController = ScrollController();
  final lyricService = PlayService.instance.lyricService;
  late StreamSubscription lyricLineStreamSubscription;
  int _scrollToken = 0;

  var currContent = 'Enjoy Music';
  bool _isTransition = false;
  LrcLine? _transitionLrcLine;
  SyncLyricLine? _transitionSyncLine;

  static bool _isTransitionLine(LyricLine line) {
    if (line is LrcLine) {
      return line.isBlank &&
          line.length > const Duration(seconds: 3) &&
          line.start == Duration.zero;
    }
    if (line is SyncLyricLine) {
      return line.words.isEmpty && line.length > const Duration(seconds: 3);
    }
    return false;
  }

  void _setContent(LyricLine line) {
    if (_isTransitionLine(line)) {
      _isTransition = true;
      _transitionLrcLine = line is LrcLine ? line : null;
      _transitionSyncLine = line is SyncLyricLine ? line : null;
      currContent = '';
    } else {
      _isTransition = false;
      _transitionLrcLine = null;
      _transitionSyncLine = null;
      if (line is LrcLine) {
        currContent = line.translation == null
            ? line.content
            : '${line.content}┃${line.translation}';
      } else if (line is SyncLyricLine) {
        currContent = line.translation == null
            ? line.content
            : '${line.content}┃${line.translation}';
      }
    }
  }

  Widget _buildText(String content, ColorScheme scheme) {
    return Text(
      content,
      maxLines: 1,
      softWrap: false,
      style: TextStyle(color: scheme.onSecondaryContainer),
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget.lyric.lines.isNotEmpty) {
      _setContent(widget.lyric.lines.first);
    }

    lyricLineStreamSubscription = lyricService.lyricLineStream.listen((line) {
      if (widget.lyric.lines.isEmpty) return;
      _scrollToken += 1;
      final token = _scrollToken;
      final currLine = widget.lyric.lines[line];

      setState(() {
        _setContent(currLine);
      });

      /// 减去启动延时和滚动结束停留时间
      late final Duration lastTime;
      if (currLine is LrcLine) {
        lastTime = currLine.length - waitFor - waitFor;
      } else if (currLine is SyncLyricLine) {
        lastTime = currLine.length - waitFor - waitFor;
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!scrollController.hasClients) return;

        scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
        );
        if (scrollController.position.maxScrollExtent > 0) {
          if (lastTime.isNegative) return;

          Future.delayed(waitFor, () {
            if (!mounted) return;
            if (!scrollController.hasClients) return;
            if (token != _scrollToken) return;

            scrollController.animateTo(
              scrollController.position.maxScrollExtent,
              duration: lastTime,
              curve: Curves.easeOutQuart,
            );
          });
        }
      });
    });
  }

  @override
  void didUpdateWidget(covariant _LyricHorizontalScrollArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyric != widget.lyric) {
      // 歌词切换时重置显示和滚动状态
      _scrollToken = 0;
      if (widget.lyric.lines.isNotEmpty) {
        setState(() {
          _setContent(widget.lyric.lines.first);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: LyricViewController.instance,
      builder: (context, _) {
        if (_isTransition) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: LyricTransitionTile(
                lrcLine: _transitionLrcLine,
                syncLine: _transitionSyncLine,
                enableBreathing: false,
                compact: true,
                useMaterialYouColor:
                    AppSettings.instance.useMaterialYouForTransition,
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: SingleChildScrollView(
            controller: scrollController,
            scrollDirection: Axis.horizontal,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _buildText(currContent, scheme),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    super.dispose();
    lyricLineStreamSubscription.cancel();
    scrollController.dispose();
  }
}
