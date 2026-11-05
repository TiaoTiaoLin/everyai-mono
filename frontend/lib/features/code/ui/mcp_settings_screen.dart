import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../code_providers.dart' show codeProjectsProvider;
import '../mcp_providers.dart';

/// Settings → MCP servers: the servers Code sessions get, for every project
/// or one project. Local commands need the user's approval of the exact
/// command before any session starts them.
class McpSettingsBody extends ConsumerStatefulWidget {
  const McpSettingsBody({super.key, this.projectId});

  /// The project the page opens on (null: every project).
  final String? projectId;

  @override
  ConsumerState<McpSettingsBody> createState() => _McpSettingsBodyState();
}

class _McpSettingsBodyState extends ConsumerState<McpSettingsBody> {
  /// Null: every project.
  late String? _projectId = widget.projectId;

  /// The entry being edited: a server (new or existing) and the name it had.
  ({McpServer server, String? original})? _editing;

  String _scopeLabel(String? projectId) {
    if (projectId == null) return 'every project';
    return ref.read(codeProjectsProvider).where((p) => p.id == projectId).firstOrNull?.name ?? 'this project';
  }

  /// Shows the consent dialog for [server] and records the approval.
  Future<void> _review(McpServer server) async {
    if (!server.needsConsent || server.problem != null) return;
    final flags = reviewMcpServer(server);
    final scope = _scopeLabel(_projectId);
    if (flags.any((f) => f.level == McpFlagLevel.blocked)) {
      await showAdaptiveConfirm(
        context,
        title: 'This command is blocked',
        message:
            '${mcpConsentMessage(server, scope: scope, flags: flags)}\n\nIt is on the safety floor and never runs.',
        confirmLabel: 'OK',
      );
      return;
    }
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Allow ${server.name} to run?',
      message: mcpConsentMessage(server, scope: scope, flags: flags),
      confirmLabel: 'Allow',
      destructive: flags.any((f) => f.level == McpFlagLevel.danger),
    );
    if (ok && mounted) ref.read(codeMcpServersProvider.notifier).approve(server.name, projectId: _projectId);
  }

  /// Shows [server]'s tools that sessions leave out, and allows them on OK.
  Future<void> _reviewTools(McpServer server) async {
    if (server.pending.isEmpty) return;
    final review = mcpToolsReviewMessage(server);
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Review tools of ${server.name}',
      message: review.message,
      detail: review.detail,
      confirmLabel: 'Allow these tools',
      destructive: server.pending.any((t) => t.flagged),
    );
    if (ok && mounted) ref.read(codeMcpServersProvider.notifier).allowTools(server.name, projectId: _projectId);
  }

  Future<void> _save(McpServer server, String? original) async {
    ref.read(codeMcpServersProvider.notifier).put(server, projectId: _projectId, replacing: original);
    setState(() => _editing = null);
    if (server.enabled) await _review(server);
  }

  Future<void> _addPreset(McpPreset preset) async {
    final taken = ref.read(codeMcpServersProvider).listFor(_projectId).any((s) => s.name == preset.server.name);
    if (taken) return;
    ref.read(codeMcpServersProvider.notifier).put(preset.server, projectId: _projectId);
    await _review(preset.server);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final stored = ref.watch(codeMcpServersProvider);
    final projects = ref.watch(codeProjectsProvider);
    final ctl = ref.read(codeMcpServersProvider.notifier);
    final list = stored.listFor(_projectId);
    final inherited = _projectId == null
        ? const <McpServer>[]
        : stored.global.where((g) => !list.any((s) => s.name == g.name)).toList();
    final names = {for (final s in list) s.name};
    final editing = _editing;

    String status(McpServer s) {
      if (s.problem case final p?) return p;
      if (s.blocked) return 'Blocked: on the safety floor';
      if (!s.enabled) return 'Off';
      if (s.needsConsent) return 'Needs your approval before sessions use it';
      if (s.pending.isNotEmpty) {
        final n = s.pending.length;
        return n == 1 ? '1 tool changed or needs a look: review' : '$n tools changed or need a look: review';
      }
      return s.description.isEmpty ? 'On' : s.description;
    }

    Widget tile(McpServer s) => AdaptiveListTile(
      title: Text(s.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.transport.remote ? s.url : s.commandLine, style: theme.type.caption.mono.tint(theme.textMuted)),
          Text(
            status(s),
            style: theme.type.caption.tint(
              s.problem != null || s.blocked
                  ? theme.danger
                  : s.enabled && (s.needsConsent || s.pending.isNotEmpty)
                  ? theme.warning
                  : theme.textMuted,
            ),
          ),
        ],
      ),
      onTap: () => setState(() => _editing = (server: s, original: s.name)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AdaptiveSwitch(
            value: s.enabled,
            onChanged: (on) async {
              ctl.setEnabled(s.name, on, projectId: _projectId);
              if (on) await _review(s.copyWith(enabled: true));
            },
          ),
          AdaptiveMenuButton(
            tooltip: 'More',
            actions: [
              MenuAction(
                label: 'Edit',
                icon: EveryIcon.edit,
                onSelected: () => setState(() => _editing = (server: s, original: s.name)),
              ),
              if (s.needsConsent && s.problem == null)
                MenuAction(label: 'Review and allow…', icon: EveryIcon.check, onSelected: () => _review(s)),
              if (s.pending.isNotEmpty)
                MenuAction(label: 'Review tools…', icon: EveryIcon.check, onSelected: () => _reviewTools(s)),
              MenuAction(
                label: 'Remove',
                icon: EveryIcon.delete,
                destructive: true,
                onSelected: () => ctl.remove(s.name, projectId: _projectId),
              ),
            ],
            child: const Padding(padding: EdgeInsets.all(6), child: AdaptiveIcon(EveryIcon.more, size: 16)),
          ),
        ],
      ),
    );

    return ListView(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(
            'Tools from MCP servers for Code sessions. The agent server starts local servers and connects to '
            'remote ones when a session starts. Every MCP tool asks before it runs, except in Full auto or when '
            'you allow it.',
            style: theme.type.callout.tint(theme.textMuted),
          ),
        ),
        AdaptiveListTile(
          title: const Text('Applies to'),
          trailing: AdaptiveMenuButton(
            actions: [
              MenuAction(
                label: 'Every project',
                checked: _projectId == null,
                onSelected: () => setState(() {
                  _projectId = null;
                  _editing = null;
                }),
              ),
              for (final p in projects)
                MenuAction(
                  label: p.name,
                  checked: _projectId == p.id,
                  onSelected: () => setState(() {
                    _projectId = p.id;
                    _editing = null;
                  }),
                ),
            ],
            child: MenuTrigger(_projectId == null ? 'Every project' : _scopeLabel(_projectId)),
          ),
        ),
        AdaptiveSectionHeader(_projectId == null ? 'Every project' : 'Only ${_scopeLabel(_projectId)}'),
        if (list.isEmpty && editing == null)
          AdaptiveListTile(title: Text('No servers yet', style: theme.type.body.tint(theme.textMuted))),
        for (final s in list)
          if (editing != null && editing.original == s.name)
            _ServerEditor(
              key: ValueKey('edit-${s.name}'),
              initial: s,
              taken: names.difference({s.name}),
              onCancel: () => setState(() => _editing = null),
              onSave: (server) => _save(server, s.name),
            )
          else
            tile(s),
        if (editing != null && editing.original == null)
          _ServerEditor(
            key: const ValueKey('edit-new'),
            initial: editing.server,
            taken: names,
            onCancel: () => setState(() => _editing = null),
            onSave: (server) => _save(server, null),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AdaptiveButton(
                label: 'Add server',
                emphasis: ButtonEmphasis.secondary,
                icon: const AdaptiveIcon(EveryIcon.add, size: 14),
                onPressed: () => setState(() => _editing = (server: const McpServer(name: ''), original: null)),
              ),
              AdaptiveMenuButton(
                tooltip: 'Add a ready-made server',
                actions: [
                  for (final p in mcpPresets)
                    MenuAction(label: p.title, checked: names.contains(p.server.name), onSelected: () => _addPreset(p)),
                ],
                child: const MenuTrigger('Add a preset'),
              ),
            ],
          ),
        ),
        if (inherited.isNotEmpty) ...[
          const AdaptiveSectionHeader('Also from every project'),
          for (final s in inherited)
            AdaptiveListTile(
              title: Text(s.name),
              subtitle: Text(status(s), style: theme.type.caption.tint(theme.textMuted)),
            ),
        ],
        const AdaptiveSectionHeader('Presets'),
        for (final p in mcpPresets)
          AdaptiveListTile(
            title: Text(p.title),
            subtitle: Text(p.blurb, style: theme.type.caption.tint(theme.textMuted)),
            trailing: names.contains(p.server.name)
                ? Text('Added', style: theme.type.caption.tint(theme.textMuted))
                : AdaptiveButton(label: 'Add', emphasis: ButtonEmphasis.secondary, onPressed: () => _addPreset(p)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Text(
            'Allow an MCP tool for good from its approval card ("Always allow"), or add a rule such as '
            'Mcp(browser_take_screenshot) or Mcp(playwright_*) to your permissions. A server asking for input '
            'mid-call (elicitation) is not supported yet.',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ),
      ],
    );
  }
}

