import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../billing/billing_providers.dart' show formatMicros;
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../../skills/skills_providers.dart' show installedSkillsProvider, skillSettingsProvider;
import '../../usage/ui/usage_meter.dart' show ContextRing, UsageBreakdown;
import '../../usage/usage_totals.dart';
import '../code_providers.dart';
import '../code_settings_providers.dart';
import '../drivers/driver_registry.dart' show driverRegistryProvider;
import '../mcp_providers.dart';
import '../permissions_providers.dart';
import '../../settings/settings_registry.dart';
import '../../settings/ui/settings_modal.dart';

/// How much of the session header fits, from the width the page really has
/// (not the window: the sidebar and the panes take part of it).
enum TopBarTier {
  /// Everything.
  wide,

  /// The Changes button goes (the panes have it).
  narrow;

  static TopBarTier forWidth(double width) => width >= 820 ? wide : narrow;
}

/// The session's top bar: only what isn't in the composer, the session
/// settings popover. Model, effort, tier and mode live in the composer, and
/// the spend and its cap in the composer's usage meter.
class CodeTopBar extends ConsumerWidget {
  const CodeTopBar({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(codeSessionsProvider.select((all) => all.where((s) => s.id == sessionId).firstOrNull));
    if (info == null) return const SizedBox.shrink();

    // The session controller stops the run at the budget; this only says so.
    ref.listen(codeUsageProvider(sessionId), (before, after) {
      final budget = ref.read(codeSettingsProvider).budgets[sessionId];
      final was = before?.value?.chargedMicros ?? 0;
      final now = after.value?.chargedMicros ?? was;
      if (!crossedBudget(was, now, budget)) return;
      if (context.mounted) {
        showAdaptiveToast(context, 'Stopped: this session reached its ${formatMicros((budget! * 1e6).round())} budget');
      }
    });

    return _SettingsChip(projectId: info.projectId, sessionId: sessionId);
  }
}

/// The settings popover on the New session page, for the session about to
/// start (the Agent menu in the composer has the tier, model and cap).
class CodeDraftBar extends StatelessWidget {
  const CodeDraftBar({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context) => _SettingsChip(projectId: projectId);
}

/// A compact outlined chip that opens a popover.
class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.icon, this.semantics});

  final String label;
  final EveryIcon? icon;
  final String? semantics;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final fg = theme.textMuted;
    return Semantics(
      button: true,
      label: semantics ?? label,
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: theme.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              AdaptiveIcon(icon!, size: 13, color: fg),
              if (label.isNotEmpty) const SizedBox(width: 5),
            ],
            if (label.isNotEmpty)
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.type.callout.copyWith(color: fg, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            const SizedBox(width: 4),
            AdaptiveIcon(EveryIcon.chevronDown, size: 10, color: fg),
          ],
        ),
      ),
    );
  }
}

Widget _check(EveryTheme theme, bool on) =>
    on ? AdaptiveIcon(EveryIcon.check, size: 14, color: theme.accent) : const SizedBox(width: 14);

/// Shortcuts to the settings a session runs with.
class _SettingsChip extends ConsumerWidget {
  const _SettingsChip({required this.projectId, this.sessionId});

  final String projectId;

  /// Null on the New session page: the settings the next session starts with.
  final String? sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(codePermissionsProvider).rulesFor(projectId);
    final mcp = ref.watch(codeMcpServersProvider).serversFor(projectId).where((s) => s.active).length;
    final skillSettings = ref.watch(skillSettingsProvider);
    final skills = (ref.watch(installedSkillsProvider).value ?? const []).where(skillSettings.active).length;
    final prompts = ref.watch(codeSettingsProvider);
    final promptCount = [prompts.globalPrompt, prompts.promptFor(projectId)].where((p) => p.isNotEmpty).length;

    String plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

