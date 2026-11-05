// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../domain/agent_mode.dart';
import '../../harness/events.dart';
import '../../harness/harness.dart' show NativeMode;
import '../briefing/briefing_types.dart';
import '../briefing/recipes.dart';
import '../driver.dart';
import '../driver_events.dart';
import '../driver_policy.dart' show hostRunTools;
import '../usage_limit.dart';

// Claude Code's stdio protocol (`claude -p --input-format stream-json
// --output-format stream-json`, verified on 2.1.318; recordings in
// test/fixtures/drivers/claude/), as pure functions: the command line, the
// lines we write, and its lines turned into the app's events. The control
// messages (`control_request` / `control_response`) are the ones the Agent
// SDK uses on the same pipe.

/// The PreToolUse hook every session registers in `initialize`: the CLI asks
/// us before every tool call, also those its own allow rules (or the user's
/// `~/.claude` settings) would let through, so our floor and rules see them
/// all. A failed or late answer blocks the call.
const gateCallbackId = 'everyai_gate';

Map<String, Object?> get gateHooks => {
  'PreToolUse': [
    {
      'matcher': null,
      'hookCallbackIds': [gateCallbackId],
      'timeout': 86400,
      'onFailure': 'block',
    },
  ],
};

/// Held MCP calls (question cards) wait up to 300 s on our side; Claude's
/// default MCP timeout would cut them first.
const _mcpTimeoutMs = '330000';

/// Claude's permission mode for ours. Our hook decides every call, so this
/// mostly shapes how Claude behaves; Plan is the one that matters.
String permissionModeFor(AgentMode mode) => switch (mode) {
  AgentMode.plan => 'plan',
  AgentMode.autoEdit => 'acceptEdits',
  // Bypass too: our hook allows every call, so nothing reaches Claude's own prompts.
  AgentMode.ask || AgentMode.fullAuto || AgentMode.bypass => 'default',
};

/// Claude Code's own permission modes for the picker, each under the app's
/// policy for it (our hook still decides every call). `auto` only when the
/// session's model supports it ([claudeAutoMode]); `bypassPermissions` is not
/// listed (see [claudeHiddenModes]; EveryAI's own "Bypass EveryAI checks" sits
/// under the list); `dontAsk` and `manual` are left out (our hook's answers
/// would undo `dontAsk`).
List<NativeMode> claudeModes({required bool autoMode}) => [
  const NativeMode(
    id: 'default',
    label: 'Default',
    description: 'Asks before edits and commands',
    policy: AgentMode.ask,
  ),
  const NativeMode(
    id: 'acceptEdits',
    label: 'Accept edits',
    description: 'Edits files without asking; commands still ask',
    policy: AgentMode.autoEdit,
  ),
  const NativeMode(
    id: 'plan',
    label: 'Plan mode',
    description: 'Reads and plans; changes nothing until you approve the plan',
    policy: AgentMode.plan,
  ),
  if (autoMode)
    const NativeMode(
      id: 'auto',
      label: 'Auto mode',
      description: "Works without asking; EveryAI's safety check still runs before each call",
      policy: AgentMode.fullAuto,
    ),
];

/// Claude Code modes the picker doesn't show and EveryAI never switches to, by id → label. If Claude reports one
/// anyway, the session is set back.
const claudeHiddenModes = {'bypassPermissions': 'Bypass permissions'};

/// Whether [model] (the session's, as the app names it) supports Claude's
/// `auto` mode, from the `initialize` reply's `models` (`supportsAutoMode`).
bool claudeAutoMode(Map<String, Object?> initReply, String model) {
  final want = claudeModelArg(model) ?? 'default';
  for (final m in initReply['models'] as List<Object?>? ?? const []) {
    if (m case {'value': final String v} when v == want || m['resolvedModel'] == want) {
      return m['supportsAutoMode'] == true;
    }
  }
  return false;
}

