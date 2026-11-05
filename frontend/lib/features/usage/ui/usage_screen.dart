import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/segmented.dart';
import '../../../core/ui/every_icons.dart';
import '../../billing/billing_providers.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../usage_stats.dart';
import '../usage_totals.dart';

/// Settings → Usage: spend and tokens over time by model, kind or provider,
/// cache savings, the provider split and the plan's included-usage bar.
class UsageBody extends ConsumerStatefulWidget {
  const UsageBody({super.key});

  @override
  ConsumerState<UsageBody> createState() => _UsageBodyState();
}

class _UsageBodyState extends ConsumerState<UsageBody> {
  var _range = UsageRange.week;
  var _by = UsageGroupBy.model;
  var _metric = UsageMetric.spend;

  /// Series colors, bottom of the stack first. Checked for colour-vision
  /// separation in this order; "Other" is the muted ink.
  static const palette = [
    EveryPalette.violet400,
    EveryPalette.cyan500,
    Color(0xFFE8833A),
    Color(0xFF3B8FE5),
    Color(0xFFC9A227),
    Color(0xFFD9488B),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final query = (range: _range, by: _by);
    final stats = ref.watch(usageStatsProvider(query));
    final providers = ref.watch(usageStatsProvider((range: _range, by: UsageGroupBy.provider)));
    final billing = ref.watch(billingProvider);
    final catalog = ref.watch(modelCatalogProvider);

    String label(String key) => switch (_by) {
      _ when key == UsageSeries.other => UsageSeries.other,
      UsageGroupBy.model => catalog.resolve(ModelId(key)).name,
      UsageGroupBy.kind => usageKindLabel(key),
      UsageGroupBy.provider => usageProviderLabel(key),
    };

    return ListView(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
      children: [
        if (billing case AsyncData(value: final b)) _QuotaCard(b),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            AdaptiveSegmented(
              values: UsageRange.values,
              selected: _range,
              label: (r) => r.label,
              onSelected: (r) => setState(() => _range = r),
            ),
            AdaptiveSegmented(
              values: UsageGroupBy.values,
              selected: _by,
              label: (b) => b.label,
              onSelected: (b) => setState(() => _by = b),
            ),
            AdaptiveSegmented(
              values: UsageMetric.values,
              selected: _metric,
              label: (m) => m.label,
              onSelected: (m) => setState(() => _metric = m),
            ),
            AdaptiveIconButton(
              icon: EveryIcon.retry,
              tooltip: 'Refresh',
              onPressed: () {
                ref.invalidate(usageStatsProvider);
                ref.invalidate(billingProvider);
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        switch (stats) {
          AsyncData(value: final agg) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Totals(agg.total),
              _Card(
                children: [
                  Text(
                    '${_metric.label} by ${_by.label.toLowerCase()}, ${_range.weekly ? 'per week' : 'per day'}',
                    style: theme.type.headline.tint(theme.text),
                  ),
                  const SizedBox(height: 12),
                  _StackedBars(
                    series: UsageSeries.from(agg, range: _range, now: DateTime.now(), metric: _metric),
                    metric: _metric,
                    weekly: _range.weekly,
                    label: label,
                  ),
                ],
              ),
              if (providers case AsyncData(value: final p) when p.keys.isNotEmpty) _ProviderSplit(p),
              if (agg.keys.isNotEmpty) AdaptiveSectionHeader('By ${_by.label.toLowerCase()}'),
              for (final (i, k) in agg.keys.indexed) _KeyTile(k, label: label(k.key), color: _colorFor(agg, i)),
            ],
          ),
          AsyncError(:final error) => Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text('Couldn’t load your usage.', style: theme.type.headline.tint(theme.text)),
                const SizedBox(height: 4),
                Text('$error', style: theme.type.callout.tint(theme.textMuted), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                AdaptiveButton(label: 'Try again', onPressed: () => ref.invalidate(usageStatsProvider(query))),
              ],
            ),
          ),
          _ => const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: AdaptiveProgress()),
          ),
        },
      ],
    );
  }

  /// The swatch for the [i]th key of the list, matching its chart series.
  Color? _colorFor(UsageAggregate agg, int i) {
    final ranked = [...agg.keys]..sort((a, b) => _metric.of(b).compareTo(_metric.of(a)));
    final at = ranked.indexWhere((k) => k.key == agg.keys[i].key);
    return at >= 0 && at < 5 ? palette[at] : null;
  }
}

