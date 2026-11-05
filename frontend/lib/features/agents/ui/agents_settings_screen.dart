import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../code/code_providers.dart' show codeProjectsProvider;
import '../../code/domain/code_session.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../agents_providers.dart';

/// Settings → Agents: the agents a Code session can hand work to with
/// `run_subagent`. Built-in ones ship with the app (customize one to edit a
/// copy); global ones live in app support `agents/`; project ones in
/// `<project>/.everyai/agents` stay off until the user trusts them.
class AgentsSettingsBody extends ConsumerStatefulWidget {
  const AgentsSettingsBody({super.key});

  @override
  ConsumerState<AgentsSettingsBody> createState() => _AgentsSettingsBodyState();
}

class _AgentsSettingsBodyState extends ConsumerState<AgentsSettingsBody> {
  /// The agent open in the editor, if any.
  AgentDefinition? _editing;
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _edit(AgentDefinition a) => setState(() {
    _editing = a;
    _text.text = a.text;
  });

  @override
  Widget build(BuildContext context) {
    final editing = _editing;
    if (editing != null) return _editor(context, editing);
    final theme = EveryTheme.of(context);
    final library = ref.watch(agentLibraryProvider);
    final settings = ref.watch(agentLibrarySettingsProvider);
    final projects = ref.watch(codeProjectsProvider);
    final all = library.value ?? const <AgentDefinition>[];
    final globalWinners = agentWinners(all, null);

    Widget section(
      String title,
      List<AgentDefinition> items, {
      String? empty,
      Map<String, AgentDefinition>? winners,
      CodeProject? newIn,
      bool canCreate = false,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdaptiveSectionHeader(title),
        if (items.isEmpty && empty != null)
          AdaptiveListTile(title: Text(empty, style: theme.type.body.tint(theme.textMuted))),
        for (final a in items)
          _AgentTile(
            agent: a,
            settings: settings,
            onEdit: () => _edit(a),
            shadowedBy: switch ((winners ?? globalWinners)[a.name]) {
              final w? when a.usable && w.key != a.key => w,
              _ => null,
            },
          ),
        if (canCreate)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: AdaptiveButton(
                label: 'New agent',
                emphasis: ButtonEmphasis.secondary,
                icon: const AdaptiveIcon(EveryIcon.add, size: 14),
                onPressed: () => _create(newIn),
              ),
            ),
          ),
      ],
    );

    return ListView(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
      children: [
        Text(
          'An agent is a Markdown file: a description that tells the Code agent when to hand it work, optional '
          'model, effort, tools and permissions lines, and its instructions. The Code agent starts one as a '
          'subagent when a task fits its description. An agent can make a subagent more careful than the session '
          'that starts it, never less.',
          style: theme.type.caption.tint(theme.textMuted),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: AdaptiveButton(
              label: 'Reload',
              emphasis: ButtonEmphasis.secondary,
              onPressed: ref.read(agentLibraryProvider.notifier).reload,
            ),
          ),
        ),
        if (library case AsyncError(:final error))
          Text("Couldn't read the agent folders: $error", style: theme.type.body.tint(theme.danger)),
        section('Built-in', [...all.where((a) => a.source == AgentSource.builtin)]),
        section(
          'Global',
          [...all.where((a) => a.source == AgentSource.global)],
          empty: 'No agents of your own yet',
          canCreate: true,
        ),
        for (final p in projects)
          section(
            p.name,
            [...all.where((a) => a.projectId == p.id)],
            empty: 'No agents in $projectAgentsDir',
            winners: agentWinners(all, p.id),
            newIn: p,
            canCreate: true,
          ),
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(
            'Global agents live in the app support folder\'s agents/ and work in every project. Project agents live '
            'in <project>/$projectAgentsDir; one that came with a repository stays off until you review it, and goes '
            'off again if its file changes. A project agent takes the place of a global or built-in one of the same '
            'name once trusted.',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ),
      ],
    );
  }

  Widget _editor(BuildContext context, AgentDefinition a) {
    final theme = EveryTheme.of(context);
    final readOnly = a.path == null;
    final preview = AgentDefinition.parse(_text.text, fileName: '${a.name}.md', source: a.source);
    final problems = [...preview.errors, ...preview.warnings];
    return ListView(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                readOnly ? '${a.name} (built-in)' : a.name,
                style: theme.type.headline.tint(theme.text),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            AdaptiveButton(
              label: readOnly ? 'Close' : 'Cancel',
              emphasis: ButtonEmphasis.secondary,
              onPressed: () => setState(() => _editing = null),
            ),
            const SizedBox(width: 8),
            if (readOnly)
              AdaptiveButton(label: 'Customize', onPressed: () => _customize(a))
            else
              AdaptiveButton(label: 'Save', onPressed: () => _save(a)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          readOnly
              ? 'Built-in agents are read-only. Customize makes a copy in your global agents that you can edit; it '
                    'takes the built-in\'s place.'
              : a.path!,
          style: theme.type.caption.tint(theme.textMuted),
        ),
        if (problems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              problems.join('\n'),
              style: theme.type.caption.tint(preview.usable ? theme.textMuted : theme.danger),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: readOnly
              ? Text(a.text, style: theme.type.callout.mono)
              : AdaptiveTextField(controller: _text, minLines: 18, maxLines: null, onChanged: (_) => setState(() {})),
        ),
      ],
    );
  }

  Future<void> _save(AgentDefinition a) async {
    try {
      await ref.read(agentLibraryProvider.notifier).save(a, _text.text);
      if (mounted) setState(() => _editing = null);
    } on Object catch (e) {
      if (mounted) await _tell(context, 'Could not save', '$e');
    }
  }

  Future<void> _customize(AgentDefinition a) async {
    try {
      final copy = await ref.read(agentLibraryProvider.notifier).customize(a);
      if (!mounted) return;
      if (copy == null) {
        setState(() => _editing = null);
      } else {
        _edit(copy);
      }
    } on StateError catch (e) {
      if (mounted) await _tell(context, 'Could not customize', e.message);
    }
  }

  Future<void> _create(CodeProject? project) async {
    final name = await showAdaptivePrompt(
      context,
      title: project == null ? 'New global agent' : 'New agent in ${project.name}',
      confirmLabel: 'Create',
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      final a = await ref
          .read(agentLibraryProvider.notifier)
          .create(name.trim().toLowerCase().replaceAll(' ', '-'), projectPath: project?.path);
      if (a != null && mounted) _edit(a);
    } on StateError catch (e) {
      if (mounted) await _tell(context, 'Could not create', e.message);
    }
  }

  static Future<void> _tell(BuildContext context, String title, String message) =>
      showAdaptiveConfirm(context, title: title, message: message, confirmLabel: 'OK');
}

