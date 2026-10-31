import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// The time span the Usage screen charts, and its bucket size.
enum UsageRange {
  week('7 days', 7, false),
  month('30 days', 30, false),
  quarter('12 weeks', 84, true);

  const UsageRange(this.label, this.days, this.weekly);

  final String label;
  final int days;

  /// Buckets are Monday weeks instead of days.
  final bool weekly;

  String get group => weekly ? 'week' : 'day';
}

/// What each chart series is keyed by.
enum UsageGroupBy {
  model('Model'),
  kind('Kind'),
  provider('Provider');

  const UsageGroupBy(this.label);

  final String label;
}

/// Totals for one bucket and key, one key over the range, or everything.
@immutable
final class UsageBucket {
  const UsageBucket({
    this.start,
    this.key = '',
    this.calls = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.cachedTokens = 0,
    this.cacheWriteTokens = 0,
    this.chargedMicros = 0,
    this.savedMicros = 0,
  });

  factory UsageBucket.fromJson(Map<String, Object?> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    final start = n('start');
    return UsageBucket(
      start: start == 0 ? null : DateTime.fromMillisecondsSinceEpoch(start * 1000),
      key: j['key'] as String? ?? '',
      calls: n('calls'),
      promptTokens: n('prompt_tokens'),
      completionTokens: n('completion_tokens'),
      cachedTokens: n('cached_tokens'),
      cacheWriteTokens: n('cache_write_tokens'),
      chargedMicros: n('charged_micros'),
      savedMicros: n('saved_micros'),
    );
  }

  final DateTime? start;
  final String key;
  final int calls;

  /// Input tokens, cached ones included.
  final int promptTokens;
  final int completionTokens;
  final int cachedTokens;
  final int cacheWriteTokens;

  /// Charged, in millionths of a dollar (marked up).
  final int chargedMicros;

  /// What cache reads saved against the uncached input price.
  final int savedMicros;

  int get tokens => promptTokens + completionTokens;

  /// Share of input tokens served from the prompt cache.
  double get cacheShare => promptTokens == 0 ? 0 : (cachedTokens / promptTokens).clamp(0, 1);
}

/// `GET /v1/usage?group=…&by=…`.
@immutable
final class UsageAggregate {
  const UsageAggregate({required this.buckets, required this.keys, required this.total});

  factory UsageAggregate.fromJson(Map<String, Object?> j) {
    List<UsageBucket> list(String k) => [
      for (final b in (j[k] as List<Object?>?) ?? const [])
        if (b case final Map<String, Object?> m) UsageBucket.fromJson(m),
    ];
    return UsageAggregate(
      buckets: list('buckets'),
      keys: list('keys'),
      total: switch (j['total']) {
        final Map<String, Object?> m => UsageBucket.fromJson(m),
        _ => const UsageBucket(),
      },
    );
  }

  static const empty = UsageAggregate(buckets: [], keys: [], total: UsageBucket());

  final List<UsageBucket> buckets;

  /// Per key over the range, most charged first.
  final List<UsageBucket> keys;
  final UsageBucket total;
}

/// What a chart bar is measured in.
enum UsageMetric {
  spend('Spend'),
  tokens('Tokens');

  const UsageMetric(this.label);

  final String label;

  double of(UsageBucket b) => switch (this) {
    UsageMetric.spend => b.chargedMicros / 1e6,
    UsageMetric.tokens => b.tokens.toDouble(),
  };
}

/// Stacked bars ready to draw: one column per bucket start in the range
/// (empty ones included), stacked by the top keys plus "Other".
@immutable
final class UsageSeries {
  const UsageSeries({required this.starts, required this.keys, required this.values});

  /// Label for everything past the top keys.
  static const other = 'Other';

  final List<DateTime> starts;

  /// Stack order, bottom first; [other] last when present.
  final List<String> keys;

  /// `values[column][key]`.
  final List<List<double>> values;

  double get maxStack => values.fold(0, (m, col) {
    final sum = col.fold<double>(0, (a, b) => a + b);
    return sum > m ? sum : m;
  });

  static UsageSeries from(
    UsageAggregate agg, {
    required UsageRange range,
    required DateTime now,
    UsageMetric metric = UsageMetric.spend,
    int top = 5,
  }) {
    final starts = bucketStarts(range, now);
    // Top keys by the chosen metric over the whole range.
    final ranked = [...agg.keys]..sort((a, b) => metric.of(b).compareTo(metric.of(a)));
    final shown = ranked.take(top).map((k) => k.key).toList();
    final hasOther = ranked.length > top;
    final keys = [...shown, if (hasOther) other];
    final index = {for (final (i, s) in starts.indexed) s.millisecondsSinceEpoch: i};
    final values = [for (final _ in starts) List<double>.filled(keys.length, 0)];
    for (final b in agg.buckets) {
      // Snap to the local day: the server used today's UTC offset, which is
      // an hour off across a daylight-saving change.
      final col = b.start == null ? null : index[_day(b.start!.add(const Duration(hours: 12))).millisecondsSinceEpoch];
      if (col == null) continue;
      var k = keys.indexOf(b.key);
      if (k < 0) {
        if (!hasOther) continue;
        k = keys.length - 1;
      }
      values[col][k] += metric.of(b);
    }
    return UsageSeries(starts: starts, keys: keys, values: values);
  }
}

/// Local midnight of `d`.
DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// The bucket starts of [range] ending with the bucket holding [now]: local
/// days, or local Monday weeks, matching the server's buckets.
List<DateTime> bucketStarts(UsageRange range, DateTime now) {
  final today = _day(now);
  if (!range.weekly) {
    return [for (var i = range.days - 1; i >= 0; i--) DateTime(today.year, today.month, today.day - i)];
  }
  final monday = DateTime(today.year, today.month, today.day - (today.weekday - DateTime.monday));
  final weeks = range.days ~/ 7;
  return [for (var i = weeks - 1; i >= 0; i--) DateTime(monday.year, monday.month, monday.day - 7 * i)];
}

/// Readable names for usage kinds.
String usageKindLabel(String kind) => switch (kind) {
  'chat' => 'Chat',
  'gateway' => 'Code',
  'image' || 'images' => 'Images',
  'followups' => 'Suggestions',
  'decide' => 'Decisions',
  'summarise' => 'Long reads',
  final k when k.isEmpty => 'Other',
  final k => '${k[0].toUpperCase()}${k.substring(1)}',
};

String usageProviderLabel(String provider) => switch (provider) {
  'openrouter' => 'OpenRouter',
  'anthropic' => 'Anthropic',
  final p => p,
};

/// The query for one Usage screen view.
typedef UsageQuery = ({UsageRange range, UsageGroupBy by});

/// Query string for [q], starting at the first bucket and offset to local time.
String usagePath(UsageQuery q, DateTime now) {
  final from = bucketStarts(q.range, now).first;
  final params = {
    'group': q.range.group,
    'by': q.by.name,
    'from': '${from.millisecondsSinceEpoch ~/ 1000}',
    'tz_offset': '${now.timeZoneOffset.inSeconds}',
  };
  return 'v1/usage?${params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
}

final usageStatsProvider = FutureProvider.autoDispose.family<UsageAggregate, UsageQuery>((ref, q) async {
  final api = ref.read(apiClientProvider);
  final json = await api.getJson(usagePath(q, DateTime.now()), authenticated: !ref.read(appConfigProvider).devSkipAuth);
  return UsageAggregate.fromJson(json);
});
