// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../domain/agent_mode.dart';
import '../../domain/mcp_servers.dart' show shellSplit;
import '../../harness/events.dart';
import '../../harness/harness.dart' show NativeMode;
import '../driver_events.dart';

// Codex app-server shapes ↔ the app's events, as pure functions. Field names
// come from the generated schema in github.com/openai/codex
// `codex-rs/app-server-protocol/schema/json/` at 3a2788e6 (ThreadItem,
// ThreadTokenUsage, AskForApproval, SandboxMode, SandboxPolicy), checked
// against `codex app-server generate-json-schema` of codex-cli 0.166.0.

/// What Codex is told for a mode: its approval policy, who answers its
/// approvals (`approvalsReviewer`), the thread's `sandbox` (a `SandboxMode`
/// string, for thread/start and thread/resume) and the turn's
/// `sandboxPolicy` (a tagged object, which holds for that turn and the ones
/// after it).
typedef CodexPolicy = ({
  String approvalPolicy,
  String approvalsReviewer,
  String sandbox,
  Map<String, Object?> sandboxPolicy,
});

/// The policy for [mode]. Codex always asks ("untrusted": every patch and
/// every command outside its known-safe reads, `core/src/safety.rs`) and
/// the app's own permission policy answers, as for the EveryAI harness: the
/// safety floor, the mode and the rules judge every call Codex asks about,
/// Full auto included (Codex's "never" would skip them, and "on-request"
/// lets the model run commands without asking).
///
/// Not covered: the reads Codex counts as known-safe (`cat`, `rg`, `sed -n`,
/// `git log`, ...) run without asking, so deny rules on reads (`Read(.env)`)
/// don't hold for Codex, and its sandboxes never limit reads.
///
/// Outside Plan the sandbox is off, like the EveryAI harness: a call the
/// app approved runs once, as approved (inside a sandbox Codex runs a
/// blocked call again without one and without asking, and a network call
/// just fails). Plan keeps a read-only sandbox with the network on, for the
/// fetches planning may approve; it isn't a backstop, since an approved
/// call that the sandbox blocks runs again without it.
///
/// The thread itself always starts and resumes read-only, in every mode,
/// and each turn/start carries the mode's sandbox. A thread/start with a cwd
/// and a writable sandbox makes app-server write `[projects."<cwd>"]
/// trust_level = "trusted"` into the user's own `~/.codex/config.toml` for a
/// git checkout or project root (app-server README, "Project trust"; seen in
/// the 2026-11-04 recordings). Codex loads a trusted project's own `.codex/`
/// config and hooks, so any repo opened here (a cloned one too) would get to
/// run them in later Codex sessions without the app's consent. Checked live
/// with codex-cli 0.166.0 (2026-11-04, signed in): a read-only thread/start
/// left config.toml as it was, the thread reply said `readOnly`, and a
/// turn/start with `dangerFullAccess` ran an approved write outside the
/// repo once, with one approval (the rollout's turn context recorded
/// `danger-full-access`); thread/resume read-only also wrote nothing.
///
/// The reviewer is always the user (here: the app). A user's
/// `approvals_reviewer = "auto_review"` in their Codex config would
/// otherwise let Codex's own reviewer answer calls the app must judge.
///
/// [native] is the preset picked by its own name ([codexModes]): `read-only`
/// adds the read-only sandbox outside Plan too; the approvals stay the same.
CodexPolicy codexPolicy(AgentMode mode, {String? native}) => (
  approvalPolicy: 'untrusted',
  approvalsReviewer: 'user',
  sandbox: 'read-only',
  sandboxPolicy: mode == AgentMode.plan || native == codexReadOnly
      ? const {'type': 'readOnly', 'networkAccess': true}
      : const {'type': 'dangerFullAccess'},
);

const codexReadOnly = 'read-only';

/// Codex's own presets under its names, each under the app's policy for it.
/// `full-access` is listed greyed, never offered (Codex's `never` would skip
/// the app's check). Codex's plan mode is the experimental collaboration
/// mode, not used here. Descriptions are ours: in both, Codex asks the app
/// about every edit and command it doesn't count as a safe read.
const codexModes = [
  NativeMode(
    id: codexReadOnly,
    label: 'Read Only',
    description: 'Asks before edits and commands; runs in a read-only sandbox',
    policy: AgentMode.ask,
  ),
  NativeMode(
    id: 'default',
    label: 'Default',
    description: 'Edits files without asking; commands still ask',
    policy: AgentMode.autoEdit,
  ),
  NativeMode(
    id: 'full-access',
    label: 'Full Access',
    policy: AgentMode.fullAuto,
    blocked: 'Not offered: Codex would run everything without asking EveryAI first.',
  ),
];

