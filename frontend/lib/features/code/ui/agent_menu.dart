import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../../core/ui/segmented.dart';
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
import '../settings/agent_prompt.dart' show HarnessTier;
import '../settings/code_settings.dart' show budgetPresets;
import '../workflows/workflow_library.dart';
import '../workflows/workflow_picker.dart';

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
        blocked: leadFix(info, statuses?[info.id], consented: ownClis.contains(info.consentId)),
        detail: statuses?[info.id]?.version ?? '',
      ),
];

/// The agent menu: the lead Harness, the Workflow (Max, Ultra, Bug fix,
/// Security review and the project's own), the EveryAI effort level
/// (Efficient or Thorough), Model (the user's own models that can call
/// tools, or an outside agent's own) and Effort, in one popover on every
/// design language (never a bottom sheet). [onChanged] gets the new model and
/// effort ('' is the model's default); an open session applies it live, and
/// [onLevel] likewise.
class AgentMenu extends ConsumerWidget {
  const AgentMenu({
    super.key,
    required this.model,
    required this.effort,
    required this.onChanged,
    this.demo = false,
    this.bordered = false,
    this.level = HarnessTier.efficient,
    this.onLevel,
    this.workflow,
    this.onWorkflow,
    this.workflowBusy,
    this.projectDir = '',
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

  final String model;
  final String effort;
  final void Function(String model, String effort) onChanged;

  /// The scripted demo: no effort or workflows.
  final bool demo;

  /// How hard the EveryAI harness works (Efficient or Thorough).
  final HarnessTier level;

  /// Picks the level; null hides the row (it is shown for EveryAI leads only).
  final ValueChanged<HarnessTier>? onLevel;

  /// The workflow armed or on, or null for none.
  final WorkflowPick? workflow;

  /// Picks a workflow (null: none); null hides the row.
  final ValueChanged<WorkflowPick?>? onWorkflow;

  /// Why no script workflow can be picked now (one is running), or null.
  final String? workflowBusy;

  /// The project whose own workflows the Workflow page lists.
  final String projectDir;

  /// The spending cap, on the New session page (a session sets it from the
  /// usage meter instead); null [onBudget] hides the row.
  final double? budget;
  final ValueChanged<double?>? onBudget;

  /// A pill outline, for the page header.
  final bool bordered;

  /// What the menu shows, worked out once for the trigger and its panel.
  _Resolved _resolve(WidgetRef ref) {
    final catalog = ref.watch(agentCatalogProvider);
    final specs = ref.watch(modelCatalogProvider);
    final library = ref.watch(libraryProvider).value ?? const <ModelSpec>[];
    final groups = libraryMenuGroups(library, catalog, current: model, nameOf: (id) => specs[ModelId(id)]?.name);
    final current = [for (final (_, ms) in groups) ...ms].where((m) => m.model == model).firstOrNull;
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
    final workflows = onWorkflow == null || demo || projectDir.isEmpty
        ? null
        : ref.watch(workflowChoicesProvider(projectDir)).value;
    final driverModel = driverModels?.where((m) => m.id == model).firstOrNull;
    return (
      groups: groups,
      current: current,
      lead: lead,
      outside: outside,
      leads: leads,
      driverModels: driverModels,
      workflows: workflows,
      modelName: outside
          ? driverModel?.label ?? (model.isEmpty ? 'Default model' : model)
          : current?.name ?? model.split('/').last,
      reasons: outside ? driverModel?.efforts.isNotEmpty ?? false : specs[ModelId(model)]?.reasoning ?? true,
    );
  }

  /// The parts of the composer's settings line, in order: model, effort
  /// (when the model or the EveryAI level takes one), the workflow while
  /// one is picked, and the spending cap on the New session page.
  List<AgentMenuPage> lineParts(WidgetRef ref) {
    final r = _resolve(ref);
    return [
      AgentMenuPage.model,
      if (!demo && (r.reasons || (!r.outside && onLevel != null))) AgentMenuPage.effort,
      if (workflow != null && onWorkflow != null) AgentMenuPage.workflow,
      if (onBudget != null) AgentMenuPage.budget,
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => AgentMenuPart(menu: this, page: AgentMenuPage.root);
}

typedef _Resolved = ({
  List<(ModelProvider, List<AgentMenuModel>)> groups,
  AgentMenuModel? current,
  DriverInfo lead,
  bool outside,
  List<LeadOption> leads,
  List<DriverModel>? driverModels,
  WorkflowLibrary? workflows,
  String modelName,
  bool reasons,
});

/// One part of an [AgentMenu] as its own trigger: it opens the menu at
/// [page] (no way back to the others; a pick closes it). The composer's
/// strip has the harness and workflow parts, its settings line the rest.
/// [AgentMenuPage.root] is the whole menu behind one joined label.
/// [trigger] draws the label (null: the menu's own look); [enabled] is false
/// when the part can't be changed here (a subagent's harness).
class AgentMenuPart extends ConsumerWidget {
  const AgentMenuPart({super.key, required this.menu, required this.page, this.trigger});

  final AgentMenu menu;
  final AgentMenuPage page;
  final Widget Function(BuildContext context, String label, bool enabled)? trigger;

  /// What the part says, as its label reads.
  static String _labelOf(AgentMenu m, AgentMenuPage page, _Resolved r) => switch (page) {
    AgentMenuPage.harness => r.lead.label,
    AgentMenuPage.workflow => m.workflow?.title ?? 'Workflows',
    AgentMenuPage.model => r.modelName,
    AgentMenuPage.effort => [
      if (r.reasons) m.effort.isEmpty ? 'Default effort' : effortLabel(m.effort),
      if (!r.outside && m.onLevel != null) m.level.label,
    ].join(' · '),
    AgentMenuPage.budget => m.budget == null ? 'No cap' : '${formatMicros((m.budget! * 1e6).round())} cap',
    AgentMenuPage.root => [
      if (r.outside) ...[
        r.lead.label,
        agentMenuLabel(r.modelName, m.effort),
      ] else ...[
        agentMenuLabel(r.modelName, m.effort),
        if (m.onLevel != null) m.level.label,
      ],
      ?m.workflow?.title,
    ].join(' · '),
  };

  static const _names = {
    AgentMenuPage.root: 'Agent model',
    AgentMenuPage.harness: 'Harness',
    AgentMenuPage.workflow: 'Workflow',
    AgentMenuPage.model: 'Model',
    AgentMenuPage.effort: 'Effort',
    AgentMenuPage.budget: 'Spending cap',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final m = menu;
    final r = m._resolve(ref);
    final label = _labelOf(m, page, r);
    final enabled = page != AgentMenuPage.harness || m.onHarness != null;
    final look =
        trigger?.call(context, label, enabled) ??
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: m.bordered
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
        );
    final semantic = Semantics(
      button: enabled,
      label: '${_names[page]}: $label',
      tooltip: enabled ? null : 'Switching comes later',
      child: look,
    );
    if (!enabled) return semantic;
    final direct = page != AgentMenuPage.root;
    return AnchoredPopover(
      width: 320,
      builder: (context, close) => AgentMenuPanel(
        initialPage: page,
        groups: r.groups,
        model: m.model,
        effort: m.effort,
        demo: m.demo,
        reasons: r.outside ? true : r.reasons,
        onChanged: m.onChanged,
        close: close,
        level: m.level,
        onLevel: r.outside ? null : m.onLevel,
        workflow: m.workflow,
        onWorkflow: m.onWorkflow,
        workflowBusy: m.workflowBusy,
        workflows: r.workflows,
        onTrust: (w) => ref.read(workflowTrustProvider.notifier).set(w, true),
        budget: m.budget,
        onBudget: m.onBudget,
        leads: r.leads,
        harness: m.harness,
        // Opened at a page, a pick closes the panel anyway.
        onHarness: m.onHarness == null || !m.switchesLive || direct
            ? m.onHarness
            : (h) {
                close();
                m.onHarness!(h);
              },
        onCheckAgain: m.onHarness == null
            ? null
            : () => unawaited(ref.read(driverStatusesProvider.notifier).refresh(reloadShell: true)),
        driverModels: r.driverModels,
      ),
      child: semantic,
    );
  }
}

/// The agent menu's pages: [root] lists the others.
enum AgentMenuPage { root, harness, workflow, model, effort, budget }

/// The popover's content: a root list whose rows open their submenu in place,
/// with a back row to return. Opened at another [initialPage] (one part of
/// the menu, from the composer), it has no back row and a pick closes it.
class AgentMenuPanel extends StatefulWidget {
  const AgentMenuPanel({
    super.key,
    this.initialPage = AgentMenuPage.root,
    required this.groups,
    required this.model,
    required this.effort,
    this.demo = false,
    required this.onChanged,
    required this.close,
    this.reasons = true,
    this.level = HarnessTier.efficient,
    this.onLevel,
    this.workflow,
    this.onWorkflow,
    this.workflowBusy,
    this.workflows,
    this.onTrust,
    this.budget,
    this.onBudget,
    this.leads = const [],
    this.harness = everyaiHarnessName,
    this.onHarness,
    this.onCheckAgain,
    this.driverModels,
  });

  final AgentMenuPage initialPage;

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

  final HarnessTier level;
  final ValueChanged<HarnessTier>? onLevel;
  final WorkflowPick? workflow;
  final ValueChanged<WorkflowPick?>? onWorkflow;

  /// Why the script workflows can't be picked now, shown on their rows; null when they can.
  final String? workflowBusy;

  /// The project workflows the Workflow page lists (null while they load,
  /// and in the demo).
  final WorkflowLibrary? workflows;

  /// Trusts a project workflow the user reviewed.
  final ValueChanged<WorkflowEntry>? onTrust;
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
  late var _page = widget.initialPage;

  // Reflects a pick at once, before the parent rebuilds with it.
  late String _model = widget.model;
  late String _effort = widget.effort;
  late HarnessTier _level = widget.level;
  late WorkflowPick? _workflow = widget.workflow;
  late double? _budget = widget.budget;
  late String _harness = widget.harness;

  @override
  void didUpdateWidget(AgentMenuPanel old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) _model = widget.model;
    if (old.effort != widget.effort) _effort = widget.effort;
    if (old.level != widget.level) _level = widget.level;
    if (old.workflow != widget.workflow) _workflow = widget.workflow;
    if (old.budget != widget.budget) _budget = widget.budget;
    if (old.harness != widget.harness) _harness = widget.harness;
  }

  /// Opened at one page: no back row, and a pick closes the panel.
  bool get _direct => widget.initialPage != AgentMenuPage.root;

  /// After a pick (or a tap on the current row): back to the root, or closed.
  void _home() {
    if (_direct) {
      widget.close();
    } else {
      setState(() => _page = AgentMenuPage.root);
    }
  }

  Widget _top(String title) => _direct ? PopoverHeader(title) : _Back(title, onTap: _home);

  /// The lead is an outside agent: its own models, and no effort level.
  bool get _outside => widget.driverModels != null;

  DriverModel? get _driverModel => widget.driverModels?.where((m) => m.id == _model).firstOrNull;

  void _pickWorkflow(WorkflowPick? w) {
    setState(() => _workflow = w);
    _home();
    widget.onWorkflow!(w);
  }

  /// Shows a project workflow's whole file; trusting it binds its digest and picks it.
  Future<void> _review(WorkflowEntry w) async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Trust ${w.title}?',
      message:
          'This workflow came with the project, in ${w.path ?? w.id}. It starts agents that follow its '
          'instructions.${w.description.isEmpty ? '' : '\n\n${w.description}'}',
      // The whole file: trust covers all of it.
      detail: w.source,
      confirmLabel: 'Trust and pick',
    );
    if (!ok || !mounted) return;
    widget.onTrust?.call(w);
    _pickWorkflow(WorkflowPick.script(w));
  }

