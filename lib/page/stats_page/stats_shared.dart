import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/services/native/playback_stats_service.dart';

String formatCount(int value) {
  if (value >= 10000) {
    return '${_trimCompact(value / 10000)} 万';
  }
  if (value >= 1000) {
    return '${_trimCompact(value / 1000)} 千';
  }
  return value.toString();
}

String _trimCompact(double value) {
  final formatted = value.toStringAsFixed(1);
  return formatted.endsWith('.0')
      ? formatted.substring(0, formatted.length - 2)
      : formatted;
}

String formatDuration(int seconds) {
  if (seconds <= 0) return '0 分钟';
  final totalMinutes = seconds ~/ 60;
  final days = totalMinutes ~/ (24 * 60);
  final hours = totalMinutes.remainder(24 * 60) ~/ 60;
  final minutes = totalMinutes.remainder(60);
  if (days > 0) return '$days 天 $hours 小时';
  if (hours > 0) return '$hours 小时 $minutes 分钟';
  return '$minutes 分钟';
}

List<int> toIntList(Iterable<int> values) => List<int>.from(values);

void playAudio(AudioLibrary library, Audio audio) {
  final audioIndex = library.audioCollection.indexOf(audio);
  if (audioIndex < 0) return;
  PlayService.instance.playbackService.play(
    audioIndex,
    library.audioCollection,
  );
}

class NamedPlayStat {
  const NamedPlayStat(this.name, this.playCount);

  final String name;
  final int playCount;
}

List<NamedPlayStat> buildTopArtists(
  List<Audio> audios,
  List<PlayCountRecord>? entries, {
  int? limit,
}) {
  final counts = <String, int>{};
  final source = entries == null
      ? audios
            .where((audio) => audio.playCount > 0)
            .map((audio) => (audio, audio.artist, audio.playCount))
      : entries.map((entry) {
          final audio = AudioLibrary.instance.audioByPath(entry.path);
          return (audio, entry.artist, entry.playCount);
        });
  for (final item in source) {
    final audio = item.$1;
    final artists = audio != null && audio.splitedArtists.isNotEmpty
        ? audio.splitedArtists
        : <String>[item.$2];
    for (final artist in artists) {
      final name = artist.trim();
      if (name.isEmpty) continue;
      counts.update(name, (value) => value + item.$3, ifAbsent: () => item.$3);
    }
  }
  return _sortedNamed(counts, limit);
}

List<NamedPlayStat> buildTopAlbums(
  List<Audio> audios,
  List<PlayCountRecord>? entries, {
  int? limit,
}) {
  final counts = <String, int>{};
  final source = entries == null
      ? audios
            .where((audio) => audio.playCount > 0)
            .map((audio) => (audio.album, audio.playCount))
      : entries.map((entry) {
          final audio = AudioLibrary.instance.audioByPath(entry.path);
          return (audio?.album ?? entry.album, entry.playCount);
        });
  for (final item in source) {
    if (item.$1.trim().isEmpty) continue;
    counts.update(item.$1, (value) => value + item.$2, ifAbsent: () => item.$2);
  }
  return _sortedNamed(counts, limit);
}

List<NamedPlayStat> _sortedNamed(Map<String, int> counts, int? limit) {
  final result =
      counts.entries
          .map((entry) => NamedPlayStat(entry.key, entry.value))
          .toList()
        ..sort((a, b) {
          final byCount = b.playCount.compareTo(a.playCount);
          return byCount != 0 ? byCount : a.name.compareTo(b.name);
        });
  if (limit == null) return result;
  return result.take(limit).toList(growable: false);
}

/// 章节标题行：左标题、右副标题。
Widget statsSectionTitle(
  BuildContext context, {
  required String title,
  required String subtitle,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.fromLTRB(
      Spacing.sm,
      Spacing.lg,
      Spacing.sm,
      Spacing.sm,
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppType.sectionTitle,
              fontWeight: AppType.weightSemibold,
              color: scheme.onSurface,
            ),
          ),
        ),
        const SizedBox(width: Spacing.sm),
        Flexible(
          child: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 居中的空态/错误提示。
Widget statsMessage(
  BuildContext context, {
  required IconData icon,
  required String text,
  double height = 180,
}) {
  final scheme = Theme.of(context).colorScheme;
  return SizedBox(
    height: height,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 40,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
          ),
          const SizedBox(height: Spacing.md),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: AppType.body,
            ),
          ),
        ],
      ),
    ),
  );
}

Widget statsCard(
  BuildContext context, {
  required Widget child,
  EdgeInsetsGeometry padding = const EdgeInsets.all(Spacing.md),
}) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    padding: padding,
    decoration: BoxDecoration(
      color: scheme.surfaceContainerLow,
      borderRadius: AppRadius.smCircular,
      border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
    ),
    child: child,
  );
}

