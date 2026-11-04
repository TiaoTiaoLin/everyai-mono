// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../domain/agent_mode.dart';
import '../../domain/compaction.dart';
import '../../domain/phases.dart';
import '../../domain/shell_readonly.dart';
import '../../domain/transcript.dart' show PlanProposal, planApprovedReason;
import '../../domain/subagents.dart' show forkingTaskSpec, subagentRules, taskTool;
import '../../settings/agent_prompt.dart' show forHeldClientTools;
import '../events.dart';
import '../harness.dart';
import 'browser_io.dart';
import 'llm.dart';
import 'mcp_io.dart';
import 'model_family.dart';
import 'prompt_io.dart';
import 'reasoning_binding.dart';
import 'project_notes_io.dart';
import 'script_io.dart';
import 'shell_io.dart';
import 'tools_io.dart';

/// The EveryAI harness: the agent loop runs here, in the app, against the
/// gateway. It speaks the same events as the agent-server (the transcript,
/// permissions and approvals are shared), but the loop, the tools and the
/// history are ours: questions block inside the call, tool results can be cut
/// to size, and a session can be forked from another's history.
final class EveryAIHarness implements Harness {
  EveryAIHarness({required this.dataDir, required this.gatewayKey, this.client});

  /// App Support; sessions are kept under `everyai-sessions/<id>/`.
  final Future<String> Function() dataDir;

  /// The user's gateway key, asked for when a session is reopened (it isn't
  /// written to disk with the session).
  final Future<String> Function() gatewayKey;
  final http.Client? client;

  final _sessions = <String, EveryAISession>{};

  Future<Directory> _dirFor(String id) async =>
      Directory('${await dataDir()}/everyai-sessions/$id')..createSync(recursive: true);

  @override
  Future<HarnessSession> start(SessionSpec spec) async {
    final id = const Uuid().v4();
    final session = EveryAISession._(id, spec, await _dirFor(id), client);
    _sessions[id] = session;
    await excludeScratch(spec.workingDir);
    await session._begin();
    return session;
  }

  /// A new session that starts from [parentId]'s history up to now (a fork):
  /// the same system prompt and tools, so the model's cached prefix holds,
  /// then [spec]'s initial message as the directive.
  Future<HarnessSession> fork(String parentId, SessionSpec spec) async {
    final parent = _sessions[parentId] ?? (await attach(parentId)) as EveryAISession;
    final id = const Uuid().v4();
    final session = EveryAISession._(id, spec, await _dirFor(id), client);
    _sessions[id] = session;
    await session._beginFork(parent);
    return session;
  }

  @override
  Future<HarnessSession> attach(String conversationId) async {
    if (_sessions[conversationId] case final s?) return s;
    final dir = Directory('${await dataDir()}/everyai-sessions/$conversationId');
    if (!dir.existsSync()) {
      throw const HarnessError("This session's history is no longer on this computer, so it can't be resumed.");
    }
    final session = await EveryAISession._load(conversationId, dir, await gatewayKey(), client);
    _sessions[conversationId] = session;
    return session;
  }

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async {
    final root = '${await dataDir()}/everyai-sessions';
    return {
      for (final id in conversationIds)
        if (_sessions[id] case final s?)
          id: s.status
        else if (Directory('$root/$id').existsSync())
          id: ExecutionStatus.idle,
    };
  }
}

/// Most model calls one run makes before it is asked to wrap up.
const maxStepsPerRun = 400;

