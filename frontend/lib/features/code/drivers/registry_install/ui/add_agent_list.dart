// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/every_theme.dart';
import '../../../../../core/ui/adaptive.dart';
import '../../acp/acp_files.dart' show whichCommand;
import '../acp_registry.dart';
import '../installed_agents.dart';

/// Whether `npx` and `uvx` are on the login shell's PATH (tests replace it).
final agentRunnersProvider = FutureProvider<Map<DistKind, bool>>(
  (ref) async => {DistKind.npx: await whichCommand('npx') != null, DistKind.uvx: await whichCommand('uvx') != null},
);

/// Settings → Code → Harnesses → Add agent: the ACP registry's agents, each
/// with Install, Update (the registry has another version) and Remove. An
/// added agent shows up among the harnesses once the check after it ends.
class AddAgentList extends ConsumerStatefulWidget {
  const AddAgentList({super.key});

  @override
  ConsumerState<AddAgentList> createState() => _AddAgentListState();
}

class _AddAgentListState extends ConsumerState<AddAgentList> {
  var _query = '';

  /// The agent whose download has no checksum and awaits a second click.
  String? _confirming;
  final _errors = <String, String>{};

  Future<void> _run(String id, Future<void> Function() action) async {
    setState(() {
      _errors.remove(id);
      if (_confirming == id) _confirming = null;
    });
    try {
      await action();
    } on Object catch (e) {
      if (mounted) setState(() => _errors[id] = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final list = ref.watch(acpRegistryProvider);
    final installed = ref.watch(installedAgentsProvider);
    final runners = ref.watch(agentRunnersProvider).value ?? const {};
    final installer = ref.read(agentInstallerProvider);
    final inFlight = ref.watch(agentsInFlightProvider);
    final value = list.value;
    final q = _query.trim().toLowerCase();
    final agents = [
      for (final a in value?.agents ?? const <RegistryAgent>[])
        if (q.isEmpty || '${a.id} ${a.name} ${a.description}'.toLowerCase().contains(q)) a,
    ];
    final known = {for (final a in value?.agents ?? const <RegistryAgent>[]) a.id};
    // Added agents the registry no longer lists can still be removed.
    final gone = [
      for (final a in installed.values)
        if (!known.contains(a.id) && (q.isEmpty || a.name.toLowerCase().contains(q))) a,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdaptiveTextField(
          key: const ValueKey('add-agent.search'),
          placeholder: 'Search agents',
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 6),
        if (list.isLoading && value == null)
          Text('Loading the agent list…', style: theme.type.caption.tint(theme.textMuted)),
        if (value?.note case final note?)
          Text(note, key: const ValueKey('add-agent.note'), style: theme.type.caption.tint(theme.textMuted)),
        for (final a in agents) _row(theme, a, installed[a.id], installer.distributionOf(a), runners, inFlight),
        for (final a in gone) _row(theme, null, a, null, runners, inFlight),
        const SizedBox(height: 6),
        Text(
          'From the ACP registry (agentclientprotocol.com). Downloads go in the app\'s own folder; npx and uvx agents '
          'are fetched by Node.js or uv the first time you start them.',
          style: theme.type.caption.tint(theme.textMuted),
        ),
      ],
    );
  }

  Widget _row(
    EveryTheme theme,
    RegistryAgent? agent,
    InstalledAgent? have,
    Distribution? dist,
    Map<DistKind, bool> runners,
    Set<String> inFlight,
  ) {
    final id = agent?.id ?? have!.id;
    final name = agent?.name ?? have!.name;
    final notifier = ref.read(installedAgentsProvider.notifier);
    final busy = have != null && notifier.busy(id);
    final working = inFlight.contains(id);
    final kind = dist?.kind ?? have?.kind;
    final noRunner = kind != null && kind != DistKind.binary && runners[kind] == false;
    final unchecked = dist?.binary != null && dist!.binary!.sha256 == null;
    final env = dist?.env ?? have?.env ?? const {};
    final muted = theme.type.caption.tint(theme.textMuted);
    final details = [
      if (agent != null) agent.version else have!.version,
      ?kind?.label,
      if (have != null) agent != null && agent.version != have.version ? 'Added: ${have.version}' : 'Added',
    ].join(' · ');
    void install({bool anyway = false}) {
      if (unchecked && !anyway) {
        setState(() => _confirming = id);
        return;
      }
      _run(id, () => notifier.install(agent!, allowUnchecked: anyway));
    }

    return Padding(
      key: ValueKey('add-agent.$id'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: theme.type.callout.medium.tint(theme.text)),
                    Text(details, style: muted),
                    if (agent != null && agent.description.isNotEmpty) Text(agent.description, style: muted),
                    if (agent != null && dist == null) Text('Not available for this computer', style: muted),
                    if (noRunner)
                      Text(
                        kind == DistKind.npx ? 'Needs Node.js' : 'Needs uv',
                        key: ValueKey('add-agent.$id.runner'),
                        style: muted,
                      ),
                    if (dist?.run case final run?)
                      Text('Downloads and runs ${run.package} the first time you start it.', style: muted),
                    if (env.isNotEmpty)
                      Text('Sets ${[for (final e in env.entries) '${e.key}=${e.value}'].join(', ')}', style: muted),
                    if (busy) Text('Close its sessions to update or remove it.', style: muted),
                    if (_errors[id] case final error?)
                      Text(error, key: ValueKey('add-agent.$id.error'), style: theme.type.caption.tint(theme.danger)),
                  ],
                ),
              ),
              if (have == null && agent != null && dist != null && _confirming != id)
                AdaptiveButton(
                  key: ValueKey('add-agent.$id.install'),
                  label: 'Install',
                  busy: working,
                  onPressed: working ? null : install,
                ),
              if (have != null && agent != null && dist != null && agent.version != have.version) ...[
                AdaptiveButton(
                  key: ValueKey('add-agent.$id.update'),
                  label: 'Update',
                  busy: working,
                  onPressed: working || busy ? null : install,
                ),
                const SizedBox(width: 6),
              ],
              if (have != null)
                AdaptiveButton(
                  key: ValueKey('add-agent.$id.remove'),
                  label: 'Remove',
                  emphasis: ButtonEmphasis.secondary,
                  onPressed: working || busy ? null : () => _run(id, () => notifier.remove(id)),
                ),
            ],
          ),
          if (_confirming == id) ...[
            const SizedBox(height: 4),
            Text(
              'No checksum is published for this download, so the app can\'t check it arrived unchanged. '
              'Install anyway?',
              key: ValueKey('add-agent.$id.unchecked'),
              style: muted,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                AdaptiveButton(
                  key: ValueKey('add-agent.$id.anyway'),
                  label: 'Install anyway',
                  busy: working,
                  onPressed: working ? null : () => install(anyway: true),
                ),
                const SizedBox(width: 6),
                AdaptiveButton(
                  key: ValueKey('add-agent.$id.cancel'),
                  label: 'Cancel',
                  emphasis: ButtonEmphasis.secondary,
                  onPressed: working ? null : () => setState(() => _confirming = null),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The "Add agent…" button under the harnesses, which opens [AddAgentList]
/// below it.
class AddAgentEntry extends StatefulWidget {
  const AddAgentEntry({super.key});

  @override
  State<AddAgentEntry> createState() => _AddAgentEntryState();
}

class _AddAgentEntryState extends State<AddAgentEntry> {
  var _open = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          AdaptiveButton(
            key: const ValueKey('code-settings.harnesses.add'),
            label: _open ? 'Hide agents' : 'Add agent…',
            emphasis: ButtonEmphasis.secondary,
            onPressed: () => setState(() => _open = !_open),
          ),
        ],
      ),
      if (_open) ...[const SizedBox(height: 8), const AddAgentList()],
    ],
  );
}
