// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../domain/agent_mode.dart';
import '../../harness/events.dart';
import '../briefing/briefing_types.dart';
import '../briefing/recipes.dart';
import '../driver.dart';
import '../driver_events.dart';

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
  AgentMode.ask || AgentMode.fullAuto => 'default',
};

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
Delivery claudeDelivery(DriverBriefing b, {String sessionText = ''}) {
  final input = (
    mcpUrl: Uri.parse(b.mcpUrl),
    mcpToken: b.mcpToken,
    skillDir: b.skillDir ?? '',
    sessionText: sessionText,
  );
  if (b.skillDir != null) return claudeCode(input);
  final all = claudeCode(input, grantSkillAccess: false);
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

/// How to start one session's process. [resume] continues the conversation
/// [sessionId] (it has had a message); otherwise it starts under that id.
/// Never `--dangerously-skip-permissions`: every call comes to our hook.
({List<String> args, Map<String, String> env}) claudeLaunch({
  required String sessionId,
  required bool resume,
  required AgentMode mode,
  String model = '',
  String? effort,
  Delivery? briefing,
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
      permissionModeFor(mode),
      ...resume ? ['--resume', sessionId] : ['--session-id', sessionId],
      if (m != null) ...['--model', m],
      if (effort != null && effort.isNotEmpty) ...['--effort', effort],
      // Briefed sessions ask the user through our question cards.
      if (briefing != null) ...['--disallowedTools', 'AskUserQuestion'],
      ...?briefing?.args,
    ],
    env: {...?briefing?.env, 'MCP_TOOL_TIMEOUT': _mcpTimeoutMs, 'CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT': _mcpTimeoutMs},
  );
}

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

/// Tools that only touch Claude's own state (or reach the user through our
/// MCP server), which the session allows itself: they still show.
bool answeredBySession(String toolName) =>
    toolName.startsWith('mcp__${everyaiServerName}__') || _internalTools.contains(toolName);

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
    'WebFetch' => (kind: 'WebFetchAction', args: {'url': s('url')}),
    'WebSearch' => (kind: 'WebSearchAction', args: {'query': s('query')}),
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
        ..add(HarnessEvent.decode({'kind': 'ConversationErrorEvent', 'id': '$id:error', 'detail': _failure(line)}))
        ..add(stateEvent('$id:state', ExecutionStatus.error));
    }
    return out;
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
