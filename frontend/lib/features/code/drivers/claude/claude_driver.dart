// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:uuid/uuid.dart';

import '../../domain/agent_mode.dart';
import '../../git/git_service.dart';
import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../briefing/briefing_types.dart';
import '../driver.dart';
import '../driver_events.dart';
import '../driver_policy.dart';
import '../driver_process.dart';
import '../event_journal.dart';
import '../json_rpc.dart' show LineChannel;
import 'claude_files.dart';
import 'claude_wire.dart';

/// Starts the CLI with [args] for a session (tests replay a recording).
typedef ClaudeSpawn = Future<LineChannel> Function(
  List<String> args, {
  required String cwd,
  required Map<String, String> env,
  required String sessionTag,
  required String logPath,
});

/// Claude Code (`claude`), on the user's own subscription or key: one
/// `claude -p` process per session speaking stream-json on stdio (see
/// `claude_wire.dart`). Every tool call comes to us through a PreToolUse
/// hook and waits for the app's rules or the user.
///
/// A session's record (`<dataDir>/driver-sessions/claude-code/<id>.json`:
/// folder, model, mode; never a token) and its event journal let [attach]
/// show it after a restart; the CLI keeps the conversation itself and
/// continues it with `--resume`. It doesn't print history back, so the
/// journal is the transcript.
final class ClaudeDriver
    implements HarnessDriver, AttachesBriefed, ChecksResume, StartsInNativeMode, AdoptsNativeSession {
  ClaudeDriver({this.which, this.dataDir = GitService.dataDir, this.spawn, this.run, this.configDir});

  /// Replaces the CLI's config folder (tests).
  final String? configDir;

  /// Replaces the PATH lookup in [detect] (tests).
  final Future<String?> Function(String command)? which;

  /// The app's data folder.
  final Future<String> Function() dataDir;

  /// Replaces starting the CLI (tests).
  final ClaudeSpawn? spawn;

  /// Replaces running `claude auth status` in [detect] (tests): its output.
  final Future<String?> Function(String executable, List<String> args)? run;

  final _live = <String, ClaudeSession>{};
  List<DriverModel>? _models;
  Future<String?>? _path;

  @override
  DriverInfo get info => const DriverInfo(
    id: 'claude-code',
    label: 'Claude Code',
    needsConsent: true,
    installHint: 'npm install -g @anthropic-ai/claude-code',
  );

  @override
  /// [permissionModeFor]: Full auto starts in `default`, which asks.
  @override
  bool startsNatively(AgentMode mode) => mode != AgentMode.fullAuto;

  @override
  Set<DriverCap> get caps => const {
    DriverCap.resume,
    DriverCap.approvals,
    DriverCap.perCallApprovals,
    DriverCap.usage,
    DriverCap.mcp,
    DriverCap.skills,
    DriverCap.images,
    DriverCap.switchModel,
    DriverCap.effort,
    DriverCap.nativeModes,
    DriverCap.subagents,
  };

  /// Installed, its version, and whether it is signed in. `claude auth
  /// status` reads local state only (no model call); only `loggedIn` is
  /// kept, never the account fields it prints with it.
  @override
  Future<DriverStatus> detect() async {
    final found = await detectCli('claude', which: which);
    final path = found.path;
    if (!found.installed || path == null) return found;
    bool? signedIn;
    try {
      if (jsonDecode(await (run ?? runQuiet)(path, const ['auth', 'status', '--json']) ?? '') case {
        'loggedIn': final bool b,
      }) {
        signedIn = b;
      }
    } on FormatException {
      // Unknown.
    }
    return DriverStatus(
      installed: true,
      path: path,
      version: found.version,
      signedIn: signedIn,
      problem: found.problem ?? (signedIn == false ? 'Not signed in. Run `claude auth login` in a terminal.' : null),
    );
  }

  /// What the user's account offers, asked once from a process that makes
  /// no model call (`initialize`); Claude's aliases when that fails.
  @override
  Future<List<DriverModel>> models() async {
    if (_models case final m?) return m;
    try {
      final dir = await _dir();
      await makeDir(dir);
      final c = await _spawn(
        claudeProbeArgs,
        cwd: dir,
        env: const {},
        sessionTag: 'claude-models',
        logPath: '$dir/models.log',
      );
      try {
        final reply = c.lines
            .map(_json)
            .firstWhere((j) => j?['type'] == 'control_response')
            .timeout(const Duration(seconds: 20));
        c.send(jsonEncode(controlRequest('req_1', {'subtype': 'initialize'})));
        final r = (await reply)?['response'] as Map<String, Object?>?;
        if (modelsOf(r?['response'] as Map<String, Object?>? ?? const {}) case final m?) return _models = m;
      } finally {
        await c.close();
      }
    } on Object {
      // Fall back below.
    }
    return fallbackModels;
  }

  @override
  Future<HarnessSession> start(SessionSpec spec) async {
    final id = const Uuid().v4();
    final dir = await _dir();
    final meta = _Meta(
      cwd: spec.workingDir,
      sessionTag: spec.sessionTag,
      model: spec.model,
      effort: spec.effort,
      mode: spec.mode,
      sent: false,
    );
    await writeTextFile('$dir/$id.json', jsonEncode(meta.toJson()));
    final briefing = await _briefing(spec.briefing);
    // The CLI starts with the first message that runs, not before.
    final session = _live[id] = ClaudeSession._(this, id, dir, meta, briefing, openEventJournal(dir, id));
    if (spec.initialMessage case final text?) {
      await session.send(text, run: spec.runInitial, images: spec.initialImages);
    }
    return session;
  }

  /// Makes [id], a conversation written into Claude's own files (a native
  /// import), a session of this driver: [attach] then opens it and the first
  /// message continues it with `--resume`.
  Future<void> adoptImported(
    String id, {
    required String cwd,
    required String sessionTag,
    required String model,
    String? effort,
    required AgentMode mode,
  }) async {
    final meta = _Meta(cwd: cwd, sessionTag: sessionTag, model: model, effort: effort, mode: mode, sent: true);
    await writeTextFile('${await _dir()}/$id.json', jsonEncode(meta.toJson()));
  }

  @override
  Future<String> adoptNative(
    String nativeId, {
    required String cwd,
    required String sessionTag,
    required String model,
    String? effort,
    required AgentMode mode,
  }) async {
    await adoptImported(nativeId, cwd: cwd, sessionTag: sessionTag, model: model, effort: effort, mode: mode);
    return nativeId;
  }

  /// `--resume` prints nothing back: the history comes from the session file.
  @override
  bool get replaysNativeHistory => false;

  /// Shows the session from its journal; the CLI starts with the next
  /// message, not before. A briefing isn't kept across restarts (its MCP
  /// token was in memory), so a reopened session runs without our tools;
  /// [attachBriefed] hands it a new one.
  @override
  Future<HarnessSession> attach(String conversationId) => _attach(conversationId, null);

  /// [attach] with a new briefing (the old token was revoked when the session
  /// closed): the next process the session starts carries it. A session still
  /// open here is returned as it is (the controller only reattaches closed ones).
  @override
  Future<HarnessSession> attachBriefed(
    String conversationId,
    DriverBriefing briefing, {
    Map<String, Object?> mcpConfig = const {},
  }) => _attach(conversationId, briefing);

  @override
  Future<String?> resumeProblem(String conversationId) async {
    if (_live.containsKey(conversationId)) return null;
    final raw = await readTextFile('${await _dir()}/$conversationId.json');
    final json = raw == null ? null : _json(raw);
    if (json == null) return "This Claude Code session's record is gone.";
    final meta = _Meta.fromJson(json);
    // Before its first message the CLI has nothing to resume.
    if (!meta.sent) return null;
    if (await claudeSessionExists(meta.cwd, conversationId, configDir: configDir)) return null;
    return 'Claude Code no longer has that conversation.';
  }

  Future<HarnessSession> _attach(String conversationId, DriverBriefing? b) async {
    if (_live[conversationId] case final s?) return s;
    final dir = await _dir();
    final raw = await readTextFile('$dir/$conversationId.json');
    final json = raw == null ? null : _json(raw);
    if (json == null) throw const HarnessError("This Claude Code session's record is gone.");
    final journal = openEventJournal(dir, conversationId);
    final meta = _Meta.fromJson(json);
    final session = ClaudeSession._(this, conversationId, dir, meta, await _briefing(b), journal)
      .._history.addAll(await journal.read())
      .._carry.addAll(meta.carry);
    _live[conversationId] = session;
    session._emit(stateEvent(const Uuid().v4(), ExecutionStatus.idle), keep: false);
    return session;
  }

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async {
    final dir = await _dir();
    return {
      for (final id in conversationIds)
        if (_live[id] case final s?)
          id: s._status
        else if (await readTextFile('$dir/$id.json') != null)
          id: ExecutionStatus.idle,
    };
  }

  Future<String> _dir() async => '${await dataDir()}/driver-sessions/${info.id}';

  /// The briefing as Claude takes it; the session text is the file the
  /// briefing wrote next to its skills.
  Future<Delivery?> _briefing(DriverBriefing? b) async {
    if (b == null) return null;
    final skills = b.skillDir;
    final text = skills == null ? '' : await readTextFile('${briefingRootOf(skills)}/$sessionFileName') ?? '';
    return claudeDelivery(b, sessionText: text);
  }

  Future<LineChannel> _spawn(
    List<String> args, {
    required String cwd,
    required Map<String, String> env,
    required String sessionTag,
    required String logPath,
  }) async {
    if (spawn case final s?) return s(args, cwd: cwd, env: env, sessionTag: sessionTag, logPath: logPath);
    final path = await (_path ??= detectCli('claude', which: which).then((s) => s.path));
    if (path == null) {
      _path = null;
      throw const HarnessError("Claude Code isn't installed on this computer.");
    }
    return spawnDriver(executable: path, args: args, cwd: cwd, sessionTag: sessionTag, logPath: logPath, env: env);
  }
}

