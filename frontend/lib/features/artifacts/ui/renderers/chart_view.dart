import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../domain/chart_spec.dart';

/// A chart from a [ChartSpec] (`render_chart`, or a ```chart block in a
/// document): bars (grouped, stacked, horizontal), lines and areas with
/// reference lines and marked points, pie and donut, scatter. Under it the
/// caption, the source, and the numbers as a table with Copy CSV.
class ChartView extends StatefulWidget {
  const ChartView({super.key, required this.spec, this.height = 280, this.showTitle = false});

  final ChartSpec spec;
  final double height;

  /// Draw the title above (in documents; cards show it in their header).
  final bool showTitle;

  static Color colorOf(int i) => Color(chartPalette[i % chartPalette.length]);

  @override
  State<ChartView> createState() => _ChartViewState();
}

class _ChartViewState extends State<ChartView> {
  bool _table = false;
  bool _copied = false;

  ChartSpec get spec => widget.spec;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (spec.isEmpty) return Text('No data to chart.', style: theme.type.body.tint(theme.textMuted));
    final label = theme.type.footnote.tint(theme.textMuted);
    final legend = spec.isRound
        ? [for (final (i, s) in spec.slices.indexed) (s.label, s.other ? Color(chartOtherColor) : ChartView.colorOf(i))]
        : [for (final (i, _) in spec.series.indexed) (spec.seriesName(i), ChartView.colorOf(i))];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showTitle && spec.title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(spec.title, style: theme.type.headline.semibold.tint(theme.text)),
          ),
        if (spec.type == ChartType.bar && spec.horizontal)
          _HorizontalBars(spec: spec)
        else
          SizedBox(
            height: widget.height,
            child: Padding(padding: const EdgeInsets.only(top: 8, right: 12), child: _chart(theme, label)),
          ),
        if (legend.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                for (final (name, color) in legend)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                      ),
                      const SizedBox(width: 6),
                      Text(name, style: theme.type.caption.tint(theme.text)),
                    ],
                  ),
              ],
            ),
          ),
        if (spec.caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(spec.caption, style: theme.type.callout.tint(theme.text).copyWith(height: 1.35)),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 14,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (spec.source.isNotEmpty) Text('Source: ${spec.source}', style: label),
              _Link(_table ? 'Hide data' : 'Data', () => setState(() => _table = !_table)),
              if (_table)
                _Link(_copied ? 'Copied' : 'Copy CSV', () async {
                  await Clipboard.setData(ClipboardData(text: spec.csv));
                  if (mounted) setState(() => _copied = true);
                }),
            ],
          ),
        ),
        if (_table)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _DataTable(spec: spec),
          ),
      ],
    );
  }

  Widget _chart(EveryTheme theme, TextStyle label) {
    final cats = spec.categories;
    final categorical = spec.categorical;
    double xOf(Object x) => categorical ? cats.indexOf(xText(x)).toDouble() : (x as num).toDouble();

    Widget bottomTitle(double v, TitleMeta meta) {
      if (!categorical) {
        return SideTitleWidget(
          meta: meta,
          child: Text(formatNumber(v), style: label),
        );
      }
      final i = v.round();
      if (i != v || i < 0 || i >= cats.length) return const SizedBox.shrink();
      return SideTitleWidget(
        meta: meta,
        child: Text(cats[i], style: label, overflow: TextOverflow.ellipsis),
      );
    }

    final titles = FlTitlesData(
      topTitles: const AxisTitles(),
      rightTitles: const AxisTitles(),
      leftTitles: AxisTitles(
        axisNameWidget: spec.yLabel.isEmpty ? null : Text(spec.yLabel, style: label),
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 44,
          getTitlesWidget: (v, meta) => v == meta.max || v == meta.min && v != 0
              ? const SizedBox.shrink()
              : SideTitleWidget(
                  meta: meta,
                  child: Text(spec.format(v), style: label),
                ),
        ),
      ),
      bottomTitles: AxisTitles(
        axisNameWidget: spec.xLabel.isEmpty ? null : Text(spec.xLabel, style: label),
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 28,
          interval: categorical ? math.max(1, (cats.length / 8).ceil()).toDouble() : null,
          getTitlesWidget: bottomTitle,
        ),
      ),
    );
    final grid = FlGridData(
      drawVerticalLine: false,
      getDrawingHorizontalLine: (_) => FlLine(color: theme.border, strokeWidth: 1),
    );
    final border = FlBorderData(show: false);
    final note = theme.type.micro.semibold.tint(theme.text);
    final extra = ExtraLinesData(
      horizontalLines: [
        for (final r in spec.referenceLines)
          HorizontalLine(
            y: r.y,
            color: theme.text.withValues(alpha: 0.7),
            strokeWidth: 1.2,
            dashArray: const [5, 4],
            label: HorizontalLineLabel(
              show: true,
              alignment: Alignment.topRight,
              style: note,
              labelResolver: (_) => r.label.isEmpty ? spec.format(r.y) : '${r.label} (${spec.format(r.y)})',
            ),
          ),
      ],
      verticalLines: [
        if (spec.type != ChartType.bar)
          for (final a in spec.annotations)
            if (!categorical || cats.contains(xText(a.x)))
              VerticalLine(
                x: xOf(a.x),
                color: theme.textMuted,
                strokeWidth: 1,
                dashArray: const [3, 3],
                label: VerticalLineLabel(
                  show: a.label.isNotEmpty,
                  alignment: Alignment.topRight,
                  style: note,
                  labelResolver: (_) => a.label,
                ),
              ),
      ],
    );
    final (lo, hi) = spec.valueRange;

    switch (spec.type) {
      case ChartType.pie || ChartType.donut:
        final slices = spec.slices;
        final total = slices.fold(0.0, (t, s) => t + s.value);
        final donut = spec.type == ChartType.donut;
        final chart = PieChart(
          PieChartData(
            sectionsSpace: 2,
            centerSpaceRadius: donut ? widget.height * 0.24 : 0,
            sections: [
              for (final (i, s) in slices.indexed)
                PieChartSectionData(
                  value: s.value,
                  color: s.other ? Color(chartOtherColor) : ChartView.colorOf(i),
                  title: s.value / total >= 0.06 ? _pct(s.value / total) : '',
                  radius: donut ? widget.height * 0.16 : widget.height * 0.4,
                  titlePositionPercentageOffset: donut ? 0.5 : 0.62,
                  titleStyle: theme.type.footnote.semibold.tint(const Color(0xFFFFFFFF)),
                ),
            ],
          ),
        );
        // A total of shares means nothing; values in % are already shares.
        if (!donut || spec.unit == '%') return chart;
        return Stack(
          alignment: Alignment.center,
          children: [
            chart,
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(spec.format(total), style: theme.type.title.semibold.tint(theme.text)),
                Text('Total', style: label),
              ],
            ),
          ],
        );
      case ChartType.bar:
        final n = spec.series.length;
        return BarChart(
          BarChartData(
            titlesData: titles,
            gridData: grid,
            borderData: border,
            minY: lo,
            maxY: hi + (hi - lo) * 0.05,
            extraLinesData: ExtraLinesData(horizontalLines: extra.horizontalLines),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipItem: (group, _, rod, rodIndex) {
                  final c = cats[group.x];
                  final lines = [
                    for (final (si, s) in spec.series.indexed)
                      if (spec.valueAt(s, c) case final v?)
                        if (spec.stacked || si == rodIndex)
                          '${n > 1 ? '${spec.seriesName(si)}: ' : ''}${spec.format(v)}',
                  ];
                  return BarTooltipItem('$c\n${lines.join('\n')}', theme.type.caption.tint(const Color(0xFFFFFFFF)));
                },
              ),
            ),
            barGroups: [
              for (final (ci, c) in cats.indexed)
                BarChartGroupData(
                  x: ci,
                  barsSpace: 3,
                  barRods: spec.stacked
                      ? [_stack(c, cats.length)]
                      : [
                          for (final (si, s) in spec.series.indexed)
                            BarChartRodData(
                              toY: spec.valueAt(s, c) ?? 0,
                              color: ChartView.colorOf(si),
                              width: (240 / (n * cats.length).clamp(1, 240)).clamp(4, 24),
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                            ),
                        ],
                ),
            ],
          ),
        );
      case ChartType.scatter:
        return ScatterChart(
          ScatterChartData(
            titlesData: titles,
            gridData: grid,
            borderData: border,
            scatterSpots: [
              for (final (si, s) in spec.series.indexed)
                for (final p in s.points)
                  ScatterSpot(xOf(p.x), p.y, dotPainter: FlDotCirclePainter(radius: 4, color: ChartView.colorOf(si))),
            ],
          ),
        );
      case ChartType.line || ChartType.area:
        final marked = {for (final a in spec.annotations) xText(a.x)};
        return LineChart(
          LineChartData(
            titlesData: titles,
            gridData: grid,
            borderData: border,
            extraLinesData: extra,
            minY: spec.type == ChartType.area ? lo : null,
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipItems: (spots) => [
                  for (final s in spots)
                    LineTooltipItem(
                      '${spec.series.length > 1 ? '${spec.seriesName(s.barIndex)}: ' : ''}${spec.format(s.y)}',
                      theme.type.caption.tint(const Color(0xFFFFFFFF)),
                    ),
                ],
              ),
            ),
            lineBarsData: [
              for (final (si, s) in spec.series.indexed)
                LineChartBarData(
                  spots: [for (final p in s.points) FlSpot(xOf(p.x), p.y)]..sort((a, b) => a.x.compareTo(b.x)),
                  isCurved: true,
                  preventCurveOverShooting: true,
                  color: ChartView.colorOf(si),
                  barWidth: 2.5,
                  dotData: FlDotData(
                    show: s.points.length <= 24 || marked.isNotEmpty,
                    checkToShowDot: (spot, _) =>
                        s.points.length <= 24 || marked.contains(categorical ? cats[spot.x.round()] : xText(spot.x)),
                  ),
                  belowBarData: BarAreaData(
                    show: spec.type == ChartType.area,
                    color: ChartView.colorOf(si).withValues(alpha: 0.18),
                  ),
                ),
            ],
          ),
        );
    }
  }

  /// One stacked bar: the series' values piled up (negatives below zero).
  BarChartRodData _stack(String category, int count) {
    var up = 0.0, down = 0.0;
    final items = <BarChartRodStackItem>[];
    for (final (si, s) in spec.series.indexed) {
      final v = spec.valueAt(s, category) ?? 0;
      if (v >= 0) {
        items.add(BarChartRodStackItem(up, up + v, ChartView.colorOf(si)));
        up += v;
      } else {
        items.add(BarChartRodStackItem(down + v, down, ChartView.colorOf(si)));
        down += v;
      }
    }
    return BarChartRodData(
      fromY: down,
      toY: up,
      rodStackItems: items,
      color: const Color(0x00000000),
      width: (280 / count.clamp(1, 280)).clamp(6, 36),
      borderRadius: BorderRadius.zero,
    );
  }
}