/// The form for one server: name, kind, command or URL, environment or headers.
class _ServerEditor extends StatefulWidget {
  const _ServerEditor({
    super.key,
    required this.initial,
    required this.taken,
    required this.onCancel,
    required this.onSave,
  });

  final McpServer initial;
  final Set<String> taken;
  final VoidCallback onCancel;
  final ValueChanged<McpServer> onSave;

  @override
  State<_ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<_ServerEditor> {
  late final _name = TextEditingController(text: widget.initial.name);
  late final _command = TextEditingController(text: widget.initial.commandLine);
  late final _env = TextEditingController(text: envLines(widget.initial.env));
  late final _url = TextEditingController(text: widget.initial.url);
  late final _headers = TextEditingController(text: headerLines(widget.initial.headers));
  late final _description = TextEditingController(text: widget.initial.description);
  late McpTransport _transport = widget.initial.transport;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _command, _env, _url, _headers, _description]) {
      c.dispose();
    }
    super.dispose();
  }

  McpServer _built() {
    final words = shellSplit(_command.text);
    final stdio = _transport == McpTransport.stdio;
    return widget.initial.copyWith(
      name: _name.text.trim(),
      transport: _transport,
      command: stdio && words.isNotEmpty ? words.first : '',
      args: stdio && words.length > 1 ? words.sublist(1) : const [],
      env: stdio ? parseEnvLines(_env.text) : const {},
      url: stdio ? '' : _url.text.trim(),
      headers: stdio ? const {} : parseHeaderLines(_headers.text),
      description: _description.text.trim(),
    );
  }

  void _submit() {
    final server = _built();
    final problem = server.problem ?? (widget.taken.contains(server.name) ? 'Another server has that name.' : null);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    widget.onSave(server);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final stdio = _transport == McpTransport.stdio;
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(text, style: theme.type.caption.tint(theme.textMuted)),
    );
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: AdaptiveTextField(controller: _name, placeholder: 'Name (playwright, github, …)'),
              ),
              const SizedBox(width: 8),
              AdaptiveMenuButton(
                actions: [
                  for (final t in McpTransport.values)
                    MenuAction(
                      label: t.label,
                      checked: t == _transport,
                      onSelected: () => setState(() => _transport = t),
                    ),
                ],
                child: MenuTrigger(_transport.label),
              ),
            ],
          ),
          if (stdio) ...[
            label('Command and arguments, as you would type them'),
            AdaptiveTextField(controller: _command, placeholder: 'npx -y @scope/server@1.2.3'),
            label('Environment, one KEY=value per line'),
            AdaptiveTextField(controller: _env, minLines: 2, maxLines: 6, placeholder: 'API_KEY=…'),
          ] else ...[
            label('URL'),
            AdaptiveTextField(controller: _url, placeholder: 'https://example.com/mcp'),
            label('Headers, one Name: value per line'),
            AdaptiveTextField(controller: _headers, minLines: 2, maxLines: 6, placeholder: 'Authorization: Bearer …'),
          ],
          label('Description (optional)'),
          AdaptiveTextField(controller: _description),
          if (_error case final e?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(e, style: theme.type.caption.tint(theme.danger)),
            ),
          if (stdio)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'You will see the full command and approve it before any session runs it.',
                style: theme.type.caption.tint(theme.textMuted),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AdaptiveButton(label: 'Cancel', emphasis: ButtonEmphasis.secondary, onPressed: widget.onCancel),
                const SizedBox(width: 8),
                AdaptiveButton(label: 'Save', onPressed: _submit),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