Map<String, Object?>? _json(String line) {
  try {
    return switch (jsonDecode(line)) {
      final Map<String, Object?> m => m,
      _ => null,
    };
  } on FormatException {
    return null;
  }
}

/// Claude Code's command list: `initialize` gives `{name, description,
/// argumentHint}`, `system/init` bare names.
List<NativeCommand> claudeCommands(List<Object?> list) => [
  for (final c in list)
    if (c is String && c.isNotEmpty)
      NativeCommand(name: c)
    else if (c case {'name': final String name} when name.isNotEmpty)
      NativeCommand(
        name: name,
        description: c['description'] as String? ?? '',
        argsHint: switch (c['argumentHint']) {
          final String h when h.isNotEmpty => h,
          _ => null,
        },
      ),
];

/// What [ClaudeDriver.attach] needs to continue a session: where it runs
/// (`--resume` looks the conversation up by folder), its model and mode, and
/// whether the CLI has had a message (before that there is nothing to resume),
/// and messages shown but not sent yet ([ClaudeSession.send] `run: false`).
final class _Meta {
  const _Meta({
    required this.cwd,
    required this.sessionTag,
    required this.model,
    required this.effort,
    required this.mode,
    required this.sent,
    this.carry = const [],
    this.commands = const [],
    this.native,
    this.autoMode = false,
  });

