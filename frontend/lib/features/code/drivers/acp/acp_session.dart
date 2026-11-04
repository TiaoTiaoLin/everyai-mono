// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../domain/agent_mode.dart';
import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../briefing/briefing_types.dart';
import '../briefing/recipes.dart' show acpMcpServer;
import '../driver.dart';
import '../driver_events.dart';
import '../driver_policy.dart' show rewindRefusal;
import '../event_journal.dart';
import '../json_rpc.dart';
import 'acp_agents.dart';
import 'acp_files.dart';
import 'acp_mapping.dart';

/// Starts an ACP agent's process (`spawnDriver`, or a recorded one in tests).
typedef AcpConnect = Future<LineChannel> Function({
  required String executable,
  required List<String> args,
  required String cwd,
  required String sessionTag,
  required String logPath,
  required Map<String, String> env,
});

/// What a session needs from its driver.
final class AcpLauncher {
  const AcpLauncher({
    required this.info,
    required this.caps,
    required this.command,
    required this.resolve,
    required this.connect,
    required this.initTimeout,
    required this.offered,
    required this.closed,
  });

  final DriverInfo info;
  final Set<DriverCap> caps;
  final AcpCommand command;

  /// The executable's absolute path; throws [HarnessError] when it is missing.
  final Future<String> Function() resolve;
  final AcpConnect connect;
  final Duration initTimeout;

  /// A `session/new` or `session/load` reply, for the models list.
  final Future<void> Function(Map<String, Object?> reply) offered;

  /// The session closed.
  final void Function(String conversationId) closed;
}

/// One conversation with an ACP agent (agentclientprotocol.com). The agent
/// uses its own file and shell tools (the client offers no `fs`/`terminal`);
/// every call it asks about comes as `session/request_permission`, which the
/// app's rules or the user answer per call. The transcript is the event
/// journal in [dir]; after an app restart the agent's own memory comes back
/// through `session/load` when the next message is sent.
final class AcpSession implements HarnessSession, PerCallApprovals {
  AcpSession({
    required this.id,
    required this.dir,
    required this.cwd,
    required this.sessionTag,
    required this._launcher,
    required this._mode,
    this.briefing,
    this.mcpConfig = const {},
    this._acpSessionId,
    List<HarnessEvent> history = const [],
  }) : _journal = openEventJournal(dir, 'events') {
    _history.addAll(history);
  }

  /// The conversation id the app stores.
  @override
  final String id;

  /// `<dataDir>/acp-sessions/<id>`: `meta.json`, `events.jsonl`, `stderr.log`.
  final String dir;
  final String cwd;
  final String sessionTag;
  final DriverBriefing? briefing;
  final Map<String, Object?> mcpConfig;

  final AcpLauncher _launcher;
  final EventJournal _journal;
  final _history = <HarnessEvent>[];
  final _listeners = <StreamController<HarnessEvent>>{};
  final _run = const Uuid().v4().substring(0, 8);
  var _seq = 0;

  AgentMode _mode;
  ({String model, String? effort})? _llm;
  String? _acpSessionId;
  JsonRpcPeer? _peer;
  Future<void>? _connecting;
  Map<String, Object?> _agentCaps = const {};
  List<Object?> _authMethods = const [];
  List<Object?>? _config;
  Map<String, Object?>? _modes;
  Map<String, Object?>? _models;
  String? _firstPrompt;
  Set<String> _mcpNames = const {};

  /// Updates are the agent's replay of a reopened conversation until the
  /// next prompt; the journal already shows it.
  var _replaying = false;
  var _status = ExecutionStatus.idle;
  Future<void> _turns = Future.value();
  Future<void>? _turn;
  var _cancelled = false;
  var _parked = false;
  var _paused = false;
  var _closed = false;
  double? _cost;
  final _text = StringBuffer();
  final _reasoning = StringBuffer();

  /// Tool calls by ACP id, merged; which were shown, which finished.
  final _calls = <String, Map<String, Object?>>{};
  final _shown = <String, ActionCall>{};
  final _done = <String>{};

  /// Permission requests waiting for an answer, by action id.
  final _asking = <String, ({Completer<Object?> reply, List<Object?> options, String callId})>{};

  /// Why calls were refused, for the next prompt (ACP has no reason field).
  final _notes = <String>[];

  /// Messages sent with `run: false`, for the next prompt.
  final _held = <({String text, List<String> images})>[];