String _money(int micros) => micros == 0 ? r'$0' : formatMicros(micros);

class _QuotaCard extends StatelessWidget {
  const _QuotaCard(this.b);

  final BillingSummary b;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final fraction = b.quotaUsedFraction;
    return _Card(
      children: [
        Row(
          children: [
            Text('${b.plan.name} plan · included usage', style: theme.type.headline.tint(theme.text)),
            const Spacer(),
            Text(
              '${formatMicros(b.usedMicros)} of ${formatMicros(b.includedMicros)}',
              style: theme.type.callout.tint(theme.textMuted),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: theme.border)),
                FractionallySizedBox(
                  widthFactor: fraction,
                  child: ColoredBox(color: fraction > 0.9 ? theme.danger : theme.accent),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${formatMicros(b.quotaLeftMicros)} left this period · wallet ${formatMicros(b.walletMicros)}',
          style: theme.type.caption.tint(theme.textMuted),
        ),
      ],
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals(this.t);

  final UsageBucket t;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          _Stat(label: 'Spent', value: _money(t.chargedMicros), note: '${t.calls} calls'),
          _Stat(
            label: 'Tokens',
            value: formatTokens(t.tokens),
            note: '${formatTokens(t.promptTokens)} in · ${formatTokens(t.completionTokens)} out',
          ),
          _Stat(label: 'Cache saved', value: _money(t.savedMicros), note: 'vs. uncached input'),
          _Stat(
            label: 'From cache',
            value: '${(t.cacheShare * 100).round()}%',
            note: '${formatTokens(t.cachedTokens)} input tokens',
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.note});

  final String label;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      width: 160,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.type.caption.tint(theme.textMuted)),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.type.title.copyWith(color: theme.text, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          Text(note, style: theme.type.footnote.tint(theme.textMuted), overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _StackedBars extends StatelessWidget {
  const _StackedBars({required this.series, required this.metric, required this.weekly, required this.label});

  final UsageSeries series;
  final UsageMetric metric;
  final bool weekly;
  final String Function(String key) label;

  String _value(double v) => switch (metric) {
    UsageMetric.spend => _money((v * 1e6).round()),
    UsageMetric.tokens => formatTokens(v.round()),
  };

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Color colorOf(int k) => series.keys[k] == UsageSeries.other
        ? theme.textMuted.withValues(alpha: 0.5)
        : _UsageBodyState.palette[k % _UsageBodyState.palette.length];
    if (series.keys.isEmpty) {
      return SizedBox(
        height: 120,
        child: Center(child: Text('No usage in this range yet.', style: theme.type.body.tint(theme.textMuted))),
      );
    }
    final axis = theme.type.footnote.tint(theme.textMuted);
    final n = series.starts.length;
    final labelEvery = n <= 7 ? 1 : (n <= 12 ? 2 : 5);
    final maxY = series.maxStack == 0 ? 1.0 : series.maxStack * 1.1;
    final width = (420 / n).clamp(4.0, 28.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 220,
          child: BarChart(
            BarChartData(
              maxY: maxY,
              alignment: BarChartAlignment.spaceAround,
              borderData: FlBorderData(show: false),
              gridData: FlGridData(
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => FlLine(color: theme.border, strokeWidth: 1),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 48,
                    getTitlesWidget: (v, meta) => v == meta.max
                        ? const SizedBox.shrink()
                        : SideTitleWidget(
                            meta: meta,
                            child: Text(_value(v), style: axis),
                          ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                    getTitlesWidget: (v, meta) {
                      final i = v.round();
                      if (i < 0 || i >= n || (n - 1 - i) % labelEvery != 0) return const SizedBox.shrink();
                      return SideTitleWidget(
                        meta: meta,
                        child: Text(shortDate(series.starts[i]), style: axis),
                      );
                    },
                  ),
                ),
              ),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  maxContentWidth: 220,
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipColor: (_) => theme.surfaceRaised,
                  tooltipBorder: BorderSide(color: theme.border),
                  getTooltipItem: (group, _, rod, _) {
                    final col = series.values[group.x];
                    final title = weekly
                        ? 'Week of ${shortDate(series.starts[group.x])}'
                        : shortDate(series.starts[group.x]);
                    return BarTooltipItem(
                      '$title · ${_value(rod.toY)}',
                      theme.type.caption.semibold.tint(theme.text),
                      textAlign: TextAlign.left,
                      children: [
                        for (final (k, v) in col.indexed)
                          if (v > 0)
                            TextSpan(
                              text: '\n${label(series.keys[k])}: ${_value(v)}',
                              style: theme.type.footnote.tint(theme.textMuted),
                            ),
                      ],
                    );
                  },
                ),
              ),
              barGroups: [
                for (final (i, col) in series.values.indexed)
                  BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: col.fold(0, (a, b) => a + b),
                        width: width,
                        color: theme.border,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                        rodStackItems: [
                          for (final (k, from, to) in _stack(col))
                            BarChartRodStackItem(
                              from,
                              to,
                              colorOf(k),
                              borderSide: BorderSide(color: theme.surfaceRaised),
                            ),
                        ],
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            for (final (k, key) in series.keys.indexed)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: colorOf(k), borderRadius: BorderRadius.circular(3)),
                  ),
                  const SizedBox(width: 6),
                  Text(label(key), style: theme.type.caption.tint(theme.text)),
                ],
              ),
          ],
        ),
      ],
    );
  }

  static Iterable<(int, double, double)> _stack(List<double> col) sync* {
    var at = 0.0;
    for (final (k, v) in col.indexed) {
      if (v <= 0) continue;
      yield (k, at, at + v);
      at += v;
    }
  }
}