  final String cwd;
  final String sessionTag;
  final String model;
  final String? effort;
  final AgentMode mode;
  final bool sent;
  final List<String> carry;

  /// The CLI's `/` commands as it last listed them (the menu before it starts).
  final List<NativeCommand> commands;

  /// The permission mode picked by its own name ([ClaudeSession.setNativeMode]),
  /// or null for the one [mode] maps to ([permissionModeFor]).
  final String? native;

  /// The model supports `auto` (its last `initialize` said so).
  final bool autoMode;

  /// [effort] is taken as given (null is Claude's default), not kept.
  _Meta withLlm({required String model, required String? effort}) => _Meta(
    cwd: cwd,
    sessionTag: sessionTag,
    model: model,
    effort: effort,
    mode: mode,
    sent: sent,
    carry: carry,
    commands: commands,
    native: native,
    autoMode: autoMode,
  );

  /// [native] '' clears it.
  _Meta copyWith({
    AgentMode? mode,
    bool? sent,
    List<String>? carry,
    List<NativeCommand>? commands,
    String? native,
    bool? autoMode,
  }) => _Meta(
    cwd: cwd,
    sessionTag: sessionTag,
    model: model,
    effort: effort,
    mode: mode ?? this.mode,
    sent: sent ?? this.sent,
    carry: carry ?? this.carry,
    commands: commands ?? this.commands,
    native: native == null ? this.native : (native.isEmpty ? null : native),
    autoMode: autoMode ?? this.autoMode,
  );