class _AgentTile extends ConsumerWidget {
  const _AgentTile({required this.agent, required this.settings, required this.onEdit, this.shadowedBy});

  final AgentDefinition agent;
  final AgentLibrarySettings settings;
  final AgentDefinition? shadowedBy;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final a = agent;
    final ctl = ref.read(agentLibrarySettingsProvider.notifier);
    final status = agentStatus(a, settings, shadowedBy: shadowedBy);
    final needsTrust = a.usable && !settings.trustedNow(a);
    final traits = [
      if (a.model case final m?) m.split('/').last,
      if (a.effort case final e?) '$e effort',
      if (a.mode case final m?) m.label,
      if (a.tools case final t?) t.join(', '),
    ];
    final notes = [...a.warnings, if (status != null && status != 'Off') status];
    return AdaptiveListTile(
      title: Text(a.name),
      onTap: onEdit,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (a.description.isNotEmpty) Text(a.description, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (traits.isNotEmpty) Text(traits.join(' · '), style: theme.type.caption.tint(theme.textMuted)),
          if (a.usable)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _PreferredModel(agent: a),
            ),
          if (notes.isNotEmpty)
            Text(
              notes.join(' · '),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.type.caption.tint(a.usable ? theme.textMuted : theme.danger),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (needsTrust)
            AdaptiveButton(label: 'Review…', emphasis: ButtonEmphasis.secondary, onPressed: () => _review(context, ctl))
          else
            AdaptiveSwitch(
              value: a.usable && settings.enabled(a),
              onChanged: a.usable ? (on) => ctl.setEnabled(a, on) : null,
            ),
          AdaptiveMenuButton(
            tooltip: 'More',
            actions: [
              MenuAction(label: a.path == null ? 'View' : 'Edit', icon: EveryIcon.edit, onSelected: onEdit),
              if (a.path case final path?)
                MenuAction(label: 'Open in your editor', onSelected: () => launchUrl(Uri.file(path))),
              if (a.source == AgentSource.builtin)
                MenuAction(
                  label: 'Customize',
                  onSelected: () async {
                    try {
                      await ref.read(agentLibraryProvider.notifier).customize(a);
                    } on StateError catch (e) {
                      if (context.mounted) {
                        await showAdaptiveConfirm(
                          context,
                          title: 'Could not customize',
                          message: e.message,
                          confirmLabel: 'OK',
                        );
                      }
                    }
                  },
                ),
              if (a.source == AgentSource.project && settings.trusted.containsKey(a.key))
                MenuAction(label: 'Stop trusting', onSelected: () => ctl.untrust(a)),
              if (a.path != null)
                MenuAction(
                  label: 'Delete…',
                  icon: EveryIcon.delete,
                  destructive: true,
                  onSelected: () => _remove(context, ref),
                ),
            ],
            child: const Padding(padding: EdgeInsets.all(6), child: AdaptiveIcon(EveryIcon.more, size: 16)),
          ),
        ],
      ),
    );
  }

  Future<void> _review(BuildContext context, AgentLibrarySettingsNotifier ctl) async {
    final a = agent;
    final traits = [
      if (a.model != null) 'Model: ${a.model}',
      if (a.effort != null) 'Effort: ${a.effort}',
      if (a.mode != null) 'Permissions: ${a.mode!.label}',
      if (a.tools != null) 'Tools: ${a.tools!.join(', ')}',
    ];
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Trust ${a.name}?',
      message:
          'This agent came with the project, in ${a.path}. Subagents started with it follow its instructions.\n\n'
          '${a.description}${traits.isEmpty ? '' : '\n${traits.join('\n')}'}',
      // The whole prompt: trust covers all of it.
      detail: a.prompt,
      confirmLabel: 'Trust and turn on',
    );
    if (ok) ctl.trust(a);
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Delete ${agent.name}?',
      message: 'The file ${agent.path} is deleted.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (ok) await ref.read(agentLibraryProvider.notifier).remove(agent);
  }
}

