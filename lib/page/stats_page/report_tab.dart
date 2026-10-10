import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/stacked_list_view.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/native/rust/api/library_db.dart' as rust_library_db;
import 'package:pure_music/page/stats_page/charts.dart';
import 'package:pure_music/page/stats_page/stats_shared.dart';

/// 报告 tab：收听洞察卡 + 星期热力图 + 每周分布。
class ReportTab extends StatelessWidget {
  const ReportTab({super.key, required this.history});

  final rust_library_db.PlayHistoryStats? history;

  @override
  Widget build(BuildContext context) {
    final history = this.history;
    if (history == null || history.total == 0) {
      return SmoothScrollListView(
        padding: const EdgeInsets.only(bottom: Spacing.bottomNav + Spacing.sm),
        children: [
          statsMessage(
            context,
            icon: Symbols.insights,
            text: '播放几首歌曲后，这里会出现收听报告',
            height: 280,
          ),
        ],
      );
    }
    final hourly = toIntList(history.hourly);
    final weekdayHourly = toIntList(history.weekdayHourly);
    return SmoothScrollListView(
      padding: const EdgeInsets.only(bottom: Spacing.bottomNav + Spacing.sm),
      children: [
        statsSectionTitle(
          context,
          title: '收听报告',
          subtitle: '${formatDay(history.firstAt)} – ${formatDay(history.lastAt)}',
        ),
        statsBlock(
          statsCard(
            context,
            child: buildMetricGrid(
              context,
              columnsFor: (width) => width >= 1000 ? 3 : width >= 560 ? 2 : 1,
              tiles: (width) => _insights(
                context,
                history,
                hourly,
                weekdayHourly,
                width,
              ),
            ),
          ),
          top: 0,
        ),
        statsBlock(
          statsSplitRow(
            context,
            minWidth: 900,
            leadingFlex: 2,
            trailingFlex: 1,
            leading: _heatmapCard(context, weekdayHourly),
            trailing: _weekdayCard(context, history.total, weekdayHourly),
          ),
          top: Spacing.lg,
        ),
      ],
    );
  }

  List<Widget> _insights(
    BuildContext context,
    rust_library_db.PlayHistoryStats history,
    List<int> hourly,
    List<int> weekdayHourly,
    double width,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final daily = history.daily;
    final activeDays = daily.length;
    final average = activeDays > 0 ? history.total ~/ activeDays : 0;
    var peakDay = '';
    var peakDayCount = 0;
    for (final day in daily) {
      if (day.count > peakDayCount) {
        peakDayCount = day.count;
        peakDay = day.day;
      }
    }
    final peakDate = peakDay.isEmpty ? null : DateTime.tryParse(peakDay);
    final lateNight = lateNightPlays(hourly);
    final lateShare = history.total > 0
        ? (lateNight * 100 / history.total).round()
        : 0;
    final peakHour = peakHourOf(hourly);
    final peakWeekday = peakWeekdayOf(weekdayHourly);
    final weekdayTotalsList = weekdayTotals(weekdayHourly);
    return [
      _insightTile(
        context,
        width: width,
        icon: Symbols.calendar_month,
        color: scheme.primary,
        label: '最长连续收听',
        value: '${longestStreakDays(daily)} 天',
      ),
      _insightTile(
        context,
        width: width,
        icon: Symbols.today,
        color: scheme.tertiary,
        label: '最活跃的一天',
        value: peakDate == null
            ? '-'
            : '${peakDate.month}月${peakDate.day}日 · $peakDayCount 次',
      ),
      _insightTile(
        context,
        width: width,
        icon: Symbols.schedule,
        color: scheme.secondary,
        label: '高峰时段',
        value: '$peakHour:00 – ${peakHour + 1}:00',
      ),
      _insightTile(
        context,
        width: width,
        icon: Symbols.dark_mode,
        color: scheme.onSurfaceVariant,
        label: '深夜播放（22–6 点）',
        value: '$lateNight 次 · $lateShare%',
      ),
      _insightTile(
        context,
        width: width,
        icon: Symbols.date_range,
        color: scheme.tertiary,
        label: '最常听的星期',
        value:
            '${weekdayLabel(peakWeekday)} · ${formatCount(weekdayTotalsList[peakWeekday])} 次',
      ),
      _insightTile(
        context,
        width: width,
        icon: Symbols.trending_up,
        color: scheme.primary,
        label: '活跃日均播放',
        value: '$average 次 / 天',
      ),
    ];
  }

  Widget _insightTile(
    BuildContext context, {
    required double width,
    required IconData icon,
    required Color color,
    required String label,
    required String value,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: AppRadius.smCircular,
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: AppRadius.smCircular,
            ),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.subtitle,
                    fontWeight: AppType.weightSemibold,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _heatmapCard(BuildContext context, List<int> weekdayHourly) {
    final scheme = Theme.of(context).colorScheme;
    return statsCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '收听热力',
                style: TextStyle(
                  fontSize: AppType.sectionTitle,
                  fontWeight: AppType.weightSemibold,
                  color: scheme.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                '星期 × 小时',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          WeekHeatmap(weekdayHourly: weekdayHourly),
        ],
      ),
    );
  }

  Widget _weekdayCard(
    BuildContext context,
    int total,
    List<int> weekdayHourly,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return statsCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '每周分布',
                style: TextStyle(
                  fontSize: AppType.sectionTitle,
                  fontWeight: AppType.weightSemibold,
                  color: scheme.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                '${formatCount(total)} 次',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          WeekdayBars(weekdayHourly: weekdayHourly),
        ],
      ),
    );
  }
}
