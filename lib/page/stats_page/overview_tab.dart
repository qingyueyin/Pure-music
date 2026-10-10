import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/stacked_list_view.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as rust_library_db;
import 'package:pure_music/page/stats_page/charts.dart';
import 'package:pure_music/page/stats_page/stats_shared.dart';

/// 概览 tab：指标、听歌趋势、收听节律。榜单在另外三个栏目。
class OverviewTab extends StatefulWidget {
  const OverviewTab({
    super.key,
    required this.totalPlays,
    required this.playedTracks,
    required this.totalTracks,
    required this.artistCount,
    required this.albumCount,
    required this.estimatedListen,
    required this.history,
  });

  final int totalPlays;
  final int playedTracks;
  final int totalTracks;
  final int artistCount;
  final int albumCount;
  final int estimatedListen;
  final rust_library_db.PlayHistoryStats? history;

  @override
  State<OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<OverviewTab> {
  static const _ranges = ['日', '周', '月'];

  int _range = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final history = widget.history;
    final hasHistory = history != null && history.total > 0;
    return SmoothScrollListView(
      padding: const EdgeInsets.only(bottom: Spacing.bottomNav + Spacing.sm),
      children: [
        statsBlock(
          statsCard(
            context,
            child: buildMetricGrid(
              context,
              tiles: (width) => [
                buildMetricTile(
                  context,
                  width: width,
                  icon: Symbols.play_arrow,
                  color: scheme.primary,
                  label: '累计播放',
                  value: formatCount(widget.totalPlays),
                ),
                buildMetricTile(
                  context,
                  width: width,
                  icon: Symbols.library_music,
                  color: scheme.tertiary,
                  label: '听过的曲目',
                  value: '${widget.playedTracks} / ${widget.totalTracks}',
                ),
                buildMetricTile(
                  context,
                  width: width,
                  icon: Symbols.album,
                  color: scheme.secondary,
                  label: '艺术家 / 专辑',
                  value: '${widget.artistCount} / ${widget.albumCount}',
                ),
                buildMetricTile(
                  context,
                  width: width,
                  icon: Symbols.schedule,
                  color: scheme.onSurfaceVariant,
                  label: '预估收听',
                  value: formatDuration(widget.estimatedListen),
                ),
              ],
            ),
          ),
          top: Spacing.sm,
        ),
        statsBlock(
          statsSplitRow(
            context,
            minWidth: 820,
            leading: _trendCard(context, history, hasHistory),
            trailing: _rhythmCard(context, history, hasHistory),
          ),
        ),
      ],
    );
  }

  Widget _trendCard(
    BuildContext context,
    rust_library_db.PlayHistoryStats? history,
    bool hasHistory,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final daily = history?.daily ?? const <rust_library_db.DayCount>[];
    final points = switch (_range) {
      0 => buildDailyTrend(daily),
      1 => buildWeeklyTrend(daily),
      _ => buildMonthlyTrend(daily),
    };
    return statsCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '听歌趋势',
                style: TextStyle(
                  fontSize: AppType.sectionTitle,
                  fontWeight: AppType.weightSemibold,
                  color: scheme.onSurface,
                ),
              ),
              const Spacer(),
              _rangeSelector(context, scheme),
            ],
          ),
          const SizedBox(height: Spacing.md),
          if (!hasHistory || history == null || points.isEmpty)
            statsMessage(
              context,
              icon: Symbols.show_chart,
              text: '播放几首歌曲后，这里会出现趋势',
              height: 172,
            )
          else ...[
            BarSeriesChart(
              values: [for (final point in points) point.value],
              labels: [for (final point in points) point.label],
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              '${formatCount(history.total)} 次 · ${formatDay(history.firstAt)} – ${formatDay(history.lastAt)}',
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _rangeSelector(BuildContext context, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.xsCircular,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _ranges.length; i++)
            _rangeButton(context, i, scheme),
        ],
      ),
    );
  }

  Widget _rangeButton(BuildContext context, int index, ColorScheme scheme) {
    final selected = _range == index;
    return InkWell(
      borderRadius: AppRadius.xsCircular,
      onTap: () => setState(() => _range = index),
      child: AnimatedContainer(
        duration: MotionDuration.fast,
        curve: MotionCurve.standard,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: selected
            ? BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: AppRadius.xsCircular,
              )
            : null,
        child: Text(
          _ranges[index],
          style: TextStyle(
            fontSize: AppType.caption,
            fontWeight: selected ? AppType.weightSemibold : AppType.weightRegular,
            color: selected
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _rhythmCard(
    BuildContext context,
    rust_library_db.PlayHistoryStats? history,
    bool hasHistory,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final hourly = history == null ? const <int>[] : toIntList(history.hourly);
    final peakHour = hourly.isEmpty ? null : peakHourOf(hourly);
    return statsCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '收听节律',
                style: TextStyle(
                  fontSize: AppType.sectionTitle,
                  fontWeight: AppType.weightSemibold,
                  color: scheme.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                peakHour == null ? '按小时统计' : '高峰 $peakHour:00',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          if (!hasHistory || history == null)
            statsMessage(
              context,
              icon: Symbols.schedule,
              text: '播放几首歌曲后，这里会出现节律分布',
              height: 154,
            )
          else ...[
            RhythmChart(hourly: hourly),
            const SizedBox(height: Spacing.sm),
            Text(
              '${formatCount(history.total)} 次',
              style: TextStyle(
                fontSize: AppType.caption,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
