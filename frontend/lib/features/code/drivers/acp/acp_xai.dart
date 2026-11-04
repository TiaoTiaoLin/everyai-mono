// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import '../../harness/events.dart';
import '../driver_events.dart';
import '../json_rpc.dart';
import 'acp_mapping.dart' show acpResultText, acpToolPrefix;

// Grok Build's ACP extensions (`x.ai/*`, and the older `_x.ai/*` names) as
// pure functions: the end of a prompt, background tasks, subagents that
// finish later, and its limit signals. Ported from T3 Code (MIT),
// packages/provider-grok/src/server/xaiAcpExtension.ts and status.ts. The
// shapes come from T3's code and tests, not from a live `grok agent stdio`:
// unverified, so every reader tolerates missing fields and gives null.

/// [method] without its `x.ai/` or `_x.ai/` prefix, or null for any other
/// method.
String? xaiMethod(String method) {
  for (final prefix in const ['x.ai/', '_x.ai/']) {
    if (method.startsWith(prefix) && method.length > prefix.length) return method.substring(prefix.length);
  }
  return null;
}

/// What stands in for a secret in a redacted payload.
const xaiRedactedValue = '<redacted>';

final _secretKey = RegExp(r'api[_-]?key|token|secret|password|authorization|cookie', caseSensitive: false);

/// A copy of [v] without secrets: under an `env` or `headers` key every
/// value is replaced (the names stay; a header's `name` too), and so is a
/// string under a key that names a secret. Grok's `mcp/servers_updated`
/// carries the MCP servers' environment, API keys included; every x.ai
/// payload passes here before anything reads it.
Object? xaiRedacted(Object? v) => switch (v) {
  final Map<String, Object?> m => {
    for (final MapEntry(:key, :value) in m.entries)
      key: switch (key.toLowerCase()) {
        'env' || 'headers' => _allRedacted(value),
        _ when value is String && _secretKey.hasMatch(key) => xaiRedactedValue,
        _ => xaiRedacted(value),
      },
  },
  final List<Object?> l => [for (final x in l) xaiRedacted(x)],
  _ => v,
};

Object? _allRedacted(Object? v) => switch (v) {
  final Map<String, Object?> m => {
    for (final MapEntry(:key, :value) in m.entries) key: key == 'name' && value is String ? value : _allRedacted(value),
  },
  final List<Object?> l => [for (final x in l) _allRedacted(x)],
  null => null,
  _ => xaiRedactedValue,
};

/// Whether an agent that stopped said [text] because it has no terminal to
/// open: Grok opens `/dev/tty` and exits with ENXIO when the app wasn't
/// started from one (xai-org/grok-build-plugin-cc#7).
bool isNoTtyExit(String text) =>
    RegExp(r'os error 6\b').hasMatch(text) &&
    RegExp(r'device not configured|no such device or address', caseSensitive: false).hasMatch(text);

/// Whether `grok models` printed [output] signed in: "You are logged in" is,
/// "not logged in" / "not authenticated" isn't, anything else is unknown
/// (null). It exits 0 either way.
// Ported from T3 Code (MIT), packages/provider-grok/src/server/status.ts `parseGrokModelsCliOutput`.
bool? parseGrokModelsLogin(String output) {
  if (RegExp('you are logged in', caseSensitive: false).hasMatch(output)) return true;
  if (RegExp('not authenticated|not logged in', caseSensitive: false).hasMatch(output)) return false;
  return null;
}

/// Grok's JSON-RPC error code for a spent usage limit.
const xaiRateLimitedCode = -32003;

/// Whether a failed `session/prompt` is Grok's usage limit.
bool xaiUsageLimit(JsonRpcError e) => e.code == xaiRateLimitedCode;

/// The prompt ids of Grok's own background wakes (a finished task resumes
/// the agent outside any prompt of ours).
const _wakePrefix = 'task-completed-';

/// A finished prompt: from `session/prompt_complete`, or a `turn_completed`
/// update in `session_notification` / `session/update`.
typedef XaiPromptDone = ({String? sessionId, String? promptId, String? stopReason, String? agentResult});