/// Bars running right, one row per category: labels stay readable however long.
class _HorizontalBars extends StatelessWidget {
  const _HorizontalBars({required this.spec});

  final ChartSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final (lo, hi) = spec.valueRange;
    final span = hi - lo;
    final label = theme.type.footnote.tint(theme.text);
    final value = theme.type.footnote.tint(theme.textMuted);
    final ref = spec.referenceLines.firstOrNull;
    return LayoutBuilder(
      builder: (context, box) {
        final labelWidth = math.min(170.0, box.maxWidth * 0.32);
        final barArea = box.maxWidth - labelWidth - 64;
        double at(double v) => (v - lo) / span * barArea;
        Widget row(String c) {
          final segments = <Widget>[];
          if (spec.stacked) {
            var up = 0.0;
            for (final (si, s) in spec.series.indexed) {
              final v = spec.valueAt(s, c) ?? 0;
              if (v <= 0) continue;
              segments.add(
                Positioned(
                  left: at(up),
                  width: at(up + v) - at(up),
                  top: 0,
                  bottom: 0,
                  child: ColoredBox(color: ChartView.colorOf(si)),
                ),
              );
              up += v;
            }
          }
          final total = spec.stacked ? spec.series.fold(0.0, (t, s) => t + math.max(0, spec.valueAt(s, c) ?? 0)) : null;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: labelWidth,
                  child: Text(c, style: label, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (spec.stacked)
                        Row(
                          children: [
                            SizedBox(
                              width: at(total!),
                              height: 16,
                              child: Stack(children: segments),
                            ),
                            const SizedBox(width: 6),
                            Text(spec.format(total), style: value),
                          ],
                        )
                      else
                        for (final (si, s) in spec.series.indexed)
                          if (spec.valueAt(s, c) case final v?)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 1),
                              child: Row(
                                children: [
                                  SizedBox(width: at(math.max(lo, 0))),
                                  Container(
                                    width: math.max(1, at(v) - at(math.max(lo, 0))),
                                    height: spec.series.length > 1 ? 10 : 16,
                                    decoration: BoxDecoration(
                                      color: ChartView.colorOf(si),
                                      borderRadius: const BorderRadius.horizontal(right: Radius.circular(3)),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(spec.format(v), style: value),
                                ],
                              ),
                            ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        final rows = Column(children: [for (final c in spec.categories) row(c)]);
        if (ref == null) return rows;
        return Stack(
          children: [
            rows,
            Positioned(
              left: labelWidth + 8 + at(ref.y),
              top: 0,
              bottom: 0,
              child: Container(width: 1.2, color: theme.text.withValues(alpha: 0.6)),
            ),
            Positioned(
              left: labelWidth + 12 + at(ref.y),
              top: -2,
              child: Text(
                ref.label.isEmpty ? spec.format(ref.y) : ref.label,
                style: theme.type.micro.semibold.tint(theme.text),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The numbers behind the chart.
class _DataTable extends StatelessWidget {
  const _DataTable({required this.spec});

  final ChartSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final rows = spec.csv.trimRight().split('\n').map(_cells).toList();
    final head = theme.type.footnote.semibold.tint(theme.text);
    final body = theme.type.footnote.tint(theme.text);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder(horizontalInside: BorderSide(color: theme.border)),
        children: [
          for (final (i, r) in rows.indexed)
            TableRow(
              children: [
                for (final (j, c) in r.indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    child: Text(c, style: i == 0 ? head : body, textAlign: j == 0 ? TextAlign.start : TextAlign.end),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// One CSV line's cells (quotes as [ChartSpec.csv] writes them).
  static List<String> _cells(String line) {
    final out = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (quoted) {
        if (ch == '"' && i + 1 < line.length && line[i + 1] == '"') {
          cell.write('"');
          i++;
        } else if (ch == '"') {
          quoted = false;
        } else {
          cell.write(ch);
        }
      } else if (ch == '"') {
        quoted = true;
      } else if (ch == ',') {
        out.add(cell.toString());
        cell.clear();
      } else {
        cell.write(ch);
      }
    }
    out.add(cell.toString());
    return out;
  }
}

class _Link extends StatelessWidget {
  const _Link(this.text, this.onTap);

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Text(text, style: theme.type.footnote.medium.tint(theme.accent)),
      ),
    );
  }
}

String _pct(double share) {
  final p = share * 100;
  return '${p >= 10 || p == p.roundToDouble() ? p.round() : p.toStringAsFixed(1)}%';
}
