import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/list_locate_buttons.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/stacked_list_view.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as rust_library_db;
import 'package:pure_music/page/stats_page/stats_shared.dart';
import 'package:pure_music/play_service/play_service.dart';

/// 单曲榜单 tab：最常播放 Top100 + 从未播放，右下角定位/回顶按钮。
class RankedTab extends StatefulWidget {
  const RankedTab({
    super.key,
    required this.rankedTracks,
    required this.totalPlayed,
    required this.loading,
    required this.loadFailed,
  });

  final List<rust_library_db.PlayCountEntry> rankedTracks;
  final int totalPlayed;
  final bool loading;
  final bool loadFailed;

  @override
  State<RankedTab> createState() => _RankedTabState();
}

class _RankedTabState extends State<RankedTab> {
  static const _rankedTrackExtent = 68.0;
  static const _unheardPreviewLimit = 8;

  final _scrollController = SmoothScrollController();
  double _rankedLeadingExtent = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 当前正在播放乐曲在榜单中的索引；不在榜时返回 null。
  int? _locateTargetAt() {
    final nowPlaying = PlayService.instance.playbackService.nowPlaying;
    final ranked = widget.rankedTracks;
    if (nowPlaying == null || ranked.isEmpty) return null;
    final targetAt = ranked.indexWhere((entry) => entry.path == nowPlaying.path);
    return targetAt < 0 ? null : targetAt;
  }