/// The `--model` value for [model], or null for Claude's own default. Takes
/// Claude's aliases and ids as they are, and an OpenRouter id
/// (`anthropic/claude-sonnet-5.5`) as Claude's (`claude-sonnet-5-5`).
String? claudeModelArg(String model) {
  final m = model.trim();
  if (m.isEmpty || m == 'default') return null;
  return m.startsWith('anthropic/') ? m.substring('anthropic/'.length).replaceAll('.', '-') : m;
}

/// The briefing as Claude takes it ([claudeCode]); without a skill folder
/// only the MCP server and the settings apply.
Delivery claudeDelivery(DriverBriefing b, {String sessionText = '', Set<String> skillsOff = const {}}) {
  final input = (
    mcpUrl: Uri.parse(b.mcpUrl),
    mcpToken: b.mcpToken,
    skillDir: b.skillDir ?? '',
    sessionText: sessionText,
  );
  if (b.skillDir != null) return claudeCode(input, skillsOff: skillsOff);
  final all = claudeCode(input, grantSkillAccess: false, skillsOff: skillsOff);
  return (
    args: [
      for (var i = 0; i + 1 < all.args.length; i += 2)
        if (all.args[i] == '--mcp-config' || all.args[i] == '--settings') ...[all.args[i], all.args[i + 1]],
    ],
    env: all.env,
    initRequests: all.initRequests,
    instructions: null,
    firstPrompt: null,
  );
}

/// Only the user's own settings (`~/.claude`): a project's
/// `.claude/settings*.json` would run its hooks, `apiKeyHelper`, env and
/// `.mcp.json` servers before our hook sees anything (`-p` skips Claude's
/// trust prompt), so a cloned repo could run code just by being opened.
const _userSettingsOnly = ['--setting-sources', 'user'];

/// How to start one session's process. [resume] continues the conversation
/// [sessionId] (it has had a message); otherwise it starts under that id.
/// Never `--dangerously-skip-permissions`: every call comes to our hook.
({List<String> args, Map<String, String> env}) claudeLaunch({
  required String sessionId,
  required bool resume,
  required AgentMode mode,
  String? nativeMode,
  String model = '',
  String? effort,
  Delivery? briefing,
  Set<String> skillsOff = const {},
}) {
  final m = claudeModelArg(model);
  return (
    args: [
      '-p',
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--verbose',
      '--include-partial-messages',
      // Permission prompts come back on this pipe as `can_use_tool`.
      '--permission-prompt-tool',
      'stdio',
      '--permission-mode',
      nativeMode ?? permissionModeFor(mode),
      ..._userSettingsOnly,
      ...resume ? ['--resume', sessionId] : ['--session-id', sessionId],
      if (m != null) ...['--model', m],
      if (effort != null && effort.isNotEmpty) ...['--effort', effort],
      // Briefed sessions ask the user through our question cards.
      if (briefing != null) ...['--disallowedTools', 'AskUserQuestion'],
      ...?briefing?.args,
      if (briefing == null) ...['--settings', claudeSettingsJson(skillsOff: skillsOff)],
    ],
    env: {...?briefing?.env, 'MCP_TOOL_TIMEOUT': _mcpTimeoutMs, 'CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT': _mcpTimeoutMs},
  );
}

/// A `/btw` side question's process: a fork of conversation [sessionId] (a
/// fresh one before its first message ran) that isn't saved, with only the
/// read-only tools and none of the user's MCP servers.
List<String> claudeAsideArgs({
  required String sessionId,
  required bool resume,
  String model = '',
  String? effort,
  Set<String> skillsOff = const {},
}) {
  final m = claudeModelArg(model);
  return [
    '-p',
    '--input-format',
    'stream-json',
    '--output-format',
    'stream-json',
    '--verbose',
    '--strict-mcp-config',
    '--no-session-persistence',
    ..._userSettingsOnly,
    if (resume) ...['--resume', sessionId, '--fork-session'],
    '--tools',
    'Read,Grep,Glob',
    '--permission-mode',
    'default',
    if (m != null) ...['--model', m],
    if (effort != null && effort.isNotEmpty) ...['--effort', effort],
    '--settings',
    claudeSettingsJson(skillsOff: skillsOff),
  ];
}