  AgentMenuModel? get _current =>
      [for (final (_, ms) in widget.groups) ...ms].where((m) => m.model == _model).firstOrNull;

  void _pick(String model, String effort) {
    setState(() {
      _model = model;
      _effort = effort;
    });
    _home();
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
      AgentMenuPage.root => [
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
            onTap: widget.onHarness == null ? null : () => setState(() => _page = AgentMenuPage.harness),
          )
        // Only EveryAI is found: no Harness page to open, but the user may
        // be about to install one, so the check stays in reach.
        else if (widget.onHarness != null && widget.onCheckAgain != null)
          PopoverRow(
            key: const ValueKey('agent-menu.find-harnesses'),
            title: 'Find installed harnesses',
            subtitle: 'Claude Code, Codex, OpenCode and others',
            onTap: widget.onCheckAgain,
          ),
        if (widget.onWorkflow != null)
          PopoverRow(
            key: const ValueKey('agent-menu.workflow'),
            title: 'Workflow',
            subtitle: _workflow?.title ?? (widget.demo ? 'Not in the demo' : 'None'),
            trailing: more,
            onTap: () => setState(() => _page = AgentMenuPage.workflow),
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
          onTap: () => setState(() => _page = AgentMenuPage.model),
        ),
        PopoverRow(
          key: const ValueKey('agent-menu.effort'),
          title: 'Effort',
          subtitle: [
            reasons ? effortLabel(_effort) : 'Not used by this model',
            if (widget.onLevel != null && !_outside) _level.label,
          ].join(' · '),
          trailing: more,
          onTap: widget.demo ? null : () => setState(() => _page = AgentMenuPage.effort),
        ),
        if (widget.onBudget != null)
          PopoverRow(
            key: const ValueKey('agent-menu.budget'),
            title: 'Spending cap',
            subtitle: _budget != null ? formatMicros((_budget! * 1e6).round()) : 'No cap',
            trailing: more,
            onTap: () => setState(() => _page = AgentMenuPage.budget),
          ),
      ],
      AgentMenuPage.budget => [
        _top('Spending cap'),
        for (final usd in [null, ...budgetPresets])
          PopoverRow(
            key: ValueKey('agent-menu.budget.${usd ?? 'none'}'),
            title: usd == null ? 'No cap' : formatMicros((usd * 1e6).round()),
            selected: usd == _budget,
            trailing: check(usd == _budget),
            onTap: () {
              setState(() => _budget = usd);
              _home();
              widget.onBudget!(usd);
            },
          ),
      ],
      AgentMenuPage.workflow => [
        _top('Workflow'),
        PopoverRow(
          key: const ValueKey('agent-menu.workflow.none'),
          title: 'None',
          subtitle: _outside ? 'The harness works its own way' : 'The agent works at its effort level',
          selected: _workflow == null,
          trailing: check(_workflow == null),
          onTap: () => _pickWorkflow(null),
        ),
        if ((widget.demo ? null : widget.workflows) case final lib?) ...[
          PopoverRow(
            key: const ValueKey('agent-menu.workflow.$maxWorkflowId'),
            title: 'Max',
            subtitle: maxWorkflowDescription,
            selected: _workflow?.isMax ?? false,
            trailing: check(_workflow?.isMax ?? false),
            onTap: () => _pickWorkflow(const WorkflowPick.max()),
          ),
          for (final w in lib.active.where((w) => w.origin == WorkflowOrigin.bundled)) _scriptRow(w, check),
          if (lib.active.any((w) => w.origin == WorkflowOrigin.project) || lib.locked.isNotEmpty) ...[
            const PopoverHeader('This project'),
            for (final w in lib.active.where((w) => w.origin == WorkflowOrigin.project)) _scriptRow(w, check),
            for (final (:entry, :note) in lib.locked)
              PopoverRow(
                key: ValueKey('agent-menu.workflow.locked.${entry.id}'),
                title: entry.title,
                subtitle: note,
                leading: AdaptiveIcon(EveryIcon.shield, size: 13, color: theme.textMuted),
                // Same id as a bundled one: renaming the file is the fix, not trust.
                onTap: lib.active.any((w) => w.id == entry.id) ? null : () => unawaited(_review(entry)),
              ),
          ],
        ],
      ],
      AgentMenuPage.harness => [
        _top('Harness'),
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
                ? _home
                : () {
                    setState(() => _harness = l.info.id);
                    _home();
                    widget.onHarness!(l.info.id);
                  },
          ),
        if (widget.onCheckAgain case final again?)
          PopoverRow(
            key: const ValueKey('agent-menu.harness.check-again'),
            title: 'Check again',
            subtitle: 'Looks for harnesses you installed',
            onTap: () {
              _home();
              again();
            },
          ),
      ],
      AgentMenuPage.model when _outside => [
        _top('Model'),
        if (widget.driverModels!.isEmpty)
          PopoverRow(
            key: const ValueKey('agent-menu.model.default'),
            title: 'Its default model',
            selected: true,
            trailing: check(true),
            onTap: _home,
          ),
        for (final m in widget.driverModels!)
          PopoverRow(
            key: ValueKey('agent-menu.model.${m.id}'),
            title: m.label,
            subtitle: m.isDefault ? 'default' : null,
            selected: m.id == _model,
            trailing: check(m.id == _model),
            onTap: m.id == _model ? _home : () => _pick(m.id, m.efforts.contains(_effort) ? _effort : ''),
          ),
      ],
      AgentMenuPage.model => [
        _top('Model'),
        for (final (vendor, models) in widget.groups) ...[
          PopoverHeader(vendor.company),
          for (final m in models)
            PopoverRow(
              key: ValueKey('agent-menu.model.${m.model}'),
              title: m.name,
              subtitle: m.tierHint.isEmpty ? null : m.tierHint,
              selected: m.model == _model,
              trailing: check(m.model == _model),
              onTap: m.model == _model ? _home : () => _pick(m.model, effortForModel(m, _effort)),
            ),
        ],
      ],
      AgentMenuPage.effort => [
        _top('Effort'),
        if (widget.onLevel != null && !_outside)
          Padding(
            key: const ValueKey('agent-menu.level'),
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Effort level', style: theme.type.callout),
                const SizedBox(height: 6),
                AdaptiveSegmented<HarnessTier>(
                  values: HarnessTier.offered,
                  selected: HarnessTier.offered.contains(_level) ? _level : HarnessTier.efficient,
                  label: (t) => t.label,
                  onSelected: (t) {
                    if (t == _level) return;
                    setState(() => _level = t);
                    widget.onLevel!(t);
                  },
                ),
                const SizedBox(height: 6),
                Text(_level.description, style: theme.type.caption.tint(theme.textMuted)),
              ],
            ),
          ),
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
                ? _home
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

extension on _AgentMenuPanelState {
  Widget _scriptRow(WorkflowEntry w, Widget Function(bool) check) {
    final on = _workflow?.entry?.id == w.id;
    final busy = widget.workflowBusy;
    return PopoverRow(
      key: ValueKey('agent-menu.workflow.${w.id}'),
      title: w.title,
      subtitle: busy ?? (w.description.isEmpty ? 'Runs on your next message' : w.description),
      selected: on,
      trailing: check(on),
      onTap: busy == null ? () => _pickWorkflow(WorkflowPick.script(w)) : null,
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