  void _smoothScrollTo(double offset) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position is SmoothScrollPosition) {
      position.smoothScrollTo(offset);
      return;
    }
    _scrollController.animateTo(
      offset.clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.fastOutSlowIn,
    );
  }

  /// 按偏移定位，行滚出视口后 key 会被卸掉，不依赖 item context。
  void _scrollToIndex(int targetAt) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _smoothScrollTo(_rankedLeadingExtent + targetAt * _rankedTrackExtent);
    });
  }

  void _forwardWheel(double delta) {
    if (!AppSettings.instance.enableStackedScrollEffect ||
        MediaQuery.disableAnimationsOf(context)) {
      return;
    }
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position is SmoothScrollPosition) position.pointerScroll(delta);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final stacked =
        AppSettings.instance.enableStackedScrollEffect &&
        !MediaQuery.disableAnimationsOf(context);
    final library = AudioLibrary.instance;
    return Stack(
      children: [
        Positioned.fill(
          child: CustomScrollView(
            controller: _scrollController,
            physics: stacked ? const SmoothScrollPhysics() : null,
            slivers: [
              SliverToBoxAdapter(
                child: statsSectionTitle(
                  context,
                  title: '最常播放',
                  subtitle: _rankedSubtitle(),
                ),
              ),
              ..._rankedSlivers(scheme, stacked),
              ..._unheardSlivers(scheme, library),
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.bottomNav)),
            ],
          ),
        ),
        ListLocateButtons(
          controller: _scrollController,
          locateTargetAt: _locateTargetAt,
          onScrollToIndex: _scrollToIndex,
          onWheel: _forwardWheel,
        ),
      ],
    );
  }

  String _rankedSubtitle() {
    final ranked = widget.rankedTracks;
    if (widget.loading) return '正在更新';
    if (widget.loadFailed && ranked.isNotEmpty) return '刷新失败，显示上次结果';
    if (widget.totalPlayed > ranked.length) {
      return '前 ${ranked.length} 首曲目';
    }
    return '${ranked.length} 首曲目';
  }

  List<Widget> _rankedSlivers(ColorScheme scheme, bool stacked) {
    final ranked = widget.rankedTracks;
    if (widget.loading) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: scheme.surfaceContainerHighest.withValues(
                alpha: 0.35,
              ),
            ),
          ),
        ),
      ];
    }
    if (widget.loadFailed && ranked.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: statsMessage(
            context,
            icon: Symbols.sync_problem,
            text: '播放记录读取失败',
          ),
        ),
      ];
    }
    if (ranked.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: statsMessage(
            context,
            icon: Symbols.bar_chart,
            text: '播放几首歌曲后，这里会出现排行',
          ),
        ),
      ];
    }
    return [
      SliverLayoutBuilder(
        builder: (context, constraints) {
          _rankedLeadingExtent = constraints.precedingScrollExtent;
          return SliverFixedExtentList.builder(
            itemExtent: _rankedTrackExtent,
            itemCount: ranked.length,
            itemBuilder: (context, index) => StackedSliverItem(
              controller: _scrollController,
              rowIndex: index,
              itemExtent: _rankedTrackExtent,
              leadingScrollExtent: constraints.precedingScrollExtent,
              enabled: stacked,
              child: _buildRow(
                scheme,
                ranked[index],
                index: index,
                maxPlays: ranked.first.playCount,
              ),
            ),
          );
        },
      ),
    ];
  }

  List<Widget> _unheardSlivers(ColorScheme scheme, AudioLibrary library) {
    final unheard = [
      for (final audio in library.audioCollection)
        if (audio.playCount <= 0) audio,
    ];
    if (unheard.isEmpty) return const [];
    unheard.sort((a, b) {
      final byCreated = a.created.compareTo(b.created);
      return byCreated != 0 ? byCreated : a.title.compareTo(b.title);
    });
    final preview = unheard.take(_unheardPreviewLimit).toList(growable: false);
    final subtitle = unheard.length > preview.length
        ? '共 ${unheard.length} 首，入库较早的 ${preview.length} 首'
        : '${preview.length} 首曲目';
    return [
      SliverToBoxAdapter(
        child: statsSectionTitle(context, title: '从未播放', subtitle: subtitle),
      ),
      SliverToBoxAdapter(
        child: StackedEffectScope(
          child: Column(
            children: [for (final audio in preview) _buildUnheardRow(scheme, library, audio)],
          ),
        ),
      ),
    ];
  }

  Widget _buildRow(
    ColorScheme scheme,
    rust_library_db.PlayCountEntry entry, {
    required int index,
    required int maxPlays,
  }) {
    final fraction = maxPlays > 0 ? entry.playCount / maxPlays : 0.0;
    final library = AudioLibrary.instance;
    final audio = library.audioByPath(entry.path);
    return DirectionalListItemEntrance(
      identity: entry.path,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
        child: SizedBox(
          height: 64,
          child: Material(
            color: Colors.transparent,
            borderRadius: AppRadius.smCircular,
            child: InkWell(
              hoverColor: scheme.onSurface.withValues(alpha: Alpha.hover),
              borderRadius: AppRadius.smCircular,
              onTap: audio == null ? null : () => playAudio(library, audio),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final modeWidth = SidebarMotionScope.layoutWidthOf(
                    context,
                    constraints.maxWidth,
                  );
                  return _rowContent(
                    scheme,
                    entry,
                    audio,
                    index: index,
                    fraction: fraction,
                    showAlbum: modeWidth >= 760,
                    albumWidth: modeWidth >= 1100 ? 260.0 : 180.0,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _rowContent(
    ColorScheme scheme,
    rust_library_db.PlayCountEntry entry,
    Audio? audio, {
    required int index,
    required double fraction,
    required bool showAlbum,
    required double albumWidth,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
      child: Row(
        children: [
          _rankLabel(scheme, index),
          StatsCover(audio: audio),
          const SizedBox(width: Spacing.md),
          Expanded(child: _titleArtistTexts(scheme, entry.title, entry.artist)),
          if (showAlbum) ...[
            const SizedBox(width: Spacing.lg),
            SizedBox(
              width: albumWidth,
              child: Text(
                audio?.album ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.body,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          const SizedBox(width: Spacing.lg),
          _buildCount(scheme, entry.playCount, fraction),
        ],
      ),
    );
  }

  Widget _rankLabel(ColorScheme scheme, int index) {
    return SizedBox(
      width: 36,
      child: Text(
        '${index + 1}',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: AppType.caption,
          fontWeight: index < 3 ? AppType.weightBold : AppType.weightRegular,
          color: index < 3 ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _titleArtistTexts(ColorScheme scheme, String title, String artist) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppType.subtitle,
            color: scheme.onSurface,
            fontWeight: AppType.weightMedium,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppType.body,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildCount(ColorScheme scheme, int count, double fraction) {
    return SizedBox(
      width: 84,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${formatCount(count)} 次',
            style: TextStyle(
              fontSize: AppType.body,
              fontWeight: AppType.weightSemibold,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: AppRadius.xsCircular,
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 3,
              backgroundColor: scheme.primaryContainer.withValues(alpha: 0.3),
              valueColor: AlwaysStoppedAnimation<Color>(
                scheme.primary.withValues(alpha: 0.68),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnheardRow(
    ColorScheme scheme,
    AudioLibrary library,
    Audio audio,
  ) {
    return DirectionalListItemEntrance(
      identity: audio.path,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
        child: SizedBox(
          height: 64,
          child: Material(
            color: Colors.transparent,
            borderRadius: AppRadius.smCircular,
            child: InkWell(
              hoverColor: scheme.onSurface.withValues(alpha: Alpha.hover),
              borderRadius: AppRadius.smCircular,
              onTap: () => playAudio(library, audio),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
                child: Row(
                  children: [
                    StatsCover(audio: audio),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: _titleArtistTexts(
                        scheme,
                        audio.title,
                        audio.artist,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