/// Claude Code's own `/usage`, run headless: a local command (no model call, nothing spent) that answers with the
/// plan's windows ("Current week (all models): 35% used · resets …") and what used them. Nothing is saved.
const claudeUsageArgs = [
  '-p',
  '/usage',
  '--output-format',
  'json',
  '--no-session-persistence',
  '--strict-mcp-config',
  ..._userSettingsOnly,
];

/// The text of `/usage`'s reply ([claudeUsageArgs]), or null when it gave none or an error.
String? claudeUsageText(Object? reply) {
  if (reply is! Map<String, Object?> || reply['is_error'] == true) return null;
  final text = switch (reply['result']) {
    final String t => t.trim(),
    _ => '',
  };
  return text.isEmpty ? null : text;
}

/// The `/btw` message the side process gets.
/// Prompt reason: the fork must answer, not carry on with the session's task.
String asideMessage(String question) =>
    '<side-question>The user asks this off to the side while you work. Your main conversation never sees this reply, '
    'so answer only the question, briefly, from what you know of the session (you may read files). Don\'t carry on '
    'with the task or change anything.</side-question>\n\n${question.trim()}';

/// The process `models()` asks once: no session saved, none of the user's
/// MCP servers started, no model call.
const claudeProbeArgs = [
  '-p',
  '--input-format',
  'stream-json',
  '--output-format',
  'stream-json',
  '--verbose',
  '--strict-mcp-config',
  '--no-session-persistence',
  ..._userSettingsOnly,
];

Map<String, Object?> controlRequest(String id, Map<String, Object?> request) => {
  'type': 'control_request',
  'request_id': id,
  'request': request,
};

Map<String, Object?> controlResponse(String id, Map<String, Object?> response) => {
  'type': 'control_response',
  'response': {'subtype': 'success', 'request_id': id, 'response': response},
};

Map<String, Object?> controlError(String id, String error) => {
  'type': 'control_response',
  'response': {'subtype': 'error', 'request_id': id, 'error': error},
};

/// A user message: [text], then each picture of [images] (`data:` URLs) as a
/// base64 image block.
Map<String, Object?> userLine(String text, {List<String> images = const []}) => {
  'type': 'user',
  'message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
      for (final url in images)
        if (_dataUrl.firstMatch(url) case final m?)
          {
            'type': 'image',
            'source': {'type': 'base64', 'media_type': m[1], 'data': m[2]},
          },
    ],
  },
  'parent_tool_use_id': null,
  'session_id': '',
};

final _dataUrl = RegExp(r'^data:([^;,]+);base64,(.*)$', dotAll: true);

/// The answer to a held call: a hook decision for `hook_callback`, a
/// behaviour for `can_use_tool` (which takes the call's [input] back when
/// allowed).
Map<String, Object?> approvalAnswer({
  required bool hook,
  required bool accept,
  String? reason,
  Map<String, Object?> input = const {},
}) {
  final why = reason == null || reason.isEmpty ? refusedByUser : reason;
  if (hook) {
    return {
      'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': accept ? 'allow' : 'deny',
        'permissionDecisionReason': accept ? 'Allowed in EveryAI.' : why,
      },
    };
  }
  return accept ? {'behavior': 'allow', 'updatedInput': input} : {'behavior': 'deny', 'message': why};
}

const refusedByUser = 'The user refused this.';

/// What [ClaudeSession.resume] sends to run a stopped or failed turn on.
const continueMessage = 'Carry on from where you stopped.';

/// Tools that only touch Claude's own state (or, in a [briefed] session,
/// reach the user through our MCP server), which the session allows itself:
/// they still show. Without a briefing an `everyai` MCP server isn't ours.
/// Our tools that run a command ([hostRunTools]) ask like any other.
bool answeredBySession(String toolName, {required bool briefed}) =>
    (briefed &&
        toolName.startsWith('mcp__${everyaiServerName}__') &&
        !hostRunTools.contains(toolName.substring('mcp__${everyaiServerName}__'.length))) ||
    _internalTools.contains(toolName);