/// One conversation: its history (OpenAI-style messages), its events, and the
/// loop that calls the model and runs tools.
final class EveryAISession
    implements
        HarnessSession,
        AsksAside,
        HasBackgroundShells,
        CompactsInPlace,
        PhasedSession,
        RetriesModelCalls,
        PerCallApprovals {
  EveryAISession._(this.id, this._spec, this._dir, http.Client? client)
    : _gateway = GatewayClient(baseUrl: _spec.llmBaseUrl, apiKey: _spec.llmApiKey, client: client),
      _shell = SessionShell(root: _spec.workingDir, sessionTag: _spec.sessionTag, scratchDir: '${_dir.path}/shell') {
    _tools = ToolRunner(
      root: _spec.workingDir,
      shell: _shell,
      gateway: _gateway,
      sessionTag: _spec.sessionTag,
      vision: _spec.vision,
      pathMap: _spec.pathMap,
      researchSites: _spec.researchSites,
      browser: _browser,
    );
  }

  @override
  final String id;
  SessionSpec _spec;
  final Directory _dir;
  GatewayClient _gateway;
  final SessionShell _shell;

  /// The session's own headless browser (browser tool): started on first
  /// use, closed when a run ends or is stopped.
  late final HeadlessBrowser _browser = HeadlessBrowser(profileDir: '${_dir.path}/browser');

  /// The session's MCP servers (connected once, at start or first run).
  McpTools _mcp = McpTools.empty;
  Future<void>? _mcpReady;

  Future<void> _ensureMcp() => _mcpReady ??= () async {
    final config = _spec.mcpConfig;
    if (config.isEmpty || !(_spec.tools?.contains('mcp') ?? true)) return;
    _mcp = await McpTools.start(config, reserved: {...actionKinds.keys, ...clientTools});
  }();
  late ToolRunner _tools;

  /// The model's history; each entry may carry `_eid`, the event it came
  /// from (for rewinds), stripped before sending.
  final _messages = <Map<String, Object?>>[];

  /// Every event except streaming deltas, replayed to new listeners.
  final _history = <HarnessEvent>[];
  final _listeners = <StreamController<HarnessEvent>>{};

  ExecutionStatus status = ExecutionStatus.idle;

  /// Messages sent while a run is going: added before the next model call.
  final _inbox = <Map<String, Object?>>[];

  /// Completes when a message lands in [_inbox]: cuts a sleep short.
  Completer<void> _arrived = Completer<void>();

  /// The calls waiting for approval, by action id, each with its own answer.
  final _decisions = <String, Completer<({bool accept, String? reason})>>{};

  /// The user refused every call still undecided at once ("Deny all"): if
  /// none was allowed, the run parks instead of carrying on.
  bool _denyAll = false;

  bool _looping = false;
  bool _pauseRequested = false;
  Completer<void>? _cancel;

  /// Input tokens of the last model call: how full the context is.
  int lastPromptTokens = 0;

  /// Of [lastPromptTokens], how many came from the prompt cache (live checks).
  int lastCachedTokens = 0;

  /// The Max or Ultra flow this session runs, or null.
  late PhaseFlow? _flow = _loadFlow();

  PhaseFlow? _loadFlow() {
    final file = File('${_dir.path}/phases.json');
    if (file.existsSync()) {
      try {
        final j = jsonDecode(file.readAsStringSync());
        if (j is Map<String, Object?>) return PhaseFlow.fromJson(j);
      } on Object {
        // A broken file starts the flow over.
      }
    }
    return PhaseFlow.named(_spec.phaseFlow);
  }

  void _saveFlow() {
    final file = File('${_dir.path}/phases.json');
    if (_flow case final f?) {
      file.writeAsStringSync(jsonEncode(f.toJson()));
    } else if (file.existsSync()) {
      file.deleteSync();
    }
  }

  /// Puts the flow's note for the current phase in the conversation.
  void _notePhase({bool stuck = false}) {
    final f = _flow;
    if (f == null) return;
    _saveFlow();
    final eid = _newId();
    final text = f.note(stuck: stuck);
    _emit({
      'kind': 'MessageEvent',
      'id': eid,
      'source': 'user',
      'llm_message': {'role': 'user', 'content': text},
    });
    _append({'role': 'user', 'content': text, '_eid': eid});
  }

  @override
  Future<void> skipPhase() async {
    final f = _flow;
    if (f == null || f.phase == Phase.done) return;
    f.skip();
    _notePhase();
    if (!_looping) unawaited(_run());
  }

  @override
  Future<void> setPhaseFlow(String? flow) async {
    final had = _flow;
    _flow = had != null && had.name == flow ? had : PhaseFlow.named(flow);
    _spec = _withSpec(phaseFlow: flow ?? '');
    _writeSpec();
    if (_flow != null && _flow != had) {
      _notePhase();
    } else {
      _saveFlow();
    }
  }

  // ------------------------------------------------- what compaction keeps

  /// The last plan (`present_plan`) the user approved, as Markdown.
  String _approvedPlan = '';

  /// The latest `todo_write` list.
  List<Map<String, Object?>> _todos = const [];

  /// Files read or changed, least recent first (at most [_maxTouched]).
  final _touched = <String>[];
  static const _maxTouched = 20;

  /// SKILL.md files the agent read this session.
  final _loadedSkills = <String>[];

  File get _stateFile => File('${_dir.path}/state.json');

  void _loadState() {
    if (!_stateFile.existsSync()) return;
    try {
      final j = jsonDecode(_stateFile.readAsStringSync());
      if (j is! Map<String, Object?>) return;
      _approvedPlan = j['approved_plan'] as String? ?? '';
      _todos = [...(j['todos'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>()];
      _touched
        ..clear()
        ..addAll((j['touched'] as List<Object?>? ?? const []).whereType<String>());
      _loadedSkills
        ..clear()
        ..addAll((j['skills'] as List<Object?>? ?? const []).whereType<String>());
    } on Object {
      // A broken file only loses what compaction would re-inject.
    }
  }

  void _saveState() => _stateFile.writeAsStringSync(
    jsonEncode({'approved_plan': _approvedPlan, 'todos': _todos, 'touched': _touched, 'skills': _loadedSkills}),
  );

  /// Notes what a finished call means for compaction: the todo list, the
  /// files it touched, the skills it loaded.
  void _track(LlmToolCall call, ToolOutput out) {
    final args = call.args;
    if (args == null || out.isError) return;
    var changed = false;
    switch (call.name) {
      case ToolNames.todo:
        _todos = [...(args['todos'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>()];
        changed = true;
      case ToolNames.read || ToolNames.write || ToolNames.edit:
        final path = resolvePath(_spec.workingDir, args['file_path'] as String? ?? '');
        _touch(path);
        if (call.name == ToolNames.read && path.endsWith('/SKILL.md') && !_loadedSkills.contains(path)) {
          _loadedSkills.add(path);
        }
        changed = true;
    }
    for (final path in (out.observation['paths'] as List<Object?>? ?? const []).whereType<String>()) {
      _touch(path);
      changed = true;
    }
    if (changed) _saveState();
  }

  void _touch(String path) {
    _touched
      ..remove(path)
      ..add(path);
    if (_touched.length > _maxTouched) _touched.removeAt(0);
  }

  /// Remembers [call] (a `present_plan`) as the approved plan.
  void _planApproved(LlmToolCall call) {
    final args = call.args;
    if (args == null) return;
    _approvedPlan = PlanProposal(
      ActionCall(id: '', raw: const {}, toolName: presentPlanTool, toolCallId: call.id, action: args),
    ).markdown;
    _saveState();
    // Kept with the project (git-excluded), so later sessions can pick the work up.
    try {
      savePlan(_spec.workingDir, _approvedPlan);
    } on FileSystemException {
      // The plan still lives in the session's state.
    }
  }

  /// The re-injected parts of a continuation message.
  ({String plan, String todos, String files, String skills}) _carriedState() {
    final todos = [
      for (final t in _todos)
        '- [${switch (t['status']) {
          'completed' => 'x',
          'in_progress' => '~',
          _ => ' ',
        }}] ${t['content'] ?? ''}',
    ].join('\n');
    // The newest files first, each and all capped (about 8K and 30K tokens).
    const each = 32000, total = 120000;
    final files = StringBuffer();
    var used = 0;
    var shown = 0;
    for (final path in _touched.reversed) {
      if (shown == 5 || used >= total) break;
      final file = File(path);
      if (!file.existsSync()) continue;
      String text;
      try {
        text = file.readAsStringSync();
      } on Object {
        continue;
      }
      final room = (total - used).clamp(0, each);
      final cut = text.length > room;
      if (cut) {
        text = '${text.substring(0, room)}\n[… ${text.length - room} more characters; read the rest if needed …]';
      }
      files
        ..writeln('<file path="$path">')
        ..writeln(text)
        ..writeln('</file>');
      used += text.length;
      shown++;
      // Its text is in front of the model again: it may be edited without a read.
      if (!cut) _tools.markRead(path);
    }
    final skills = StringBuffer();
    for (final path in _loadedSkills) {
      final file = File(path);
      if (!file.existsSync()) continue;
      var text = file.readAsStringSync();
      if (text.length > each) text = '${text.substring(0, each)}\n[… cut; read $path for the rest …]';
      skills
        ..writeln('<skill path="$path">')
        ..writeln(text.trim())
        ..writeln('</skill>');
    }
    return (plan: _approvedPlan, todos: todos, files: files.toString(), skills: skills.toString());
  }

  /// For a fork: the parent's tool list, kept as it was so the cached prefix
  /// (tools, system prompt, history) matches.
  List<Map<String, Object?>>? _forkTools;
  bool get isFork => _forkTools != null;

  // ------------------------------------------------------------------ setup

  Future<void> _begin() async {
    _writeSpec();
    await _ensureMcp();
    final system = await _systemPrompt();
    _append({'role': 'system', 'content': system});
    if (_spec.initialMessage case final first?) {
      // The flow's first note follows the task, before the first model call.
      if (_flow != null) await send(first, run: false, images: _spec.initialImages);
      if (_flow != null) {
        _notePhase();
        if (_spec.runInitial) unawaited(_run());
      } else {
        await send(first, run: _spec.runInitial, images: _spec.initialImages);
      }
    }
  }

  Future<void> _beginFork(EveryAISession parent) async {
    _forkTools = parent._toolSpecs;
    family = parent.family;
    // Its own connections to the same servers: forks run side by side.
    await _ensureMcp();
    _writeSpec();
    _writeForkTools();
    // The parent's history as it stands, without a trailing assistant turn
    // whose tool calls have no results yet (the call that started the fork).
    final copy = [for (final m in parent._messages) Map.of(m)..remove('_eid')];
    _trimDangling(copy);
    // What compaction re-injects carries over too.
    _approvedPlan = parent._approvedPlan;
    _todos = parent._todos;
    _touched.addAll(parent._touched);
    _loadedSkills.addAll(parent._loadedSkills);
    _saveState();
    for (final m in copy) {
      _append(m);
    }
    if (_spec.initialMessage case final first?) {
      await send(first, run: _spec.runInitial, images: _spec.initialImages);
    }
  }

  /// Drops a trailing assistant message whose tool calls are unanswered, so
  /// the history is valid to send.
  static void _trimDangling(List<Map<String, Object?>> messages) {
    final answered = <String>{
      for (final m in messages)
        if (m['role'] == 'tool') m['tool_call_id'] as String? ?? '',
    };
    while (messages.isNotEmpty) {
      final last = messages.last;
      final calls = last['tool_calls'] as List<Object?>?;
      if (last['role'] == 'assistant' &&
          calls != null &&
          calls.any((c) => !answered.contains((c as Map<String, Object?>)['id']))) {
        messages.removeLast();
        continue;
      }
      break;
    }
  }

  static Future<EveryAISession> _load(String id, Directory dir, String key, http.Client? client) async {
    final specJson = jsonDecode(File('${dir.path}/spec.json').readAsStringSync()) as Map<String, Object?>;
    final spec = _specFromJson(specJson, key);
    final s = EveryAISession._(id, spec, dir, client);
    if (ModelFamily.values.asNameMap()[specJson['family']] case final f?) s.family = f;
    final forkTools = File('${dir.path}/fork_tools.json');
    if (forkTools.existsSync()) {
      s._forkTools = (jsonDecode(forkTools.readAsStringSync()) as List<Object?>).cast<Map<String, Object?>>();
    }
    final messages = File('${dir.path}/messages.jsonl');
    if (messages.existsSync()) {
      for (final line in messages.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        s._messages.add(jsonDecode(line) as Map<String, Object?>);
      }
    }
    final events = File('${dir.path}/events.jsonl');
    if (events.existsSync()) {
      for (final line in events.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        s._history.add(HarnessEvent.decode(jsonDecode(line) as Map<String, Object?>));
      }
    }
    // A run cut off by quitting: its unanswered calls are dropped so the
    // history can be sent again.
    final before = s._messages.length;
    _trimDangling(s._messages);
    if (s._messages.length != before) s._rewriteMessages();
    s._loadState();
    s.status = ExecutionStatus.idle;
    return s;
  }

  void _writeSpec() =>
      File('${_dir.path}/spec.json').writeAsStringSync(jsonEncode({..._specToJson(_spec), 'family': family.name}));

  /// The model family the session was started for: its tools and rules
  /// (fixed for the session, so the cached prefix holds after a model switch).
  late ModelFamily family = familyOf(_spec.model);

  static Map<String, Object?> _specToJson(SessionSpec s) => {
    'working_dir': s.workingDir,
    'model': s.model,
    'mode': s.mode.name,
    'llm_base_url': s.llmBaseUrl,
    'session_tag': s.sessionTag,
    'max_input_tokens': s.maxInputTokens,
    'max_output_tokens': s.maxOutputTokens,
    'vision': s.vision,
    'effort': s.effort,
    'subagent': s.subagent,
    'tools': s.tools,
    'client_tools': s.clientTools,
    'auto_compact_at': s.autoCompactAt,
    'mcp_config': s.mcpConfig,
    'path_map': s.pathMap,
    'research_sites': ?s.researchSites,
    'phase_flow': ?s.phaseFlow,
    'script': ?s.script?.toJson(),
  };

  void _writeForkTools() {
    if (_forkTools case final t?) File('${_dir.path}/fork_tools.json').writeAsStringSync(jsonEncode(t));
  }

  static SessionSpec _specFromJson(Map<String, Object?> j, String key) => SessionSpec(
    workingDir: j['working_dir']! as String,
    model: j['model']! as String,
    mode: AgentMode.values.asNameMap()[j['mode']] ?? AgentMode.ask,
    llmBaseUrl: j['llm_base_url']! as String,
    llmApiKey: key,
    sessionTag: j['session_tag']! as String,
    maxInputTokens: (j['max_input_tokens'] as num?)?.toInt(),
    maxOutputTokens: (j['max_output_tokens'] as num?)?.toInt() ?? 64000,
    vision: j['vision'] == true,
    effort: j['effort'] as String?,
    subagent: j['subagent'] == true,
    tools: (j['tools'] as List<Object?>?)?.cast<String>(),
    clientTools: (j['client_tools'] as List<Object?>?)?.cast<Map<String, Object?>>(),
    autoCompactAt: (j['auto_compact_at'] as num?)?.toDouble() ?? 0.6,
    mcpConfig: (j['mcp_config'] as Map<String, Object?>?) ?? const {},
    pathMap: {for (final e in (j['path_map'] as Map<String, Object?>? ?? const {}).entries) e.key: '${e.value}'},
    researchSites: (j['research_sites'] as List<Object?>?)?.cast<String>(),
    phaseFlow: j['phase_flow'] as String?,
    script: ScriptCaps.fromJson(j['script']),
  );

  Future<String> _systemPrompt() async {
    final spec = _spec;
    final suffix = spec.promptSuffix == null ? '' : forHeldClientTools(spec.promptSuffix!);
    final parts = [
      harnessRules,
      ?familyRules(family),
      ?spec.persona,
      if (suffix.isNotEmpty) suffix,
      if (spec.subagent) subagentRules,
      ?spec.rolePrompt,
      if (spec.skills.isNotEmpty) _skillsBlock(spec.skills),
      if (_mcp.failures.isNotEmpty)
        '<MCP>\nThese MCP servers could not start, so their tools are missing: '
            '${_mcp.failures.entries.map((e) => '${e.key} (${e.value})').join('; ')}. Tell the user if the task needs them.\n</MCP>',
      if (await projectNotesBlock(spec.workingDir) case final notes when notes.isNotEmpty) notes,
      await environmentBlock(spec.workingDir),
    ];
    return parts.join('\n\n');
  }

  static String _skillsBlock(List<Map<String, Object?>> skills) {
    final out = StringBuffer(
      '<SKILLS>\nSkills are instructions for particular kinds of task. When a task matches one, read its SKILL.md '
      'first and follow it.\n',
    );
    for (final s in skills) {
      out.writeln('- ${s['name']}: ${s['description'] ?? ''} (${s['source'] ?? ''})');
    }
    out.write('</SKILLS>');
    return out.toString();
  }

  List<Map<String, Object?>> get _toolSpecs =>
      _forkTools ??
      [
        ...builtInToolSpecs(only: _spec.tools, applyPatch: family == ModelFamily.gpt),
        if (_scripting) runScriptSpec,
        memoryToolSpec,
        ..._mcp.specs,
        if (!_spec.subagent && (_spec.phaseFlow?.startsWith('bugfix') ?? false))
          {
            'type': 'function',
            'function': {
              'name': bugCheckSpec['name'],
              'description': bugCheckSpec['description'],
              'parameters': bugCheckSpec['parameters'],
            },
          },
        for (final Map<String, Object?> t
            in _spec.clientTools ??
                (_spec.subagent
                    ? const <Map<String, Object?>>[]
                    : [for (final t in clientToolSpecs(held: true)) t['name'] == taskTool ? forkingTaskSpec() : t]))
          {
            'type': 'function',
            'function': {'name': t['name'], 'description': t['description'], 'parameters': t['parameters']},
          },
      ];

  // ------------------------------------------------------------ persistence

  void _append(Map<String, Object?> message) {
    _messages.add(message);
    File('${_dir.path}/messages.jsonl').writeAsStringSync('${jsonEncode(message)}\n', mode: FileMode.append);
  }

  void _rewriteMessages() =>
      File('${_dir.path}/messages.jsonl').writeAsStringSync(_messages.map((m) => '${jsonEncode(m)}\n').join());

  void _rewriteEvents() =>
      File('${_dir.path}/events.jsonl').writeAsStringSync(_history.map((e) => '${jsonEncode(e.raw)}\n').join());

  // ----------------------------------------------------------------- events

  @override
  Stream<HarnessEvent> get events {
    late final StreamController<HarnessEvent> c;
    c = StreamController<HarnessEvent>(
      onListen: () {
        _history.forEach(c.add);
        c.add(const ConnectionChange(connected: true));
        _listeners.add(c);
      },
      onCancel: () => _listeners.remove(c),
    );
    return c.stream;
  }

  String _newId() => const Uuid().v4();

  /// Emits an event built from agent-server-shaped [raw] JSON, and keeps it.
  HarnessEvent _emit(Map<String, Object?> raw) {
    raw['timestamp'] ??= DateTime.now().toIso8601String();
    final e = HarnessEvent.decode(raw);
    if (e is! StreamDelta) {
      _history.add(e);
      File('${_dir.path}/events.jsonl').writeAsStringSync('${jsonEncode(raw)}\n', mode: FileMode.append);
    }
    for (final c in [..._listeners]) {
      c.add(e);
    }
    return e;
  }

  void _delta({String content = '', String reasoning = '', StreamingTool? tool}) {
    final e = StreamDelta(raw: const {}, content: content, reasoning: reasoning, tool: tool);
    for (final c in [..._listeners]) {
      c.add(e);
    }
  }

  /// How a failed model call is retried: 8 attempts, 15 in a Max or Ultra
  /// session (long unattended runs ride out an overload).
  RetryPolicy get retryPolicy =>
      testRetryPolicy ?? RetryPolicy(maxAttempts: const {'max', 'ultra'}.contains(_spec.phaseFlow) ? 15 : 8);

  /// Replaces [retryPolicy] in tests (short waits).
  @visibleForTesting
  static RetryPolicy? testRetryPolicy;

  final _retryWait = RetryWait();

  /// Cuts the wait before the next attempt short ("Retry now").
  @override
  void retryNow() => _retryWait.skip();

  /// Tells listeners a call is being retried; live only (not kept, not
  /// replayed). The transcript drops what had streamed of the reply.
  void _retrying(RetryNotice n) {
    final raw = <String, Object?>{
      'kind': 'ConversationStateUpdateEvent',
      'id': _newId(),
      'timestamp': DateTime.now().toIso8601String(),
      'key': 'retry',
      'value': {
        'attempt': n.attempt,
        'max': n.max,
        'delay_ms': n.delay.inMilliseconds,
        'reason': n.reason,
        'status': ?n.status,
        'until': DateTime.now().add(n.delay).millisecondsSinceEpoch,
      },
    };
    final e = HarnessEvent.decode(raw);
    for (final c in [..._listeners]) {
      c.add(e);
    }
  }

  void _setStatus(ExecutionStatus s) {
    if (status == s) return;
    status = s;
    _emit({'kind': 'ConversationStateUpdateEvent', 'id': _newId(), 'key': 'execution_status', 'value': s.wire});
  }

  // ------------------------------------------------------------------- API

  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async {
    // The user spoke: a repeated call may be what they asked for.
    _lastCall = null;
    final eid = _newId();
    final content = <Map<String, Object?>>[
      {'type': 'text', 'text': text},
      for (final url in images)
        {
          'type': 'image_url',
          'image_url': {'url': url},
        },
    ];
    _emit({
      'kind': 'MessageEvent',
      'id': eid,
      'source': 'user',
      'llm_message': {'role': 'user', 'content': content},
    });
    final message = {'role': 'user', 'content': images.isEmpty ? text : content, '_eid': eid};
    final moved = _flow?.onMessage(text) ?? false;
    if (_looping) {
      // Steering: read before the next model call. A message right after a
      // stop (Option-Enter) is a new instruction, so the run carries on.
      _pauseRequested = false;
      _inbox.add(message);
      if (moved) _inbox.add({'role': 'user', 'content': _flow!.note(), '_eid': _newId()});
      if (moved) _saveFlow();
      if (!_arrived.isCompleted) _arrived.complete();
      return;
    }
    _append(message);
    if (moved) _notePhase();
    if (run) unawaited(_run());
  }

  @override
  Future<void> interrupt() async {
    unawaited(_browser.close());
    if (_cancel case final c? when !c.isCompleted) c.complete();
    for (final d in _decisions.values) {
      if (!d.isCompleted) d.complete((accept: false, reason: 'The user stopped this.'));
    }
    _pauseRequested = true;
  }

  @override
  Future<void> pause() async {
    _pauseRequested = true;
    if (!_looping) _setStatus(ExecutionStatus.paused);
  }

  @override
  Future<void> resume() async {
    _pauseRequested = false;
    if (_looping) return;
    unawaited(_run());
  }

  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {
    // Without ids: every call still undecided ("Allow all" / "Deny all").
    if (callIds == null && !accept) _denyAll = true;
    for (final id in callIds ?? [..._decisions.keys]) {
      final d = _decisions[id];
      if (d != null && !d.isCompleted) d.complete((accept: accept, reason: reason));
    }
  }

  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {
    _spec = _withSpec(mode: mode);
    _writeSpec();
  }

  @override
  Future<void> switchLlm(SessionSpec spec) async {
    _spec = _withSpec(
      model: spec.model,
      effort: spec.effort,
      llmBaseUrl: spec.llmBaseUrl,
      llmApiKey: spec.llmApiKey,
      maxInputTokens: spec.maxInputTokens,
      vision: spec.vision,
    );
    _gateway = GatewayClient(baseUrl: _spec.llmBaseUrl, apiKey: _spec.llmApiKey);
    _tools = ToolRunner(
      root: _spec.workingDir,
      shell: _shell,
      gateway: _gateway,
      sessionTag: _spec.sessionTag,
      vision: _spec.vision,
      pathMap: _spec.pathMap,
      researchSites: _spec.researchSites,
      browser: _browser,
    );
    _writeSpec();
  }

  SessionSpec _withSpec({
    AgentMode? mode,
    String? model,
    String? effort,
    String? llmBaseUrl,
    String? llmApiKey,
    int? maxInputTokens,
    bool? vision,
    String? phaseFlow,
    ScriptCaps? script,
  }) {
    final s = _spec;
    return SessionSpec(
      workingDir: s.workingDir,
      model: model ?? s.model,
      mode: mode ?? s.mode,
      llmBaseUrl: llmBaseUrl ?? s.llmBaseUrl,
      llmApiKey: llmApiKey ?? s.llmApiKey,
      sessionTag: s.sessionTag,
      maxInputTokens: maxInputTokens ?? s.maxInputTokens,
      maxOutputTokens: s.maxOutputTokens,
      vision: vision ?? s.vision,
      effort: effort ?? s.effort,
      holdClientTools: true,
      subagent: s.subagent,
      tools: s.tools,
      clientTools: s.clientTools,
      autoCompactAt: s.autoCompactAt,
      mcpConfig: s.mcpConfig,
      pathMap: s.pathMap,
      researchSites: s.researchSites,
      phaseFlow: phaseFlow == null ? s.phaseFlow : (phaseFlow.isEmpty ? null : phaseFlow),
      script: script ?? s.script,
    );
  }

  @override
  Future<void> rewindTo(String? head) async {
    if (_looping) throw const HarnessError('Stop the agent before rewinding.');
    final keep = <String>{};
    if (head != null) {
      for (final e in _history) {
        if (e.id.isNotEmpty) keep.add(e.id);
        if (e.id == head) break;
      }
    }
    _history.retainWhere((e) => e.id.isEmpty || keep.contains(e.id));
    _messages.retainWhere((m) => m['role'] == 'system' || keep.contains(m['_eid']));
    _trimDangling(_messages);
    _rewriteEvents();
    _rewriteMessages();
  }

  @override
  Future<void> close() async {
    // The session keeps running with no view open; only the listeners go.
    for (final c in [..._listeners]) {
      await c.close();
    }
    _listeners.clear();
  }

  @override
  Future<String> askAside(String question, {int maxTokens = 800}) async {
    final reply = await _gateway.complete(
      model: _spec.model,
      messages: [
        ..._bound().messages,
        {'role': 'user', 'content': question},
      ],
      // The same tools as the conversation keep the cached prefix; none may run.
      tools: _toolSpecs,
      toolChoice: 'none',
      sessionTag: _spec.sessionTag,
      effort: _spec.effort,
      maxTokens: maxTokens,
    );
    return reply.text;
  }

  @override
  List<BackgroundTask> get backgroundTasks => [
    for (final b in _shell.background)
      (
        id: b.id,
        command: b.command,
        description: b.description,
        running: b.running,
        exitCode: b.exitCode,
        startedAt: b.startedAt,
      ),
  ];

  @override
  Future<void> stopBackground(String id) async => _shell.backgroundShell(id)?.kill();

  /// Kills what the session's shell is still running.
  Future<void> killProcesses() => _shell.killAll();

  // ------------------------------------------------------------------ loop

  /// [_outgoing] (plus [extra]) with Claude thinking whose earlier
  /// conversation changed taken out; see [bindReasoning].
  Bound _bound({List<Map<String, Object?>> extra = const []}) =>
      bindReasoning([..._outgoing(), ...extra], bindingSeed(_spec.model, _toolSpecs));

  /// The messages as the model gets them. Old tool pictures become a note,
  /// in batches: up to 2 × [keptImages] − 1 go out whole, then the oldest
  /// batch of [keptImages] is dropped at once. Dropping one per new picture
  /// changed a message deep in the history on every screenshot, and each
  /// change made the provider re-read the whole conversation uncached (a
  /// felice-website run paid that 15 times, $13.81 on Opus).
  List<Map<String, Object?>> _outgoing() => withOlderImagesNoted(_messages, keptImages);

  /// Tool pictures sent whole at least (see [_outgoing]).
  static const keptImages = 8;

  Future<void> _run() async {
    if (_looping) return;
    _looping = true;
    _pauseRequested = false;
    // A reopened session reconnects its servers before the first call.
    await _ensureMcp();
    var steps = 0;
    try {
      while (true) {
        for (final m in _inbox) {
          _append(m);
        }
        _inbox.clear();
        if (_pauseRequested) {
          _setStatus(ExecutionStatus.paused);
          return;
        }
        _setStatus(ExecutionStatus.running);
        await _maybeCompact();
        steps++;
        final wrapUp = steps > maxStepsPerRun;
        final cancel = _cancel = Completer<void>();
        final sent = _bound(
          extra: [
            if (wrapUp)
              {
                'role': 'user',
                'content':
                    'You have used this run\'s step budget. Stop calling tools and write your final message: '
                    'what you did, what is verified, and what is left.',
              },
          ],
        );
        final LlmReply reply;
        try {
          reply = await _gateway.completeWithRetry(
            policy: retryPolicy,
            onRetry: _retrying,
            wait: _retryWait,
            model: _spec.model,
            messages: sent.messages,
            tools: _toolSpecs,
            toolChoice: wrapUp ? 'none' : null,
            sessionTag: _spec.sessionTag,
            effort: _spec.effort,
            maxTokens: _outputRoom(),
            onText: (d) => _delta(content: d),
            onReasoning: (d) => _delta(reasoning: d),
            onToolProgress: (p) => _delta(
              tool: StreamingTool(index: p.index, name: p.name, path: p.path, lines: p.lines, chars: p.chars),
            ),
            cancel: cancel.future,
          );
        } on LlmCancelled {
          _setStatus(ExecutionStatus.paused);
          return;
        }
        lastPromptTokens = reply.promptTokens;
        lastCachedTokens = reply.cachedTokens;
        final textId = _newId();
        final kept = reply.toMessage();
        // Claude's thinking is replayed only while what it saw stays the same.
        if (hasClaudeThinking(kept)) kept[boundKey] = sent.prefix;
        _append({...kept, '_eid': textId});
        // The text before the first call opens the turn; text the model wrote
        // between calls is shown between them, as it wrote it.
        final (lead, between, trailing) = _split(reply);
        // Always emitted (an empty one shows nothing): rewinds keep the
        // assistant turn by this event's id.
        _emit({
          'kind': 'MessageEvent',
          'id': textId,
          'source': 'agent',
          'llm_message': {
            'role': 'assistant',
            'content': reply.toolCalls.isEmpty || wrapUp ? reply.text : lead,
            'reasoning_content': reply.reasoning,
          },
        });
        if (reply.toolCalls.isEmpty || wrapUp) {
          if (_inbox.isNotEmpty) continue;
          // The flow decides whether this turn may end.
          if (!wrapUp && _flow != null) {
            switch (_flow!.onTurnEnd()) {
              case Nudge():
                _notePhase();
                continue;
              case Stuck():
                _notePhase(stuck: true);
                _setStatus(ExecutionStatus.paused);
                return;
              case EndTurn(:final finished):
                // The done note closes the phase strip and tells the model follow-ups run free.
                finished ? _notePhase() : _saveFlow();
            }
          }
          _setStatus(ExecutionStatus.finished);
          return;
        }
        final stopped = await _handleCalls(reply.toolCalls, cancel, textBefore: between, trailing: trailing);
        if (stopped) return;
      }
    } on LlmCancelled {
      _setStatus(ExecutionStatus.paused);
    } on LlmError catch (e) {
      _emit({'kind': 'ConversationErrorEvent', 'id': _newId(), 'detail': e.message});
      _setStatus(ExecutionStatus.error);
    } on Object catch (e) {
      _emit({'kind': 'ConversationErrorEvent', 'id': _newId(), 'detail': 'The agent loop failed: $e'});
      _setStatus(ExecutionStatus.error);
    } finally {
      _looping = false;
      _cancel = null;
      // A message that arrived while the stopped call unwound starts the next run.
      if (_inbox.isNotEmpty && !_pauseRequested) {
        unawaited(_run());
      } else {
        unawaited(_browser.close());
      }
    }
  }

  /// The reply's token limit: the session's, or what the window has left
  /// after the last call's input (less a margin), but never under 8K.
  int _outputRoom() {
    final window = _spec.maxInputTokens ?? 0;
    if (window <= 0 || lastPromptTokens <= 0) return _spec.maxOutputTokens;
    final room = window - lastPromptTokens - 4000;
    final floor = _spec.maxOutputTokens < 8192 ? _spec.maxOutputTokens : 8192;
    return room.clamp(floor, _spec.maxOutputTokens);
  }

  /// Compacts the history in place once the last call's input passed
  /// [SessionSpec.autoCompactAt] of the window: old tool output is pruned and
  /// the older span summarized by the session's own model; the newest turns
  /// stay word for word. The transcript shows it as "Context compacted".
  Future<void> _maybeCompact() async {
    // First the cheap step: old tool output goes (rarely, so the cached prefix holds).
    if (clearOldToolOutput(_messages, needed: await _stillNeeded()) > 0) _rewriteMessages();
    final window = _spec.maxInputTokens ?? 0;
    if (window <= 0 || _spec.autoCompactAt <= 0 || lastPromptTokens < window * _spec.autoCompactAt) return;
    await compact();
  }

  /// On Thorough and up, when old tool output is about to be cleared: the
  /// call ids of the outputs the decider says the work still needs, cleared
  /// last. Empty (plain oldest-first) when it can't tell.
  Future<Set<String>> _stillNeeded() async {
    if (!(_spec.script?.smartCompaction ?? false)) return const {};
    final all = oldToolOutputs(_messages);
    if (all.isEmpty) return const {};
    // The newest 64 are scored; anything older goes first anyway.
    final old = all.length > 64 ? all.sublist(all.length - 64) : all;
    String text(Map<String, Object?> m) => switch (m['content']) {
      final String s => s,
      final List<Object?> parts => [
        for (final p in parts)
          if (p case {'type': 'text', 'text': final String t}) t,
      ].join('\n'),
      _ => '',
    };
    String cut(String s, int n) => s.length > n ? '${s.substring(0, n)}…' : s;
    // The work in progress: the latest user message and what the agent last said.
    final user = _messages.lastWhere((m) => m['role'] == 'user', orElse: () => const {});
    final said = _messages.lastWhere((m) => m['role'] == 'assistant' && text(m).isNotEmpty, orElse: () => const {});
    final focus = 'Task: ${cut(text(user), 2000)}\nAgent, latest: ${cut(text(said), 1000)}';
    final needed = <String>{};
    for (var start = 0; start < old.length; start += 32) {
      final batch = old.sublist(start, (start + 32).clamp(0, old.length));
      final q = neededQuestions(batch, focus);
      try {
        final answers = await _gateway.decide(q.text, q.questions, sessionTag: _spec.sessionTag, job: 'compaction');
        for (final (n, o) in batch.indexed) {
          // Unsure counts as needed: clearing it can wait.
          if (answers['o$n'] != false) needed.add(o.callId);
        }
      } on LlmError {
        return const {};
      }
    }
    return needed;
  }

  /// Compacts now (auto-compact, or `/compact` with [focus]). False when
  /// there was nothing to summarize or the summary came back unusable.
  @override
  Future<bool> compact({String focus = ''}) async {
    final since = _history.lastIndexWhere((e) => e is ChatMessage && e.fromUser && splitCompacted(e.text) != null);
    final plan = planCompaction(_history.sublist(since < 0 ? 0 : since));
    if (plan == null) return false;
    final reply = await _gateway.raw(
      {'model': _spec.model, 'messages': summaryRequest(plan, focus: focus), 'max_tokens': 6000},
      sessionTag: _spec.sessionTag,
      retry: retryPolicy,
      onRetry: _retrying,
      wait: _retryWait,
      cancel: _cancel?.future,
    );
    final text = switch (reply['choices']) {
      [{'message': {'content': final String c}}, ...] => c,
      _ => '',
    };
    final summary = cleanSummary(text);
    if (summary == null) return false;
    final kept = _carriedState();
    final message = continuationMessage(
      summary: summary,
      recent: renderTail(plan),
      resume: _looping,
      plan: kept.plan,
      todos: kept.todos,
      files: kept.files,
      skills: kept.skills,
    );
    final eid = _newId();
    _emit({
      'kind': 'MessageEvent',
      'id': eid,
      'source': 'user',
      'llm_message': {'role': 'user', 'content': message},
    });
    final system = _messages.first;
    _messages
      ..clear()
      ..add(system)
      ..add({'role': 'user', 'content': message, '_eid': eid});
    _rewriteMessages();
    lastPromptTokens = 0;
    return true;
  }

  /// [reply]'s text split around its tool calls: before the first, before
  /// each later one (by position), and after the last.
  static (String, Map<int, String>, String) _split(LlmReply reply) {
    if (reply.order.isEmpty) return (reply.text, const {}, '');
    var lead = '';
    final between = <int, String>{};
    var pending = StringBuffer();
    var seenCall = false;
    for (final o in reply.order) {
      if (o is String) {
        pending.write(o);
      } else if (o is int) {
        if (!seenCall) {
          lead = pending.toString();
          seenCall = true;
        } else {
          between[o] = pending.toString();
        }
        pending = StringBuffer();
      }
    }
    if (!seenCall) return (reply.text, const {}, '');
    return (lead, between, pending.toString());
  }

  /// Identical tool calls in a row that make a loop: the last one isn't run.
  static const doomRepeats = 3;

  String? _lastCall;
  var _callRun = 0;

  /// How many times in a row [call] (same tool, same arguments) was made,
  /// itself included. Talking to the user and the todo list don't count;
  /// a user message starts the count over.
  int _repeats(LlmToolCall call) {
    if (clientTools.contains(call.name) || call.name == ToolNames.todo || call.name == bugCheckTool) return 0;
    final sig = '${call.name}\u0000${call.arguments}';
    _callRun = sig == _lastCall ? _callRun + 1 : 1;
    _lastCall = sig;
    return _callRun;
  }

  /// Shows [calls], waits for approval, runs them, and records the results.
  /// Calls whose arguments arrived cut off, this session: the advice grows
  /// firmer each time (one more whole-file attempt is what fails).
  var _cutOffs = 0;

  String _cutOffAdvice(String tool) {
    _cutOffs++;
    final writes = tool == ToolNames.write || tool == ToolNames.edit || tool == ToolNames.applyPatch;
    if (!writes) {
      return 'Error: the arguments for $tool were not valid JSON (the reply was likely cut off). Nothing ran. Call '
          'it again with complete, shorter arguments.';
    }
    if (_cutOffs == 1) {
      return 'Error: the $tool call was cut off before its arguments were complete, so nothing was written. Write '
          'the file in parts: the first ~$writePartLines lines with write, then each next part with write mode '
          '"append" (or a skeleton, then edit per section).';
    }
    return 'Error: the $tool call was cut off again and nothing was written. Do NOT try the whole file in one call '
        'again. Send parts of at most ~$writePartLines lines: write the first part now, then one write with mode '
        '"append" per part, each in its own turn.';
  }

  /// True when the run should stop (refused or interrupted).
  Future<bool> _handleCalls(
    List<LlmToolCall> calls,
    Completer<void> cancel, {
    Map<int, String> textBefore = const {},
    String trailing = '',
  }) async {
    final waiting = <({LlmToolCall call, String actionId})>[];
    void say(String text) {
      if (text.trim().isEmpty) return;
      _emit({
        'kind': 'MessageEvent',
        'id': _newId(),
        'source': 'agent',
        'llm_message': {'role': 'assistant', 'content': text.trim()},
      });
    }

    for (final (n, call) in calls.indexed) {
      say(textBefore[n] ?? '');
      final actionId = _newId();
      final args = call.args;
      _emit({
        'kind': 'ActionEvent',
        'id': actionId,
        'tool_name': call.name,
        'tool_call_id': call.id,
        'tool_call': {'name': call.name, 'arguments': call.arguments},
        'action': _mcp.has(call.name)
            ? {'kind': 'MCPToolAction', ...?args}
            : args == null
            ? {'kind': actionKinds[call.name] ?? ''}
            : actionFor(call.name, args, _spec.workingDir),
        'security_risk': 'UNKNOWN',
      });
      // A fork's questions go to the agent that started it (the app routes
      // them); the other client tools are the orchestrator's.
      if (isFork && clientTools.contains(call.name) && call.name != askUserQuestionTool) {
        // A fork keeps the parent's tools (for the cache) but can't use these.
        _result(
          call,
          actionId,
          ToolOutput(
            'Error: a fork cannot use ${call.name}. Finish the task with your other tools and put everything in your '
            'final message.',
            isError: true,
          ),
        );
        continue;
      }
      // A research job's shell or out-of-bounds write is refused here, not
      // after it waited for an approval no one may be watching for.
      final early = args == null ? null : _tools.refusalBeforeApproval(call.name, args);
      if (early != null) {
        _result(call, actionId, ToolOutput(early, isError: true));
        continue;
      }
      if (args != null && _flow != null) {
        _flow!.onCall(call.name, args);
        final refusal = _flow!.gate(
          call.name,
          args,
          inScratch: (p) => resolvePath(_spec.workingDir, p).startsWith('${_spec.workingDir}/.everyai/scratch/'),
        );
        if (refusal != null) {
          _result(call, actionId, ToolOutput(refusal, isError: true));
          continue;
        }
      }
      if (args != null && _repeats(call) >= doomRepeats) {
        _result(
          call,
          actionId,
          ToolOutput(
            'Not run: this is the $doomRepeats${doomRepeats == 3 ? 'rd' : 'th'} identical ${call.name} call in a row, '
            'and it will give the same result. Change your approach: read the error closely, try something '
            'different, or ask the user with ask_user_question if you are stuck.',
            isError: true,
          ),
        );
        continue;
      }
      if (args == null) {
        // A call cut off or garbled: never run, the model is told why.
        _result(call, actionId, ToolOutput(_cutOffAdvice(call.name), isError: true));
        continue;
      }
      waiting.add((call: call, actionId: actionId));
    }
    say(trailing);
    if (waiting.isEmpty) return false;
    // One decision per call: the user (or the app's rules) can allow some and
    // refuse others; the calls run once every one of them has an answer.
    _denyAll = false;
    _decisions
      ..clear()
      ..addAll({for (final w in waiting) w.actionId: Completer<({bool accept, String? reason})>()});
    _setStatus(ExecutionStatus.waitingForConfirmation);
    final verdicts = await Future.wait([for (final w in waiting) _decisions[w.actionId]!.future]);
    _decisions.clear();
    final denyAll = _denyAll;
    _denyAll = false;
    final approved = <({LlmToolCall call, String actionId})>[];
    var moved = false;
    for (final (n, w) in waiting.indexed) {
      final verdict = verdicts[n];
      if (verdict.accept) {
        if (w.call.name == presentPlanTool) _planApproved(w.call);
        approved.add(w);
        continue;
      }
      final reason = verdict.reason ?? '';
      if (w.call.name == presentPlanTool && reason.startsWith(planApprovedReason)) _planApproved(w.call);
      if (_flow?.onAnswer(w.call.name, w.call.args ?? const {}, reason, callId: w.actionId) ?? false) moved = true;
      _emit({
        'kind': 'UserRejectObservation',
        'id': _newId(),
        'action_id': w.actionId,
        'tool_name': w.call.name,
        'rejection_reason': reason,
      });
      _append({
        'role': 'tool',
        'tool_call_id': w.call.id,
        'content': reason.isEmpty ? 'The user declined this call.' : reason,
        '_eid': w.actionId,
      });
    }
    if (moved) _notePhase();
    if (_flow != null && approved.length < waiting.length) _saveFlow();
    if (approved.isEmpty && (denyAll || cancel.isCompleted)) {
      // Parked like the agent-server: a refusal the app decided is followed
      // by resume(); the user's own "Deny all" leaves it waiting for them.
      _setStatus(ExecutionStatus.paused);
      return true;
    }
    _setStatus(ExecutionStatus.running);
    // Calls that only look run together (up to 8 at a time, results in
    // order); the rest one by one.
    var i = 0;
    while (i < approved.length) {
      if (cancel.isCompleted) {
        for (final w in approved.skip(i)) {
          _result(w.call, w.actionId, const ToolOutput('Not run: the user stopped the agent.', isError: true));
        }
        _flushImages();
        _setStatus(ExecutionStatus.paused);
        return true;
      }
      final batch = [approved[i]];
      while (_readOnly(batch.last.call) &&
          batch.length < maxParallelReads &&
          i + batch.length < approved.length &&
          _readOnly(approved[i + batch.length].call)) {
        batch.add(approved[i + batch.length]);
      }
      final outputs = await Future.wait([for (final w in batch) _execute(w.call, cancel.future)]);
      for (final (n, w) in batch.indexed) {
        _result(w.call, w.actionId, outputs[n]);
        _track(w.call, outputs[n]);
      }
      i += batch.length;
    }
    _flushImages();
    if (_notePhaseAfter) {
      _notePhaseAfter = false;
      _notePhase();
    }
    return false;
  }

  /// Most read-only calls run at once.
  static const maxParallelReads = 8;

  static bool _readOnly(LlmToolCall call) => runsInParallel(call);

  Future<ToolOutput> _execute(LlmToolCall call, Future<void> cancel) async {
    if (call.name == ToolNames.bash && isWaitCommand(call.args!['command'] as String? ?? '')) {
      // A sleep to wait for something (a background fork, say) ends when a
      // message arrives, so the agent reads it at once.
      if (_arrived.isCompleted) _arrived = Completer<void>();
      final arrived = _arrived.future;
      var woke = false;
      final out = await _tools.run(
        call.name,
        call.args!,
        cancel: Future.any([cancel, arrived.then((_) => woke = true)]),
      );
      if (!woke) return out;
      return const ToolOutput(
        '[Cut short: a message arrived (below). You never need to sleep to wait for background tasks: end your turn '
        'and their notifications wake you.]',
      );
    }
    if (call.name == bugCheckTool) return _bugCheck(call.args!, cancel);
    if (call.name == ToolNames.runScript) return _runScript(call.args!, cancel);
    if (call.name == ToolNames.memory) {
      if (_spec.researchSites != null) {
        return const ToolOutput(
          'Error: research jobs keep notes under their scratch folder, not in the project memory.',
          isError: true,
        );
      }
      return runMemory(_spec.workingDir, call.args!);
    }
    if (actionKinds.containsKey(call.name)) return _tools.run(call.name, call.args!, cancel: cancel);
    if (_spec.researchSites != null && (_mcp.has(call.name) || call.name.startsWith('mcp'))) {
      return const ToolOutput('Error: research jobs have no MCP tools. Use web_fetch and web_search.', isError: true);
    }
    if (_mcp.has(call.name)) {
      final out = await _mcp.call(call.name, call.args!);
      if (out.images.isNotEmpty && !_spec.vision) {
        return ToolOutput('${out.text}\n(${out.images.length} image(s) left out: this model can\'t view images.)');
      }
      return out;
    }
    // A client tool the app approved without answering it (present_files).
    return const ToolOutput('Shown to the user.');
  }

  /// Whether the session offers run_script: its tier allows it and Deno is
  /// here (decided once, so the tool list stays as it was).
  late final bool _scripting = (_spec.script?.enabled ?? false) && findDeno() != null;

  ScriptRunner _scriptRunner() => ScriptRunner(
    deno: findDeno()!,
    dir: '${_dir.path}/scripts',
    root: _spec.workingDir,
    pathMap: _spec.pathMap,
    tools: _tools,
    gateway: _gateway,
    sessionTag: _spec.sessionTag,
  );

  /// Runs a run_script program; the transcript row gets its calls and counts.
  Future<ToolOutput> _runScript(Map<String, Object?> args, Future<void> cancel) async {
    final caps = _spec.script;
    if (caps == null || !_scripting) {
      return const ToolOutput(
        'Error: run_script is not available in this session. Use your other tools.',
        isError: true,
      );
    }
    final code = args['code'] as String? ?? '';
    if (code.trim().isEmpty) return const ToolOutput('Error: give the program as code.', isError: true);
    final seconds = ((args['timeout_seconds'] as num?)?.toInt() ?? caps.timeoutSeconds).clamp(5, 600);
    final runner = _scriptRunner();
    final budget = ScriptBudget(caps);
    final r = await runner.run(
      code,
      budget: budget,
      timeout: Duration(seconds: seconds),
      cancel: cancel,
    );
    return ToolOutput(
      runner.describe(r),
      isError: r.exitCode != 0 || r.timedOut,
      observation: {
        'exit_code': r.exitCode,
        'timed_out': r.timedOut,
        'decides': budget.decides,
        'queries': budget.queries,
        'call_count': r.calls.length,
        'calls': [
          for (final c in r.calls.take(200)) {'fn': c.fn, 'detail': c.detail, 'failed': c.failed},
        ],
      },
    );
  }

  /// Bug fix mode's proofs: the harness runs the repro itself, so a fix the
  /// model only claims doesn't count.
  Future<ToolOutput> _bugCheck(Map<String, Object?> args, Future<void> cancel) async {
    final f = _flow;
    if (f == null || !f.bugfix) return const ToolOutput('Error: bug_check is for Bug fix mode.', isError: true);
    Future<({int exit, String out})> run(String command) async {
      final r = await _tools.run(ToolNames.bash, {'command': command, 'timeout': 300000}, cancel: cancel);
      return (exit: (r.observation['exit_code'] as num?)?.toInt() ?? (r.isError ? 1 : 0), out: r.text);
    }

    String tail(String out) => out.length > 3000 ? '…${out.substring(out.length - 3000)}' : out;
    final action = args['action'] as String? ?? '';
    final ToolOutput result;
    switch (action) {
      case 'reproduced':
        final command = (args['command'] as String? ?? '').trim();
        final expect = (args['expect'] as String? ?? '').trim();
        if (command.isEmpty) return const ToolOutput('Error: give the command that shows the bug.', isError: true);
        final r = await run(command);
        final shown = expect.isNotEmpty ? r.out.contains(expect) : r.exit != 0;
        // Any failure counts without `expect`: the decider checks it is this bug, not another one.
        final match = shown && expect.isEmpty ? await _reproMatch(command, r.out) : 'bug';
        if (match == 'other') {
          return ToolOutput(
            'Not reproduced: the command fails, but its output reads as a different failure than the bug described '
            '(a build or setup error, say). Make the repro fail on exactly this bug, or pass `expect` with the text '
            'in the output that shows it.\n${tail(r.out)}',
            isError: true,
            observation: const {'repro_match': 'other'},
          );
        }
        if (f.reproduced(command, expect, shown: shown)) {
          f.reproFiles
            ..clear()
            ..addAll(await _reproSnapshot(command));
          result = ToolOutput(
            'Reproduced: the harness ran it and saw the bug.\n${tail(r.out)}',
            observation: {'repro_match': match},
          );
          _notePhaseAfter = true;
        } else {
          result = ToolOutput(
            'Not reproduced: the harness ran it and ${expect.isNotEmpty ? 'the output lacks "$expect"' : 'it '
                      'exited 0'}. Find a command that really shows the bug, or ask the user how to reproduce it.\n'
            '${tail(r.out)}',
            isError: true,
          );
        }
      case 'confirmed_by_user':
        if (f.confirmedByUser()) {
          result = const ToolOutput('Recorded: the user confirmed the bug.');
          _notePhaseAfter = true;
        } else {
          result = const ToolOutput(
            'Error: ask the user first (ask_user_question) whether what you describe is the bug.',
            isError: true,
          );
        }
      case 'triage':
        final hard = args['kind'] == 'hard';
        f.triage(hard: hard);
        result = ToolOutput('Triaged as ${hard ? 'hard: research it first' : 'simple: plan the fix'}.');
        _notePhaseAfter = true;
      case 'verify':
        if (f.reproByUser) {
          if (!f.askedUser) {
            return const ToolOutput(
              'Error: this bug was confirmed by the user, so ask them (ask_user_question) whether it is gone first.',
              isError: true,
            );
          }
          f.askedUser = false;
          f.verified(gone: true);
          result = const ToolOutput('Verified by the user.');
          _notePhaseAfter = true;
          break;
        }
        // The repro has to pass as it was: a test edited into passing proves nothing.
        final changed = f.changedReproFiles(
          _digests(f.reproFiles.keys),
          before: (p) => _readOr('${_dir.path}/repro-files/$p'),
          after: (p) => _readOr('${_spec.workingDir}/$p'),
        );
        if (changed.isNotEmpty) {
          if (!f.askedUser) {
            return ToolOutput(
              'Not verified: the fix changed what reproduces the bug (${changed.take(8).join(', ')}). The original '
              'repro has to pass unchanged. Restore those files; if a test itself was wrong, ask the user '
              '(ask_user_question) whether to change it, then call verify again.',
              isError: true,
            );
          }
          f.askedUser = false;
          f.reproFiles
            ..clear()
            ..addAll(await _reproSnapshot(f.reproCommand));
        }
        final r = await run(f.reproCommand);
        final gone = r.exit == 0 && (f.reproExpect.isEmpty || !r.out.contains(f.reproExpect));
        final moved = f.verified(gone: gone);
        if (gone) {
          result = ToolOutput('Verified: the harness ran the repro again and the bug is gone.\n${tail(r.out)}');
        } else {
          result = ToolOutput(
            moved
                ? 'Still failing, after ${f.failedFixes} fixes. Stop trying variations: the cause is not '
                      'understood yet. The flow goes back to research: find how others fixed this, then plan again.'
                      '\n${tail(r.out)}'
                : 'Still failing: the harness ran the repro and the bug is still there. Do not try another variation; '
                      'rethink the cause from the evidence.\n${tail(r.out)}',
            isError: true,
          );
        }
        if (moved) _notePhaseAfter = true;
      default:
        return ToolOutput('Error: unknown bug_check action "$action".', isError: true);
    }
    _saveFlow();
    return result;
  }

  /// Whether a failing repro's output shows the bug the user described
  /// ('bug'), another failure ('other'), or the decider can't tell
  /// ('unsure', which counts as shown).
  Future<String> _reproMatch(String command, String output) async {
    final task = _messages.firstWhere((m) => m['role'] == 'user', orElse: () => const {})['content'];
    final report = switch (task) {
      final String t => t,
      final List<Object?> parts => [
        for (final p in parts)
          if (p case {'type': 'text', 'text': final String t}) t,
      ].join('\n'),
      _ => '',
    };
    String cut(String s, int n) => s.length > n ? s.substring(s.length - n) : s;
    try {
      final a = await _gateway.decide(
        '<bug-report>\n${report.length > 4000 ? report.substring(0, 4000) : report}\n</bug-report>\n'
        '<command>$command</command>\n<output>\n${cut(output, 6000)}\n</output>',
        const [
          {
            'id': 'shows',
            'kind': 'choice',
            'prompt':
                'Does this failing output show the bug in the report ("bug"), or a different failure such as a '
                'build, setup or unrelated error ("other")?',
            'choices': ['bug', 'other'],
          },
        ],
        sessionTag: _spec.sessionTag,
        job: 'repro',
      );
      return switch (a['shows']) {
        'bug' => 'bug',
        'other' => 'other',
        _ => 'unsure',
      };
    } on LlmError {
      return 'unsure';
    }
  }

  /// The tests and repro scripts the bug was reproduced with (path →
  /// digest): tracked or new test files, `.everyai/scratch/` scripts, and
  /// files the command names.
  Future<Map<String, String>> _reproSnapshot(String command) async {
    final root = _spec.workingDir;
    final paths = <String>{};
    try {
      final r = await Process.run('git', ['ls-files', '-co', '--exclude-standard'], workingDirectory: root);
      if (r.exitCode == 0) {
        paths.addAll(const LineSplitter().convert('${r.stdout}').where(PhaseFlow.isReproPath).take(3000));
      }
    } on Object {
      // Not git: the scratch scripts and named files still count.
    }
    final scratch = Directory('$root/.everyai/scratch');
    if (scratch.existsSync()) {
      for (final e in scratch.listSync(recursive: true).whereType<File>().take(500)) {
        final rel = e.path.substring(root.length + 1);
        if (PhaseFlow.isReproPath(rel)) paths.add(rel);
      }
    }
    for (final word in command.split(RegExp(r'\s+'))) {
      final w = word.replaceAll(RegExp('^[\'"]+|[\'"]+\$'), '');
      if (w.isEmpty || w.startsWith('-')) continue;
      final full = resolvePath(root, w);
      if (full.startsWith('$root/') && File(full).existsSync()) paths.add(full.substring(root.length + 1));
    }
    // Copies to compare against at verify (a file that only gained lines is fine).
    final copies = Directory('${_dir.path}/repro-files');
    if (copies.existsSync()) copies.deleteSync(recursive: true);
    for (final p in paths) {
      final f = File('$root/$p');
      if (!f.existsSync() || f.lengthSync() > 512000) continue;
      File('${copies.path}/$p')
        ..createSync(recursive: true)
        ..writeAsBytesSync(f.readAsBytesSync());
    }
    return _digests(paths);
  }

  static String? _readOr(String path) {
    try {
      return File(path).readAsStringSync();
    } on Object {
      return null;
    }
  }

  /// [paths] (relative to the project) → a digest of each file's bytes;
  /// a missing file has none.
  Map<String, String> _digests(Iterable<String> paths) => {
    for (final p in paths)
      if (File('${_spec.workingDir}/$p') case final f when f.existsSync())
        p: sha256.convert(f.readAsBytesSync()).toString().substring(0, 24),
  };

  /// A bug_check moved the flow: its note follows this turn's results.
  bool _notePhaseAfter = false;

  void _result(LlmToolCall call, String actionId, ToolOutput out) {
    _emit({
      'kind': 'ObservationEvent',
      'id': _newId(),
      'action_id': actionId,
      'tool_name': call.name,
      'observation': {
        ...out.observation,
        'content': [
          {'type': 'text', 'text': out.text},
        ],
        'is_error': out.isError,
      },
    });
    _append({'role': 'tool', 'tool_call_id': call.id, 'content': out.text, '_eid': actionId});
    _pendingImages.addAll(out.images);
  }

  /// Pictures from this turn's tool results, sent once every result is in.
  final _pendingImages = <ToolImage>[];

  /// The pictures as one user message after the tool results: tool results
  /// can't carry images on every provider, a user message can.
  void _flushImages() {
    if (_pendingImages.isEmpty) return;
    _append({
      'role': 'user',
      'content': [
        for (final i in _pendingImages) ...[
          {'type': 'text', 'text': '<tool-image>${i.label}</tool-image>'},
          {
            'type': 'image_url',
            'image_url': {'url': i.dataUrl},
          },
        ],
      ],
      '_eid': _newId(),
    });
    _pendingImages.clear();
  }
}