/// "Oct 30".
String shortDate(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[d.month - 1]} ${d.day}';
}

/// Spend per provider as one segmented bar with labels.
class _ProviderSplit extends StatelessWidget {
  const _ProviderSplit(this.agg);

  final UsageAggregate agg;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final byTokens = agg.total.chargedMicros == 0;
    int weight(UsageBucket b) => byTokens ? b.tokens : b.chargedMicros;
    final total = agg.keys.fold<int>(0, (a, b) => a + weight(b));
    if (total == 0) return const SizedBox.shrink();
    const colors = [EveryPalette.violet400, EveryPalette.cyan500, Color(0xFFE8833A)];
    return _Card(
      children: [
        Text(
          byTokens ? 'Provider split (tokens)' : 'Provider split (spend)',
          style: theme.type.headline.tint(theme.text),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 10,
            child: Row(
              children: [
                for (final (i, k) in agg.keys.indexed)
                  if (weight(k) > 0)
                    Expanded(
                      flex: (weight(k) * 1000 ~/ total).clamp(1, 1000),
                      child: Container(
                        margin: EdgeInsets.only(right: i == agg.keys.length - 1 ? 0 : 2),
                        color: i < colors.length ? colors[i] : theme.textMuted,
                      ),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            for (final (i, k) in agg.keys.indexed)
              Text(
                '${usageProviderLabel(k.key)} ${(weight(k) * 100 / total).round()}% · '
                '${byTokens ? formatTokens(k.tokens) : _money(k.chargedMicros)}',
                style: theme.type.caption.tint(i < colors.length ? theme.text : theme.textMuted),
              ),
          ],
        ),
      ],
    );
  }
}

class _KeyTile extends StatelessWidget {
  const _KeyTile(this.k, {required this.label, required this.color});

  final UsageBucket k;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return AdaptiveListTile(
      dense: true,
      leading: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color ?? theme.textMuted.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      title: Text(label),
      subtitle: Text(
        [
          '${k.calls} calls',
          '${formatTokens(k.promptTokens)} in / ${formatTokens(k.completionTokens)} out',
          if (k.cachedTokens > 0) '${(k.cacheShare * 100).round()}% cached',
          if (k.savedMicros > 0) 'saved ${_money(k.savedMicros)}',
        ].join(' · '),
      ),
      trailing: Text(
        k.chargedMicros == 0 ? 'Free' : _money(k.chargedMicros),
        style: TextStyle(color: theme.textMuted, fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
        border: Border.all(color: theme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}