const _internalTools = {
  'ToolSearch',
  'Skill',
  'Task',
  'Agent',
  'TodoWrite',
  'TaskCreate',
  'TaskUpdate',
  'TaskList',
  'TaskGet',
  'TaskStop',
  'EnterPlanMode',
};

/// A Claude tool call as one of the app's action kinds (see
/// `HarnessDriver`), with the fields the policy reads; tools it can't judge
/// keep their input as `ClaudeToolAction` and always ask the user.
({String kind, Map<String, Object?> args}) claudeAction(String name, Map<String, Object?> input) {
  String s(String key) => input[key] as String? ?? '';
  if (name.startsWith('mcp__')) return (kind: 'MCPToolAction', args: input);
  return switch (name) {
    'Bash' => (kind: 'TerminalAction', args: {'command': s('command')}),
    'Edit' => (
      kind: 'FileEditorAction',
      args: {'command': 'str_replace', 'path': s('file_path'), 'old_str': s('old_string'), 'new_str': s('new_string')},
    ),
    'MultiEdit' => (kind: 'FileEditorAction', args: {'command': 'str_replace', 'path': s('file_path')}),
    'Write' => (
      kind: 'FileEditorAction',
      args: {'command': 'create', 'path': s('file_path'), 'file_text': s('content')},
    ),
    'NotebookEdit' => (kind: 'FileEditorAction', args: {'command': 'edit', 'path': s('notebook_path')}),
    'Read' => (kind: 'ReadFileAction', args: {'path': s('file_path')}),
    'Grep' => (kind: 'GrepAction', args: {'pattern': s('pattern'), 'path': s('path')}),
    'Glob' => (kind: 'GlobAction', args: {'pattern': s('pattern'), 'path': s('path')}),
    // Not the EveryAI harness's web tools (which go through the backend's
    // safe fetcher and the secret scrubber): a URL can carry data out, so the
    // user approves each one.
    'WebFetch' => (kind: 'ClaudeWebFetchAction', args: {'url': s('url')}),
    'WebSearch' => (kind: 'ClaudeWebSearchAction', args: {'query': s('query')}),
    // The plan the agent proposes; the approval decides, the card shows it.
    'ExitPlanMode' => (kind: 'ProposedPlanAction', args: {'body': s('plan')}),
    'TodoWrite' => (
      kind: 'TaskTrackerAction',
      args: {
        'command': 'plan',
        'task_list': [
          for (final t in input['todos'] as List<Object?>? ?? const [])
            if (t is Map<String, Object?>)
              {
                'title': t['content'] as String? ?? '',
                'status': switch (t['status']) {
                  'completed' => 'done',
                  'in_progress' => 'in_progress',
                  _ => 'todo',
                },
                if (t['activeForm'] is String) 'active': t['activeForm'],
              },
        ],
      },
    ),
    _ => (kind: 'ClaudeToolAction', args: input),
  };
}

/// A message the user sent (the CLI doesn't echo ours by default).
ChatMessage userMessage(String id, String text) => _message(id, user: true, text: text);

/// What the agent said, or thought ([reasoning]).
ChatMessage agentMessage(String id, String text, {String reasoning = ''}) =>
    _message(id, user: false, text: text, reasoning: reasoning);

ChatMessage _message(String id, {required bool user, required String text, String reasoning = ''}) =>
    HarnessEvent.decode({
      'kind': 'MessageEvent',
      'id': id,
      'source': user ? 'user' : 'agent',
      'llm_message': {
        'role': user ? 'user' : 'assistant',
        'content': [
          if (text.isNotEmpty) {'type': 'text', 'text': text},
        ],
        if (reasoning.isNotEmpty) 'reasoning_content': reasoning,
      },
    }) as ChatMessage;

StreamDelta _delta({String content = '', String reasoning = ''}) =>
    HarnessEvent.decode({'kind': 'StreamingDeltaEvent', 'content': content, 'reasoning_content': reasoning})
        as StreamDelta;