/// Tools that only look at things.
const _readOnlyTools = {
  ToolNames.read,
  ToolNames.grep,
  ToolNames.glob,
  ToolNames.webFetch,
  ToolNames.webSearch,
  ToolNames.bashOutput,
};

/// A call that only looks, so it may run beside other such calls: a reading
/// tool, or a shell command the classifier vouches for (not `cd`, which
/// moves the shell, nor a wait or a background job).
bool runsInParallel(LlmToolCall call) {
  if (_readOnlyTools.contains(call.name)) return true;
  if (call.name != ToolNames.bash && call.name != 'terminal') return false;
  final args = call.args;
  if (args == null || args['run_in_background'] == true) return false;
  final command = args['command'] as String? ?? '';
  if (!isReadOnlyShell(command) || isWaitCommand(command)) return false;
  return !(shellSegments(command) ?? const []).any((w) => w.isNotEmpty && w.first == 'cd');
}

/// Keeps the harness's own files (`.everyai/scratch`, `.everyai/spill`) out
/// of git status and diffs in [dir]'s repository, through the clone-local
/// `info/exclude` so nothing the user commits changes. Not a repo: nothing.
Future<void> excludeScratch(String dir) async {
  try {
    final res = await Process.run('git', ['rev-parse', '--git-path', 'info/exclude'], workingDirectory: dir);
    if (res.exitCode != 0) return;
    var path = (res.stdout as String).trim();
    if (!path.startsWith('/')) path = '$dir/$path';
    final file = File(path);
    final current = file.existsSync() ? file.readAsStringSync() : '';
    const lines = ['.everyai/scratch/', '.everyai/spill/', '.everyai/plans/', '.everyai/memory.md'];
    final missing = lines.where((l) => !current.split('\n').contains(l)).toList();
    if (missing.isEmpty) return;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${current.isEmpty || current.endsWith('\n') ? '' : '\n'}# EveryAI agent scratch files\n${missing.join('\n')}\n',
      mode: FileMode.append,
    );
  } on Object {
    // Not git, or git missing: the files just show up as untracked.
  }
}

/// [messages] without `_eid`, the oldest pictures as a note: none while at
/// most [kept] × 2 − 1 are there, then whole batches of [kept] (the oldest
/// first), so the history before the newest pictures changes rarely and the
/// prompt cache holds.
@visibleForTesting
List<Map<String, Object?>> withOlderImagesNoted(List<Map<String, Object?>> messages, int kept) {
  bool isImage(Object? part) => part is Map && part['type'] == 'image_url';
  final total = messages.fold<int>(
    0,
    (n, m) => n + (m['content'] is List<Object?> ? (m['content']! as List<Object?>).where(isImage).length : 0),
  );
  final drop = total < kept * 2 ? 0 : ((total - kept) ~/ kept) * kept;
  var seen = 0;
  return [
    for (final m in messages)
      () {
        var msg = m.containsKey('_eid') ? (Map.of(m)..remove('_eid')) : m;
        if (msg['content'] case final List<Object?> parts when seen < drop && parts.any(isImage)) {
          msg = {
            ...msg,
            'content': [
              for (final p in parts)
                if (isImage(p) && seen++ < drop)
                  {'type': 'text', 'text': '(an older picture, no longer attached)'}
                else
                  p,
            ],
          };
        }
        return msg;
      }(),
  ];
}
