import 'dart:convert';

import 'package:everyai_markdown/everyai_markdown.dart' show languageForPath;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/platform/platform_kind.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../../core/ui/syntax_spans.dart';
import '../../domain/agent_mode.dart';
import '../../domain/line_diff.dart';
import '../../domain/permissions.dart';
import '../../domain/transcript.dart';
import '../../harness/events.dart';
import 'transcript_items.dart';

/// Actions waiting for the user: what will run, and Allow (once, for the
/// session, always) / Deny.
class ApprovalCard extends StatefulWidget {
  const ApprovalCard({
    super.key,
    required this.pending,
    required this.mode,
    required this.onAllow,
    required this.onDeny,
    required this.onMode,
    this.remember,
    this.flags = const {},
    this.onAllowCall,
    this.onDenyCall,
    this.decided = const {},
    this.rememberBy = const {},
  });

  /// One call's answer, for sessions that take one per call (null: the
  /// batch is answered as one, as the agent-server does).
  final void Function(String callId, ApprovalScope scope)? onAllowCall;
  final void Function(String callId)? onDenyCall;

  /// Calls answered already (id → allowed); their rows are settled.
  final Map<String, bool> decided;

  /// The rule "for this session" / "always" stores, per call that has one.
  final Map<String, String> rememberBy;

  final List<ActionCall> pending;
  final AgentMode mode;
  final ValueChanged<ApprovalScope> onAllow;
  final ValueChanged<String> onDeny;
  final ValueChanged<AgentMode> onMode;

  /// The rules "for this session" / "always" would store; null hides those
  /// buttons (compound commands and dangerous actions are approved once).
  final List<String>? remember;