/// The model and effort the user runs [agent] on when a fork or workflow
/// takes its role; "Same as orchestrator" keeps the session's.
class _PreferredModel extends ConsumerWidget {
  const _PreferredModel({required this.agent});

  final AgentDefinition agent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final pick = ref.watch(agentLibrarySettingsProvider.select((s) => s.preferredFor(agent.name)));
    final ctl = ref.read(agentLibrarySettingsProvider.notifier);
    // The model list loads only when the popover opens.
    final name = pick.model.isEmpty ? 'Same as orchestrator' : pick.model.split('/').last;
    final label = pick.effort.isEmpty ? name : '$name · ${pick.effort}';
    Widget check(bool on) => on ? AdaptiveIcon(EveryIcon.check, size: 14, color: theme.accent) : const SizedBox();
    return Align(
      alignment: Alignment.centerLeft,
      child: AnchoredPopover(
        width: 300,
        builder: (context, close) => Consumer(
          builder: (context, ref, _) {
            final library = (ref.watch(libraryProvider).value ?? const <ModelSpec>[]).where((m) => m.tools).toList();
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PopoverHeader('${agent.name}: preferred model'),
                  PopoverRow(
                    title: 'Same as orchestrator',
                    subtitle: 'The session\'s model: forks share its cache',
                    trailing: check(pick.model.isEmpty),
                    onTap: () => ctl.setPreferred(agent.name, model: ''),
                  ),
                  for (final m in library)
                    PopoverRow(
                      key: ValueKey('agent.${agent.name}.model.${m.id.value}'),
                      title: m.name,
                      trailing: check(pick.model == m.id.value),
                      onTap: () => ctl.setPreferred(agent.name, model: m.id.value),
                    ),
                  const PopoverHeader('Effort'),
                  for (final e in ['', ...agentEfforts])
                    PopoverRow(
                      title: e.isEmpty ? 'Same as orchestrator' : e,
                      trailing: check(pick.effort == e),
                      onTap: () => ctl.setPreferred(agent.name, effort: e),
                    ),
                ],
              ),
            );
          },
        ),
        child: Text(
          'Runs on: $label ▾',
          style: theme.type.caption.tint(pick.model.isEmpty ? theme.textMuted : theme.accent),
        ),
      ),
    );
  }
}