  ExecutionStatus get status => _status;
  String get _label => _launcher.info.label;
  AcpProfile get _profile => _launcher.command.profile;

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

  // ------------------------------------------------------------- lifecycle

  /// Starts the agent on a new conversation (a fresh session).
  Future<void> open({String? model, String? effort}) async {
    _llm = model == null ? null : (model: model, effort: effort);
    await _ensureConnected(fresh: true);
  }

  /// A reopened conversation: what it showed, and a run cut off by the app
  /// closing marked as stopped.
  void reopened() {
    final results = {for (final e in _history.whereType<ToolResult>()) e.actionId};
    final open = [
      for (final e in _history.whereType<ActionCall>())
        if (!results.contains(e.id)) e,
    ];
    final last = _history.whereType<StateChange>().lastOrNull?.executionStatus;
    _status = last ?? ExecutionStatus.idle;
    for (final c in open) {
      _emit(resultEvent(id: '${c.id}-x', actionId: c.id, toolName: c.toolName, text: 'Stopped when the app closed.'));
    }
    if (last == ExecutionStatus.running || last == ExecutionStatus.waitingForConfirmation) {
      _setStatus(ExecutionStatus.paused);
    }
  }

  Future<void> _ensureConnected({bool fresh = false}) {
    if (_peer case final p? when !p.isClosed) return Future.value();
    return _connecting ??= _connect(fresh: fresh).whenComplete(() => _connecting = null);
  }

  Future<void> _connect({required bool fresh}) async {
    final exe = await _launcher.resolve();
    final delivery = await _delivery();
    final cmd = _launcher.command;
    final channel = await _launcher.connect(
      executable: exe,
      args: addArgs(cmd.args, delivery?.args ?? const []),
      cwd: cwd,
      sessionTag: sessionTag,
      logPath: '$dir/stderr.log',
      env: _profile.env(delivery),
    );
    final peer = JsonRpcPeer(channel, onRequest: _onRequest, onNotify: _onNotify);
    _peer = peer;
    unawaited(peer.done.then((_) => _gone(peer)));
    try {
      final init = _map(
        await peer.request('initialize', {
          'protocolVersion': 1,
          'clientCapabilities': {
            'fs': {'readTextFile': false, 'writeTextFile': false},
            'terminal': false,
          },
          'clientInfo': {'name': 'everyai', 'title': 'EveryAI', 'version': '0.1.0'},
        }, _launcher.initTimeout),
      );
      if (init['protocolVersion'] != 1) {
        throw HarnessError("$_label speaks ACP version ${init['protocolVersion']}, which this app doesn't.");
      }
      _agentCaps = _map(init['agentCapabilities']);
      _authMethods = init['authMethods'] as List<Object?>? ?? const [];
      final mcp = _mcpServers();
      Map<String, Object?>? reply;
      final known = _acpSessionId;
      if (!fresh && known != null && _agentCaps['loadSession'] == true) {
        _replaying = true;
        try {
          reply = _map(await peer.request('session/load', {'sessionId': known, 'cwd': cwd, 'mcpServers': mcp}));
        } on JsonRpcError catch (e) {
          if (e.code != -32602 || peer.isClosed) rethrow;
        }
      }
      if (reply == null) {
        _replaying = false;
        reply = _map(await peer.request('session/new', {'cwd': cwd, 'mcpServers': mcp}));
        _acpSessionId = reply['sessionId'] as String?;
        if (_acpSessionId == null) throw HarnessError("$_label didn't start a session.");
        _firstPrompt = delivery?.firstPrompt;
        if (!fresh) {
          _emit(
            acpNotice(
              _next('n'),
              "$_label couldn't reopen its conversation, so it starts fresh. The history above is for you only.",
            ),
          );
        }
      }
      _absorb(reply);
      await _launcher.offered(reply);
      await _saveMeta();
      await _pinMode();
      if (_llm case final l?) await _applyLlm(l.model, l.effort, strict: false);
    } on TimeoutException {
      await peer.close();
      throw HarnessError(
        "$_label didn't start. If it asks you to sign in, run `${cmd.executable}` in a terminal once, then try again.",
      );
    } on JsonRpcError catch (e) {
      final closed = peer.isClosed;
      await peer.close();
      throw HarnessError(_errorText(e, closed: closed));
    } on Object {
      await peer.close();
      rethrow;
    }
  }

