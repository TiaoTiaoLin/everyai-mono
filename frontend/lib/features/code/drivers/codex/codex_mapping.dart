// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../domain/agent_mode.dart';
import '../../domain/mcp_servers.dart' show shellSplit;
import '../../harness/events.dart';
import '../driver_events.dart';

// Codex app-server shapes ↔ the app's events, as pure functions. Field names
// come from the generated schema in github.com/openai/codex
// `codex-rs/app-server-protocol/schema/json/` at 3a2788e6 (ThreadItem,
// ThreadTokenUsage, AskForApproval, SandboxMode, SandboxPolicy).

/// What Codex is told for a mode: its approval policy, the thread's
/// `sandbox` (a `SandboxMode` string) and the turn's `sandboxPolicy` (the
/// same as a tagged object).
typedef CodexPolicy = ({String approvalPolicy, String sandbox, Map<String, Object?> sandboxPolicy});

/// The policy for [mode]. Codex always asks ("untrusted": every patch and
/// every command outside its known-safe reads, `core/src/safety.rs`) and
/// the app's own permission policy answers, as for the EveryAI harness: the
/// safety floor and deny rules hold in every mode, Full auto included
/// (Codex's "never" would skip them, and "on-request" lets the model run
/// commands without asking). Plan also gets a read-only sandbox; the rest
/// write inside the workspace (the session's worktree).
CodexPolicy codexPolicy(AgentMode mode) => mode == AgentMode.plan
    ? (approvalPolicy: 'untrusted', sandbox: 'read-only', sandboxPolicy: const {'type': 'readOnly'})
    : (approvalPolicy: 'untrusted', sandbox: 'workspace-write', sandboxPolicy: const {'type': 'workspaceWrite'});

/// Codex's reasoning effort for ours: it has no `max`, its top is `xhigh`.
String? codexEffort(String? effort) => effort == 'max' ? 'xhigh' : effort;

/// The script inside `bash -lc '<script>'` (Codex runs commands through
/// the user's shell), so the permission rules read the command itself.
/// Anything else is left as it is; the classifier then just asks.
String unwrapCommand(String command) {
  final words = shellSplit(command);
  if (words.length != 3) return command;
  final shell = words[0].split('/').last;
  if (!const {'sh', 'bash', 'zsh'}.contains(shell) || !const {'-c', '-lc'}.contains(words[1])) return command;
  return words[2].trim().isEmpty ? command : words[2];
}

/// The tool call a started Codex item is, or null for items that aren't
/// calls (messages, reasoning, ...). Paths are made absolute against [cwd].
ActionCall? callOf(Map<String, Object?> item, String cwd) {
  final id = item['id'] as String? ?? '';
  if (id.isEmpty) return null;
  switch (item['type']) {
    case 'commandExecution':
      final command = item['command'] as String? ?? '';
      return actionEvent(
        id: id,
        toolName: 'shell',
        kind: 'TerminalAction',
        args: {'command': unwrapCommand(command), 'cwd': item['cwd'] as String? ?? cwd},
      );
    case 'fileChange':
      final files = <Map<String, Object?>>[];
      final diffs = <String>[];
      for (final c in (item['changes'] as List<Object?>? ?? const [])) {
        if (c is! Map<String, Object?>) continue;
        final path = _absolute(cwd, c['path'] as String? ?? '');
        final kind = c['kind'] as Map<String, Object?>? ?? const {};
        final moveTo = kind['move_path'] as String?;
        files.add({
          'path': path,
          'op': moveTo != null && moveTo.isNotEmpty ? 'move' : kind['type'] as String? ?? 'update',
          if (moveTo != null && moveTo.isNotEmpty) 'to': _absolute(cwd, moveTo),
        });
        if (c['diff'] case final String d when d.isNotEmpty) diffs.add(d);
      }
      final paths = [
        for (final f in files) ...[f['path']! as String, ?f['to'] as String?],
      ];
      return actionEvent(
        id: id,
        toolName: 'apply_patch',
        kind: 'ApplyPatchAction',
        args: {'files': files, 'paths': paths, if (paths.isNotEmpty) 'path': paths.first, 'patch': diffs.join('\n')},
      );
    case 'mcpToolCall':
      // `server__tool`, so a tool of ours can't pass for one of the app's
      // client tools.
      return actionEvent(
        id: id,
        toolName: '${item['server']}__${item['tool']}',
        kind: 'MCPToolAction',
        args: {...?item['arguments'] as Map<String, Object?>?},
      );
    case 'webSearch':
      return actionEvent(
        id: id,
        toolName: 'web_search',
        kind: 'WebSearchAction',
        args: {'query': item['query'] as String? ?? ''},
      );
    case 'imageView':
      return actionEvent(
        id: id,
        toolName: 'view_image',
        kind: 'ReadFileAction',
        args: {'path': _absolute(cwd, item['path'] as String? ?? '')},
      );
  }
  return null;
}