/// Turns the CLI's stdout lines (not the control messages) into events. It
/// remembers what the lines need across a session: tool names by call id,
/// the calls we refused, and where the credentials come from.
final class ClaudeDecoder {
  /// From `system/init`: `none` on a subscription login, else the key's
  /// source (`ANTHROPIC_API_KEY`, `apiKeyHelper`, …).
  String? apiKeySource;

  /// Calls we refused, with the reason: their results show as refusals.
  final refused = <String, String>{};

  final _tools = <String, String>{};
  var _n = 0;

  /// Set by an API-error line that says the plan or key ran out; the turn's
  /// failed `result` then becomes a usage limit.
  ({DateTime? resetsAt})? _limit;

  /// Whether the call [id] has been shown.
  bool knows(String id) => _tools.containsKey(id);

  /// [name]'s call [id] with [input], as an [ActionCall].
  ActionCall action(String id, String name, Map<String, Object?> input) {
    _tools[id] = name;
    final a = claudeAction(name, input);
    return actionEvent(id: id, toolName: name, kind: a.kind, args: a.args);
  }

  List<HarnessEvent> decode(Map<String, Object?> line) => switch (line['type']) {
    'system' => _system(line),
    'stream_event' => _stream(line),
    'assistant' => _assistant(line),
    'user' => _user(line),
    'result' => _result(line),
    'rate_limit_event' => [?planLimitsOf(line['rate_limit_info'], id: _id(line))],
    _ => const [],
  };

  String _id(Map<String, Object?> line) => line['uuid'] as String? ?? 'claude-${++_n}';

  List<HarnessEvent> _system(Map<String, Object?> line) {
    if (line['subtype'] == 'init') apiKeySource = line['apiKeySource'] as String?;
    return const [];
  }

  List<HarnessEvent> _stream(Map<String, Object?> line) {
    final delta = switch (line['event']) {
      {'type': 'content_block_delta', 'delta': final Map<String, Object?> d} => d,
      _ => null,
    };
    return switch (delta) {
      {'type': 'text_delta', 'text': final String t} when t.isNotEmpty => [_delta(content: t)],
      {'type': 'thinking_delta', 'thinking': final String t} when t.isNotEmpty => [_delta(reasoning: t)],
      _ => const [],
    };
  }

  List<HarnessEvent> _assistant(Map<String, Object?> line) {
    // Only the main thread's last frame before the result counts: a
    // subagent's error frame (parent_tool_use_id set) doesn't end the turn,
    // and a frame Claude Code recovered from is followed by a normal one.
    if (line['parent_tool_use_id'] == null) _limit = line['is_api_error_message'] == true ? _limitOf(line) : null;
    final blocks = _blocks(line);
    final id = _id(line);
    final out = <HarnessEvent>[];
    for (final (i, b) in blocks.indexed) {
      final bid = blocks.length == 1 ? id : '$id:$i';
      switch (b) {
        case {'type': 'text', 'text': final String t} when t.trim().isNotEmpty:
          out.add(agentMessage(bid, t));
        case {'type': 'thinking', 'thinking': final String t} when t.trim().isNotEmpty:
          out.add(agentMessage(bid, '', reasoning: t));
        case {'type': 'tool_use', 'id': final String callId, 'name': final String name}:
          out.add(action(callId, name, b['input'] as Map<String, Object?>? ?? const {}));
      }
    }
    return out;
  }

  List<HarnessEvent> _user(Map<String, Object?> line) => [
    // Text from the "user" is our own message echoed or Claude's interruption note.
    for (final b in _blocks(line))
      if (b case {'type': 'tool_result', 'tool_use_id': final String callId}) _toolResult(callId, b),
  ];