  /// The agent went away: nothing it asked about can be answered now.
  void _gone(JsonRpcPeer peer) {
    if (!identical(_peer, peer)) return;
    _peer = null;
    for (final a in _asking.values) {
      if (!a.reply.isCompleted) a.reply.complete(_cancelledOutcome);
      _cancelledResult(a.callId);
    }
    _asking.clear();
  }

  Future<Delivery?> _delivery() async {
    final b = briefing;
    if (b == null || b.skillDir == null || b.sessionSkill == null) return null;
    final input = (
      mcpUrl: Uri.parse(b.mcpUrl),
      mcpToken: b.mcpToken,
      skillDir: b.skillDir!,
      sessionText: b.sessionSkill!,
    );
    return _profile.deliver(input, await listSkills(b.skillDir!));
  }

  /// The session's MCP servers for `session/new`: ours over HTTP when the
  /// agent takes it (OpenCode gets it in its config), and the user's.
  List<Map<String, Object?>> _mcpServers() {
    final mcpCaps = _map(_agentCaps['mcpCapabilities']);
    final http = mcpCaps['http'] == true;
    final b = briefing;
    final ours = <Map<String, Object?>>[
      if (b != null && http && !(_profile.mcpInConfig && b.skillDir != null && b.sessionSkill != null))
        acpMcpServer((mcpUrl: Uri.parse(b.mcpUrl), mcpToken: b.mcpToken, skillDir: '', sessionText: '')),
    ];
    final theirs = acpMcpServers({...mcpConfig}..remove(everyaiServerName), http: http, sse: mcpCaps['sse'] == true);
    _mcpNames = {if (b != null) everyaiServerName, ...mcpConfig.keys};
    return [...ours, ...theirs];
  }

  Future<void> _saveMeta() => writeJsonFile('$dir/meta.json', {
    'acpSessionId': _acpSessionId,
    'cwd': cwd,
    'sessionTag': sessionTag,
    'mode': _mode.name,
  });

  void _absorb(Map<String, Object?> reply) {
    if (reply['configOptions'] case final List<Object?> c) _config = c;
    if (reply['modes'] case final Map<String, Object?> m) _modes = {...m};
    if (reply['models'] case final Map<String, Object?> m) _models = {...m};
  }

  // ------------------------------------------------------- modes and model

  /// Keeps the agent in its asking mode (or read-only for Plan), so the app's
  /// rules decide every call; never a mode that skips asking.
  Future<void> _pinMode() async {
    final targets = [if (_mode == AgentMode.plan) ?_profile.planMode, ?_profile.askMode];
    for (final target in targets) {
      try {
        if (await _setOption('mode', target)) return;
        if (_modes case final m? when _offers(m['availableModes'], 'id', target)) {
          if (m['currentModeId'] != target) {
            await _peer!.request('session/set_mode', {'sessionId': _acpSessionId, 'modeId': target});
            m['currentModeId'] = target;
          }
          return;
        }
      } on JsonRpcError catch (e) {
        _emit(acpNotice(_next('n'), "$_label didn't switch to its $target mode: ${e.message}"));
        return;
      }
    }
  }

  /// Moves the agent to [model] and [effort] where it offers them. [strict]:
  /// one it can't take is an error (a switch the user asked for).
  Future<void> _applyLlm(String model, String? effort, {required bool strict}) async {
    final legacy = _models;
    final viaConfig = acpOption(_config, 'model') != null;
    if (!viaConfig && legacy == null) {
      if (strict) throw HarnessError("$_label can't change model mid-session.");
      return;
    }
    if (viaConfig) {
      if (!await _setOption('model', model) && strict) {
        throw HarnessError("$_label doesn't offer $model.");
      }
    } else if (legacy!['currentModelId'] != model) {
      if (_offers(legacy['availableModels'], 'modelId', model)) {
        await _peer!.request('session/set_model', {'sessionId': _acpSessionId, 'modelId': model});
        legacy['currentModelId'] = model;
      } else if (strict) {
        throw HarnessError("$_label doesn't offer $model.");
      }
    }
    if (effort != null) await _setOption('thought_level', effort);
  }

  /// Sets the config option of [category] to [value] when the agent offers
  /// it; true when it has that option at all (set now or already).
  Future<bool> _setOption(String category, String value) async {
    final o = acpOption(_config, category);
    if (o == null || !o.choices.any((c) => c.value == value)) return false;
    if (o.current != value) {
      _absorb(
        _map(
          await _peer!.request('session/set_config_option', {
            'sessionId': _acpSessionId,
            'configId': o.id,
            'value': value,
          }),
        ),
      );
    }
    return true;
  }