/// The prompt [method] (an [xaiMethod] name) with [params] says finished,
/// or null. A `turn_completed` must name its prompt; a direct
/// `prompt_complete` without one is the only prompt running. Background
/// wakes never count.
XaiPromptDone? xaiPromptDone(String method, Map<String, Object?> params) {
  final XaiPromptDone done;
  if (method == 'session/prompt_complete') {
    done = (
      sessionId: _str(params['sessionId']),
      promptId: _str(params['promptId']),
      stopReason: _str(params['stopReason']),
      agentResult: _text(params['agentResult']),
    );
  } else if (method == 'session_notification' || method == 'session/update') {
    final u = _map(params['update']);
    if (u['sessionUpdate'] != 'turn_completed') return null;
    final id = _str(u['prompt_id']) ?? _str(u['promptId']);
    if (id == null) return null;
    done = (
      sessionId: _str(params['sessionId']),
      promptId: id,
      stopReason: _str(u['stop_reason']) ?? _str(u['stopReason']),
      agentResult: _text(u['agent_result']),
    );
  } else {
    return null;
  }
  return done.promptId?.startsWith(_wakePrefix) == true ? null : done;
}

/// A background task's change: started (`task_backgrounded`) or ended
/// (`task_completed`, failed on a non-zero exit code).
typedef XaiTask = ({String id, String status, String label, bool monitor, String? output, int? exitCode});

/// The task in a `task_backgrounded` / `task_completed` notification's
/// [params] (`{sessionId, update:{task_id, tool_call_id, task_snapshot,
/// …}}`), or null without an id.
// Ported from T3 Code (MIT), xaiAcpExtension.ts `xAiBackgroundTaskLifecycleMutation`.
XaiTask? xaiTask(Map<String, Object?> params, {required bool completed}) {
  final u = _map(params['update']);
  final snap = _map(u['task_snapshot']);
  final id = _str(snap['task_id']) ?? _str(u['task_id']) ?? _str(u['tool_call_id']);
  if (id == null) return null;
  final monitorText = _str(u['monitor_description']);
  final display = _str(snap['display_command']);
  final monitor = snap['kind'] == 'monitor' || monitorText != null || (display?.startsWith('[monitor]') ?? false);
  final label =
      monitorText ??
      _str(snap['description']) ??
      _str(u['description']) ??
      display?.replaceFirst(RegExp(r'^\[monitor\]\s*'), '') ??
      _str(snap['command']) ??
      _str(u['command']) ??
      'Background task';
  final exit = snap['exit_code'];
  final code = exit is num ? exit.toInt() : null;
  return (
    id: id,
    status: !completed ? 'running' : (code != null && code != 0 ? 'failed' : 'completed'),
    label: label,
    monitor: monitor,
    output: snap['output'] is String ? snap['output']! as String : null,
    exitCode: code,
  );
}

/// The row of a background task Grok started.
ActionCall xaiTaskCall(XaiTask t, {required String id}) {
  final base = actionEvent(
    id: id,
    toolName: '${acpToolPrefix}background',
    kind: 'TerminalAction',
    args: {'command': t.label, 'background': true},
  );
  return HarnessEvent.decode({
    ...base.raw,
    'summary': t.monitor ? 'Watching: ${t.label}' : 'In the background: ${t.label}',
  }) as ActionCall;
}

/// The text that closes [t]'s row.
String xaiTaskResultText(XaiTask t) {
  final out = (t.output ?? '').trimRight();
  if (out.isNotEmpty) return out.length > 30000 ? '${out.substring(0, 30000)}\n… (cut)' : out;
  return t.status == 'failed' ? 'Failed (exit code ${t.exitCode}).' : 'Done.';
}

/// A subagent Grok started in the background has finished: its child
/// session, how (completed, failed, cancelled) and what it said.
typedef XaiSubagentDone = ({String child, String status, String? result});

/// The `subagent_finished` update in a session notification's [params],
/// or null (another update, or a status Grok doesn't define).
// Ported from T3 Code (MIT), xaiAcpExtension.ts `xAiSubagentFinishedNotice`.
XaiSubagentDone? xaiSubagentDone(Map<String, Object?> params) {
  final u = _map(params['update']);
  final child = _str(u['child_session_id']);
  if (u['sessionUpdate'] != 'subagent_finished' || child == null) return null;
  final status = u['status'];
  if (status is! String || !const {'completed', 'failed', 'cancelled'}.contains(status)) return null;
  return (child: child, status: status, result: _str(status == 'completed' ? u['output'] : u['error']));
}

/// Whether the ACP tool [call] (merged) is Grok starting a subagent: its
/// title, `variant` or `subagent_type` say so.
// Ported from T3 Code (MIT), xaiAcpExtension.ts `isXAiSpawnOrTaskTool`.
bool xaiIsSpawn(Map<String, Object?> call) {
  final title = (_str(call['title']) ?? '').toLowerCase();
  if (title == 'task' || title == 'spawn_subagent' || title.contains('spawn subagent')) return true;
  final raw = _map(call['rawInput']);
  final variant = _str(raw['variant'])?.toLowerCase();
  if (variant == 'cursortask' || variant == 'task' || variant == 'spawn_subagent') return true;
  return _str(raw['subagent_type']) != null || _str(raw['subagentType']) != null;
}

