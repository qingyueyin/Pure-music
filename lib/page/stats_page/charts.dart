import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/page/stats_page/stats_shared.dart';

/// 竖直柱状图，CustomPainter 手绘。
///
/// [values] 为各柱数值，[labels] 为底部标签（空串跳过）；
/// 柱数超过可用宽度时按相邻分桶合并。
class BarSeriesChart extends StatelessWidget {
  const BarSeriesChart({
    super.key,
    required this.values,
    required this.labels,
    this.height = 168,
    this.summary,
  });

  final List<int> values;
  final List<String> labels;
  final double height;

  /// 右上角说明文字（如峰值）。
  final String? summary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 固定高度，避免 LayoutBuilder 固有高度为 0 时把卡片压塌、柱子画到外面。
    return SizedBox(
      width: double.infinity,
      height: height,
      child: ClipRect(
        child: CustomPaint(
          painter: _BarSeriesPainter(
            values: values,
            labels: labels,
            summary: summary,
            barColor: scheme.primary,
            labelColor: scheme.onSurfaceVariant,
            lineColor: scheme.outlineVariant,
          ),
        ),
      ),
    );
  }
}

class _AggBar {
  const _AggBar(this.value, this.label);

  final int value;
  final String label;
}

class _BarSeriesPainter extends CustomPainter {
  const _BarSeriesPainter({
    required this.values,
    required this.labels,
    required this.summary,
    required this.barColor,
    required this.labelColor,
    required this.lineColor,
  });

  final List<int> values;
  final List<String> labels;
  final String? summary;
  final Color barColor;
  final Color labelColor;
  final Color lineColor;

