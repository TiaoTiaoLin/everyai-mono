// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../domain/agent_mode.dart';
import '../../domain/permissions.dart' show typedReason;
import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../../host/host.dart' show HostCall, HostEnd, HostResult;
import '../briefing/briefing_types.dart';
import '../briefing/recipes.dart' show acpMcpServer;
import '../driver.dart';
import '../driver_events.dart';
import '../driver_policy.dart' show rewindRefusal;
import '../event_journal.dart';
import '../json_rpc.dart';
import '../usage_limit.dart';
import 'acp_agents.dart';
import 'acp_cursor.dart';
import 'acp_files.dart';
import 'acp_mapping.dart';
import 'acp_xai.dart';

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
    required this.switchToTty,
    required this.loginEnv,
    required this.initTimeout,
    required this.replayQuiet,
    required this.offered,
    required this.closed,
  });

  final DriverInfo info;
  final Set<DriverCap> caps;
  final AcpCommand command;

  /// The executable's absolute path; throws [HarnessError] when it is missing.
  final Future<String> Function() resolve;
  final AcpConnect connect;

  /// Starts later agents under a terminal of their own; false when the
  /// channel given already ran under one (`AcpProfile.ttyFallback`).
  final bool Function(LineChannel channel) switchToTty;

  /// The login shell's environment, read only to pick an `authenticate`
  /// method.
  final Future<Map<String, String>> Function() loginEnv;
  final Duration initTimeout;

  /// How long a late `session/load` replay must stay quiet before the first
  /// prompt goes ([AcpProfile.lateReplay]).
  final Duration replayQuiet;

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
final class AcpSession implements HarnessSession, PerCallApprovals, HasNativeCommands {
  AcpSession({
    required this.id,
    required this.dir,
    required this.cwd,
    required this.sessionTag,
    required this._launcher,
    required this._mode,
    this.briefing,
    this.mcpConfig = const {},
    this.rememberedMcp = const [],
    this.mcpGiven = false,
    this._acpSessionId,
    List<HarnessEvent> history = const [],
    List<NativeCommand> commands = const [],
  }) : _journal = openEventJournal(dir, 'events'),
       _commands = NativeCommandList(commands) {
    _history.addAll(history);
  }

  /// The conversation id the app stores.
  @override
  final String id;

  /// `<dataDir>/acp-sessions/<id>`: `meta.json`, `events.jsonl`, `stderr.log`
  /// (and `tty.log` under a terminal).
  final String dir;
  final String cwd;
  final String sessionTag;
  final DriverBriefing? briefing;
  final Map<String, Object?> mcpConfig;

  /// The user's MCP servers a reopened conversation had (names from
  /// `meta.json`; their settings can hold keys, so they aren't kept).
  final List<String> rememberedMcp;

  /// The reopen came with the app's current server list (possibly empty), so a name
  /// missing from it was turned off by the user, not lost.
  final bool mcpGiven;

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

  /// Loaded, and nothing of the new turn seen yet: a tool call that first
  /// shows up finished is the tail of a late replay.
  var _afterLoad = false;

  /// Waiting for a late replay to go quiet; each update restarts the timer.
  Completer<void>? _quiet;
  Timer? _quietTimer;
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

  /// Tool calls by ACP id, merged while open; which were shown, which the
  /// agent asked about, which finished.
  final _calls = <String, Map<String, Object?>>{};
  final _shown = <String, ActionCall>{};
  final _asked = <String>{};
  final _done = <String>{};

  /// Permission requests waiting for an answer, by action id.
  final _asking = <String, ({Completer<Object?> reply, List<Object?> options, String callId})>{};

  /// What the user typed when refusing calls, for the next prompt (ACP has
  /// no reason field).
  final _notes = <String>[];

  /// Messages sent with `run: false`, for the next prompt.
  final _held = <({String text, List<String> images})>[];

  /// Cursor's question and plan requests waiting on their card, by its
  /// tool call id: completing one gives the card up.
  final _extWaits = <String, Completer<HostEnd>>{};

  /// Tool call ids an extension request shows (cards, subagents): Cursor's
  /// ordinary `tool_call` for the same id adds no second row.
  final _extOwned = <String>{};

  /// Cursor's to-do list, by id in order (`cursor/update_todos`).
  var _todos = <String, Map<String, Object?>>{};

  /// The prompt id sent with the running turn (Grok's `_meta.promptId`) and
  /// what completes it when Grok says the prompt is complete before (or
  /// instead of) replying.
  String? _xaiPrompt;
  Completer<Object?>? _xaiDone;