  HarnessEvent _toolResult(String callId, Map<String, Object?> b) {
    final name = _tools[callId] ?? '';
    if (refused[callId] case final reason?) {
      return HarnessEvent.decode({
        'kind': 'UserRejectObservation',
        'id': 'r:$callId',
        'action_id': callId,
        'tool_name': name,
        'tool_call_id': callId,
        'rejection_reason': reason,
      });
    }
    return resultEvent(
      id: 'r:$callId',
      actionId: callId,
      toolName: name,
      text: _text(b['content']),
      isError: b['is_error'] == true,
    );
  }

  List<HarnessEvent> _result(Map<String, Object?> line) {
    final id = _id(line);
    final out = <HarnessEvent>[?usageOf(line, apiKeySource: apiKeySource, id: id)];
    final aborted = (line['terminal_reason'] as String? ?? '').startsWith('aborted');
    if (aborted) {
      out.add(stateEvent('$id:state', ExecutionStatus.paused));
    } else if (line['subtype'] == 'success' && line['is_error'] != true) {
      out.add(stateEvent('$id:state', ExecutionStatus.finished));
    } else {
      out
        ..add(switch (_limit) {
          (:final resetsAt) => usageLimitEvent('$id:error', _failure(line), resetsAt: resetsAt),
          null => HarnessEvent.decode({'kind': 'ConversationErrorEvent', 'id': '$id:error', 'detail': _failure(line)}),
        })
        ..add(stateEvent('$id:state', ExecutionStatus.error));
    }
    _limit = null;
    return out;
  }

  /// Claude Code's own verdict on an API error (2.1.318): `api_error`
  /// `usage_limit_reached` / `model_requires_usage_credits` (a plan limit,
  /// with `rate_limit_info.resetsAt` in unix seconds) or `error:
  /// billing_error` (an API key out of credit). `error: rate_limit` without
  /// `api_error` is a rate limit Claude Code already retried: not a limit.
  static ({DateTime? resetsAt})? _limitOf(Map<String, Object?> line) {
    final api = line['api_error'];
    if (api != 'usage_limit_reached' && api != 'model_requires_usage_credits' && line['error'] != 'billing_error') {
      return null;
    }
    final info = (line['api_error_params'] as Map<String, Object?>?)?['rate_limit_info'] as Map<String, Object?>?;
    return (
      resetsAt: switch (info?['resetsAt']) {
        final num s => DateTime.fromMillisecondsSinceEpoch((s * 1000).round(), isUtc: true),
        _ => null,
      },
    );
  }

  static String _failure(Map<String, Object?> line) {
    final errors = [for (final e in line['errors'] as List<Object?>? ?? const []) '$e'];
    if (errors.isNotEmpty) return errors.join('\n');
    if (line['result'] case final String r when r.isNotEmpty) return r;
    if (line['api_error_status'] case final Object s) return 'Claude Code stopped: API error $s.';
    return 'Claude Code stopped with an error.';
  }

  static List<Map<String, Object?>> _blocks(Map<String, Object?> line) => [
    for (final b in (line['message'] as Map<String, Object?>?)?['content'] as List<Object?>? ?? const [])
      if (b is Map<String, Object?>) b,
  ];

  static String _text(Object? content) => switch (content) {
    final String s => s,
    final List<Object?> parts => [
      for (final p in parts)
        if (p case {'type': 'text', 'text': final String t}) t,
    ].join('\n'),
    _ => '',
  };
}

