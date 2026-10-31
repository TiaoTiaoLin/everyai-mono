import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/billing/billing_providers.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/ui/usage_screen.dart';
import 'package:every_ai/features/usage/usage_stats.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

class _Catalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

class _Billing extends BillingController {
  @override
  Future<BillingSummary> build() async => BillingSummary.fromJson({
    'plan': {'id': 'pro', 'name': 'Pro', 'price_cents': 2000, 'included_micros': 20000000},
    'period_end': 1795000000,
    'included_micros': 20000000,
    'used_micros': 5000000,
    'wallet_micros': 1000000,
  });
}

int _s(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

void main() {
  final now = DateTime(2026, 10, 30, 15); // a Friday

  test('bucketStarts: days end today; weeks start on Monday', () {
    final days = bucketStarts(UsageRange.week, now);
    expect(days, hasLength(7));
    expect(days.last, DateTime(2026, 10, 30));
    expect(days.first, DateTime(2026, 10, 24));
    final weeks = bucketStarts(UsageRange.quarter, now);
    expect(weeks, hasLength(12));
    expect(weeks.last, DateTime(2026, 10, 26));
    expect(weeks.every((w) => w.weekday == DateTime.monday), isTrue);
  });

  test('usagePath asks for local buckets from the first one', () {
    final path = usagePath((range: UsageRange.month, by: UsageGroupBy.provider), now);
    final uri = Uri.parse('https://x/$path');
    expect(uri.path, '/v1/usage');
    expect(uri.queryParameters['group'], 'day');
    expect(uri.queryParameters['by'], 'provider');
    expect(uri.queryParameters['from'], '${_s(DateTime(2026, 10, 1))}');
    expect(uri.queryParameters['tz_offset'], '${now.timeZoneOffset.inSeconds}');
  });

  test('aggregate parses and series fills empty days and folds extra keys into Other', () {
    final today = DateTime(2026, 10, 30);
    final yesterday = DateTime(2026, 10, 29);
    Map<String, Object?> b(DateTime? at, String key, int micros, {int cached = 0}) => {
      'start': at == null ? 0 : _s(at),
      'key': key,
      'calls': 1,
      'prompt_tokens': 1000,
      'completion_tokens': 100,
      'cached_tokens': cached,
      'charged_micros': micros,
      'saved_micros': cached,
    };
    final agg = UsageAggregate.fromJson({
      'buckets': [
        b(yesterday, 'a', 3000000),
        b(today, 'a', 1000000),
        b(today, 'b', 500000),
        b(today, 'c', 200000),
        b(DateTime(2026, 1, 1), 'a', 9), // outside the range: dropped
      ],
      'keys': [b(null, 'a', 4000000), b(null, 'b', 500000), b(null, 'c', 200000)],
      'total': b(null, '', 4700000, cached: 500),
    });
    expect(agg.total.chargedMicros, 4700000);
    expect(agg.total.cacheShare, 0.5);
    expect(agg.keys.first.start, isNull);

    final s = UsageSeries.from(agg, range: UsageRange.week, now: now, top: 2);
    expect(s.starts, hasLength(7));
    expect(s.keys, ['a', 'b', UsageSeries.other]);
    expect(s.values[5], [3.0, 0, 0]);
    expect(s.values[6], [1.0, 0.5, 0.2]);
    expect(s.values[0], [0, 0, 0]);
    expect(s.maxStack, closeTo(3.0, 1e-9));

    final tokens = UsageSeries.from(agg, range: UsageRange.week, now: now, metric: UsageMetric.tokens);
    expect(tokens.keys, hasLength(3));
    expect(tokens.values[6], [1100, 1100, 1100]);
  });

  test('labels', () {
    expect(usageKindLabel('gateway'), 'Code');
    expect(usageKindLabel('polish'), 'Polish');
    expect(usageKindLabel('decide'), 'Decisions');
    expect(usageKindLabel('summarise'), 'Long reads');
    expect(usageProviderLabel('anthropic'), 'Anthropic');
  });

  testWidgets('Settings → Usage renders the quota, totals, chart and breakdown', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);
    Map<String, Object?> b(DateTime? at, String key, int micros) => {
      'start': at == null ? 0 : _s(at),
      'key': key,
      'calls': 2,
      'prompt_tokens': 2000,
      'completion_tokens': 100,
      'cached_tokens': 1000,
      'charged_micros': micros,
      'saved_micros': 1234,
    };
    UsageAggregate agg(String a, String c) => UsageAggregate.fromJson({
      'buckets': [b(day, a, 1500000), b(day, c, 500000)],
      'keys': [b(null, a, 1500000), b(null, c, 500000)],
      'total': b(null, '', 2000000),
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          modelCatalogProvider.overrideWith(_Catalog.new),
          billingProvider.overrideWith(_Billing.new),
          usageStatsProvider.overrideWith(
            (ref, q) async => q.by == UsageGroupBy.provider ? agg('anthropic', 'openrouter') : agg('chat', 'gateway'),
          ),
        ],
        child: m.MaterialApp(
          home: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: m.Material(child: UsageBody()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Pro plan'), findsOneWidget);
    expect(find.text(r'$2.00'), findsWidgets);
    expect(find.text('Cache saved'), findsOneWidget);
    expect(find.textContaining('Anthropic 75%'), findsOneWidget);
    await tester.tap(find.text('Kind'));
    await tester.pumpAndSettle();
    expect(find.text('Code'), findsWidgets);
    expect(find.text('By kind'), findsOneWidget);
  });
}