  /// The permission mode the CLI runs in.
  String get permissionMode => native ?? permissionModeFor(mode);

  Map<String, Object?> toJson() => {
    'cwd': cwd,
    'session_tag': sessionTag,
    'model': model,
    'effort': ?effort,
    'mode': mode.name,
    'sent': sent,
    if (carry.isNotEmpty) 'carry': carry,
    if (commands.isNotEmpty) 'commands': [for (final c in commands) c.toJson()],
    'native_mode': ?native,
    if (autoMode) 'auto_mode': true,
  };

  static _Meta fromJson(Map<String, Object?> j) => _Meta(
    cwd: j['cwd'] as String? ?? '',
    sessionTag: j['session_tag'] as String? ?? '',
    model: j['model'] as String? ?? '',
    effort: j['effort'] as String?,
    mode: AgentMode.values.where((m) => m.name == j['mode']).firstOrNull ?? AgentMode.ask,
    sent: j['sent'] == true,
    carry: [for (final t in j['carry'] as List<Object?>? ?? const []) ?t as String?],
    commands: [for (final c in j['commands'] as List<Object?>? ?? const []) ?NativeCommand.fromJson(c)],
    native: j['native_mode'] as String?,
    autoMode: j['auto_mode'] == true,
  );
}

/// A call the CLI is waiting on us for: the request to answer, whether it
/// came from our hook (else `can_use_tool`), and the call's input.
typedef _Held = ({String requestId, bool hook, String name, Map<String, Object?> input});

