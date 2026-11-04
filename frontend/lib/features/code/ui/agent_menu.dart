import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../models/domain/model_catalog.dart';
import '../../billing/billing_providers.dart' show formatMicros;
import '../../models/models_providers.dart';
import '../agent_models.dart';
import '../code_providers.dart' show driverModelsProvider;
import '../code_settings_providers.dart' show codeSettingsProvider;
import '../domain/agent_menu.dart';
import '../domain/code_session.dart' show everyaiHarnessName;
import '../drivers/driver.dart';
import '../drivers/driver_policy.dart' show leadFix, offeredAsLead;
import '../drivers/driver_registry.dart';
import '../settings/agent_prompt.dart' show HarnessMode, HarnessTier;
import '../settings/code_settings.dart' show budgetPresets;
import '../../settings/byok_keys.dart' show byokUltraCapProvider, modelBillingProvider;
import '../ultra/ultra_access.dart' show ultraAccessProvider;

/// A harness that can lead a session, as the menu lists it: why it can't
/// now ([blocked], null when it can) and its version.
typedef LeadOption = ({DriverInfo info, String? blocked, String detail});

/// The leads the Harness page lists: EveryAI, [current], and the
/// harnesses installed here ([offeredAsLead]), each greyed with what is in
/// its way and the fix ([leadFix]). Missing ones are left out.
List<LeadOption> leadOptions(
  Iterable<DriverInfo> listed,
  Map<String, DriverStatus>? statuses,
  Set<String> ownClis, {
  required String current,
}) => [
  for (final info in listed)
    if (offeredAsLead(info, statuses?[info.id], current: current))
      (
        info: info,
        blocked: leadFix(info, statuses?[info.id], consented: ownClis.contains(info.id)),
        detail: statuses?[info.id]?.version ?? '',
      ),
];

/// The agent menu: the lead Harness, Harness mode, the tier bar (Efficient
/// → Ultra), Model (the user's own models that can call tools, or an
/// outside agent's own) and Effort, in one popover on every design language
/// (never a bottom sheet). [onChanged] gets the new model and effort ('' is
/// the model's default); an open session applies it live, and [onTier]
/// likewise.
class AgentMenu extends ConsumerWidget {
  const AgentMenu({
    super.key,
    required this.model,
    required this.effort,
    required this.onChanged,
    this.demo = false,
    this.bordered = false,
    this.tier = HarnessTier.efficient,
    this.onTier,
    this.harnessMode = HarnessMode.build,
    this.onHarnessMode,
    this.budget,
    this.onBudget,
    this.harness = everyaiHarnessName,
    this.onHarness,
    this.switchesLive = false,
  });

  /// The lead harness (a driver id).
  final String harness;

  /// Picks the lead; null shows it without a choice (a subagent, the demo).
  final ValueChanged<String>? onHarness;

  /// An open session: picking a harness closes the menu and moves the
  /// session to it (which may ask first).
  final bool switchesLive;

  /// Picks Build or Bug fix; null shows the mode without a choice.
  final ValueChanged<HarnessMode>? onHarnessMode;

  final String model;
  final String effort;
  final void Function(String model, String effort) onChanged;

  /// The scripted demo: no effort, Bug fix or phased tiers.
  final bool demo;
  final HarnessTier tier;

  /// Picks the tier; null hides the bar.
  final ValueChanged<HarnessTier>? onTier;
  final HarnessMode harnessMode;

  /// The spending cap, on the New session page (a session sets it from the
  /// usage meter instead); null [onBudget] hides the row.
  final double? budget;
  final ValueChanged<double?>? onBudget;