/// The preset a session in [mode] shows when none was picked by name.
String codexModeFor(AgentMode mode) =>
    mode == AgentMode.autoEdit || mode == AgentMode.fullAuto ? 'default' : codexReadOnly;

/// Whether usage under an `account/updated` `authMode` is on a plan rather
/// than billed per token: the modes Codex serves from its own backend
/// (`AuthMode::uses_codex_backend`, `app-server-protocol/src/protocol/
/// common.rs` @ rust-v0.166.0: ChatGPT, host-supplied ChatGPT tokens,
/// headers, agent identity, personal access token). An API key or Bedrock
/// is billed per token, and no mode (null: signed out) has no plan.
bool codexAuthOnPlan(Object? authMode) =>
    const {'chatgpt', 'chatgptAuthTokens', 'headers', 'agentIdentity', 'personalAccessToken'}.contains(authMode);

/// Whether a turn's `codexErrorInfo` says the account ran out: Codex folds
/// its plan's usage limit, an API key's quota or credits, a plan without
/// Codex and a workspace's credit or spend cap into `usageLimitExceeded`
/// (`CodexErr::to_codex_protocol_error`, `codex-rs/protocol/src/error.rs`
/// lines 500-541 @ rust-v0.166.0). `rateLimitExceeded` is a burst Codex
/// retries itself, and `sessionBudgetExceeded` is Codex's own budget, so
/// neither counts.
bool codexUsageLimit(Object? codexErrorInfo) => codexErrorInfo == 'usageLimitExceeded';

/// When the used-up windows of a rate-limit snapshot
/// (`account/rateLimits/updated`'s `RateLimitSnapshot`) have all reset: the
/// latest `resetsAt` (epoch seconds) of `primary`, `secondary` and
/// `individualLimit` among those used up (`usedPercent` 100, or no
/// `remainingPercent` left). Null when none is used up, or when a used-up
/// window has no time (it may last longer than the others; T3's
/// `codexUsageLimitResetAt` makes the same call).
DateTime? codexLimitResetsAt(Map<String, Object?>? snapshot) {
  bool usedUp(Object? window) => switch (window) {
    {'usedPercent': final num used} => used >= 100,
    {'remainingPercent': final num left} => left <= 0,
    _ => false,
  };
  final times = <int>[];
  for (final w in [snapshot?['primary'], snapshot?['secondary'], snapshot?['individualLimit']]) {
    if (!usedUp(w)) continue;
    if (w case {'resetsAt': final int at}) {
      times.add(at);
    } else {
      return null;
    }
  }
  if (times.isEmpty) return null;
  return DateTime.fromMillisecondsSinceEpoch(times.reduce((a, b) => a > b ? a : b) * 1000, isUtc: true);
}

/// When a usage limit lifts, from the rate-limit snapshots by `limitId`
/// ([byLimit]; recorded snapshots all had `limitId: "codex"`, and
/// `account/rateLimits/read` has `rateLimitsByLimitId`, so a plan may have
/// more than one; unverified until a paid-plan recording shows it). The
/// snapshot updated last ([last]) wins: core sends the one that ran out
/// just before the error. When it has no used-up window, the latest reset
/// among the other limits that ran out.
DateTime? codexLimitResetsAtOf(Map<String, Map<String, Object?>> byLimit, String? last) {
  if (codexLimitResetsAt(byLimit[last]) case final at?) return at;
  DateTime? latest;
  for (final e in byLimit.entries) {
    if (e.key == last) continue;
    final at = codexLimitResetsAt(e.value);
    if (at != null && (latest == null || at.isAfter(latest))) latest = at;
  }
  return latest;
}

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
/// summaries, proposed plans and compaction notes; null for anything else,
/// and for a message with no text (Codex completes empty `commentary`
/// messages before a tool call: recorded with 0.166.0).
ChatMessage? messageOf(Map<String, Object?> item) {
  final id = item['id'] as String? ?? '';
  String joined(Object? parts) => [
    for (final p in (parts as List<Object?>? ?? const []))
      if (p is String && p.isNotEmpty) p,
  ].join('\n\n');
  return switch (item['type']) {
    'agentMessage' || 'plan' => switch (item['text']) {
      final String t when t.isNotEmpty => agentMessage(id, t),
      _ => null,
    },
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