    return AnchoredPopover(
      width: 320,
      builder: (context, close) {
        void open(SettingsSection section, {String? anchor, SettingsScope? scope}) {
          close();
          showSettings(
            context,
            section: section,
            anchor: anchor,
            args: {if (scope != null) 'scope': scope.name, 'project': projectId, 'session': ?sessionId},
          );
        }

        // Scrolls: the rows outgrow the popover's height cap on short windows.
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PopoverHeader(sessionId == null ? 'New session settings' : 'Session settings'),
              PopoverRow(
                key: const ValueKey('top-bar.settings.permissions'),
                title: 'Permissions',
                subtitle: '${plural(rules.allow.length, 'allow rule')} · ${plural(rules.deny.length, 'deny rule')}',
                onTap: () => open(SettingsSection.code, anchor: 'permissions', scope: SettingsScope.project),
              ),
              PopoverRow(
                key: const ValueKey('top-bar.settings.mcp'),
                title: 'MCP servers',
                subtitle: '${plural(mcp, 'server')} on',
                onTap: () => open(SettingsSection.mcp),
              ),
              PopoverRow(
                key: const ValueKey('top-bar.settings.skills'),
                title: 'Skills',
                subtitle: '${plural(skills, 'skill')} on',
                onTap: () => open(SettingsSection.skills),
              ),
              PopoverRow(
                key: const ValueKey('top-bar.settings.prompt'),
                title: 'System prompt',
                subtitle: promptCount == 0 ? 'None' : 'Global and project · ${plural(promptCount, 'prompt')} set',
                onTap: () => open(SettingsSection.code, anchor: 'prompt', scope: SettingsScope.project),
              ),
              PopoverRow(
                key: const ValueKey('top-bar.settings.compact'),
                title: 'Auto-compact',
                subtitle: prompts.autoCompactPercent == 0
                    ? 'Off · EveryAI sessions'
                    : 'At ${prompts.autoCompactPercent}% of the context · EveryAI sessions',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AdaptiveIconButton(
                      icon: EveryIcon.chevronLeft,
                      tooltip: 'Earlier',
                      size: 13,
                      onPressed: () =>
                          ref.read(codeSettingsProvider.notifier).setAutoCompact(prompts.autoCompactPercent - 10),
                    ),
                    AdaptiveIconButton(
                      icon: EveryIcon.chevronRight,
                      tooltip: 'Later',
                      size: 13,
                      onPressed: () =>
                          ref.read(codeSettingsProvider.notifier).setAutoCompact(prompts.autoCompactPercent + 10),
                    ),
                  ],
                ),
              ),
              PopoverRow(
                key: const ValueKey('top-bar.settings.forks'),
                title: 'Forks',
                subtitle: prompts.forksIsolated
                    ? 'Each in its own worktree, merged back when done · EveryAI sessions'
                    : 'Share this session\'s folder · EveryAI sessions',
                trailing: _check(EveryTheme.of(context), prompts.forksIsolated),
                onTap: () => ref.read(codeSettingsProvider.notifier).setForksIsolated(!prompts.forksIsolated),
              ),
              PopoverRow(
                key: const ValueKey('top-bar.settings.research'),
                title: 'Research sites',
                subtitle: '${plural(prompts.researchSites.length, 'site')} · what Max and Ultra research may read',
                onTap: () async {
                  close();
                  final next = await showAdaptivePrompt(
                    context,
                    title: 'Research sites (comma separated; *.example.com for subdomains; empty for the defaults)',
                    confirmLabel: 'Save',
                    initialValue: prompts.researchSites.join(', '),
                  );
                  if (next != null) ref.read(codeSettingsProvider.notifier).setResearchSites(next.split(','));
                },
              ),
              PopoverRow(
                key: const ValueKey('top-bar.settings.json'),
                title: 'All Code settings…',
                subtitle: 'Global, project and session layers',
                onTap: () => open(
                  SettingsSection.code,
                  anchor: 'json',
                  scope: sessionId == null ? SettingsScope.project : SettingsScope.session,
                ),
              ),
            ],
          ),
        );
      },
      child: const _Chip(icon: EveryIcon.settings, label: '', semantics: 'Session settings'),
    );
  }
}

