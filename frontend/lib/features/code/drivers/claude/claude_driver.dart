// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

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
final class ClaudeDriver implements HarnessDriver {
  ClaudeDriver({this.which, this.dataDir = GitService.dataDir, this.spawn, this.run});

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
  DriverInfo get info => const DriverInfo(id: 'claude-code', label: 'Claude Code', needsConsent: true);

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
    final session = _live[id] = ClaudeSession._(this, id, dir, meta, briefing, openEventJournal(dir, id));
    await session._ensure();
    if (spec.initialMessage case final text?) {
      await session.send(text, run: spec.runInitial, images: spec.initialImages);
    }
    return session;
  }

  /// Shows the session from its journal; the CLI starts with the next
  /// message, not before. A briefing isn't kept across restarts (its MCP
  /// token was in memory), so a reopened session runs without our tools.
  @override
  Future<HarnessSession> attach(String conversationId) async {
    if (_live[conversationId] case final s?) return s;
    final dir = await _dir();
    final raw = await readTextFile('$dir/$conversationId.json');
    final json = raw == null ? null : _json(raw);
    if (json == null) throw const HarnessError("This Claude Code session's record is gone.");
    final journal = openEventJournal(dir, conversationId);
    final session = ClaudeSession._(this, conversationId, dir, _Meta.fromJson(json), null, journal)
      .._history.addAll(await journal.read());
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

/// What [ClaudeDriver.attach] needs to continue a session: where it runs
/// (`--resume` looks the conversation up by folder), its model and mode, and
/// whether the CLI has had a message (before that there is nothing to resume).
final class _Meta {
  const _Meta({
    required this.cwd,
    required this.sessionTag,
    required this.model,
    required this.effort,
    required this.mode,
    required this.sent,
  });

  final String cwd;
  final String sessionTag;
  final String model;
  final String? effort;
  final AgentMode mode;
  final bool sent;

  _Meta copyWith({String? model, String? effort, AgentMode? mode, bool? sent}) => _Meta(
    cwd: cwd,
    sessionTag: sessionTag,
    model: model ?? this.model,
    effort: effort ?? this.effort,
    mode: mode ?? this.mode,
    sent: sent ?? this.sent,
  );

  Map<String, Object?> toJson() => {
    'cwd': cwd,
    'session_tag': sessionTag,
    'model': model,
    'effort': ?effort,
    'mode': mode.name,
    'sent': sent,
  };

  static _Meta fromJson(Map<String, Object?> j) => _Meta(
    cwd: j['cwd'] as String? ?? '',
    sessionTag: j['session_tag'] as String? ?? '',
    model: j['model'] as String? ?? '',
    effort: j['effort'] as String?,
    mode: AgentMode.values.where((m) => m.name == j['mode']).firstOrNull ?? AgentMode.ask,
    sent: j['sent'] == true,
  );
}

/// A call the CLI is waiting on us for: the request to answer, whether it
/// came from our hook (else `can_use_tool`), and the call's input.
typedef _Held = ({String requestId, bool hook, Map<String, Object?> input});

/// One Claude Code conversation. Refusing a call doesn't stop the run (the
/// model is told and carries on), so [resume] does nothing.
final class ClaudeSession implements HarnessSession, PerCallApprovals {
  ClaudeSession._(this._driver, this.id, this._dir, this._meta, this._briefing, this._journal);

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
  var _closed = false;
  var _status = ExecutionStatus.idle;

  /// Calls waiting for an answer, by call id.
  final _held = <String, _Held>{};

  /// Answers given before the CLI asked (parallel calls): used when it does.
  final _early = <String, ({bool accept, String? reason})>{};

  /// Calls already answered, so a second answer is dropped.
  final _answered = <String>{};

  /// Messages sent with `run: false`, which go along with the next one.
  final _carry = <String>[];

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
      return;
    }
    final c = await _ensure();
    final body = [..._carry, text].join('\n\n');
    _carry.clear();
    if (!_meta.sent) await _save(_meta.copyWith(sent: true));
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
    if (_running) _request({'subtype': 'interrupt'});
  }

  @override
  Future<void> pause() => interrupt();

  @override
  Future<void> resume() async {}

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
      if (_running) _request({'subtype': 'interrupt'});
      return;
    }
    if (_waiting && _held.isEmpty) {
      _waiting = false;
      _emit(stateEvent(const Uuid().v4(), ExecutionStatus.running));
    }
  }

  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {
    await _save(_meta.copyWith(mode: mode));
    _request({'subtype': 'set_permission_mode', 'mode': permissionModeFor(mode)});
  }

  /// The model changes in place; a new effort applies when the CLI next
  /// starts (it has no live control for it).
  @override
  Future<void> switchLlm(SessionSpec spec) async {
    await _save(_meta.copyWith(model: spec.model, effort: spec.effort));
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
    final c = _channel;
    _channel = null;
    await _sub?.cancel();
    await c?.close();
    await _journal.close();
    await _events.close();
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
      default:
        final events = _decoder.decode(line);
        if (line['type'] == 'result') {
          _running = false;
          _waiting = false;
        }
        events.forEach(_emit);
    }
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
    final held = (requestId: requestId, hook: hook, input: input);
    if (!_decoder.knows(callId)) _emit(_decoder.action(callId, name, input));
    if (answeredBySession(name)) return _answer(callId, held, accept: true);
    if (_early.remove(callId) case final a?) return _answer(callId, held, accept: a.accept, reason: a.reason);
    _held[callId] = held;
    _waiting = true;
    _emit(stateEvent(const Uuid().v4(), ExecutionStatus.waitingForConfirmation));
  }

  void _answer(String callId, _Held h, {required bool accept, String? reason}) {
    _answered.add(callId);
    if (!accept) _decoder.refused[callId] = reason == null || reason.isEmpty ? refusedByUser : reason;
    final answer = approvalAnswer(hook: h.hook, accept: accept, reason: reason, input: h.input);
    _channel?.send(jsonEncode(controlResponse(h.requestId, answer)));
  }

  /// The process ended: a turn it was running failed; the next message
  /// starts it again.
  void _gone(LineChannel c) {
    if (!identical(_channel, c)) return;
    _channel = null;
    unawaited(_sub?.cancel());
    _held.clear();
    _waiting = false;
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

  Future<void> _save(_Meta meta) async {
    _meta = meta;
    await writeTextFile('$_dir/$id.json', jsonEncode(meta.toJson()));
  }
}