/// 通栏内容块，与章节标题的左右留白对齐。
Widget statsBlock(Widget child, {double top = Spacing.lg}) {
  return Padding(
    padding: EdgeInsets.fromLTRB(Spacing.sm, top, Spacing.sm, 0),
    child: child,
  );
}

/// 宽度足够时左右分栏（按信息主次分配 flex），窄窗口退回上下堆叠。
Widget statsSplitRow(
  BuildContext context, {
  required Widget leading,
  required Widget trailing,
  double minWidth = 860,
  int leadingFlex = 6,
  int trailingFlex = 4,
}) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final modeWidth = SidebarMotionScope.contentWidthOf(
        context,
        constraints.maxWidth,
      );
      if (modeWidth < minWidth) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            leading,
            const SizedBox(height: Spacing.lg),
            trailing,
          ],
        );
      }
      // 图表已是固定高度，可以按较高的一张把两张卡片拉齐。
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: leadingFlex, child: leading),
            const SizedBox(width: Spacing.md),
            Expanded(flex: trailingFlex, child: trailing),
          ],
        ),
      );
    },
  );
}

/// 指标网格：按侧栏展开宽度自适应列数。
Widget buildMetricGrid(
  BuildContext context, {
  required List<Widget> Function(double width) tiles,
  int Function(double modeWidth)? columnsFor,
}) {
  return ListenableBuilder(
    listenable: AppSettings.listMotionNotifier,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final modeWidth = SidebarMotionScope.contentWidthOf(
          context,
          constraints.maxWidth,
        );
        final columns =
            columnsFor?.call(modeWidth) ??
            (modeWidth >= 1000
                ? 4
                : modeWidth >= 520
                ? 2
                : 1);
        final width =
            (constraints.maxWidth - (columns - 1) * Spacing.sm) / columns;
        return Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: tiles(width),
        );
      },
    ),
  );
}

Widget buildMetricTile(
  BuildContext context, {
  required double width,
  required IconData icon,
  required Color color,
  required String label,
  required String value,
}) {
  final scheme = Theme.of(context).colorScheme;
  return SizedBox(
    width: width,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 68),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
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
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedMetricValue(value, color: scheme.onSurface),
                  Text(
                    label,
                    maxLines: 2,
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
      ),
    ),
  );
}

class AnimatedMetricValue extends StatelessWidget {
  const AnimatedMetricValue(this.value, {super.key, required this.color});

  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final motionEnabled = AppSettings.instance.enableDataTransitionMotion;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final animate = motionEnabled;
    final duration = !animate
        ? Duration.zero
        : reduceMotion
        ? MotionDuration.fast
        : MotionDuration.xFast;
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: MotionCurve.entrance,
      switchOutCurve: MotionCurve.standard,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previousChildren, ?currentChild],
      ),
      transitionBuilder: (child, animation) {
        if (!animate) return child;
        if (reduceMotion) {
          return FadeTransition(opacity: animation, child: child);
        }
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.12),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: Text(
        value,
        key: ValueKey(value),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppType.pageTitle,
          fontWeight: AppType.weightSemibold,
          color: color,
        ),
      ),
    );
  }
}

/// 章节标题 + 横向卡片流（艺术家/专辑共用）。
Widget buildNamedSection(
  BuildContext context, {
  required String title,
  required List<NamedPlayStat> items,
  required Color accent,
  required void Function(String name) onTap,
}) {
  if (items.isEmpty) return const SizedBox.shrink();
  final scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.fromLTRB(Spacing.sm, Spacing.lg, Spacing.sm, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: AppType.sectionTitle,
            fontWeight: AppType.weightSemibold,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        LayoutBuilder(
          builder: (context, constraints) =>
              _namedWrap(context, items, accent, onTap, constraints),
        ),
      ],
    ),
  );
}

Widget _namedWrap(
  BuildContext context,
  List<NamedPlayStat> items,
  Color accent,
  void Function(String name) onTap,
  BoxConstraints constraints,
) {
  final modeWidth = SidebarMotionScope.contentWidthOf(
    context,
    constraints.maxWidth,
  );
  final columns = modeWidth >= 980
      ? 3
      : modeWidth >= 560
      ? 2
      : 1;
  final width = (constraints.maxWidth - (columns - 1) * Spacing.lg) / columns;
  final maxPlays = items.first.playCount;
  return Wrap(
    spacing: Spacing.lg,
    runSpacing: Spacing.md,
    children: [
      for (var i = 0; i < items.length; i++)
        SizedBox(
          width: width,
          child: _namedStat(context, items[i], i + 1, maxPlays, accent, onTap),
        ),
    ],
  );
}