/// A Grok spawn [call] as a subagent row.
ActionCall xaiSpawnCall(Map<String, Object?> call, {required String id}) {
  final raw = _map(call['rawInput']);
  return actionEvent(
    id: id,
    toolCallId: _str(call['toolCallId']),
    toolName: '${acpToolPrefix}task',
    kind: 'TaskAction',
    args: {
      'description': _str(raw['description']) ?? _str(call['title']) ?? '',
      'prompt': _str(raw['prompt']) ?? '',
      'agent': _str(raw['subagent_type']) ?? _str(raw['subagentType']) ?? '',
      'model': ?_str(raw['model']),
    },
  );
}

/// What a finished Grok tool [call] returned, as text: its `rawOutput`'s
/// text first (Grok's `{type: "Text", text}`), else the ACP content.
String xaiOutputText(Map<String, Object?> call) {
  final out = call['rawOutput'];
  if (out is Map<String, Object?>) {
    final nested = _map(out['Result'] ?? out['result']);
    final direct =
        _str(out['text']) ??
        _str(out['output_for_prompt']) ??
        _bytes(out['output']) ??
        _str(nested['output']) ??
        _str(nested['text']) ??
        _bytes(nested['output']);
    if (direct != null) return direct;
  }
  return acpResultText(call).trim();
}

const _uuid = '[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}';
final _agentIdLine = RegExp('(?:^|\\n)\\s*Agent ID:\\s*($_uuid)\\b[^\\n]*', caseSensitive: false);
final _subagentIdLine = RegExp('(?:^|\\n)\\s*subagent_id:\\s*($_uuid)\\b[^\\n]*', caseSensitive: false);
final _taskHeader = RegExp('===\\s*Task\\s+($_uuid)\\s*===', caseSensitive: false);

/// Whether a spawn's [output] only says the subagent runs on in the
/// background (its report comes with `subagent_finished`).
// Ported from T3 Code (MIT), xaiAcpExtension.ts `isXAiAsyncSpawnAck`.
bool xaiAsyncAck(String output) =>
    RegExp('subagent started in background', caseSensitive: false).hasMatch(output) ||
    (RegExp('subagent_id:\\s*$_uuid', caseSensitive: false).hasMatch(output) &&
        RegExp('get_command_or_subagent_output', caseSensitive: false).hasMatch(output));

/// The child session a spawn's [output] names, or null.
// Ported from T3 Code (MIT), xaiAcpExtension.ts `extractXAiChildSessionId`.
String? xaiChildId(String output) => [
  for (final re in [_agentIdLine, _subagentIdLine, _taskHeader]) re.firstMatch(output)?.group(1),
].nonNulls.firstOrNull;

/// A finished spawn's report: its [output] without the id lines.
String xaiReport(String output) => output.replaceAll(_agentIdLine, '\n').replaceAll(_subagentIdLine, '\n').trim();

/// The question texts of an `ask_user_question` request [params] (bare, or
/// wrapped as `{method, params}`).
List<String> xaiQuestionTexts(Map<String, Object?> params) => [
  for (final q in (_unwrap(params)['questions'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>())
    ?_str(q['question']),
];

/// The plan an `exit_plan_mode` request [params] carries, or null.
String? xaiPlanText(Map<String, Object?> params) => _str(_unwrap(params)['planContent']);

/// The reply to `exit_plan_mode`: the app showed the plan, and the user's
/// answer comes as the next message.
// Prompt reason: without it Grok goes on to build an unapproved plan; the
// words are ours.
const xaiPlanReply = {
  'outcome': 'abandoned',
  'feedback': 'The app showed your plan to the user. Stop now and wait for their reply in the next message.',
};

/// The reply to `ask_user_question`: questions go through the app's own
/// question card (its MCP tool) instead.
const xaiQuestionReply = {'outcome': 'cancelled'};

Map<String, Object?> _unwrap(Map<String, Object?> p) =>
    p['params'] is Map<String, Object?> && p['method'] is String ? p['params']! as Map<String, Object?> : p;

String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

String? _text(Object? v) => switch (v) {
  null => null,
  final String s => _str(s),
  final other => jsonEncode(other),
};

String? _bytes(Object? v) {
  if (v is String) return _str(v);
  if (v is! List<Object?> || v.isEmpty || !v.every((b) => b is int)) return null;
  return _str(utf8.decode(v.cast<int>(), allowMalformed: true));
}

Map<String, Object?> _map(Object? v) => v is Map<String, Object?> ? v : const {};
