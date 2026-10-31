import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../../usage/usage_totals.dart';
import '../../settings/settings_registry.dart';
import '../../settings/ui/settings_modal.dart';
import '../billing_providers.dart';
import 'plans_preview.dart';

/// Plan, monthly included usage, wallet balance, top-ups and recent usage.
class BillingBody extends ConsumerWidget {
  const BillingBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final billing = ref.watch(billingProvider);
    final ctl = ref.read(billingProvider.notifier);

    Future<void> run(Future<String> Function() action) async {
      final message = await action();
      if (context.mounted) showAdaptiveToast(context, message);
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
      children: [
        if (billing case AsyncData(value: final b)) ...[
          _Card(
            children: [
              Row(
                children: [
                  Expanded(child: Text('${b.plan.name} plan', style: theme.type.title.tint(theme.text))),
                  Text(
                    b.plan.priceCents == 0 ? 'Free' : '\$${b.plan.priceCents ~/ 100}/month',
                    style: theme.type.headline.tint(theme.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(b.plan.blurb, style: theme.type.callout.tint(theme.textMuted)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('Included usage', style: theme.type.headline.tint(theme.text)),
                  const Spacer(),
                  Text(
                    '${formatMicros(b.usedMicros)} of ${formatMicros(b.includedMicros)}',
                    style: theme.type.callout.tint(theme.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _Bar(fraction: b.quotaUsedFraction),
              const SizedBox(height: 6),
              Text(
                'Renews ${_date(b.periodEnd)}. Free models never count against it.',
                style: theme.type.caption.tint(theme.textMuted),
              ),
            ],
          ),
          SettingsAnchor(
            section: SettingsSection.billing,
            id: 'wallet',
            child: _Card(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Wallet', style: theme.type.headline.tint(theme.text)),
                          Text(
                            'Used after the included usage runs out.',
                            style: theme.type.caption.tint(theme.textMuted),
                          ),
                        ],
                      ),
                    ),
                    Text(formatMicros(b.walletMicros), style: theme.type.title.tint(theme.text)),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final dollars in const [10, 25, 50])
                      AdaptiveButton(
                        label: 'Add \$$dollars',
                        emphasis: ButtonEmphasis.secondary,
                        onPressed: () => run(() => ctl.topUp(dollars * 100)),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SettingsAnchor(section: SettingsSection.billing, id: 'plans', child: PlansPreview()),
          const AdaptiveSectionHeader('Plans on this server'),
          for (final p in b.plans)
            AdaptiveListTile(
              title: Text(p.priceCents == 0 ? p.name : '${p.name} · \$${p.priceCents ~/ 100}/month'),
              subtitle: Text(p.blurb),
              trailing: p.id == b.plan.id
                  ? Text('Current', style: theme.type.headline.tint(theme.textMuted))
                  : AdaptiveButton(
                      label: p.priceCents > b.plan.priceCents ? 'Upgrade' : 'Switch',
                      emphasis: p.priceCents > b.plan.priceCents ? ButtonEmphasis.primary : ButtonEmphasis.secondary,
                      onPressed: () => run(() => ctl.choosePlan(p.id)),
                    ),
            ),
          const AdaptiveSectionHeader('This month'),
          AdaptiveListTile(
            title: Text('${formatTokens(b.monthTokens)} input tokens'),
            subtitle: Text(
              b.monthCachedTokens == 0
                  ? 'Repeated context is cached automatically to cut costs.'
                  : '${(b.cacheShare * 100).round()}% served from the prompt cache at a fraction of the price.',
            ),
          ),
          if (b.recent.isNotEmpty) const AdaptiveSectionHeader('Recent usage'),
          for (final r in b.recent) _UsageTile(r),
        ] else ...[
          if (billing case AsyncError(:final error))
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Text('Couldn’t load your plan.', style: theme.type.headline.tint(theme.text)),
                  const SizedBox(height: 4),
                  Text('$error', style: theme.type.callout.tint(theme.textMuted), textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  AdaptiveButton(label: 'Try again', onPressed: ctl.reload),
                ],
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: AdaptiveProgress()),
            ),
          const SettingsAnchor(section: SettingsSection.billing, id: 'plans', child: PlansPreview()),
        ],
      ],
    );
  }

  static String _date(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}';
  }
}

class _UsageTile extends ConsumerWidget {
  const _UsageTile(this.row);

  final UsageRow row;

  static const _kinds = {
    'chat': 'Chat',
    'gateway': 'Code',
    'image': 'Image',
    'followups': 'Suggestions',
    'search': 'Search',
    'research': 'Researchers',
    'decide': 'Decisions',
    'summarise': 'Long reads',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final model = ref.watch(modelCatalogProvider).resolve(ModelId(row.model));
    final time = '${row.at.hour.toString().padLeft(2, '0')}:${row.at.minute.toString().padLeft(2, '0')}';
    return AdaptiveListTile(
      dense: true,
      title: Text('${_kinds[row.kind] ?? row.kind} · ${model.name}'),
      subtitle: Text(
        [
          '${BillingBody._date(row.at)} $time',
          '${formatTokens(row.promptTokens)} in / ${formatTokens(row.completionTokens)} out',
          if (row.cachedTokens > 0) '${formatTokens(row.cachedTokens)} cached',
        ].join(' · '),
      ),
      trailing: Text(
        row.chargedMicros == 0 ? 'Free' : formatMicros(row.chargedMicros),
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

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return ClipRRect(
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
    );
  }
}
