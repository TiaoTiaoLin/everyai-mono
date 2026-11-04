// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import '../../harness/events.dart';
import '../driver.dart';
import '../driver_events.dart';

// Agent Client Protocol messages as the app's events, as pure functions
// (agentclientprotocol.com: protocol/tool-calls, protocol/prompt-turn,
// protocol/agent-plan, schema). ACP's tool `kind`s are only hints, so a call
// becomes one of the app's kinds only with the field its rules read (a
// command, a path); otherwise it keeps a kind of its own, which always asks
// the user.

/// The `tool_name` prefix of an agent's own tools, so none equals one of the
/// app's client tools.
const acpToolPrefix = 'acp:';

/// A tool call's fields so far: an update carries only what changed.
Map<String, Object?> mergeToolCall(Map<String, Object?> call, Map<String, Object?> update) => {
  ...call,
  for (final e in update.entries)
    if (e.value != null && e.key != 'sessionUpdate') e.key: e.value,
};

/// What a call is in the app's terms.
typedef AcpShape = ({String kind, String toolName, Map<String, Object?> args});

/// [call] (an ACP `ToolCall`, merged) as one of the app's action kinds.
/// [mcpServers] are the servers the session configured; [options] are the
/// permission request's, which name the server for Gemini's MCP calls.
AcpShape acpShape(Map<String, Object?> call, {Set<String> mcpServers = const {}, List<Object?> options = const []}) {
  if (_mcp(call, mcpServers, options) case final m?) return m;
  final kind = _str(call['kind']) ?? 'other';
  final toolName = '$acpToolPrefix${_str(call['name']) ?? kind}';
  final raw = _map(call['rawInput']) ?? const {};
  final paths = _paths(call, raw);
  AcpShape shape(String k, Map<String, Object?> args) => (kind: k, toolName: toolName, args: {...raw, ...args});
  final own = (kind: 'Acp${_pascal(kind)}Action', toolName: toolName, args: raw);
  switch (kind) {
    case 'execute':
      // Gemini sends only a title for its shell; read as a command it could
      // pass rules it doesn't meet, so the user decides.
      final command = _str(raw['command']) ?? _str(raw['cmd']);
      return command == null ? own : shape('TerminalAction', {'command': command});
    case 'edit' || 'delete' || 'move':
      if (paths.length > 1) return shape('ApplyPatchAction', {'paths': paths});
      if (paths.isEmpty) return own;
      if (kind != 'edit') return shape('EditAction', {'patch_op': kind, 'path': paths.single});
      final diff = _diffs(call).firstOrNull;
      final old = _str(diff?['oldText']) ?? '';
      final created = diff != null && old.isEmpty || _str(call['name']) == 'write';
      final (before, after) = _trimmed(old, _str(diff?['newText']) ?? '');
      return shape(
        'FileEditorAction',
        created
            ? {'command': 'create', 'path': paths.single, 'file_text': after}
            : {'command': 'str_replace', 'path': paths.single, 'old_str': before, 'new_str': after},
      );
    case 'read':
      return paths.isEmpty ? own : shape('ReadFileAction', {'path': paths.first});
    case 'search':
      final pattern = _str(raw['pattern']) ?? _str(raw['query']) ?? _str(raw['regex']);
      return shape('GrepAction', {'pattern': ?pattern, 'path': ?paths.firstOrNull});
    case 'fetch':
      final url = _str(raw['url']);
      return url == null ? own : shape('WebFetchAction', {'url': url});
    default:
      return own;
  }
}

/// [call] as the app's event, with its ACP `title` as the summary the
/// transcript shows for kinds it doesn't know.
ActionCall acpActionEvent(
  Map<String, Object?> call, {
  required String id,
  Set<String> mcpServers = const {},
  List<Object?> options = const [],
}) {
  final s = acpShape(call, mcpServers: mcpServers, options: options);
  final base = actionEvent(
    id: id,
    toolName: s.toolName,
    kind: s.kind,
    toolCallId: _str(call['toolCallId']),
    args: s.args,
  );
  return HarnessEvent.decode({...base.raw, 'summary': _str(call['title']) ?? ''}) as ActionCall;
}