  /// A pill outline, for the page header.
  final bool bordered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final catalog = ref.watch(agentCatalogProvider);
    final specs = ref.watch(modelCatalogProvider);
    final library = ref.watch(libraryProvider).value ?? const <ModelSpec>[];
    final groups = libraryMenuGroups(library, catalog, current: model, nameOf: (id) => specs[ModelId(id)]?.name);
    final current = [for (final (_, ms) in groups) ...ms].where((m) => m.model == model).firstOrNull;
    // Max includes Ultra; on the user's own key it runs under their spend cap.
    final ownKey = ref.watch(modelBillingProvider).ownKey(ModelId(model));
    final ultraAllowed = (ref.watch(ultraAccessProvider).value ?? false) || ownKey;
    final registry = ref.watch(driverRegistryProvider);
    final lead = registry.resolve(harness)?.info ?? DriverInfo(id: harness, label: harness);
    final outside = harness != everyaiHarnessName;
    // EveryAI and the harnesses installed here, with what is in their way and
    // its fix, when the lead can be picked; else only its own.
    final List<LeadOption> leads;
    if (onHarness == null) {
      leads = [(info: lead, blocked: null, detail: '')];
    } else {
      final statuses = ref.watch(driverStatusesProvider).value;
      final own = ref.watch(codeSettingsProvider.select((s) => s.ownClis));
      leads = leadOptions([for (final d in registry.listed) d.info], statuses, own, current: harness);
    }
    final driverModels = outside ? ref.watch(driverModelsProvider(harness)).value ?? const <DriverModel>[] : null;
    final label = outside
        ? [
            lead.label,
            agentMenuLabel(
              driverModels?.where((m) => m.id == model).firstOrNull?.label ?? (model.isEmpty ? 'Default model' : model),
              effort,
            ),
          ].join(' · ')
        : [
            agentMenuLabel(current?.name ?? model.split('/').last, effort),
            if (onTier != null) tier.label,
            if (harnessMode == HarnessMode.bugFix) 'Bug fix',
          ].join(' · ');
    return AnchoredPopover(
      width: 320,
      builder: (context, close) => AgentMenuPanel(
        groups: groups,
        model: model,
        effort: effort,
        demo: demo,
        reasons: specs[ModelId(model)]?.reasoning ?? true,
        onChanged: onChanged,
        close: close,
        tier: tier,
        onTier: onTier,
        harnessMode: harnessMode,
        onHarnessMode: onHarnessMode,
        ultraAllowed: ultraAllowed,
        keyCap: ownKey ? ref.watch(byokUltraCapProvider) : null,
        budget: budget,
        onBudget: onBudget,
        leads: leads,
        harness: harness,
        onHarness: onHarness == null || !switchesLive
            ? onHarness
            : (h) {
                close();
                onHarness!(h);
              },
        onCheckAgain: onHarness == null
            ? null
            : () => unawaited(ref.read(driverStatusesProvider.notifier).refresh(reloadShell: true)),
        driverModels: driverModels,
      ),
      child: Semantics(
        button: true,
        label: 'Agent model: $label',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: bordered
              ? BoxDecoration(
                  border: Border.all(color: theme.border),
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.callout.tint(theme.textMuted),
                ),
              ),
              const SizedBox(width: 4),
              AdaptiveIcon(EveryIcon.chevronDown, size: 11, color: theme.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

enum _Page { root, harness, model, effort, budget }

/// The popover's content: a root list whose rows open their submenu in place,
/// with a back row to return.
class AgentMenuPanel extends StatefulWidget {
  const AgentMenuPanel({
    super.key,
    required this.groups,
    required this.model,
    required this.effort,
    this.demo = false,
    required this.onChanged,
    required this.close,
    this.reasons = true,
    this.tier = HarnessTier.efficient,
    this.onTier,
    this.harnessMode = HarnessMode.build,
    this.onHarnessMode,
    this.ultraAllowed = false,
    this.keyCap,
    this.budget,
    this.onBudget,
    this.leads = const [],
    this.harness = everyaiHarnessName,
    this.onHarness,
    this.onCheckAgain,
    this.driverModels,
  });

  /// The harnesses the Harness row lists: no row when there are none, or
  /// only one to pick from.
  final List<LeadOption> leads;
  final String harness;
  final ValueChanged<String>? onHarness;

  /// Looks for harnesses again (the user installed one); a row at the end
  /// of the Harness page.
  final VoidCallback? onCheckAgain;

  /// An outside lead's own models (its Model and Effort pages list these);
  /// null for the EveryAI harness, whose models are [groups].
  final List<DriverModel>? driverModels;

  final HarnessTier tier;
  final ValueChanged<HarnessTier>? onTier;
  final HarnessMode harnessMode;
  final ValueChanged<HarnessMode>? onHarnessMode;

  /// The plan allows Ultra (the Max plan).
  final bool ultraAllowed;

  /// The own-key Ultra cap (USD) when the model bills to the user's key.
  final double? keyCap;
  final double? budget;
  final ValueChanged<double?>? onBudget;

  final List<(ModelProvider, List<AgentMenuModel>)> groups;
  final String model;
  final String effort;
  final bool demo;

  /// Whether the current model takes an effort at all.
  final bool reasons;
  final void Function(String model, String effort) onChanged;
  final VoidCallback close;

  @override
  State<AgentMenuPanel> createState() => _AgentMenuPanelState();
}

class _AgentMenuPanelState extends State<AgentMenuPanel> {
  var _page = _Page.root;

  // Reflects a pick at once, before the parent rebuilds with it.
  late String _model = widget.model;
  late String _effort = widget.effort;
  late HarnessTier _tier = widget.tier;
  late double? _budget = widget.budget;
  late HarnessMode _mode = widget.harnessMode;
  late String _harness = widget.harness;

  @override
  void didUpdateWidget(AgentMenuPanel old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) _model = widget.model;
    if (old.effort != widget.effort) _effort = widget.effort;
    if (old.tier != widget.tier) _tier = widget.tier;
    if (old.budget != widget.budget) _budget = widget.budget;
    if (old.harnessMode != widget.harnessMode) _mode = widget.harnessMode;
    if (old.harness != widget.harness) _harness = widget.harness;
  }

  /// The lead is an outside agent: its own models, and no tiers or Bug fix yet.
  bool get _outside => widget.driverModels != null;

  DriverModel? get _driverModel => widget.driverModels?.where((m) => m.id == _model).firstOrNull;

  /// Why [t] can't be picked, or null.
  String? _blocked(HarnessTier t) => t.phased && widget.demo
      ? 'Not in the demo'
      : t == HarnessTier.ultra && !widget.ultraAllowed
      ? 'Max plan or your own key'
      : null;

  AgentMenuModel? get _current =>
      [for (final (_, ms) in widget.groups) ...ms].where((m) => m.model == _model).firstOrNull;

  void _pick(String model, String effort) {
    setState(() {
      _model = model;
      _effort = effort;
      _page = _Page.root;
    });
    widget.onChanged(model, effort);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget check(bool on) => on ? AdaptiveIcon(EveryIcon.check, size: 14, color: theme.accent) : const SizedBox();
    final more = AdaptiveIcon(EveryIcon.chevronRight, size: 12, color: theme.textMuted);
    final current = _current;

    final lead = widget.leads.where((l) => l.info.id == _harness).firstOrNull;
    final efforts = _outside ? ['', ...?_driverModel?.efforts] : agentMenuEfforts;
    final reasons = _outside ? efforts.length > 1 : widget.reasons;
    final rows = switch (_page) {
      _Page.root => [
        const PopoverHeader('Agent'),
        if (widget.leads.length > 1 || (widget.leads.isNotEmpty && widget.onHarness == null))
          PopoverRow(
            key: const ValueKey('agent-menu.harness'),
            title: 'Harness',
            subtitle: [
              lead?.info.label ?? _harness,
              if (widget.onHarness == null) 'Switching comes later' else ?lead?.blocked,
            ].join(' · '),
            trailing: widget.onHarness == null ? null : more,
            onTap: widget.onHarness == null ? null : () => setState(() => _page = _Page.harness),
          ),
        PopoverRow(
          key: const ValueKey('agent-menu.harness-mode'),
          title: 'Harness mode',
          subtitle: _outside
              ? 'Bug fix comes later for outside agents'
              : _mode == HarnessMode.bugFix
              ? 'Reproduce, triage, research, plan, fix, verify'
              : widget.demo
              ? 'Bug fix isn\'t in the demo'
              : 'Build things, or switch to fix a bug, issue or PR',
          trailing: _ModeSwitch(
            mode: _outside ? HarnessMode.build : _mode,
            onPick: widget.onHarnessMode == null || _outside
                ? null
                : (m) {
                    if (m == HarnessMode.bugFix && widget.demo) return;
                    setState(() => _mode = m);
                    widget.onHarnessMode!(m);
                  },
          ),
        ),
        if (widget.onTier != null && !_outside)
          _TierBar(
            tier: _tier,
            blocked: _blocked,
            onTier: (t) {
              setState(() => _tier = t);
              widget.onTier!(t);
            },
          ),
        PopoverRow(
          key: const ValueKey('agent-menu.model'),
          title: 'Model',
          subtitle: _outside
              ? _driverModel?.label ?? (_model.isEmpty ? 'Its default model' : _model)
              : [
                  current?.name ?? _model.split('/').last,
                  if (current?.tierHint case final h? when h.isNotEmpty) h,
                ].join(' · '),
          trailing: more,
          onTap: () => setState(() => _page = _Page.model),
        ),
        PopoverRow(
          key: const ValueKey('agent-menu.effort'),
          title: 'Effort',
          subtitle: reasons ? effortLabel(_effort) : 'Not used by this model',
          trailing: more,
          onTap: widget.demo ? null : () => setState(() => _page = _Page.effort),
        ),
        if (widget.onBudget != null)
          PopoverRow(
            key: const ValueKey('agent-menu.budget'),
            title: 'Spending cap',
            subtitle: _budget != null
                ? formatMicros((_budget! * 1e6).round())
                : _tier == HarnessTier.ultra && widget.keyCap != null
                ? 'Your key\'s Ultra cap, ${formatMicros((widget.keyCap! * 1e6).round())}'
                : 'No cap',
            trailing: more,
            onTap: () => setState(() => _page = _Page.budget),
          ),
      ],
      _Page.budget => [
        _Back('Spending cap', onTap: () => setState(() => _page = _Page.root)),
        for (final usd in [null, ...budgetPresets])
          PopoverRow(
            key: ValueKey('agent-menu.budget.${usd ?? 'none'}'),
            title: usd == null ? 'No cap' : formatMicros((usd * 1e6).round()),
            selected: usd == _budget,
            trailing: check(usd == _budget),
            onTap: () {
              setState(() {
                _budget = usd;
                _page = _Page.root;
              });
              widget.onBudget!(usd);
            },
          ),
      ],
      _Page.harness => [
        _Back('Harness', onTap: () => setState(() => _page = _Page.root)),
        for (final l in widget.leads)
          PopoverRow(
            key: ValueKey('agent-menu.harness.${l.info.id}'),
            title: l.info.label,
            subtitle: l.blocked ?? (l.detail.isEmpty ? null : l.detail),
            selected: l.info.id == _harness,
            trailing: check(l.info.id == _harness),
            onTap: l.blocked != null
                ? null
                : l.info.id == _harness
                ? () => setState(() => _page = _Page.root)
                : () {
                    setState(() {
                      _harness = l.info.id;
                      _page = _Page.root;
                    });
                    widget.onHarness!(l.info.id);
                  },
          ),
        if (widget.onCheckAgain case final again?)
          PopoverRow(
            key: const ValueKey('agent-menu.harness.check-again'),
            title: 'Check again',
            subtitle: 'Looks for harnesses you installed',
            onTap: () {
              setState(() => _page = _Page.root);
              again();
            },
          ),
      ],
      _Page.model when _outside => [
        _Back('Model', onTap: () => setState(() => _page = _Page.root)),
        if (widget.driverModels!.isEmpty)
          PopoverRow(
            key: const ValueKey('agent-menu.model.default'),
            title: 'Its default model',
            selected: true,
            trailing: check(true),
            onTap: () => setState(() => _page = _Page.root),
          ),
        for (final m in widget.driverModels!)
          PopoverRow(
            key: ValueKey('agent-menu.model.${m.id}'),
            title: m.label,
            subtitle: m.isDefault ? 'default' : null,
            selected: m.id == _model,
            trailing: check(m.id == _model),
            onTap: m.id == _model
                ? () => setState(() => _page = _Page.root)
                : () => _pick(m.id, m.efforts.contains(_effort) ? _effort : ''),
          ),
      ],
      _Page.model => [
        _Back('Model', onTap: () => setState(() => _page = _Page.root)),
        for (final (vendor, models) in widget.groups) ...[
          PopoverHeader(vendor.company),
          for (final m in models)
            PopoverRow(
              key: ValueKey('agent-menu.model.${m.model}'),
              title: m.name,
              subtitle: m.tierHint.isEmpty ? null : m.tierHint,
              selected: m.model == _model,
              trailing: check(m.model == _model),
              onTap: m.model == _model
                  ? () => setState(() => _page = _Page.root)
                  : () => _pick(m.model, effortForModel(m, _effort)),
            ),
        ],
      ],
      _Page.effort => [
        _Back('Effort', onTap: () => setState(() => _page = _Page.root)),
        for (final e in efforts)
          PopoverRow(
            key: ValueKey('agent-menu.effort.${e.isEmpty ? 'default' : e}'),
            title: effortLabel(e),
            subtitle: [
              effortBlurb(e),
              if (!_outside && current != null && e.isNotEmpty && current.efforts.contains(e))
                e == current.recommendedEffort ? 'recommended' : 'tested',
            ].where((s) => s.isNotEmpty).join(' · '),
            selected: e == _effort,
            trailing: check(e == _effort),
            onTap: !reasons
                ? null
                : e == _effort
                ? () => setState(() => _page = _Page.root)
                : () => _pick(_model, e),
          ),
      ],
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
      ),
    );
  }
}

class _Back extends StatelessWidget {
  const _Back(this.title, {required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return PopoverRow(
      key: const ValueKey('agent-menu.back'),
      title: title,
      leading: AdaptiveIcon(EveryIcon.chevronLeft, size: 12, color: theme.textMuted),
      onTap: onTap,
    );
  }
}

/// Build or Bug fix, as a two-way switch.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, this.onPick});