  /// A prompt of ours is in flight (for every agent; [_xaiDone] is made for
  /// each prompt).
  bool get _prompting => _xaiDone != null;

  /// Grok woke up on its own (a background task or subagent finished) and
  /// works outside any prompt of ours: no prompt reply will end it, its
  /// `task-completed-*` turn does.
  var _waking = false;

  /// The prompt id of Grok's last turn whose reply came without usage: a
  /// later `turn_completed` for it still reports what it used.
  String? _xaiUnreported;

  /// Grok's subagents that run on in the background, by child session id:
  /// their row waits for `subagent_finished`.
  final _xaiChildren = <String, ActionCall>{};

  /// Grok's background tasks, by task id: their rows, and which finished;
  /// a task's tool call id leads to its task id (a kill can name either).
  final _xaiTasks = <String, ActionCall>{};
  final _xaiTasksDone = <String>{};
  final _xaiTaskAlias = <String, String>{};

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
    // The agent's cost is a running total for its session: go on from the last one.
    _cost = [
      for (final u in _history.whereType<UsageReport>())
        if (u.raw['acp_total'] case final num t) t.toDouble(),
    ].lastOrNull;
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
    if (await _profile.preflight(cwd) case final problem?) throw HarnessError(problem);
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
          '_meta': ?_profile.initializeMeta,
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
          // An unknown session is -32602 on OpenCode, -32603 on Gemini; any
          // refusal but sign-in starts a fresh one.
          if (e.code == -32000 || peer.isClosed) rethrow;
        }
        if (reply != null) {
          _afterLoad = true;
          if (_profile.lateReplay) await _replayQuieted();
        }
      }
      if (reply == null) {
        _replaying = false;
        _cost = null;
        reply = _map(await _newSession(peer, mcp));
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
      if (!fresh && !mcpGiven) {
        final lost = [
          for (final n in rememberedMcp)
            if (!mcpConfig.containsKey(n)) n,
        ];
        if (lost.isNotEmpty) {
          _emit(
            acpNotice(
              _next('n'),
              '$_label reopened without your MCP servers ${lost.join(', ')}. Start a new session to use them again.',
            ),
          );
        }
      }
      _absorb(reply);
      // The models list is a cache: failing to write it doesn't stop the session.
      try {
        await _launcher.offered(reply);
      } on Object {
        // Left as it was.
      }
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
      // Exited for want of a terminal (Grok started from the Dock): once more under one.
      if (closed &&
          _profile.ttyFallback &&
          isNoTtyExit('${e.message}\n${channel.lastError}') &&
          _launcher.switchToTty(channel)) {
        return _connect(fresh: fresh);
      }
      throw HarnessError(_errorText(e, closed: closed));
    } on Object {
      await peer.close();
      rethrow;
    }
  }

  /// `session/new`; when it says the agent isn't signed in, the profile's
  /// `authenticate` method once (if the agent offers it as its own), then
  /// again.
  Future<Object?> _newSession(JsonRpcPeer peer, List<Map<String, Object?>> mcp) async {
    final params = {'cwd': cwd, 'mcpServers': mcp};
    try {
      return await peer.request('session/new', params);
    } on JsonRpcError catch (e) {
      if (e.code != -32000 || peer.isClosed) rethrow;
      final want = await _profile.authMethod(_launcher.loginEnv);
      final offered = _authMethods.whereType<Map<String, Object?>>().any(
        (m) => m['id'] == want && (m['type'] == null || m['type'] == 'agent'),
      );
      if (want == null || !offered) rethrow;
      await peer.request('authenticate', {'methodId': want});
      return peer.request('session/new', params);
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
    _endExtWaits(HostEnd.clientGone);
    // Grok's background work went with it.
    for (final id in _xaiTasks.keys.toList()) {
      _xaiTaskEnded(id, text: 'Stopped when $_label exited.', failed: true);
    }
    for (final row in _xaiChildren.values) {
      _emit(
        resultEvent(
          id: '${_resultId(row)}-done',
          actionId: row.id,
          toolName: row.toolName,
          text: 'Stopped when $_label exited.',
          isError: true,
        ),
      );
    }
    _xaiChildren.clear();
    if (_waking) {
      _waking = false;
      _setStatus(ExecutionStatus.paused);
    }
  }

  /// Gives up every card an extension request waits on ([why]); each request
  /// then answers `cancelled` and its row closes.
  void _endExtWaits(HostEnd why) {
    for (final (callId, ended) in [for (final e in _extWaits.entries) (e.key, e.value)]) {
      if (!ended.isCompleted) ended.complete(why);
      _cancelledResult(callId);
    }
    _extWaits.clear();
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

  /// Waits until the agent's replay has stopped for [AcpLauncher.replayQuiet]
  /// (at most 5 s).
  Future<void> _replayQuieted() async {
    final quiet = _quiet = Completer<void>();
    _rearmQuiet();
    try {
      await quiet.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    } finally {
      _quietTimer?.cancel();
      _quiet = null;
    }
  }

  void _rearmQuiet() {
    final quiet = _quiet;
    if (quiet == null) return;
    _quietTimer?.cancel();
    _quietTimer = Timer(_launcher.replayQuiet, () {
      if (!quiet.isCompleted) quiet.complete();
    });
  }

  /// Writes `meta.json`, one write at a time so an older state never lands last.
  Future<void> _saveMeta() {
    final write = _metaWrites.then((_) => _writeMeta());
    _metaWrites = write.catchError((Object _) {});
    return write;
  }

  Future<void> _metaWrites = Future.value();

  Future<void> _writeMeta() => writeJsonFile('$dir/meta.json', {
    'acpSessionId': _acpSessionId,
    'cwd': cwd,
    'sessionTag': sessionTag,
    'mode': _mode.name,
    'mcpServers': [
      for (final n in mcpGiven || mcpConfig.isNotEmpty ? mcpConfig.keys : rememberedMcp)
        if (n != everyaiServerName) n,
    ],
    // So a reopened session has its `/` menu before the agent starts again.
    'commands': [for (final c in _commands.latest) c.toJson()],
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
    await _pinConfig();
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

  /// Sets the profile's pinned config options ([AcpProfile.configPins])
  /// where the agent offers them. A refusal is an error: the agent would act
  /// without asking.
  Future<void> _pinConfig() async {
    for (final MapEntry(key: id, :value) in _profile.configPins.entries) {
      final o = acpOption(_config, null, id: id);
      if (o == null || o.current == value || !o.choices.any((c) => c.value == value)) continue;
      _absorb(
        _map(
          await _peer!.request('session/set_config_option', {
            'sessionId': _acpSessionId,
            'configId': id,
            'value': value,
          }),
        ),
      );
    }
  }

  /// Whether a pinned config option has moved off its value.
  bool get _pinsMoved => _profile.configPins.entries.any((e) {
    final o = acpOption(_config, null, id: e.key);
    return o != null && o.current != e.value && o.choices.any((c) => c.value == e.value);
  });

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

  /// The agent's `/` commands, from `available_commands_update` (live or
  /// during a load's replay), kept in `meta.json` for a reopen.
  final NativeCommandList _commands;

  @override
  Stream<List<NativeCommand>> get commands => _commands.stream;

  /// An ACP command is an ordinary prompt of `/name args`. The briefing,
  /// notes and held messages stay for the next normal prompt so the agent
  /// still sees the command as one.
  @override
  Future<void> runCommand(String name, String args) async {
    if (_closed) return;
    final text = '/$name $args'.trim();
    _emit(userMessageEvent(_next('u'), text));
    try {
      await _ensureConnected();
    } on HarnessError catch (e) {
      _emit(acpNotice(_next('n'), e.message));
      _setStatus(ExecutionStatus.error);
      return;
    }
    final blocks = acpPrompt(text, imagesOk: false);
    final turn = _turns.then((_) => _prompt(blocks));
    _turns = turn;
    _turn = turn;
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
    _waking = false;
    _setStatus(ExecutionStatus.running);
    // Grok can leave the reply hanging after it says the prompt is complete;
    // whichever comes first ends the turn.
    final promptId = _profile.agent == AcpAgent.grok ? _next('p') : null;
    final done = _xaiDone = Completer<Object?>();
    _xaiPrompt = promptId;
    try {
      final reply = _map(
        await Future.any([
          peer.request('session/prompt', {
            'sessionId': _acpSessionId,
            'prompt': blocks,
            if (promptId != null) '_meta': {'promptId': promptId, 'requestId': promptId},
          }),
          done.future,
        ]),
      );
      _afterLoad = false;
      _flush();
      final usage = promptId != null
          ? xaiTurnUsage(reply['usage'], id: _next('usage'))
          : acpTurnUsage(reply['usage'], id: _next('usage'));
      if (usage != null) {
        _emit(usage);
      } else if (promptId != null) {
        _xaiUnreported = promptId;
      }
      final stop = reply['stopReason'];
      final note = switch (stop) {
        'max_tokens' => '$_label ran out of room for its reply.',
        'max_turn_requests' => '$_label stopped after its limit of steps in one turn.',
        'refusal' => '$_label refused to carry on with this request.',
        'error' => switch (reply['agentResult']) {
          final String why => '$_label ended the turn with an error: $why',
          _ => '$_label ended the turn with an error.',
        },
        _ => null,
      };
      if (stop == 'rate_limit') {
        _emit(usageLimitEvent(_next('n'), '$_label: its usage limit was reached. Try again later or switch harness.'));
        _setStatus(ExecutionStatus.error);
        return;
      }
      if (note != null) _emit(acpNotice(_next('n'), note));
      _setStatus(switch (stop) {
        'cancelled' => ExecutionStatus.paused,
        'error' => ExecutionStatus.error,
        _ => ExecutionStatus.finished,
      });
    } on JsonRpcError catch (e) {
      _flush();
      final grokLimit = _profile.agent == AcpAgent.grok && xaiUsageLimit(e);
      final limit = peer.isClosed ? null : (grokLimit ? (resetsAt: null) : acpUsageLimit(e, now: DateTime.now()));
      _emit(
        limit == null
            ? acpNotice(_next('n'), _errorText(e, closed: peer.isClosed))
            : usageLimitEvent(_next('n'), '$_label: ${e.message}', resetsAt: limit.resetsAt),
      );
      _setStatus(ExecutionStatus.error);
    } finally {
      if (identical(_xaiDone, done)) {
        _xaiDone = null;
        _xaiPrompt = null;
      }
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
    _stopTurn();
    // No prompt of ours runs (Grok woke up on its own): no reply will end it.
    if (turn == null || !_prompting) {
      _waking = false;
      _setStatus(ExecutionStatus.paused);
      return;
    }
    // The agent replies `cancelled`; one that doesn't is ended.
    await turn.timeout(
      const Duration(seconds: 15),
      onTimeout: () async {
        await _peer?.close();
        _setStatus(ExecutionStatus.paused);
      },
    );
  }

  /// Cancels the turn: what waits for an answer is answered `cancelled`, and
  /// the open calls but [running] (one that already runs) are closed.
  void _stopTurn({String? running}) {
    _cancel();
    for (final entry in _asking.entries.toList()) {
      entry.value.reply.complete(_cancelledOutcome);
      _cancelledResult(entry.value.callId);
    }
    _asking.clear();
    _endExtWaits(HostEnd.cancelled);
    _flush();
    for (final callId in _shown.keys.toList()) {
      if (!_done.contains(callId) && callId != running) _cancelledResult(callId);
    }
  }

  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _peer?.notify('session/cancel', {'sessionId': _acpSessionId, '_meta': ?_profile.cancelMeta});
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
      // The agent already got the refusal; only words the user typed are worth a line in the next prompt.
      if (typedReason(reason) case final said?) {
        final note = 'The app refused ${_quoted(title)}: $said';
        if (_notes.length < 5 && !_notes.contains(note)) _notes.add(note);
      }
      _done.add(a.callId);
      _calls.remove(a.callId);
      _emit(
        acpRejectedEvent(
          id: 'tr-${a.callId}',
          actionId: actionId,
          toolName: call?.toolName ?? '${acpToolPrefix}tool',
          reason: why,
        ),
      );
    }
    if (all && !_prompting) {
      // A wake: no prompt reply comes to end it.
      _waking = false;
      _setStatus(ExecutionStatus.paused);
    } else if (_asking.isEmpty && _status == ExecutionStatus.waitingForConfirmation && !all) {
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
    // ACP keeps `_` names for extensions; Cursor's doc writes them without.
    if (xaiMethod(method) case final x?) return _xaiRequest(x, _map(xaiRedacted(params)));
    final name = method.startsWith('_') ? method.substring(1) : method;
    if (name.startsWith('cursor/')) return _cursorRequest(name, _map(params));
    if (method != 'session/request_permission') {
      throw const JsonRpcError(JsonRpcError.methodNotFound, 'Not supported by this client');
    }
    final p = _map(params);
    final tc = _map(p['toolCall']);
    final callId = tc['toolCallId'] as String? ?? _next('perm');
    // Asked about a call that already finished or was cancelled: nobody waits for it.
    if (_done.contains(callId) || _cancelled || _closed) return _cancelledOutcome;
    _wake();
    final call = _calls[callId] = mergeToolCall(_calls[callId] ?? const {}, tc);
    _asked.add(callId);
    _afterLoad = false;
    final options = p['options'] as List<Object?>? ?? const [];
    final shown = _shown[callId] ?? _show(callId, call, options: options);
    final reply = Completer<Object?>();
    _asking[shown.id] = (reply: reply, options: options, callId: callId);
    _setStatus(ExecutionStatus.waitingForConfirmation);
    return reply.future;
  }

  // ------------------------------------------------------ Cursor extensions

  /// A `cursor/*` request. Questions and plans wait on their card; an
  /// unknown one is answered `cancelled`, never with an error (Cursor can
  /// hang the turn on a failed `cursor/create_plan`).
  Future<Object?> _cursorRequest(String method, Map<String, Object?> p) async {
    switch (method) {
      case 'cursor/ask_question':
        return _cursorCard(p, question: true);
      case 'cursor/create_plan':
        return _cursorCard(p, question: false);
      case 'cursor/update_todos' || 'cursor/task':
        _cursorUpdate(method, p);
        return {
          'outcome': {'outcome': method == 'cursor/task' ? 'completed' : 'accepted'},
        };
      default:
        return cursorCancelled;
    }
  }

  /// Shows a question or plan request as the card of the app's
  /// `ask_user_question` / `present_plan` host tool (the row is named like
  /// the agent's call to our MCP server, so the controller answers it the
  /// same way) and replies with what the user decided.
  Future<Object?> _cursorCard(Map<String, Object?> p, {required bool question}) async {
    if (_closed || _cancelled) return cursorCancelled;
    final host = briefing?.host;
    if (host == null) {
      return question
          ? cursorSkipped('Nobody can answer questions in this session; decide yourself and say what you assumed.')
          : cursorCancelled;
    }
    if (question) {
      if (cursorQuestionProblem(p) case final why?) return cursorSkipped(why);
    }
    final callId = p['toolCallId'] as String? ?? _next('ext');
    if (_extOwned.contains(callId)) return cursorCancelled;
    _extOwned.add(callId);
    final tool = question ? askUserQuestionTool : presentPlanTool;
    final args = question ? cursorQuestionArgs(p) : cursorPlanArgs(p);
    _flush();
    final row = actionEvent(
      id: _extRowId(callId, 'Shown as a card.'),
      toolName: '${everyaiServerName}__$tool',
      kind: 'MCPToolAction',
      toolCallId: callId,
      args: args,
    );
    _shown[callId] = row;
    _emit(row);
    final ended = _extWaits[callId] = Completer<HostEnd>();
    HostResult result;
    try {
      result = await Future.any([
        host.call(HostCall(id: row.id, sessionId: id, name: tool, args: args, ended: ended.future)),
        ended.future.then((_) => (text: 'Cancelled.', isError: true)),
      ]);
    } on Object catch (e) {
      result = (text: 'Error: $e', isError: true);
    }
    _extWaits.remove(callId);
    if (ended.isCompleted || _closed) {
      _cancelledResult(callId);
      return cursorCancelled;
    }
    if (_done.add(callId)) {
      _emit(
        resultEvent(
          id: _resultId(row),
          actionId: row.id,
          toolName: row.toolName,
          text: result.text,
          isError: result.isError,
        ),
      );
    }
    return question ? cursorAnswerReply(p, result) : cursorPlanReply(result);
  }

  /// Cursor's to-do list and subagent updates. While a conversation loads
  /// nothing is shown (the journal has it), but the replayed to-dos are kept,
  /// so a later merge changes the whole list.
  void _cursorUpdate(String method, Map<String, Object?> p) {
    switch (method) {
      case 'cursor/update_todos':
        _todos = cursorTodos(_todos, p);
        if (_replaying) return;
        _flush();
        final (call, result) = cursorTodoEvents(_todos, id: _next('todos'));
        _emit(call);
        _emit(result);
      case 'cursor/task':
        if (_replaying) return;
        final callId = p['toolCallId'] as String? ?? _next('task');
        if (_done.contains(callId)) return;
        _extOwned.add(callId);
        var row = _shown[callId];
        if (row == null || row.actionKind != 'TaskAction') {
          _flush();
          row = _shown[callId] = cursorTaskCall(p, id: _extRowId(callId, 'Shown as a subagent.'), toolCallId: callId);
          _emit(row);
        }
        if (p['durationMs'] != null && _done.add(callId)) {
          _emit(
            resultEvent(
              id: _resultId(row),
              actionId: row.id,
              toolName: row.toolName,
              text: cursorTaskDone(p['durationMs']),
            ),
          );
        }
    }
  }

  /// The id for an extension's own row of [callId]. When Cursor's ordinary
  /// `tool_call` showed a row for it first, that row is closed with
  /// [closing] and the new one gets an id of its own.
  String _extRowId(String callId, String closing) {
    final old = _shown[callId];
    if (old == null) return 'tc-$callId';
    if (_done.add(callId)) {
      _emit(resultEvent(id: _resultId(old), actionId: old.id, toolName: old.toolName, text: closing));
    }
    _done.remove(callId);
    _calls.remove(callId);
    return 'tc-$callId-ext';
  }

  /// The result id for [row] (`tc-…` gives `tr-…`).
  static String _resultId(ActionCall row) => row.id.replaceFirst('tc-', 'tr-');

  // -------------------------------------------------------- Grok extensions

  /// A Grok `x.ai/*` request, its payload already redacted. Questions and
  /// plans have no way back from the app's cards here, so a question is
  /// declined (the app's own question tool asks instead) and a plan is shown
  /// as a message, with Grok told to wait for the user's reply.
  Future<Object?> _xaiRequest(String method, Map<String, Object?> p) async {
    switch (method) {
      case 'ask_user_question':
        final asked = xaiQuestionTexts(p);
        _emit(
          acpNotice(
            _next('n'),
            "$_label tried to ask ${asked.isEmpty ? 'something' : '"${asked.join('", "')}"'} with its own question "
            "tool, which the app can't show, so it was declined. Reply in chat if it needs an answer.",
          ),
        );
        return xaiQuestionReply;
      case 'exit_plan_mode':
        _flush();
        _emit(agentMessageEvent(_next('m'), xaiPlanText(p) ?? 'No plan was written yet.'));
        return xaiPlanReply;
      default:
        throw const JsonRpcError(JsonRpcError.methodNotFound, 'Not supported by this client');
    }
  }

  /// A Grok `x.ai/*` notification, its payload already redacted (MCP
  /// servers' environment can hold keys). Unknown ones are dropped, so
  /// nothing of them reaches the journal.
  void _onXai(String method, Map<String, Object?> p) {
    if (p['sessionId'] case final String s when _acpSessionId != null && s != _acpSessionId) return;
    switch (method) {
      case 'task_backgrounded' || 'task_completed':
        if (!_replaying) _xaiTask(p, completed: method == 'task_completed');
      case 'session/prompt_complete' || 'session_notification' || 'session/update':
        if (xaiPromptDone(method, p) case final d?) _xaiTurnDone(d);
        if (xaiSubagentDone(p) case final d? when !_replaying) _xaiSubagentFinished(d);
    }
  }

  /// A Grok turn ended: our prompt (its reply may never come), or one of its
  /// own wakes, which only this ends. What the turn used is reported when
  /// the prompt reply didn't carry it.
  void _xaiTurnDone(XaiPromptDone d) {
    final done = _xaiDone;
    if (!d.wake && done != null && !done.isCompleted && (d.promptId == null || d.promptId == _xaiPrompt)) {
      done.complete({'stopReason': d.stopReason ?? 'end_turn', 'agentResult': ?d.agentResult, 'usage': ?d.usage});
      return;
    }
    if (d.wake || (d.promptId != null && d.promptId == _xaiUnreported)) {
      if (!d.wake) _xaiUnreported = null;
      final usage = xaiTurnUsage(d.usage, id: _next('usage'));
      if (usage != null && !_replaying) _emit(usage);
    }
    if (!d.wake || !_waking || _prompting || _asking.isNotEmpty) return;
    _waking = false;
    _flush();
    _setStatus(d.stopReason == 'cancelled' ? ExecutionStatus.paused : ExecutionStatus.finished);
  }

  /// Grok works with no prompt of ours in flight: one of its background
  /// wakes, which runs until its own turn ends ([_xaiTurnDone]).
  void _wake() {
    if (_profile.agent != AcpAgent.grok || _prompting || _replaying || _closed || _cancelled) return;
    _waking = true;
    if (_status != ExecutionStatus.waitingForConfirmation) _setStatus(ExecutionStatus.running);
  }

  /// A background task's row. It is closed at once ("still running"), so it
  /// never waits among the calls to approve, and its end replaces that.
  void _xaiTask(Map<String, Object?> p, {required bool completed}) {
    final t = xaiTask(p, completed: completed);
    if (t == null) return;
    if (t.toolCallId case final c? when c != t.id) _xaiTaskAlias[c] = t.id;
    if (_xaiTasksDone.contains(t.id)) return;
    if (!_xaiTasks.containsKey(t.id)) {
      _flush();
      final row = _xaiTasks[t.id] = xaiTaskCall(t, id: 'xbg-${t.id}');
      _emit(row);
      _emit(
        resultEvent(
          id: 'xbr-${t.id}-bg',
          actionId: row.id,
          toolName: row.toolName,
          text: 'Still running in the background.',
        ),
      );
    }
    if (completed) _xaiTaskEnded(t.id, text: xaiTaskResultText(t), failed: t.status == 'failed');
  }

  /// Background task [id] (its task or tool call id) ended: its row gets
  /// [text].
  void _xaiTaskEnded(String id, {required String text, bool failed = false}) {
    final key = _xaiTaskAlias[id] ?? id;
    final row = _xaiTasks[key];
    if (row == null || !_xaiTasksDone.add(key)) return;
    _emit(resultEvent(id: 'xbr-$key', actionId: row.id, toolName: row.toolName, text: text, isError: failed));
  }

  /// A subagent that ran in the background finished: its row gets the report.
  void _xaiSubagentFinished(XaiSubagentDone d) {
    final row = _xaiChildren.remove(d.child);
    if (row == null) return;
    final text =
        d.result ??
        (d.status == 'completed' ? 'Done.' : 'The subagent ${d.status == 'failed' ? 'failed' : 'was cancelled'}.');
    _emit(
      resultEvent(
        id: '${_resultId(row)}-done',
        actionId: row.id,
        toolName: row.toolName,
        text: text,
        isError: d.status != 'completed',
      ),
    );
  }

  // ----------------------------------------------------------------- updates

  void _onNotify(String method, Object? params) {
    if (xaiMethod(method) case final x?) return _onXai(x, _map(xaiRedacted(params)));
    final name = method.startsWith('_') ? method.substring(1) : method;
    if (name.startsWith('cursor/')) {
      _cursorUpdate(name, _map(params));
      return;
    }
    if (method != 'session/update') return;
    final p = _map(params);
    if (p['sessionId'] case final String s when _acpSessionId != null && s != _acpSessionId) return;
    final u = _map(p['update']);
    _rearmQuiet();
    switch (u['sessionUpdate']) {
      case 'current_mode_update':
        _modes?['currentModeId'] = u['currentModeId'];
      case 'config_option_update':
        if (u['configOptions'] case final List<Object?> c) _config = c;
        // The agent turned a pinned option back (its own command): set it again.
        if (_pinsMoved && _peer != null) {
          unawaited(
            _pinConfig().catchError((Object e) {
              _emit(
                acpNotice(
                  _next('n'),
                  "$_label changed a setting that keeps it asking, and it couldn't be set back: $e",
                ),
              );
            }),
          );
        }
      case 'available_commands_update':
        final before = _commands.latest;
        _commands.set(acpCommands(u['availableCommands']));
        if (!identical(before, _commands.latest)) unawaited(_saveMeta().catchError((Object _) {}));
      case 'usage_update' when _replaying:
        _cost = acpUsageTotal(u) ?? _cost;
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
    if (callId is! String || _done.contains(callId)) return;
    if (_extOwned.contains(callId)) return _extToolUpdate(callId, u);
    final known = _calls.containsKey(callId) || _shown.containsKey(callId);
    final call = _calls[callId] = mergeToolCall(_calls[callId] ?? const {}, u);
    final status = call['status'] as String? ?? 'pending';
    final finished = status == 'completed' || status == 'failed';
    if (_afterLoad && finished && !_shown.containsKey(callId)) {
      // Replayed after the load reply (Gemini): the journal has it already.
      _done.add(callId);
      _calls.remove(callId);
      return;
    }
    _afterLoad = false;
    // A new call with no prompt of ours running: Grok woke up on its own.
    if (!known && !finished) _wake();
    // A pending call's input may still be streaming: shown once it runs or asks.
    if (status == 'pending') return;
    final shown = _shown[callId] ?? _show(callId, call);
    if (!_asked.contains(callId)) _unasked(callId, shown);
    if (finished) {
      _done.add(callId);
      _calls.remove(callId);
      if (_profile.agent == AcpAgent.grok) {
        for (final task in xaiKilled(call)) {
          _xaiTaskEnded(task, text: 'Stopped.');
        }
      }
      if (_xaiSpawned(call, shown)) return;
      _emit(acpResultEvent(call, id: 'tr-$callId', actionId: shown.id, toolName: shown.toolName));
    }
  }

  /// Closes a Grok subagent row: with its report, or, when the subagent runs
  /// on in the background, as running there (so it never waits among the
  /// calls to approve), its report replacing that at `subagent_finished`.
  /// False for any other call.
  bool _xaiSpawned(Map<String, Object?> call, ActionCall shown) {
    if (_profile.agent != AcpAgent.grok || shown.actionKind != 'TaskAction') return false;
    final output = xaiOutputText(call);
    final child = xaiChildId(output);
    if (call['status'] == 'completed' && xaiAsyncAck(output) && child != null) {
      _xaiChildren[child] = shown;
      _emit(
        resultEvent(
          id: 'tr-${call['toolCallId']}',
          actionId: shown.id,
          toolName: shown.toolName,
          text: 'Running in the background; its report comes when it finishes.',
        ),
      );
      return true;
    }
    final failed = call['status'] == 'failed';
    final report = xaiReport(output);
    _emit(
      resultEvent(
        id: 'tr-${call['toolCallId']}',
        actionId: shown.id,
        toolName: shown.toolName,
        text: report.isNotEmpty ? report : (failed ? 'Failed.' : 'Done.'),
        isError: failed,
      ),
    );
    return true;
  }

  /// Cursor's ordinary update for a call an extension shows: it adds no row,
  /// but a finished one closes a subagent row (a card waits for the user).
  void _extToolUpdate(String callId, Map<String, Object?> u) {
    final row = _shown[callId];
    final status = u['status'];
    if (row == null || _extWaits.containsKey(callId) || (status != 'completed' && status != 'failed')) return;
    if (!_done.add(callId)) return;
    _calls.remove(callId);
    final failed = status == 'failed';
    _emit(
      resultEvent(
        id: _resultId(row),
        actionId: row.id,
        toolName: row.toolName,
        text: failed ? 'Failed.' : cursorTaskDone(null),
        isError: failed,
      ),
    );
  }

  /// A call that changes things ran without a permission request: the
  /// agent's own settings let it past the app. The user is told; in Plan the
  /// turn is stopped.
  void _unasked(String callId, ActionCall call) {
    if (!_gated.contains(call.actionKind) || AgentMode.isReadOnly(call) || !_asked.add(callId)) return;
    final plan = _mode == AgentMode.plan;
    _emit(
      acpNotice(
        _next('n'),
        '$_label ran ${_quoted(call.summary)} without asking the app first, so its own settings allow it.'
        '${plan ? ' Plan mode stopped the turn.' : ''}',
      ),
    );
    if (plan) _stopTurn(running: callId);
  }

  static const _gated = {
    'TerminalAction',
    'FileEditorAction',
    'EditAction',
    'ApplyPatchAction',
    'AcpExecuteAction',
    'AcpEditAction',
    'AcpDeleteAction',
    'AcpMoveAction',
  };

  ActionCall _show(String callId, Map<String, Object?> call, {List<Object?> options = const []}) {
    _flush();
    final e = _profile.agent == AcpAgent.grok && xaiIsSpawn(call)
        ? xaiSpawnCall(call, id: 'tc-$callId')
        : acpActionEvent(call, id: 'tc-$callId', mcpServers: _mcpNames, options: options, cwd: cwd);
    _shown[callId] = e;
    _emit(e);
    return e;
  }

  void _cancelledResult(String callId) {
    if (!_done.add(callId)) return;
    _calls.remove(callId);
    final shown = _shown[callId];
    if (shown == null) return;
    _emit(
      resultEvent(
        id: _resultId(shown),
        actionId: shown.id,
        toolName: shown.toolName,
        text: 'Cancelled.',
        isError: true,
      ),
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
    _quietTimer?.cancel();
    for (final a in _asking.values) {
      a.reply.complete(_cancelledOutcome);
    }
    _asking.clear();
    await _peer?.close();
    // After the agent is gone, so nothing is sent to it.
    _endExtWaits(HostEnd.sessionClosed);
    await _journal.close();
    for (final c in _listeners.toList()) {
      unawaited(c.close());
    }
    _listeners.clear();
    _commands.close();
    _launcher.closed(id);
  }

  static Map<String, Object?> _map(Object? v) => v is Map<String, Object?> ? v : const {};
}

/// An ACP `availableCommands` list: `{name, description, input?: {hint}}`.
List<NativeCommand> acpCommands(Object? list) => [
  if (list is List<Object?>)
    for (final c in list)
      if (c case {'name': final String name} when name.isNotEmpty)
        NativeCommand(
          name: name,
          description: c['description'] as String? ?? '',
          argsHint: switch (c['input']) {
            {'hint': final String h} when h.isNotEmpty => h,
            _ => null,
          },
        ),
];