  static bool _offers(Object? list, String key, String value) =>
      (list as List<Object?>? ?? const []).any((m) => m is Map<String, Object?> && m[key] == value);

  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {
    _mode = mode;
    // Not running yet (a reopened conversation): set when it starts.
    if (_peer == null || _acpSessionId == null) return;
    await _saveMeta();
    await _pinMode();
  }

  @override
  Future<void> switchLlm(SessionSpec spec) async {
    _llm = (model: spec.model, effort: spec.effort);
    if (_peer == null || _acpSessionId == null) return;
    try {
      await _applyLlm(spec.model, spec.effort, strict: true);
    } on JsonRpcError catch (e) {
      throw HarnessError(_errorText(e, closed: _peer == null));
    }
  }

  @override
  Future<void> rewindTo(String? head) async => throw HarnessError(rewindRefusal(_launcher.info, _launcher.caps)!);

  // ------------------------------------------------------------------ turns

  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async {
    if (_closed) return;
    _emit(userMessageEvent(_next('u'), text, images: images));
    if (!run) {
      _held.add((text: text, images: images));
      return;
    }
    try {
      await _ensureConnected();
    } on HarnessError catch (e) {
      _emit(acpNotice(_next('n'), e.message));
      _setStatus(ExecutionStatus.error);
      return;
    }
    _queue(text, images);
  }

  void _queue(String text, List<String> images) {
    final pics = [for (final h in _held) ...h.images, ...images];
    final imagesOk = _map(_agentCaps['promptCapabilities'])['image'] == true;
    if (pics.isNotEmpty && !imagesOk) {
      _emit(acpNotice(_next('n'), "$_label can't read pictures, so ${pics.length} weren't sent."));
    }
    final b = StringBuffer();
    if (_firstPrompt case final first?) {
      b.write('<everyai-session>\n$first\n</everyai-session>\n\n');
      _firstPrompt = null;
    }
    if (_notes.isNotEmpty) {
      b.write('${_notes.join('\n')}\n\n');
      _notes.clear();
    }
    for (final h in _held) {
      b.write('${h.text}\n\n');
    }
    _held.clear();
    b.write(text);
    final blocks = acpPrompt(b.toString().trimRight(), images: pics, imagesOk: imagesOk);
    // One prompt at a time: Gemini aborts a prompt still running when the next comes.
    final turn = _turns.then((_) => _prompt(blocks));
    _turns = turn;
    _turn = turn;
  }

  Future<void> _prompt(List<Map<String, Object?>> blocks) async {
    final peer = _peer;
    if (peer == null || peer.isClosed || _closed) return;
    _replaying = false;
    _cancelled = false;
    _parked = false;
    _paused = false;
    _setStatus(ExecutionStatus.running);
    try {
      final reply = _map(await peer.request('session/prompt', {'sessionId': _acpSessionId, 'prompt': blocks}));
      _flush();
      if (acpTurnUsage(reply['usage'], id: _next('usage')) case final u?) _emit(u);
      final stop = reply['stopReason'];
      final note = switch (stop) {
        'max_tokens' => '$_label ran out of room for its reply.',
        'max_turn_requests' => '$_label stopped after its limit of steps in one turn.',
        'refusal' => '$_label refused to carry on with this request.',
        _ => null,
      };
      if (note != null) _emit(acpNotice(_next('n'), note));
      _setStatus(stop == 'cancelled' ? ExecutionStatus.paused : ExecutionStatus.finished);
    } on JsonRpcError catch (e) {
      _flush();
      _emit(acpNotice(_next('n'), _errorText(e, closed: peer.isClosed)));
      _setStatus(ExecutionStatus.error);
    }
  }

  /// A JSON-RPC error in plain words: a sign-in hint for ACP's
  /// `auth_required` (-32000), the agent's last words when it stopped.
  String _errorText(JsonRpcError e, {required bool closed}) {
    if (closed) {
      final why = e.message.startsWith('Stopped: ') ? e.message.substring('Stopped: '.length) : '';
      return why.isEmpty ? '$_label stopped.' : '$_label stopped: $why';
    }
    if (e.code == -32000) {
      final described = [
        for (final m in _authMethods.whereType<Map<String, Object?>>())
          if (m['description'] case final String d when d.isNotEmpty) d,
      ].firstOrNull;
      final hint = (described ?? _profile.signIn).replaceFirst(RegExp(r'\.$'), '');
      return hint.isEmpty
          ? "$_label isn't signed in. Sign in to it in a terminal, then try again."
          : "$_label isn't signed in. $hint, then try again.";
    }
    return '$_label: ${e.message}';
  }