Widget _namedStat(
  BuildContext context,
  NamedPlayStat item,
  int rank,
  int maxPlays,
  Color accent,
  void Function(String name) onTap,
) {
  final scheme = Theme.of(context).colorScheme;
  final fraction = maxPlays > 0 ? item.playCount / maxPlays : 0.0;
  return Material(
    color: Colors.transparent,
    borderRadius: AppRadius.smCircular,
    child: InkWell(
      hoverColor: scheme.onSurface.withValues(alpha: Alpha.hover),
      borderRadius: AppRadius.smCircular,
      onTap: () => onTap(item.name),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                rank.toString().padLeft(2, '0'),
                style: TextStyle(
                  fontSize: AppType.caption,
                  fontWeight: AppType.weightSemibold,
                  color: rank <= 3 ? accent : scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.body,
                            fontWeight: AppType.weightMedium,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Text(
                        '${formatCount(item.playCount)} 次',
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: AppRadius.xsCircular,
                    child: LinearProgressIndicator(
                      value: fraction,
                      minHeight: 3,
                      backgroundColor: scheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        accent.withValues(alpha: 0.72),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class StatsCover extends StatefulWidget {
  final Audio? audio;

  const StatsCover({super.key, required this.audio});

  @override
  State<StatsCover> createState() => _StatsCoverState();
}

class _StatsCoverState extends State<StatsCover> {
  Uint8List? _cached;

  @override
  void initState() {
    super.initState();
    _cached = widget.audio?.smallCoverBytes;
    if (_cached == null) _load();
  }

  @override
  void didUpdateWidget(StatsCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.audio, widget.audio)) return;
    _cached = widget.audio?.smallCoverBytes;
    if (_cached == null) _load();
  }

  Future<void> _load() async {
    final audio = widget.audio;
    final bytes = await audio?.loadSmallCoverBytes();
    if (mounted && identical(widget.audio, audio) && bytes != null) {
      setState(() => _cached = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cached != null) {
      return ClipRRect(
        borderRadius: AppRadius.smCircular,
        child: Image.memory(
          _cached!,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _placeholder(context),
        ),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: AppRadius.smCircular,
      ),
      child: Icon(
        Symbols.music_note,
        size: 22,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
      ),
    );
  }
}

/// 趋势数据点：x 轴标签、数值与悬停时显示的完整说明。
class TrendPoint {
  const TrendPoint(this.label, this.value, this.fullLabel);

  final String label;
  final int value;
  final String fullLabel;
}

enum StatsPeriodMode { day, week, month }

/// 统计页当前查看的时间段；翻页时只移动 [start]。
class StatsPeriod {
  const StatsPeriod(this.mode, this.start);

  final StatsPeriodMode mode;
  final DateTime start;

  factory StatsPeriod.current(StatsPeriodMode mode) =>
      StatsPeriod(mode, _startOf(mode, DateTime.now()));

  StatsPeriod shift(int delta) => StatsPeriod(mode, switch (mode) {
    StatsPeriodMode.day => DateTime(start.year, start.month, start.day + delta),
    StatsPeriodMode.week => DateTime(
      start.year,
      start.month,
      start.day + delta * 7,
    ),
    StatsPeriodMode.month => DateTime(start.year, start.month + delta),
  });

  DateTime get endExclusive => switch (mode) {
    StatsPeriodMode.day => DateTime(start.year, start.month, start.day + 1),
    StatsPeriodMode.week => DateTime(start.year, start.month, start.day + 7),
    StatsPeriodMode.month => DateTime(start.year, start.month + 1),
  };

  int get startEpoch => start.millisecondsSinceEpoch ~/ 1000;
  int get endEpoch => endExclusive.millisecondsSinceEpoch ~/ 1000;

  bool get isCurrent => _sameDay(StatsPeriod.current(mode).start, start);

  String get title {
    switch (mode) {
      case StatsPeriodMode.day:
        final today = _startOf(StatsPeriodMode.day, DateTime.now());
        final yesterday = DateTime(today.year, today.month, today.day - 1);
        if (_sameDay(start, today)) return '今天 (${start.month}/${start.day})';
        if (_sameDay(start, yesterday)) {
          return '昨天 (${start.month}/${start.day})';
        }
        return '${start.month}月${start.day}日 ${_weekdayName(start)}';
      case StatsPeriodMode.week:
        final end = DateTime(start.year, start.month, start.day + 6);
        final range = '${start.month}.${start.day}–${end.month}.${end.day}';
        return isCurrent ? '本周 ($range)' : range;
      case StatsPeriodMode.month:
        return isCurrent
            ? '本月 (${start.year}年${start.month}月)'
            : '${start.year}年${start.month}月';
    }
  }

  String get rangeLabel {
    switch (mode) {
      case StatsPeriodMode.day:
        return '${start.year}年${start.month}月${start.day}日 ${_weekdayName(start)}';
      case StatsPeriodMode.week:
        final end = DateTime(start.year, start.month, start.day + 6);
        return '${start.month}月${start.day}日 – ${end.month}月${end.day}日';
      case StatsPeriodMode.month:
        return '${start.year}年${start.month}月';
    }
  }
}

DateTime _startOf(StatsPeriodMode mode, DateTime date) => switch (mode) {
  StatsPeriodMode.day => DateTime(date.year, date.month, date.day),
  StatsPeriodMode.week => DateTime(
    date.year,
    date.month,
    date.day - (date.weekday - 1),
  ),
  StatsPeriodMode.month => DateTime(date.year, date.month),
};

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _weekdayName(DateTime date) {
  const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return names[date.weekday - 1];
}

String _two(int value) => value.toString().padLeft(2, '0');

/// 当前时段的趋势点：日=24 小时，周=7 天，月=当月每日。
List<TrendPoint> buildPeriodTrend(StatsPeriod period, PlayHistoryStats stats) {
  if (period.mode == StatsPeriodMode.day) {
    final hourly = toIntList(stats.hourly);
    return [
      for (var hour = 0; hour < 24; hour++)
        TrendPoint(
          hour % 4 == 0 ? _two(hour) : '',
          hour < hourly.length ? hourly[hour] : 0,
          '${_two(hour)}:00 – ${_two((hour + 1) % 24)}:00',
        ),
    ];
  }
  final counts = {for (final day in stats.daily) day.day: day.count.toInt()};
  final points = <TrendPoint>[];
  for (
    var date = period.start;
    date.isBefore(period.endExclusive);
    date = DateTime(date.year, date.month, date.day + 1)
  ) {
    final label = period.mode == StatsPeriodMode.week
        ? _weekdayName(date)
        : switch (date.day) {
            1 || 5 || 10 || 15 || 20 || 25 || 30 => '${date.day}',
            _ => '',
          };
    points.add(
      TrendPoint(
        label,
        counts[_dayKey(date)] ?? 0,
        '${date.month}月${date.day}日 ${_weekdayName(date)}',
      ),
    );
  }
  return points;
}

List<PlayHistoryDayCount> _sortedDaily(List<PlayHistoryDayCount> daily) =>
    [...daily]..sort((a, b) => a.day.compareTo(b.day));

DateTime _dayOnly(DateTime date) => DateTime(date.year, date.month, date.day);

String _dayKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// 连续有播放记录的最长天数。
int longestStreakDays(List<PlayHistoryDayCount> daily) {
  final days = _sortedDaily(daily);
  if (days.isEmpty) return 0;
  var best = 1;
  var run = 1;
  for (var i = 1; i < days.length; i++) {
    final prev = _dayOnly(DateTime.parse(days[i - 1].day));
    final cur = _dayOnly(DateTime.parse(days[i].day));
    final gapDays =
        ((cur.millisecondsSinceEpoch - prev.millisecondsSinceEpoch) /
                Duration.millisecondsPerDay)
            .round();
    if (gapDays == 1) {
      run++;
      if (run > best) best = run;
    } else {
      run = 1;
    }
  }
  return best;
}

/// 22:00–06:00 的播放次数。
int lateNightPlays(List<int> hourly) {
  var total = 0;
  for (final hour in const [0, 1, 2, 3, 4, 5, 22, 23]) {
    if (hour < hourly.length) total += hourly[hour];
  }
  return total;
}

int peakHourOf(List<int> hourly) {
  var best = 0;
  for (var hour = 1; hour < hourly.length; hour++) {
    if (hourly[hour] > hourly[best]) best = hour;
  }
  return best;
}

/// 各星期播放总量，索引 0=周日 … 6=周六（与 Rust 分桶一致）。
List<int> weekdayTotals(List<int> weekdayHourly) {
  final totals = List<int>.filled(7, 0);
  for (var weekday = 0; weekday < 7; weekday++) {
    var sum = 0;
    for (var hour = 0; hour < 24; hour++) {
      final index = weekday * 24 + hour;
      if (index < weekdayHourly.length) sum += weekdayHourly[index];
    }
    totals[weekday] = sum;
  }
  return totals;
}

int peakWeekdayOf(List<int> weekdayHourly) {
  final totals = weekdayTotals(weekdayHourly);
  var best = 0;
  for (var weekday = 1; weekday < 7; weekday++) {
    if (totals[weekday] > totals[best]) best = weekday;
  }
  return best;
}

/// weekday 索引 0=周日 … 6=周六。
String weekdayLabel(int weekday) => '周${'日一二三四五六'[weekday]}';