  /// Why an action needs a look, by call id (from the danger classifier).
  final Map<String, String> flags;

  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  final _reason = TextEditingController();
  bool _denying = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final calls = widget.pending;
    final edits = calls.every((c) => AgentMode.isFileEdit(c) && !AgentMode.isReadOnly(c));
    final remember = widget.remember;
    if (widget.onAllowCall != null && widget.onDenyCall != null && calls.length > 1) return _stacked(theme, edits);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => widget.onAllow(ApprovalScope.once),
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () => widget.onAllow(ApprovalScope.once),
        const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => _denying = true),
      },
      child: Focus(
        autofocus: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: theme.surfaceRaised,
            border: Border.all(color: theme.warning.withValues(alpha: 0.7)),
            borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                calls.length == 1 ? approvalTitle(calls.single) : 'Allow ${calls.length} actions?',
                style: theme.type.headline.tint(theme.text),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final c in calls) _Preview(call: c, flag: widget.flags[c.id])],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (_denying) ...[
                AdaptiveTextField(
                  controller: _reason,
                  autofocus: true,
                  placeholder: 'Tell the agent what to do instead (optional)',
                  onSubmitted: (_) => widget.onDeny(_reason.text),
                ),
                const SizedBox(height: 8),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  if (_denying)
                    AdaptiveButton(
                      label: 'Deny',
                      emphasis: ButtonEmphasis.destructive,
                      onPressed: () => widget.onDeny(_reason.text),
                    )
                  else
                    AdaptiveButton(
                      label: 'Deny…',
                      emphasis: ButtonEmphasis.secondary,
                      onPressed: () => setState(() => _denying = true),
                    ),
                  if (widget.mode == AgentMode.ask && edits)
                    AdaptiveButton(
                      label: 'Allow all edits',
                      emphasis: ButtonEmphasis.secondary,
                      onPressed: () => widget.onMode(AgentMode.autoEdit),
                    ),
                  if (remember != null) ...[
                    AdaptiveButton(
                      label: 'Always allow',
                      emphasis: ButtonEmphasis.secondary,
                      onPressed: () => widget.onAllow(ApprovalScope.always),
                    ),
                    AdaptiveButton(
                      label: 'Allow for session',
                      emphasis: ButtonEmphasis.secondary,
                      onPressed: () => widget.onAllow(ApprovalScope.session),
                    ),
                  ],
                  AdaptiveButton(
                    label: 'Allow once  ${Host.enterKeys(command: true)}',
                    onPressed: () => widget.onAllow(ApprovalScope.once),
                  ),
                ],
              ),
              if (remember != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Session and always cover: ${remember.join(', ')}',
                    textAlign: TextAlign.end,
                    style: theme.type.caption.tint(theme.textMuted),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Several calls, one answer each: a row per call (Allow / Deny / Always ⌄)
  /// under Allow all / Deny all. The batch runs once every row is answered.
  Widget _stacked(EveryTheme theme, bool edits) {
    final calls = widget.pending;
    final open = calls.where((c) => !widget.decided.containsKey(c.id)).length;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => widget.onAllow(ApprovalScope.once),
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () => widget.onAllow(ApprovalScope.once),
        const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => _denying = true),
      },
      child: Focus(
        autofocus: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: theme.surfaceRaised,
            border: Border.all(color: theme.warning.withValues(alpha: 0.7)),
            borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                open == calls.length
                    ? 'Allow ${calls.length} actions?'
                    : '$open of ${calls.length} actions still to answer',
                style: theme.type.headline.tint(theme.text),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, c) in calls.indexed) ...[
                        if (i > 0) Container(height: 1, color: theme.border, margin: const EdgeInsets.only(bottom: 8)),
                        _CallRow(
                          call: c,
                          flag: widget.flags[c.id],
                          decided: widget.decided[c.id],
                          rule: widget.rememberBy[c.id],
                          onAllow: (scope) => widget.onAllowCall!(c.id, scope),
                          onDeny: () => widget.onDenyCall!(c.id),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (_denying) ...[
                AdaptiveTextField(
                  controller: _reason,
                  autofocus: true,
                  placeholder: 'Tell the agent what to do instead (optional)',
                  onSubmitted: (_) => widget.onDeny(_reason.text),
                ),
                const SizedBox(height: 8),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  if (_denying)
                    AdaptiveButton(
                      label: 'Deny all',
                      emphasis: ButtonEmphasis.destructive,
                      onPressed: () => widget.onDeny(_reason.text),
                    )
                  else
                    AdaptiveButton(
                      label: 'Deny all…',
                      emphasis: ButtonEmphasis.secondary,
                      onPressed: () => setState(() => _denying = true),
                    ),
                  if (widget.mode == AgentMode.ask && edits)
                    AdaptiveButton(
                      label: 'Allow all edits',
                      emphasis: ButtonEmphasis.secondary,
                      onPressed: () => widget.onMode(AgentMode.autoEdit),
                    ),
                  AdaptiveButton(
                    label: 'Allow all  ${Host.enterKeys(command: true)}',
                    onPressed: () => widget.onAllow(ApprovalScope.once),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One call on the stacked card: what it does, and its own answer.
class _CallRow extends StatelessWidget {
  const _CallRow({required this.call, required this.onAllow, required this.onDeny, this.flag, this.decided, this.rule});

  final ActionCall call;
  final String? flag;

  /// Null while it waits; true allowed, false denied.
  final bool? decided;

  /// What "for this session" / "always" would store, or null (not offered).
  final String? rule;
  final ValueChanged<ApprovalScope> onAllow;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final done = decided;
    return Opacity(
      opacity: done == null ? 1 : 0.55,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Preview(call: call, flag: flag),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    approvalTitle(call),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.caption.tint(theme.textMuted),
                  ),
                ),
                if (done != null)
                  Text(
                    done ? 'Allowed' : 'Denied',
                    style: theme.type.caption.medium.tint(done ? theme.success : theme.danger),
                  )
                else ...[
                  AdaptiveButton(label: 'Deny', emphasis: ButtonEmphasis.secondary, onPressed: onDeny),
                  if (rule case final r?) ...[
                    const SizedBox(width: 6),
                    AdaptiveMenuButton(
                      tooltip: 'Remember: $r',
                      actions: [
                        MenuAction(label: 'Allow for this session', onSelected: () => onAllow(ApprovalScope.session)),
                        MenuAction(label: 'Always allow', onSelected: () => onAllow(ApprovalScope.always)),
                      ],
                      child: const MenuTrigger('Always'),
                    ),
                  ],
                  const SizedBox(width: 6),
                  AdaptiveButton(label: 'Allow', onPressed: () => onAllow(ApprovalScope.once)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.call, this.flag});
  final ActionCall call;
  final String? flag;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final mono = theme.type.callout.mono.copyWith(height: 1.45);
    final risk = call.risk.toUpperCase();
    final body = switch (call.actionKind) {
      'TerminalAction' => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: theme.codeBackground, borderRadius: BorderRadius.circular(8)),
        child: Text.rich(
          TextSpan(
            style: mono.copyWith(color: theme.text),
            children: [
              TextSpan(
                text: '\$ ',
                style: TextStyle(color: theme.textMuted),
              ),
              shellSpan(
                call.str('command'),
                base: mono.copyWith(color: theme.text),
                brightness: theme.brightness,
              ),
            ],
          ),
        ),
      ),
      'FileEditorAction' when call.str('command') != 'view' => DiffBlock(
        lines: lineDiff(call.str('old_str'), call.str('new_str').isEmpty ? call.str('file_text') : call.str('new_str')),
        maxLines: 24,
        language: languageForPath(call.str('path')),
      ),
      // A patch: its text, the way the model wrote it.
      'ApplyPatchAction' => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: theme.codeBackground, borderRadius: BorderRadius.circular(8)),
        child: Text(_clip(call.str('patch'), 60), style: mono.copyWith(color: theme.text)),
      ),
      // An MCP server's tool: its name and the arguments it gets.
      'MCPToolAction' => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: theme.codeBackground, borderRadius: BorderRadius.circular(8)),
        child: Text.rich(
          TextSpan(
            style: mono.copyWith(color: theme.text),
            children: [
              TextSpan(
                text: 'MCP ',
                style: TextStyle(color: theme.textMuted),
              ),
              TextSpan(
                text: call.toolName,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              TextSpan(text: '\n${mcpArgumentsPreview(call)}'),
            ],
          ),
        ),
      ),
      _ => Text(stepTitle(call), style: theme.type.callout.tint(theme.textMuted)),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          body,
          if (flag case final why?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  AdaptiveIcon(EveryIcon.close, size: 12, color: theme.danger),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Needs a look: this ${why.replaceFirst(RegExp(r'^an? '), '')}',
                      style: theme.type.caption.tint(theme.danger),
                    ),
                  ),
                ],
              ),
            ),
          if (risk == 'HIGH' || risk == 'MEDIUM')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  AdaptiveIcon(EveryIcon.close, size: 12, color: risk == 'HIGH' ? theme.danger : theme.textMuted),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      'The agent rates this ${risk.toLowerCase()} risk',
                      style: theme.type.caption.tint(risk == 'HIGH' ? theme.danger : theme.textMuted),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The first [max] lines of [text], with a note of how many more there are.
String _clip(String text, int max) {
  final lines = text.split('\n');
  return lines.length <= max ? text : '${lines.take(max).join('\n')}\n… ${lines.length - max} more lines';
}

/// An MCP call's arguments as indented JSON, cut to [max] characters.
String mcpArgumentsPreview(ActionCall call, {int max = 1500}) {
  final data = call.action['data'];
  final args = data is Map<String, Object?>
      ? data
      : {
          for (final e in call.action.entries)
            if (e.key != 'kind') e.key: e.value,
        };
  final text = args.isEmpty ? '{}' : const JsonEncoder.withIndent('  ').convert(args);
  return text.length <= max ? text : '${text.substring(0, max)}…';
}