/// What a turn used, from its `result` line, or null when it reports none
/// (an interrupted turn). `usage` covers the turn's calls; its last
/// `iterations` entry is the latest call, so how full the window is.
/// `total_cost_usd` adds up over the whole conversation (earlier processes
/// too), so the cost is this turn's `model_usage_since_last_result`. On the
/// user's plan when no API key is in use (`apiKeySource: none`) and every
/// model ran on Anthropic's own service (not Bedrock or Vertex).
UsageReport? usageOf(Map<String, Object?> result, {required String? apiKeySource, required String id}) {
  int n(Map<String, Object?>? m, String key) => (m?[key] as num?)?.toInt() ?? 0;
  int prompt(Map<String, Object?>? m) =>
      n(m, 'input_tokens') + n(m, 'cache_read_input_tokens') + n(m, 'cache_creation_input_tokens');
  final usage = result['usage'] as Map<String, Object?>?;
  final input = prompt(usage);
  final output = n(usage, 'output_tokens');
  if (input + output == 0) return null;
  final last = (usage?['iterations'] as List<Object?>?)?.whereType<Map<String, Object?>>().lastOrNull;
  final models = [
    for (final m in (result['model_usage_since_last_result'] as Map<String, Object?>? ?? const {}).values)
      if (m is Map<String, Object?>) m,
  ];
  final cost = models.fold<double>(0, (sum, m) => sum + ((m['costUSD'] as num?)?.toDouble() ?? 0));
  return UsageReport.of(
    id: id,
    input: input,
    output: output,
    cached: n(usage, 'cache_read_input_tokens'),
    contextTokens: last == null ? null : prompt(last),
    costMicros: models.isEmpty ? null : (cost * 1e6).round(),
    onPlan: apiKeySource == 'none' && models.isNotEmpty && models.every((m) => m['provider'] == 'firstParty'),
  );
}

/// How much of the plan's limits a `rate_limit_event`'s `rate_limit_info`
/// says is used, or null when it gives no number. Each `unifiedWindows`
/// entry is one window (`utilization` 0 to 1, `resetsAt` in epoch seconds);
/// without them the top-level `rateLimitType` window. Recorded: only
/// `status: allowed` with `seven_day`; `allowed_warning` (Claude Code's own
/// "close to the limit") and `five_hour` aren't, so the shape is read
/// loosely. A `utilization` over 1 is read as a percent.
PlanLimits? planLimitsOf(Object? info, {required String id}) {
  if (info is! Map<String, Object?>) return null;
  int? minutesOf(String name) => switch (name) {
    'five_hour' => 300,
    _ when name.startsWith('seven_day') => 10080,
    _ => null,
  };
  PlanWindow? window(String name, Object? w) {
    if (w is! Map<String, Object?>) return null;
    final raw = (w['utilization'] as num?)?.toDouble();
    if (raw == null) return null;
    final at = w['resetsAt'] as num?;
    return PlanWindow(
      name: name,
      used: (raw > 1 ? raw / 100 : raw).clamp(0, 1).toDouble(),
      resetsAt: at == null ? null : DateTime.fromMillisecondsSinceEpoch((at * 1000).round(), isUtc: true),
      minutes: minutesOf(name),
    );
  }

  final windows = [
    if (info['unifiedWindows'] case final Map<String, Object?> all)
      for (final e in all.entries) ?window(e.key, e.value)
    else if (info['rateLimitType'] case final String type)
      ?window(type, info),
  ];
  if (windows.isEmpty) return null;
  final warning =
      info['status'] == 'allowed_warning' ||
      (info['unifiedWindows'] is Map<String, Object?> &&
          (info['unifiedWindows']! as Map<String, Object?>).values.any(
            (w) => w is Map<String, Object?> && w['status'] == 'allowed_warning',
          ));
  return PlanLimits.of(id: id, windows: windows, warning: warning);
}

/// The models `initialize` lists, or null when the reply has none.
List<DriverModel>? modelsOf(Map<String, Object?> initialized) {
  final list = initialized['models'];
  if (list is! List<Object?> || list.isEmpty) return null;
  return [
    for (final m in list)
      if (m case {'value': final String id})
        DriverModel(
          id: id,
          label: (m as Map)['displayName'] as String? ?? id,
          isDefault: id == 'default',
          efforts: [for (final e in m['supportedEffortLevels'] as List<Object?>? ?? const []) '$e'],
        ),
  ];
}

/// Claude's aliases, when asking the CLI failed.
const fallbackModels = [
  DriverModel(id: 'default', label: 'Default', isDefault: true),
  DriverModel(id: 'opus', label: 'Opus'),
  DriverModel(id: 'sonnet', label: 'Sonnet'),
  DriverModel(id: 'haiku', label: 'Haiku'),
];