/// The composer's usage meter: tokens and spend (against the cap when one is
/// set) with the context ring; its popover has the breakdown and sets the cap.
class SessionMeter extends ConsumerWidget {
  const SessionMeter({super.key, required this.sessionId, required this.model});

  final String sessionId;
  final String model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final totals = ref.watch(codeUsageProvider(sessionId)).value ?? UsageTotals.zero;
    final budget = ref.watch(codeSettingsProvider.select((s) => s.budgets[sessionId]));
    final spec = ref.watch(modelCatalogProvider)[ModelId(model)];
    final window = spec?.contextLength ?? 0;
    final fill = budgetFill(totals.chargedMicros, budget);
    final spent = formatMicros(totals.chargedMicros);
    // An outside CLI on the user's own subscription: no spend to show.
    final onPlan = totals.onPlan && totals.spentMicros == 0;
    final label = [
      if (!totals.isEmpty) formatTokens(totals.totalTokens),
      if (onPlan) 'on your plan' else budget == null ? spent : '$spent / ${formatMicros((budget * 1e6).round())}',
    ].join(' · ');
    final color = fill == null || fill < 0.8
        ? theme.textMuted
        : fill >= 1
        ? theme.danger
        : theme.warning;
    final context0 = window <= 0 ? 0.0 : (totals.contextTokens / window).clamp(0, 1).toDouble();
    return AnchoredPopover(
      width: 280,
      builder: (context, close) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!totals.isEmpty) UsageBreakdown(totals: totals, contextWindow: window, modelName: spec?.name),
            // A session that changed leads: what each harness used, and how it was paid.
            if (ref.read(codeUsageProvider(sessionId).notifier).byHarness case final by when by.length > 1) ...[
              const PopoverHeader('By harness'),
              for (final MapEntry(key: harness, value: t) in by.entries)
                PopoverRow(
                  key: ValueKey('meter.harness.$harness'),
                  title: ref.read(driverRegistryProvider).resolve(harness)?.info.label ?? harness,
                  subtitle: harnessUsageLine(t),
                ),
            ],
            const PopoverHeader('Spending cap for this session'),
            for (final usd in [null, ...budgetPresets])
              PopoverRow(
                key: ValueKey('meter.budget.${usd ?? 'none'}'),
                title: usd == null ? 'No cap' : formatMicros((usd * 1e6).round()),
                subtitle: usd != null && totals.chargedMicros >= usd * 1e6 ? 'Already spent' : null,
                selected: usd == budget,
                trailing: _check(theme, usd == budget),
                onTap: () {
                  close();
                  ref.read(codeSettingsProvider.notifier).setBudget(sessionId, usd);
                },
              ),
            PopoverRow(
              key: const ValueKey('meter.settings'),
              title: 'Edit in Settings',
              leading: AdaptiveIcon(EveryIcon.settings, size: 14, color: theme.textMuted),
              onTap: () {
                close();
                showSettings(
                  context,
                  section: SettingsSection.code,
                  anchor: 'budget',
                  args: {'scope': SettingsScope.session.name, 'session': sessionId},
                );
              },
            ),
            const SizedBox(height: 5),
          ],
        ),
      ),
      child: Semantics(
        button: true,
        label: 'Usage $label${window > 0 ? ', context ${(context0 * 100).round()}% full' : ''}',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.type.caption.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              if (window > 0 && !totals.isEmpty) ...[const SizedBox(width: 6), ContextRing(fill: context0, size: 15)],
            ],
          ),
        ),
      ),
    );
  }
}

/// One harness's share of a session: "12.4K tokens · \$0.42 credits", or
/// "· on your plan" for an outside CLI on the user's subscription.
String harnessUsageLine(UsageTotals t) => [
  '${formatTokens(t.totalTokens)} tokens',
  if (t.chargedMicros > 0) '${formatMicros(t.chargedMicros)} credits',
  if (t.ownKeyMicros > 0) '${formatMicros(t.ownKeyMicros)} on your key',
  if (t.onPlan) 'on your plan',
].join(' · ');