/// What a completed call item returned; null while it is still running.
HarnessEvent? resultOf(Map<String, Object?> item, ActionCall call) {
  final status = item['status'] as String? ?? '';
  if (status == 'inProgress') return null;
  if (status == 'declined') return rejectedResult(call, 'Refused.');
  final failed = status == 'failed';
  final text = switch (item['type']) {
    'commandExecution' => [
      if (item['aggregatedOutput'] case final String out when out.isNotEmpty) out.trimRight(),
      if (item['exitCode'] case final num code) 'Exit code ${code.toInt()}',
    ].join('\n'),
    'fileChange' => failed ? 'The patch did not apply.' : 'Applied.',
    'mcpToolCall' => switch (item) {
      {'error': {'message': final String m}} => m,
      {'result': {'content': final List<Object?> parts}} => [
        for (final p in parts)
          if (p case {'text': final String t}) t,
      ].join('\n'),
      _ => '',
    },
    _ => '',
  };
  final isError = failed || item['error'] is Map;
  return resultEvent(
    id: '${call.id}-result',
    actionId: call.id,
    toolName: call.toolName,
    text: text.isEmpty ? (isError ? 'Failed.' : 'Done.') : text,
    isError: isError,
  );
}

/// A refusal of [call], as the transcript shows it.
ToolResult rejectedResult(ActionCall call, String reason) => HarnessEvent.decode({
  'kind': 'UserRejectObservation',
  'id': '${call.id}-result',
  'source': 'environment',
  'action_id': call.id,
  'tool_name': call.toolName,
  'tool_call_id': call.toolCallId,
  'rejection_reason': reason,
}) as ToolResult;

/// The agent's text a completed item carries: its messages, reasoning
/// summaries, proposed plans and compaction notes; null for anything else.
ChatMessage? messageOf(Map<String, Object?> item) {
  final id = item['id'] as String? ?? '';
  String joined(Object? parts) => [
    for (final p in (parts as List<Object?>? ?? const []))
      if (p is String && p.isNotEmpty) p,
  ].join('\n\n');
  return switch (item['type']) {
    'agentMessage' || 'plan' => agentMessage(id, item['text'] as String? ?? ''),
    'reasoning' => switch (joined(item['summary'])) {
      '' => switch (joined(item['content'])) {
        '' => null,
        final r => agentMessage(id, '', reasoning: r),
      },
      final r => agentMessage(id, '', reasoning: r),
    },
    'contextCompaction' => agentMessage(id, 'Codex compacted the conversation.'),
    _ => null,
  };
}

ChatMessage agentMessage(String id, String text, {String reasoning = ''}) => HarnessEvent.decode({
  'kind': 'MessageEvent',
  'id': id,
  'source': 'agent',
  'llm_message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
    if (reasoning.isNotEmpty) 'reasoning_content': reasoning,
  },
}) as ChatMessage;

ChatMessage userMessage(String id, String text) => HarnessEvent.decode({
  'kind': 'MessageEvent',
  'id': id,
  'source': 'user',
  'llm_message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
}) as ChatMessage;

/// A `turn/plan/updated` as a task-list call ([id] stable per update).
ActionCall planCall(String id, Map<String, Object?> params) => actionEvent(
  id: id,
  toolName: 'update_plan',
  kind: 'TaskTrackerAction',
  args: {
    'task_list': [
      for (final s in (params['plan'] as List<Object?>? ?? const []))
        if (s is Map<String, Object?>)
          {
            'title': s['step'] as String? ?? '',
            'status': switch (s['status']) {
              'completed' => 'done',
              'inProgress' => 'in_progress',
              _ => 'todo',
            },
          },
    ],
  },
);

/// Codex's running token totals (`TokenUsageBreakdown`).
typedef CodexTokens = ({int input, int cached, int output, int total});

CodexTokens? tokensOf(Object? breakdown) => switch (breakdown) {
  final Map<String, Object?> b => (
    input: (b['inputTokens'] as num?)?.toInt() ?? 0,
    cached: (b['cachedInputTokens'] as num?)?.toInt() ?? 0,
    output: (b['outputTokens'] as num?)?.toInt() ?? 0,
    total: (b['totalTokens'] as num?)?.toInt() ?? 0,
  ),
  _ => null,
};

/// What a `thread/tokenUsage/updated` adds since [previous] (the totals of
/// the last one): the change in totals, or Codex's `last` call when there
/// is no earlier total or a counter went down (T3 Code's rule). Codex's
/// input counts its cached tokens, as ours does; output counts reasoning.
/// The context in use is the last call's total (Codex's own reading). Null
/// when nothing was used.
UsageReport? usageDelta(
  CodexTokens? previous,
  CodexTokens total,
  CodexTokens? last, {
  required String turnId,
  required bool onPlan,
}) {
  final shrank =
      previous != null &&
      (total.input < previous.input ||
          total.cached < previous.cached ||
          total.output < previous.output ||
          total.total < previous.total);
  final CodexTokens d;
  if (previous == null || shrank) {
    if (last == null) return null;
    d = last;
  } else {
    d = (
      input: total.input - previous.input,
      cached: total.cached - previous.cached,
      output: total.output - previous.output,
      total: total.total - previous.total,
    );
  }
  if (d.input == 0 && d.output == 0) return null;
  return UsageReport.of(
    id: 'usage-$turnId-${total.total}',
    input: d.input,
    output: d.output,
    cached: d.cached,
    contextTokens: last?.total,
    onPlan: onPlan,
  );
}

String _absolute(String cwd, String path) {
  if (path.isEmpty || path.startsWith('/')) return path;
  final root = cwd.endsWith('/') ? cwd.substring(0, cwd.length - 1) : cwd;
  return '$root/${path.startsWith('./') ? path.substring(2) : path}';
}