  final HarnessMode mode;
  final ValueChanged<HarnessMode>? onPick;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget segment(HarnessMode m) {
      final on = m == mode;
      return GestureDetector(
        key: ValueKey('agent-menu.harness-mode.${m.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: onPick == null || on ? null : () => onPick!(m),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: on ? theme.accent.withValues(alpha: 0.18) : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(m.label, style: theme.type.caption.tint(on ? theme.accent : theme.textMuted)),
        ),
      );
    }

    return Semantics(
      label: 'Harness mode: ${mode.label}',
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          border: Border.all(color: theme.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [for (final m in HarnessMode.values) segment(m)]),
      ),
    );
  }
}

/// The progressive tier bar: Efficient · Thorough · Max · Ultra, filled up
/// to the pick, with what the pick does underneath.
class _TierBar extends StatelessWidget {
  const _TierBar({required this.tier, required this.blocked, required this.onTier});

  final HarnessTier tier;
  final String? Function(HarnessTier) blocked;
  final ValueChanged<HarnessTier> onTier;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final tiers = HarnessTier.offered;
    final at = tiers.indexOf(tier);
    final note = blocked(tier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Tier', style: theme.type.callout),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final (i, t) in tiers.indexed)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: t == tier,
                    label: 'Tier ${t.label}${blocked(t) == null ? '' : ', ${blocked(t)}'}',
                    child: GestureDetector(
                      key: ValueKey('agent-menu.tier.${t.name}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: blocked(t) == null && t != tier ? () => onTier(t) : null,
                      child: Column(
                        children: [
                          Container(
                            height: 6,
                            margin: EdgeInsets.only(right: i == tiers.length - 1 ? 0 : 3),
                            decoration: BoxDecoration(
                              color: i <= at
                                  ? theme.accent
                                  : blocked(t) == null
                                  ? theme.border
                                  : theme.border.withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            t.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.caption.tint(
                              t == tier
                                  ? theme.accent
                                  : blocked(t) == null
                                  ? theme.textMuted
                                  : theme.textMuted.withValues(alpha: 0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            note == null ? tier.description : '${tier.description} · $note',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ],
      ),
    );
  }
}