  @override
  Future<void> interrupt() async {
    final turn = _turn;
    if (_status != ExecutionStatus.running && _status != ExecutionStatus.waitingForConfirmation) return;
    _cancel();
    for (final entry in _asking.entries.toList()) {
      entry.value.reply.complete(_cancelledOutcome);
      _cancelledResult(entry.value.callId);
    }
    _asking.clear();
    _flush();
    for (final callId in _shown.keys.toList()) {
      if (!_done.contains(callId)) _cancelledResult(callId);
    }
    if (turn == null) return;
    // The agent replies `cancelled`; one that doesn't is ended.
    await turn.timeout(
      const Duration(seconds: 15),
      onTimeout: () async {
        await _peer?.close();
        _setStatus(ExecutionStatus.paused);
      },
    );
  }

  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _peer?.notify('session/cancel', {'sessionId': _acpSessionId});
  }

  /// ACP has no pause: the turn is cancelled, and [resume] asks the agent to
  /// carry on.
  @override
  Future<void> pause() async {
    final running = _status == ExecutionStatus.running || _status == ExecutionStatus.waitingForConfirmation;
    await interrupt();
    if (running) _paused = true;
  }

  /// Carries on after [pause], or after every pending call was refused at once
  /// when there is a reason to pass on; otherwise nothing (refusing some calls
  /// doesn't stop the run).
  @override
  Future<void> resume() async {
    if (!_parked && !_paused) return;
    final paused = _paused;
    _parked = false;
    _paused = false;
    if (_notes.isEmpty && !paused) return;
    if (_peer == null) return;
    _queue(paused ? 'Carry on with the task where you stopped.' : '', const []);
  }

  // -------------------------------------------------------------- approvals

  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {
    final targets = [
      for (final id in callIds ?? _asking.keys.toList())
        if (_asking.containsKey(id)) id,
    ];
    if (targets.isEmpty) return;
    // Refusing every call at once stops the turn (spec: after session/cancel
    // every pending request is answered `cancelled`).
    final all = !accept && callIds == null;
    if (all) {
      _parked = true;
      _cancel();
    }
    for (final actionId in targets) {
      final a = _asking.remove(actionId)!;
      final call = _shown[a.callId];
      final title = call?.summary ?? '';
      String? option(String kind) => [
        for (final o in a.options.whereType<Map<String, Object?>>())
          if (o['kind'] == kind && o['optionId'] is String) o['optionId']! as String,
      ].firstOrNull;
      if (accept) {
        if (option('allow_once') case final id?) {
          a.reply.complete(_selected(id));
          continue;
        }
        // "Always" would outlast this answer; the app's own rules remember.
        _emit(acpNotice(_next('n'), '$_label only offered to always allow ${_quoted(title)}, so it was refused.'));
      }
      final refuse = option('reject_once');
      a.reply.complete(all || refuse == null ? _cancelledOutcome : _selected(refuse));
      final why = reason ?? (accept ? 'Only "always allow" was offered.' : 'Refused.');
      if (reason != null) _notes.add('The app refused ${_quoted(title)}: $reason');
      _done.add(a.callId);
      _emit(
        acpRejectedEvent(
          id: 'tr-${a.callId}',
          actionId: actionId,
          toolName: call?.toolName ?? '${acpToolPrefix}tool',
          reason: why,
        ),
      );
    }
    if (_asking.isEmpty && _status == ExecutionStatus.waitingForConfirmation && !all) {
      _setStatus(ExecutionStatus.running);
    }
  }

  static String _quoted(String title) => title.isEmpty ? 'a step' : '"$title"';

  static Map<String, Object?> _selected(String optionId) => {
    'outcome': {'outcome': 'selected', 'optionId': optionId},
  };

  static const _cancelledOutcome = {
    'outcome': {'outcome': 'cancelled'},
  };

  Future<Object?> _onRequest(String method, Object? params) async {
    if (method != 'session/request_permission') {
      throw const JsonRpcError(JsonRpcError.methodNotFound, 'Not supported by this client');
    }
    final p = _map(params);
    final tc = _map(p['toolCall']);
    final callId = tc['toolCallId'] as String? ?? _next('perm');
    final call = _calls[callId] = mergeToolCall(_calls[callId] ?? const {}, tc);
    // Asked about a call that already finished or was cancelled: nobody waits for it.
    if (_done.contains(callId) || _cancelled || _closed) return _cancelledOutcome;
    final options = p['options'] as List<Object?>? ?? const [];
    final shown = _shown[callId] ?? _show(callId, call, options: options);
    final reply = Completer<Object?>();
    _asking[shown.id] = (reply: reply, options: options, callId: callId);
    _setStatus(ExecutionStatus.waitingForConfirmation);
    return reply.future;
  }

  // ----------------------------------------------------------------- updates

  void _onNotify(String method, Object? params) {
    if (method != 'session/update') return;
    final p = _map(params);
    if (p['sessionId'] case final String s when _acpSessionId != null && s != _acpSessionId) return;
    final u = _map(p['update']);
    switch (u['sessionUpdate']) {
      case 'current_mode_update':
        _modes?['currentModeId'] = u['currentModeId'];
      case 'config_option_update':
        if (u['configOptions'] case final List<Object?> c) _config = c;
      case _ when _replaying:
        break;
      case 'agent_message_chunk':
        final t = acpChunkText(u['content']);
        if (t.isEmpty) return;
        _text.write(t);
        _emit(acpDelta(content: t));
      case 'agent_thought_chunk':
        final t = acpChunkText(u['content']);
        if (t.isEmpty) return;
        _reasoning.write(t);
        _emit(acpDelta(reasoning: t));
      case 'tool_call' || 'tool_call_update':
        _toolUpdate(u);
      case 'plan':
        _flush();
        final (call, result) = acpPlanEvents(u['entries'] as List<Object?>? ?? const [], id: _next('plan'));
        _emit(call);
        _emit(result);
      case 'usage_update':
        final (report, cost) = acpUsageUpdate(u, id: _next('usage'), lastCost: _cost);
        _cost = cost;
        _emit(report);
    }
  }

  void _toolUpdate(Map<String, Object?> u) {
    final callId = u['toolCallId'];
    if (callId is! String) return;
    final call = _calls[callId] = mergeToolCall(_calls[callId] ?? const {}, u);
    if (_done.contains(callId)) return;
    final status = call['status'] as String? ?? 'pending';
    // A pending call's input may still be streaming: shown once it runs or asks.
    if (status == 'pending') return;
    final shown = _shown[callId] ?? _show(callId, call);
    if (status == 'completed' || status == 'failed') {
      _done.add(callId);
      _emit(acpResultEvent(call, id: 'tr-$callId', actionId: shown.id, toolName: shown.toolName));
    }
  }

  ActionCall _show(String callId, Map<String, Object?> call, {List<Object?> options = const []}) {
    _flush();
    final e = acpActionEvent(call, id: 'tc-$callId', mcpServers: _mcpNames, options: options);
    _shown[callId] = e;
    _emit(e);
    return e;
  }

  void _cancelledResult(String callId) {
    if (!_done.add(callId)) return;
    final shown = _shown[callId];
    if (shown == null) return;
    _emit(
      resultEvent(id: 'tr-$callId', actionId: shown.id, toolName: shown.toolName, text: 'Cancelled.', isError: true),
    );
  }

  /// The reply so far as one message.
  void _flush() {
    if (_text.isEmpty && _reasoning.isEmpty) return;
    _emit(agentMessageEvent(_next('m'), _text.toString(), reasoning: _reasoning.toString()));
    _text.clear();
    _reasoning.clear();
  }

  // ------------------------------------------------------------------ events

  String _next(String kind) => '$_run-$kind${++_seq}';

  void _setStatus(ExecutionStatus s) {
    if (s == _status && s != ExecutionStatus.waitingForConfirmation) return;
    _status = s;
    _emit(stateEvent(_next('s'), s));
  }

  void _emit(HarnessEvent e) {
    if (_closed) return;
    if (e is! StreamDelta) {
      _history.add(e);
      _journal.add(e);
    }
    for (final c in _listeners.toList()) {
      c.add(e);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final a in _asking.values) {
      a.reply.complete(_cancelledOutcome);
    }
    _asking.clear();
    await _peer?.close();
    await _journal.close();
    for (final c in _listeners.toList()) {
      unawaited(c.close());
    }
    _listeners.clear();
    _launcher.closed(id);
  }

  static Map<String, Object?> _map(Object? v) => v is Map<String, Object?> ? v : const {};
}