/// What a finished call returned (`completed`, or `failed` as an error).
ToolResult acpResultEvent(
  Map<String, Object?> call, {
  required String id,
  required String actionId,
  required String toolName,
}) {
  final failed = call['status'] == 'failed';
  final text = acpResultText(call);
  return resultEvent(
    id: id,
    actionId: actionId,
    toolName: toolName,
    text: text.isNotEmpty ? text : (failed ? 'Failed.' : 'Done.'),
    isError: failed,
  );
}

/// The text of a call's `content` (a diff as "Edited `path`"; a terminal's
/// output stays in the agent), else of its `rawOutput`, clipped.
String acpResultText(Map<String, Object?> call) {
  final parts = <String>[
    for (final c in (call['content'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>())
      switch (c['type']) {
        'content' => _blockText(c['content']),
        'diff' => 'Edited ${c['path']}',
        'terminal' => "(output shown in the agent's terminal)",
        _ => '',
      },
  ].where((t) => t.isNotEmpty).toList();
  var text = parts.join('\n');
  if (text.isEmpty) {
    text = switch (call['rawOutput']) {
      final String s => s,
      {'output': final String s} || {'stdout': final String s} || {'error': final String s} => s,
      null => '',
      final other => jsonEncode(other),
    };
  }
  return text.length > _clip ? '${text.substring(0, _clip)}\n… (cut)' : text;
}

const _clip = 30000;

/// A refused call's result, with what the agent was told.
ToolResult acpRejectedEvent({
  required String id,
  required String actionId,
  required String toolName,
  required String reason,
}) => HarnessEvent.decode({
  'kind': 'UserRejectObservation',
  'id': id,
  'source': 'environment',
  'action_id': actionId,
  'tool_name': toolName,
  'rejection_reason': reason,
}) as ToolResult;

/// An ACP `plan` (its entries replace the last) as the app's task list, plus
/// its result so it never waits for approval.
(ActionCall, ToolResult) acpPlanEvents(List<Object?> entries, {required String id}) {
  final tasks = [
    for (final e in entries.whereType<Map<String, Object?>>())
      {
        'title': _str(e['content']) ?? '',
        'status': switch (e['status']) {
          'in_progress' => 'in_progress',
          'completed' => 'done',
          _ => 'todo',
        },
        'notes': '',
      },
  ];
  const name = '${acpToolPrefix}plan';
  return (
    actionEvent(id: id, toolName: name, kind: 'TaskTrackerAction', args: {'command': 'plan', 'task_list': tasks}),
    resultEvent(id: '$id-r', actionId: id, toolName: name, text: 'Plan updated.'),
  );
}

/// The agent's reply, flushed from its chunks.
ChatMessage agentMessageEvent(String id, String text, {String reasoning = ''}) => HarnessEvent.decode({
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

/// What the user sent, as the transcript shows it.
ChatMessage userMessageEvent(String id, String text, {List<String> images = const []}) => HarnessEvent.decode({
  'kind': 'MessageEvent',
  'id': id,
  'source': 'user',
  'llm_message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
      for (final url in images)
        {
          'type': 'image_url',
          'image_url': {'url': url},
        },
    ],
  },
}) as ChatMessage;

/// A line of the reply being written.
StreamDelta acpDelta({String content = '', String reasoning = ''}) =>
    HarnessEvent.decode({'kind': 'StreamingDeltaEvent', 'content': content, 'reasoning_content': reasoning})
        as StreamDelta;

/// Something the user should know, shown as a notice in the transcript.
ConversationFailure acpNotice(String id, String message) =>
    HarnessEvent.decode({'kind': 'ConversationErrorEvent', 'id': id, 'source': 'environment', 'detail': message})
        as ConversationFailure;

/// The text of a content chunk (`{type: text, text}`), '' for anything else.
String acpChunkText(Object? content) => _blockText(content);

/// What a turn used (`PromptResponse.usage`, OpenCode). `inputTokens` leaves
/// cache reads and writes out when the totals add up that way (OpenCode's
/// `TokenUsage.total`); otherwise it is taken as the whole prompt. Paid by the
/// agent's own account ([UsageReport.onPlan]).
UsageReport? acpTurnUsage(Object? usage, {required String id}) {
  if (usage is! Map<String, Object?>) return null;
  int n(String k) => (usage[k] as num?)?.toInt() ?? 0;
  final input = n('inputTokens');
  final output = n('outputTokens');
  final thought = n('thoughtTokens');
  final read = n('cachedReadTokens');
  final write = n('cachedWriteTokens');
  final apart = usage['totalTokens'] != null && n('totalTokens') == input + output + thought + read + write;
  return UsageReport.of(
    id: id,
    input: apart ? input + read + write : input,
    output: apart ? output + thought : output,
    cached: read,
    onPlan: true,
  );
}

/// A `usage_update`: how full the context is, and what was spent since
/// [lastCost] (the agent reports a running total, in its currency; only USD
/// is counted). Returns the report and the new running total.
(UsageReport, double?) acpUsageUpdate(Map<String, Object?> update, {required String id, double? lastCost}) {
  final cost = _map(update['cost']);
  final amount = (cost?['amount'] as num?)?.toDouble();
  final usd = amount != null && '${cost?['currency']}'.toUpperCase() == 'USD';
  final delta = usd ? ((amount - (lastCost ?? 0)) * 1e6).round() : null;
  return (
    UsageReport.of(
      id: id,
      input: 0,
      output: 0,
      contextTokens: (update['used'] as num?)?.toInt(),
      costMicros: delta == null || delta < 0 ? null : delta,
      onPlan: true,
    ),
    usd ? amount : lastCost,
  );
}

/// One choice of a select config option.
typedef AcpChoice = ({String value, String name});

/// A session config option (`configOptions`, schema: session config
/// options) of [category] (`mode`, `model`, `thought_level`), or null.
({String id, String? current, List<AcpChoice> choices})? acpOption(List<Object?>? options, String category) {
  for (final o in (options ?? const []).whereType<Map<String, Object?>>()) {
    if (o['category'] != category || o['id'] is! String) continue;
    return (id: o['id']! as String, current: _str(o['currentValue']), choices: _choices(o['options']));
  }
  return null;
}

// Grouped options carry their own `options`.
List<AcpChoice> _choices(Object? options) => [
  for (final c in (options as List<Object?>? ?? const []).whereType<Map<String, Object?>>())
    if (c['options'] != null)
      ..._choices(c['options'])
    else if (_str(c['value']) case final v?)
      (value: v, name: _str(c['name']) ?? v),
];

/// The models a `session/new` or `session/load` reply offers: its `model`
/// config option (the efforts it lists are its current model's), else the
/// older `models` field. The current one is the default.
List<DriverModel> acpModels(Map<String, Object?> reply) {
  if (acpOption(reply['configOptions'] as List<Object?>?, 'model') case final m?) {
    final efforts = [
      for (final c
          in acpOption(reply['configOptions'] as List<Object?>?, 'thought_level')?.choices ?? const <AcpChoice>[])
        if (c.value != 'default') c.value,
    ];
    return [
      for (final c in m.choices)
        DriverModel(
          id: c.value,
          label: c.name,
          isDefault: c.value == m.current,
          efforts: c.value == m.current ? efforts : const [],
        ),
    ];
  }
  final legacy = _map(reply['models']);
  return [
    for (final m in (legacy?['availableModels'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>())
      if (_str(m['modelId']) case final id?)
        DriverModel(id: id, label: _str(m['name']) ?? id, isDefault: id == legacy?['currentModelId']),
  ];
}

/// [text] and [images] (`data:` URLs) as ACP content blocks; pictures only
/// when the agent reads them.
List<Map<String, Object?>> acpPrompt(String text, {List<String> images = const [], bool imagesOk = false}) => [
  {'type': 'text', 'text': text},
  if (imagesOk)
    for (final url in images)
      if (RegExp(r'^data:([^;,]+);base64,(.*)$', dotAll: true).firstMatch(url) case final m?)
        {'type': 'image', 'mimeType': m[1], 'data': m[2]},
];

/// [config]'s user MCP servers (`{name: {command, args, env} | {url,
/// transport, headers}}`) as ACP `McpServer`s; remote ones only over the
/// transports the agent has ([http], [sse]).
List<Map<String, Object?>> acpMcpServers(Map<String, Object?> config, {bool http = false, bool sse = false}) {
  List<Map<String, Object?>> pairs(Object? m) => [
    if (m is Map<String, Object?>)
      for (final e in m.entries) {'name': e.key, 'value': '${e.value}'},
  ];
  return [
    for (final MapEntry(key: name, value: s) in config.entries)
      if (s is Map<String, Object?>)
        if (_str(s['command']) case final command?)
          {
            'name': name,
            'command': command,
            'args': [for (final a in (s['args'] as List<Object?>? ?? const [])) '$a'],
            'env': pairs(s['env']),
          }
        else if (_str(s['url']) case final url?)
          if (s['transport'] == 'sse' ? sse : http)
            {
              'type': s['transport'] == 'sse' ? 'sse' : 'http',
              'name': name,
              'url': url,
              'headers': pairs(s['headers']),
            },
  ];
}

// ------------------------------------------------------------------ helpers

AcpShape? _mcp(Map<String, Object?> call, Set<String> servers, List<Object?> options) {
  final raw = _map(call['rawInput']);
  // Gemini: "Always Allow <server>" / "Always Allow <tool>", the title the
  // arguments as JSON.
  String? named(String optionId) => [
    for (final o in options.whereType<Map<String, Object?>>())
      if (o['optionId'] == optionId) _str(o['name'])?.replaceFirst(RegExp(r'^Always Allow\s+'), ''),
  ].nonNulls.firstOrNull;
  if ((named('proceed_always_server'), named('proceed_always_tool')) case (final server?, final tool?)) {
    return _mcpShape(server, tool, raw ?? _jsonObject(call['title']) ?? const {});
  }
  // OpenCode names them `<server>_<tool>`; others `mcp__<server>__<tool>`.
  final name = _str(call['name']) ?? _str(call['title']);
  if (name == null || !RegExp(r'^[\w.\-/]+$').hasMatch(name)) return null;
  for (final s in servers) {
    for (final prefix in ['mcp__${s}__', '${s}__', '${s}_', '$s.', '$s/']) {
      if (name.startsWith(prefix) && name.length > prefix.length) {
        return _mcpShape(s, name.substring(prefix.length), raw ?? const {});
      }
    }
  }
  return null;
}

AcpShape _mcpShape(String server, String tool, Map<String, Object?> args) =>
    (kind: 'MCPToolAction', toolName: '${server}__$tool', args: {...args, 'server': server, 'tool': tool});

List<Map<String, Object?>> _diffs(Map<String, Object?> call) => [
  for (final c in (call['content'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>())
    if (c['type'] == 'diff') c,
];

/// Every path the call names: its diffs, its locations, then its input.
List<String> _paths(Map<String, Object?> call, Map<String, Object?> raw) {
  final out = <String>{
    for (final d in _diffs(call)) ?_str(d['path']),
    for (final l in (call['locations'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>())
      ?_str(l['path']),
  };
  if (out.isEmpty) {
    if (_str(raw['path']) ?? _str(raw['filePath']) ?? _str(raw['file_path']) case final p?) out.add(p);
  }
  return out.toList();
}

/// A diff of whole files cut to the changed lines with 3 lines around them,
/// so the approval card's line diff stays small.
(String, String) _trimmed(String before, String after) {
  final a = before.split('\n');
  final b = after.split('\n');
  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var end = 0;
  while (end < a.length - start && end < b.length - start && a[a.length - 1 - end] == b[b.length - 1 - end]) {
    end++;
  }
  const context = 3;
  final from = (start - context).clamp(0, start);
  String cut(List<String> l) {
    final to = (l.length - end + context).clamp(0, l.length);
    final lines = l.sublist(from, to);
    return (lines.length > 400 ? [...lines.take(400), '… (cut)'] : lines).join('\n');
  }

  return (cut(a), cut(b));
}

String _blockText(Object? content) => switch (content) {
  {'type': 'text', 'text': final String t} => t,
  _ => '',
};

Map<String, Object?>? _jsonObject(Object? s) {
  if (s is! String || !s.trimLeft().startsWith('{')) return null;
  try {
    return _map(jsonDecode(s));
  } on FormatException {
    return null;
  }
}

String _pascal(String s) =>
    s.split(RegExp(r'[_\-\s]+')).map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join();

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

Map<String, Object?>? _map(Object? v) => v is Map<String, Object?> ? v : null;