/// One Claude Code conversation. Refusing a call doesn't stop the run (the
/// model is told and carries on); [resume] runs a stopped or failed turn on.
final class ClaudeSession
    implements HarnessSession, PerCallApprovals, HasNativeCommands, NativeModes, AnswersSideQuestion {
  ClaudeSession._(this._driver, this.id, this._dir, this._meta, this._briefing, this._journal)
    : _commands = NativeCommandList(_meta.commands),
      _modes = NativeModeFeed((modes: claudeModes(autoMode: _meta.autoMode), current: _meta.permissionMode));

  final ClaudeDriver _driver;
  @override
  final String id;
  final String _dir;
  _Meta _meta;
  final Delivery? _briefing;
  final EventJournal _journal;

  final _history = <HarnessEvent>[];
  final _events = StreamController<HarnessEvent>.broadcast();
  final _decoder = ClaudeDecoder();
  LineChannel? _channel;
  StreamSubscription<String>? _sub;
  Future<LineChannel>? _starting;
  var _requests = 0;
  var _running = false;
  var _waiting = false;

  /// We asked the running turn to stop; [_continueAfter]: run on once it has.
  var _interrupting = false;
  var _continueAfter = false;

  /// The process runs with an old effort or briefing: replaced once the turn ends.
  var _respawn = false;
  var _closed = false;
  var _status = ExecutionStatus.idle;

  /// Calls waiting for an answer, by call id.
  final _held = <String, _Held>{};

  /// Answers given before the CLI asked (parallel calls): used when it does.
  final _early = <String, ({bool accept, String? reason})>{};

  /// Calls already answered, so a second answer is dropped.
  final _answered = <String>{};

  /// Messages sent with `run: false`, which go along with the next one
  /// (also in the record, for [ClaudeDriver.attach]).
  final _carry = <String>[];

  /// Calls already shown as let run ([approvedEvent]).
  final _let = <String>{};

  /// The CLI's `/` commands: from its `initialize` reply, else `system/init`
  /// (names only); kept in the record so a reopened session has them.
  final NativeCommandList _commands;
  var _initListed = false;

  @override
  Stream<List<NativeCommand>> get commands => _commands.stream;

  /// Claude's permission modes ([claudeModes]); the current one as the CLI
  /// last said (`initialize`, `system` messages) or as we set it.
  final NativeModeFeed _modes;

  /// The mode before `plan`, set back once the plan is approved (ExitPlanMode).
  String? _beforePlan;

  @override
  Stream<NativeModeSet> get nativeModes => _modes.stream;

  @override
  Future<void> setNativeMode(String id) async {
    final m = offeredMode(_modes.latest.modes, id, 'Claude Code');
    await _moveTo(m.id, m.policy);
  }

  Future<void> _moveTo(String id, AgentMode policy) async {
    final from = _meta.permissionMode;
    if (id == 'plan' && from != 'plan') _beforePlan = from;
    await _save(_meta.copyWith(mode: policy, native: id));
    _modes.set(current: id);
    _request({'subtype': 'set_permission_mode', 'mode': id});
  }

  /// The CLI says which mode it is in (the user may have moved it, or a plan was approved).
  void _modeSaid(String id) {
    if (id.isEmpty || id == _modes.latest.current) return;
    final m = nativeModeOf(_modes.latest.modes, id);
    if (m?.blocked != null) {
      final back = _meta.permissionMode;
      _request({'subtype': 'set_permission_mode', 'mode': back});
      _emit(
        HarnessEvent.decode({
          'kind': 'ConversationErrorEvent',
          'id': const Uuid().v4(),
          'source': 'environment',
          'detail': 'Claude Code moved to ${m!.label}, which EveryAI doesn\'t offer; it was set back to $back.',
        }),
      );
      return;
    }
    unawaited(_save(_meta.copyWith(native: id, mode: m?.policy)));
    _modes.set(current: id);
  }

  /// The command goes as the turn's whole text; held `run: false` messages
  /// wait for the next message rather than hide it.
  @override
  Future<void> runCommand(String name, String args) async {
    final text = '/$name $args'.trim();
    _emit(userMessage(const Uuid().v4(), text));
    await _turn(text);
  }

  void _listed(List<NativeCommand> commands) {
    if (commands.isEmpty || listEquals(commands, _commands.latest)) return;
    _commands.set(commands);
    unawaited(_save(_meta.copyWith(commands: _commands.latest)));
  }

  /// History, then live events. Both are taken at the moment of listening,
  /// so nothing emitted in between is lost.
  @override
  Stream<HarnessEvent> get events {
    StreamSubscription<HarnessEvent>? live;
    late final StreamController<HarnessEvent> out;
    out = StreamController<HarnessEvent>(
      onListen: () {
        _history.forEach(out.add);
        live = _events.stream.listen(out.add, onDone: out.close);
      },
      onCancel: () => live?.cancel(),
    );
    return out.stream;
  }

  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async {
    _emit(userMessage(const Uuid().v4(), text));
    if (!run) {
      _carry.add(text);
      await _save(_meta.copyWith(carry: List.unmodifiable(_carry)));
      return;
    }
    final body = [..._carry, text].join('\n\n');
    _carry.clear();
    await _turn(body, images: images);
  }

  /// Sends [body] as the next turn, starting the CLI when it isn't running.
  /// The record's held text is cleared only when [_carry] is (in [send]): a
  /// command or a continue goes without it, and it waits on in the record too.
  Future<void> _turn(String body, {List<String> images = const []}) async {
    final c = await _ensure();
    if (!_meta.sent || _meta.carry.length != _carry.length) {
      await _save(_meta.copyWith(sent: true, carry: List.unmodifiable(_carry)));
    }
    c.send(jsonEncode(userLine(body, images: images)));
    _running = true;
    _emit(stateEvent(const Uuid().v4(), ExecutionStatus.running));
  }

  @override
  Future<void> interrupt() async {
    for (final callId in _held.keys.toList()) {
      _answer(callId, _held.remove(callId)!, accept: false, reason: 'The user stopped this.');
    }
    _waiting = false;
    _continueAfter = false;
    _stopTurn();
  }

  void _stopTurn() {
    if (!_running) return;
    _interrupting = true;
    _request({'subtype': 'interrupt'});
  }

  @override
  Future<void> pause() => interrupt();

  /// Runs on after a turn that stopped (Stop, the repeat guard's pause) or
  /// failed: the CLI has no "run again", so it gets a short message. Nothing
  /// while a turn runs, unless it is being stopped (it runs on after that).
  @override
  Future<void> resume() async {
    if (_closed) return;
    if (_running) {
      if (_interrupting) _continueAfter = true;
      return;
    }
    if (_status == ExecutionStatus.paused || _status == ExecutionStatus.error) await _turn(continueMessage);
  }

  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {
    final ids = callIds ?? _held.keys.toList();
    for (final callId in ids) {
      if (_held.remove(callId) case final h?) {
        _answer(callId, h, accept: accept, reason: reason);
      } else if (callIds != null && !_answered.contains(callId)) {
        _early[callId] = (accept: accept, reason: reason);
      }
    }
    // Refusing everything at once parks the run, as with the EveryAI harness.
    if (callIds == null && !accept) {
      _waiting = false;
      _stopTurn();
      return;
    }
    if (_waiting && _held.isEmpty) {
      _waiting = false;
      _emit(stateEvent(const Uuid().v4(), ExecutionStatus.running));
    }
  }

  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {
    await _save(_meta.copyWith(mode: mode, native: ''));
    _modes.set(current: _meta.permissionMode);
    _request({'subtype': 'set_permission_mode', 'mode': _meta.permissionMode});
  }

  /// The model changes in place. The CLI has no live control for the
  /// effort, so a new one restarts it (`--resume`): now when no turn runs,
  /// else when the turn ends.
  @override
  Future<void> switchLlm(SessionSpec spec) async {
    final effort = spec.effort == null || spec.effort!.isEmpty ? null : spec.effort;
    final restart = effort != _meta.effort;
    await _save(_meta.withLlm(model: spec.model, effort: effort));
    if (restart && _channel != null) {
      if (!_running) return _drop();
      _respawn = true;
      return;
    }
    _request({'subtype': 'set_model', 'model': claudeModelArg(spec.model) ?? 'default'});
  }

  @override
  Future<void> rewindTo(String? head) async =>
      throw HarnessError(rewindRefusal(_driver.info, _driver.caps) ?? "Claude Code can't go back.");

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _driver._live.remove(id);
    await _drop();
    await _journal.close();
    await _events.close();
    _commands.close();
    _modes.close();
  }

  /// Ends the CLI's process quietly; the next turn starts it again.
  Future<void> _drop() async {
    final c = _channel;
    _channel = null;
    _respawn = false;
    await _sub?.cancel();
    await c?.close();
  }

  /// `/btw`: a second CLI process on a fork of this conversation that isn't
  /// saved ([claudeAsideArgs]), so the running turn goes on untouched.
  @override
  Future<String> sideAnswer(String question) async {
    final c = await _driver._spawn(
      claudeAsideArgs(sessionId: id, resume: _meta.sent, model: _meta.model, effort: _meta.effort),
      cwd: _meta.cwd,
      env: const {},
      sessionTag: _meta.sessionTag,
      logPath: '$_dir/$id-aside.log',
    );
    try {
      final result = c.lines
          .map(_json)
          .firstWhere((j) => j?['type'] == 'result', orElse: () => null)
          .timeout(const Duration(minutes: 3));
      c.send(jsonEncode(userLine(asideMessage(question))));
      final r = await result;
      final text = switch (r?['result']) {
        final String t => t.trim(),
        _ => '',
      };
      if (r == null) throw const HarnessError('Claude Code stopped before it answered.');
      if (r['is_error'] == true || text.isEmpty) {
        throw HarnessError(text.isEmpty ? 'Claude Code gave no answer.' : text);
      }
      return text;
    } on TimeoutException {
      throw const HarnessError('Claude Code took too long to answer.');
    } finally {
      await c.close();
    }
  }

  /// The CLI's process, started when missing: a new conversation under our
  /// id, or the old one continued.
  Future<LineChannel> _ensure() async {
    if (_channel case final c?) return c;
    return _starting ??= _open().whenComplete(() => _starting = null);
  }

  Future<LineChannel> _open() async {
    final launch = claudeLaunch(
      sessionId: id,
      resume: _meta.sent,
      mode: _meta.mode,
      nativeMode: _meta.native,
      model: _meta.model,
      effort: _meta.effort,
      briefing: _briefing,
    );
    final c = await _driver._spawn(
      launch.args,
      cwd: _meta.cwd,
      env: launch.env,
      sessionTag: _meta.sessionTag,
      logPath: '$_dir/$id.log',
    );
    _channel = c;
    _requests = 0; // Ids count per process.
    _initListed = false;
    _sub = c.lines.listen(_line, onDone: () => _gone(c));
    // Before any message; the CLI reads its stdin in order.
    _request({'subtype': 'initialize', 'hooks': gateHooks});
    return c;
  }

  /// Sends a control request to a running CLI (one that isn't running
  /// takes the change from its record when it starts).
  void _request(Map<String, Object?> request) =>
      _channel?.send(jsonEncode(controlRequest('req_${++_requests}', request)));

  void _line(String raw) {
    final line = _json(raw);
    if (line == null) return;
    switch (line['type']) {
      case 'control_request':
        _asked(line['request_id'] as String? ?? '', line['request'] as Map<String, Object?>? ?? const {});
      case 'control_response':
        if (line['response'] case {'subtype': 'error', 'error': final Object error}) {
          _emit(HarnessEvent.decode({'kind': 'ConversationErrorEvent', 'id': const Uuid().v4(), 'detail': '$error'}));
        }
        // req_1 is this process's initialize.
        if (line['response'] case {'request_id': 'req_1', 'response': final Map<String, Object?> init}) {
          if (init['commands'] case final List<Object?> list) {
            _initListed = list.isNotEmpty;
            _listed(claudeCommands(list));
          }
          _initialized(init);
        }
      default:
        if (line case {'type': 'system', 'subtype': 'init', 'slash_commands': final List<Object?> l}
            when !_initListed) {
          _listed(claudeCommands(l));
        }
        if (line case {'type': 'system', 'permissionMode': final String mode}) _modeSaid(mode);
        final events = _decoder.decode(line);
        for (final e in events) {
          _emit(e);
          if (e is ActionCall && _selfAnswered(e.toolName)) _letRun(e.id);
        }
        if (line['type'] == 'result') _ended();
    }
  }

  /// What `initialize` says about modes: whether the model has `auto`, and the mode it runs in.
  void _initialized(Map<String, Object?> init) {
    final auto = claudeAutoMode(init, _meta.model);
    if (auto != _meta.autoMode) unawaited(_save(_meta.copyWith(autoMode: auto)));
    _modes.set(modes: claudeModes(autoMode: auto));
    if (init['current_permission_mode'] case final String mode) _modeSaid(mode);
  }

  /// A turn ended: replace a process with an old effort, and run on when
  /// [resume] asked while it was being stopped.
  void _ended() {
    _running = false;
    _waiting = false;
    _interrupting = false;
    if (_respawn) unawaited(_drop());
    if (_continueAfter) {
      _continueAfter = false;
      unawaited(_turn(continueMessage));
    }
  }

  bool _selfAnswered(String toolName) => answeredBySession(toolName, briefed: _briefing != null);

  /// Shows [callId] as no longer waiting for the user (its result is still to come).
  void _letRun(String callId) {
    if (_let.add(callId)) _emit(approvedEvent('ok:$callId', [callId]));
  }

  /// The CLI asks before a tool call: our hook, or its permission prompt.
  void _asked(String requestId, Map<String, Object?> request) {
    final hook = request['subtype'] == 'hook_callback';
    if (!hook && request['subtype'] != 'can_use_tool') {
      _channel?.send(jsonEncode(controlError(requestId, 'EveryAI does not handle ${request['subtype']}.')));
      return;
    }
    final body = hook ? request['input'] as Map<String, Object?>? ?? const {} : request;
    if (hook && body['hook_event_name'] != 'PreToolUse') {
      _channel?.send(jsonEncode(controlResponse(requestId, const {})));
      return;
    }
    final callId = body['tool_use_id'] as String? ?? '';
    final name = body['tool_name'] as String? ?? '';
    final input = body[hook ? 'tool_input' : 'input'] as Map<String, Object?>? ?? const {};
    final held = (requestId: requestId, hook: hook, name: name, input: input);
    if (!_decoder.knows(callId)) _emit(_decoder.action(callId, name, input));
    if (_selfAnswered(name)) return _answer(callId, held, accept: true);
    if (_early.remove(callId) case final a?) return _answer(callId, held, accept: a.accept, reason: a.reason);
    _held[callId] = held;
    _waiting = true;
    _emit(stateEvent(const Uuid().v4(), ExecutionStatus.waitingForConfirmation));
  }

  void _answer(String callId, _Held h, {required bool accept, String? reason}) {
    _answered.add(callId);
    if (accept) _letRun(callId);
    if (!accept) _decoder.refused[callId] = reason == null || reason.isEmpty ? refusedByUser : reason;
    final answer = approvalAnswer(hook: h.hook, accept: accept, reason: reason, input: h.input);
    _channel?.send(jsonEncode(controlResponse(h.requestId, answer)));
    // An approved plan: whether Claude leaves plan by itself under `-p` is unverified, so it is moved back.
    if (accept && h.name == 'ExitPlanMode' && _meta.permissionMode == 'plan') {
      final back = _beforePlan ?? 'default';
      final m = nativeModeOf(_modes.latest.modes, back);
      unawaited(_moveTo(back, m?.policy ?? AgentMode.ask));
    }
  }

  /// The process ended: a turn it was running failed; the next message
  /// starts it again.
  void _gone(LineChannel c) {
    if (!identical(_channel, c)) return;
    _channel = null;
    unawaited(_sub?.cancel());
    _held.clear();
    _waiting = false;
    _interrupting = false;
    _continueAfter = false;
    _respawn = false;
    if (_closed || !_running) return;
    _running = false;
    final why = c.lastError.trim();
    final detail = why.isEmpty ? 'Claude Code stopped.' : 'Claude Code stopped: ${why.split('\n').last}';
    _emit(HarnessEvent.decode({'kind': 'ConversationErrorEvent', 'id': const Uuid().v4(), 'detail': detail}));
    _emit(stateEvent(const Uuid().v4(), ExecutionStatus.error));
  }

  /// Shows [event] (and keeps it in the journal unless [keep] is off).
  void _emit(HarnessEvent event, {bool keep = true}) {
    if (event is StateChange) _status = event.executionStatus;
    if (event is! StreamDelta) {
      _history.add(event);
      if (keep) _journal.add(event);
    }
    if (!_events.isClosed) _events.add(event);
  }

  /// Writes one at a time (the command list is saved while a turn starts);
  /// each write takes the record as it is by then.
  Future<void> _save(_Meta meta) {
    _meta = meta;
    // A failed write is its caller's; the next one still runs.
    return _saving = _saving
        .catchError((Object _) {})
        .then((_) => writeTextFile('$_dir/$id.json', jsonEncode(_meta.toJson())));
  }

  Future<void> _saving = Future.value();
}