  static const _labelRow = 24.0;
  static const _topPad = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.width <= 0 || size.height <= 0) return;
    final chartBottom = size.height - _labelRow;
    final chartHeight = chartBottom - _topPad;
    if (chartHeight <= 0) return;

    final bars = _aggregate(size.width);
    var max = 0;
    for (final bar in bars) {
      if (bar.value > max) max = bar.value;
    }

    final baseline = Paint()
      ..color = lineColor.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, chartBottom), Offset(size.width, chartBottom), baseline);

    final slot = size.width / bars.length;
    // 数据少时槽很宽，柱宽封顶，避免一根柱铺成整块背景。
    final barWidth = math.min(28.0, math.max(3.0, slot * 0.6));
    final radius = Radius.circular(math.min(barWidth / 2, 4));
    for (var i = 0; i < bars.length; i++) {
      final value = bars[i].value;
      final height = max > 0 && value > 0 ? value / max * chartHeight : 0.0;
      final drawHeight = math.max(height, 2.0);
      final paint = Paint()
        ..color = height > 0
            ? (value == max
                  ? barColor
                  : barColor.withValues(alpha: 0.45))
            : barColor.withValues(alpha: 0.15);
      final rect = Rect.fromLTRB(
        i * slot + (slot - barWidth) / 2,
        chartBottom - drawHeight,
        i * slot + (slot + barWidth) / 2,
        chartBottom,
      );
      canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
    }

    if (summary != null) _paintSummary(canvas, size);
    _paintLabels(canvas, size, bars, slot, chartBottom);
  }

  /// 柱数超过每槽最小宽度时按相邻分桶求和。
  List<_AggBar> _aggregate(double width) {
    final maxBars = math.max(1, (width / 9).floor());
    final bucket = math.max(1, (values.length / maxBars).ceil());
    final bars = <_AggBar>[];
    for (var i = 0; i < values.length; i += bucket) {
      var sum = 0;
      var label = '';
      for (var j = i; j < i + bucket && j < values.length; j++) {
        sum += values[j];
        if (label.isEmpty && j < labels.length && labels[j].isNotEmpty) {
          label = labels[j];
        }
      }
      bars.add(_AggBar(sum, label));
    }
    return bars;
  }

  void _paintSummary(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: TextSpan(
        text: summary,
        style: TextStyle(fontSize: AppType.caption, color: labelColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    painter.paint(canvas, Offset(size.width - painter.width, 0));
  }

  void _paintLabels(
    Canvas canvas,
    Size size,
    List<_AggBar> bars,
    double slot,
    double chartBottom,
  ) {
    if (bars.every((bar) => bar.label.isEmpty)) return;
    final labelCapacity = math.max(1, (size.width / 56).floor());
    final step = math.max(1, (bars.length / labelCapacity).ceil());
    for (var i = 0; i < bars.length; i++) {
      final label = bars[i].label;
      if (label.isEmpty) continue;
      if (i % step != 0 && i != bars.length - 1) continue;
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(fontSize: AppType.microlabel, color: labelColor),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = i * slot + slot / 2 - painter.width / 2;
      if (x < 0 || x + painter.width > size.width) continue;
      painter.paint(canvas, Offset(x, chartBottom + 4));
    }
  }

  @override
  bool shouldRepaint(_BarSeriesPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.labels != labels ||
      oldDelegate.summary != summary ||
      oldDelegate.barColor != barColor;
}

/// 24 小时收听节律柱状图。
class RhythmChart extends StatelessWidget {
  const RhythmChart({
    super.key,
    required this.hourly,
    this.summary,
    this.height = 150,
  });

  final List<int> hourly;

  /// 右上角说明文字（如高峰时段）。
  final String? summary;

  final double height;

  @override
  Widget build(BuildContext context) {
    final labels = <String>[
      for (var hour = 0; hour < hourly.length; hour++)
        hour % 6 == 0 ? '$hour' : '',
    ];
    return BarSeriesChart(
      values: List<int>.of(hourly),
      labels: labels,
      height: height,
      summary: summary,
    );
  }
}

enum _HeatmapTextAlign { verticalCenter, horizontalCenter }

/// 星期 × 小时热力图：行=周一…周日，列=0–23 时。
class WeekHeatmap extends StatelessWidget {
  const WeekHeatmap({super.key, required this.weekdayHourly});

  final List<int> weekdayHourly;

  /// 展示顺序（周一在前），索引 0=周日。
  static const _rowWeekdays = [1, 2, 3, 4, 5, 6, 0];
  static const _rowLabels = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const labelColumn = 22.0;
    const topLabels = 18.0;
    const gap = 3.0;
    const cellHeight = 16.0;
    final height = topLabels + _rowWeekdays.length * (cellHeight + gap);
    return SizedBox(
      width: double.infinity,
      height: height,
      child: CustomPaint(
        painter: _HeatmapPainter(
          weekdayHourly: weekdayHourly,
          rowWeekdays: _rowWeekdays,
          rowLabels: _rowLabels,
          labelColumn: labelColumn,
          topLabels: topLabels,
          gap: gap,
          cellHeight: cellHeight,
          cellColor: scheme.primary,
          emptyColor: scheme.surfaceContainerHighest,
          labelColor: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  const _HeatmapPainter({
    required this.weekdayHourly,
    required this.rowWeekdays,
    required this.rowLabels,
    required this.labelColumn,
    required this.topLabels,
    required this.gap,
    required this.cellHeight,
    required this.cellColor,
    required this.emptyColor,
    required this.labelColor,
  });

  final List<int> weekdayHourly;
  final List<int> rowWeekdays;
  final List<String> rowLabels;
  final double labelColumn;
  final double topLabels;
  final double gap;
  final double cellHeight;
  final Color cellColor;
  final Color emptyColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (weekdayHourly.isEmpty) return;
    final cellWidth = (size.width - labelColumn - gap * 23) / 24;
    if (cellWidth <= 0) return;
    var max = 1;
    for (final value in weekdayHourly) {
      if (value > max) max = value;
    }

    for (var row = 0; row < rowWeekdays.length; row++) {
      final weekday = rowWeekdays[row];
      final y = topLabels + row * (cellHeight + gap);
      _paintText(
        canvas,
        rowLabels[row],
        Offset(0, y + cellHeight / 2),
        align: _HeatmapTextAlign.verticalCenter,
      );
      for (var hour = 0; hour < 24; hour++) {
        final index = weekday * 24 + hour;
        final value = index < weekdayHourly.length ? weekdayHourly[index] : 0;
        final rect = Rect.fromLTWH(
          labelColumn + hour * (cellWidth + gap),
          y,
          cellWidth,
          cellHeight,
        );
        final intensity = math.pow(value / max, 0.6).toDouble();
        final paint = Paint()
          ..color = value > 0
              ? cellColor.withValues(alpha: 0.1 + 0.85 * intensity)
              : emptyColor.withValues(alpha: 0.35);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          paint,
        );
      }
    }

    for (final hour in const [0, 6, 12, 18]) {
      final x = labelColumn + hour * (cellWidth + gap);
      _paintText(
        canvas,
        '$hour',
        Offset(x + cellWidth / 2, topLabels / 2),
        align: _HeatmapTextAlign.horizontalCenter,
      );
    }
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset anchor, {
    required _HeatmapTextAlign align,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: AppType.microlabel, color: labelColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final offset = switch (align) {
      _HeatmapTextAlign.verticalCenter => Offset(0, anchor.dy - painter.height / 2),
      _HeatmapTextAlign.horizontalCenter => Offset(
        anchor.dx - painter.width / 2,
        anchor.dy - painter.height / 2,
      ),
    };
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(_HeatmapPainter oldDelegate) =>
      oldDelegate.weekdayHourly != weekdayHourly ||
      oldDelegate.cellColor != cellColor;
}

/// 每周收听分布（周一到周日横向条）。
class WeekdayBars extends StatelessWidget {
  const WeekdayBars({super.key, required this.weekdayHourly});

  final List<int> weekdayHourly;

  static const _order = [1, 2, 3, 4, 5, 6, 0];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final totals = weekdayTotals(weekdayHourly);
    final max = totals.fold<int>(0, math.max);
    return Column(
      children: [
        for (final weekday in _order)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.sm),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    weekdayLabel(weekday),
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: ClipRRect(
                    borderRadius: AppRadius.xsCircular,
                    child: LinearProgressIndicator(
                      value: max > 0 ? totals[weekday] / max : 0,
                      minHeight: 8,
                      backgroundColor: scheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        scheme.primary.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                SizedBox(
                  width: 60,
                  child: Text(
                    '${formatCount(totals[weekday])} 次',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: AppType.caption,
                      fontWeight: AppType.weightMedium,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
