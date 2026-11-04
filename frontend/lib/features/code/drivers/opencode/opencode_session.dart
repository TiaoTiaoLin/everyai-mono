// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import '../../../../core/net/sse.dart';
import '../../domain/agent_mode.dart';
import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../driver.dart';
import '../driver_policy.dart';
import 'opencode_events.dart';
import 'opencode_server.dart';

/// The rules every session is created with (the last match wins): OpenCode
/// asks about every tool call, and the app's own permissions decide each
/// one. Its question tool and subagents are off (our question cards come
/// through our MCP server; subagents run as the app's child sessions), the
/// to-do list and skills need no answer, and our MCP server judges its own
/// tools.
const openCodeSessionRules = [
  {'action': '*', 'resource': '*', 'effect': 'ask'},
  {'action': 'question', 'resource': '*', 'effect': 'deny'},
  {'action': 'subagent', 'resource': '*', 'effect': 'deny'},
  {'action': 'todowrite', 'resource': '*', 'effect': 'allow'},
  {'action': 'skill', 'resource': '*', 'effect': 'allow'},
  {'action': 'everyai_*', 'resource': '*', 'effect': 'allow'},
];

/// OpenCode's `{providerID, id, variant}` for the app's `provider/model` id
/// and effort; null when [model] names no provider (the server's default).
Map<String, Object?>? openCodeModelRef(String model, String? effort) {
  final cut = model.indexOf('/');
  if (cut <= 0 || cut == model.length - 1) return null;
  return {
    'providerID': model.substring(0, cut),
    'id': model.substring(cut + 1),
    if (effort != null && effort.isNotEmpty) 'variant': effort,
  };
}

const _info = DriverInfo(id: 'opencode', label: 'OpenCode');

/// `compact` plus the commands in `GET /api/command`'s `data:[{name, description}]`.
List<NativeCommand> openCodeCommands(Object? data) {
  final out = [const NativeCommand(name: 'compact', description: 'Summarize the conversation to free up context')];
  final names = {'compact'};
  if (data is List<Object?>) {
    for (final c in data) {
      if (c case {'name': final String name} when name.isNotEmpty && names.add(name)) {
        out.add(NativeCommand(name: name, description: c['description'] as String? ?? ''));
      }
    }
  }
  return out;
}

/// OpenCode's primary agents (`GET /api/agent`'s `data`; hidden ones and
/// subagents left out) as modes: `plan` under the app's Plan, every other
/// one (`build`, the user's own) under Ask. The session's rules (`*: ask`,
/// last match wins) keep every agent asking, whatever its own permissions say.
List<NativeMode> openCodeModes(Object? data) => [
  if (data is List<Object?>)
    for (final a in data)
      if (a case {'id': final String id} when id.isNotEmpty && a['hidden'] != true && a['mode'] != 'subagent')
        NativeMode(
          id: id,
          label: switch (a['name']) {
            final String n when n.isNotEmpty => n,
            _ => id,
          },
          description: a['description'] as String? ?? '',
          policy: id == 'plan' ? AgentMode.plan : AgentMode.ask,
        ),
];

/// One OpenCode session on its own server: events from the server's stream
/// (only this session's), history from its message list, answers through
/// its permission replies.
final class OpenCodeSession implements HarnessSession, SteersRuns, PerCallApprovals, HasNativeCommands, NativeModes {
  OpenCodeSession(
    this._server, {
    required String workingDir,
    bool Function(String providerId)? onPlan,
    this.reconnectDelay = const Duration(seconds: 1),
    this.onClose,
  }) : _mapper = OpenCodeMapper(workingDir: workingDir, onPlan: onPlan);

  final OpenCodeServer _server;
  final OpenCodeMapper _mapper;

  /// The wait before the first reconnect; later ones wait longer.
  final Duration reconnectDelay;
  final void Function()? onClose;

  var _id = '';
  var _ready = false;
  var _closed = false;
  var _reconnecting = false;
  final _early = <Map<String, Object?>>[];
  StreamSubscription<SseEvent>? _sub;
  Completer<void>? _connected;
  final _log = <HarnessEvent>[];
  final _listeners = <StreamController<HarnessEvent>>{};
  final _held = <String>[];

  @override
  String get id => _id;

  /// The run's state as last reported.
  ExecutionStatus get status => _mapper.status == ExecutionStatus.unknown ? ExecutionStatus.idle : _mapper.status;

  @override
  Stream<HarnessEvent> get events {
    late final StreamController<HarnessEvent> c;
    c = StreamController<HarnessEvent>(
      onListen: () {
        _log.forEach(c.add);
        _listeners.add(c);
      },
      onCancel: () => _listeners.remove(c),
    );
    return c.stream;
  }

  /// Opens the event stream and waits until the server says it is
  /// connected: its stream keeps nothing, so it is open before any work.
  Future<void> connect() async {
    final connected = _connected = Completer<void>();
    final res = await _server.events();
    unawaited(_sub?.cancel());
    _sub = res.stream
        .transform(const SseDecoder())
        .listen(_onSse, onDone: _onDrop, onError: (Object _) => _onDrop(), cancelOnError: true);
    await connected.future;
  }

  /// Ties the session to OpenCode's [sessionId]. With [replay] (reopening)
  /// its history and waiting requests are read first; a run the history
  /// leaves going that this server isn't running (the app quit mid-turn)
  /// ends there.
  Future<void> bind(String sessionId, {bool replay = false}) async {
    _id = sessionId;
    if (replay) {
      await _replay(resync: false);
      if (_mapper.status == ExecutionStatus.running) {
        final active = await _server.call('GET', '/api/session/active');
        final data = active is Map ? active['data'] : null;
        if (data is! Map || !data.containsKey(_id)) _mapper.notRunning().forEach(_emit);
      }
    }
    _flush();
  }

  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async {
    if (!run) {
      _held.add(text);
      return;
    }
    final all = [..._held, text].join('\n\n');
    _held.clear();
    await _server.call('POST', '/api/session/$_id/prompt', body: {'text': all});
  }

  /// OpenCode's `/` commands (`GET /api/command`), read when the menu first
  /// asks and again on `command.updated`. `compact` is a session route of
  /// its own, not a listed command. The event name and the command route's
  /// body come from OpenCode 2.1.3's binary and T3 Code, not from docs.
  /// `compact` is offered before the list loads, and a failed load is tried
  /// again by the menu's next listen.
  final _commands = NativeCommandList(openCodeCommands(null));
  var _commandsWanted = false;

  @override
  Stream<List<NativeCommand>> get commands {
    if (!_commandsWanted) {
      _commandsWanted = true;
      unawaited(_loadCommands());
    }
    return _commands.stream;
  }

  Future<void> _loadCommands() async {
    try {
      final res = await _server.call('GET', '/api/command');
      _commands.set(openCodeCommands(res is Map ? res['data'] : null));
    } on Object {
      // The menu keeps what it had; the next listen tries again.
      _commandsWanted = false;
    }
  }

  @override
  Future<void> runCommand(String name, String args) async {
    if (name == 'compact') {
      await _server.call('POST', '/api/session/$_id/compact', body: const <String, Object?>{});
      return;
    }
    await _server.call('POST', '/api/session/$_id/command', body: {'name': name, 'text': args});
  }

  /// The agents as modes ([openCodeModes]), read when the picker first asks.
  /// A session starts on `build`; [setNativeMode] switches the agent for the
  /// turns after (`POST /api/session/:id/agent`, OpenAPI 2.1.3).
  final _modes = NativeModeFeed();
  var _modesWanted = false;

  @override
  Stream<NativeModeSet> get nativeModes {
    if (!_modesWanted) {
      _modesWanted = true;
      unawaited(_loadModes());
    }
    return _modes.stream;
  }

  Future<void> _loadModes() async {
    try {
      final res = await _server.call('GET', '/api/agent');
      final modes = openCodeModes(res is Map ? res['data'] : null);
      _modes.set(
        modes: modes,
        current: _modes.latest.current ?? (nativeModeOf(modes, 'build') ?? modes.firstOrNull)?.id,
      );
    } on Object {
      // The picker stays empty; the next listen tries again.
      _modesWanted = false;
    }
  }

  @override
  Future<void> setNativeMode(String id) async {
    offeredMode(_modes.latest.modes, id, 'OpenCode');
    await _server.call('POST', '/api/session/$_id/agent', body: {'agent': id});
    _modes.set(current: id);
  }

  @override
  Future<void> steer(String text, {List<String> images = const []}) =>
      _server.call('POST', '/api/session/$_id/prompt', body: {'text': text, 'delivery': 'steer'});

  @override
  Future<void> interrupt() => _server.call('POST', '/api/session/$_id/interrupt');

  @override
  Future<void> pause() => interrupt();

  /// Refusals with a reason don't park the run, and a parked one starts
  /// again with the next message.
  @override
  Future<void> resume() async {}

  /// Accepting allows the call once (never "always": remembering is the
  /// app's job). Refusing chosen calls sends the reason, which the model
  /// reads and carries on. Refusing all of them (no [callIds]) stops the
  /// run: with a reason, the refusals carry it and the run is interrupted
  /// (the model reads it next turn); without one, a bare refusal stops it.
  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {
    final pending = _mapper.pending;
    final targets = [
      for (final e in pending.entries)
        if (callIds == null || callIds.contains(e.key)) e.value,
    ];
    final decision = accept ? 'once' : 'reject';
    final why = (reason ?? '').trim();
    final stop = !accept && callIds == null && why.isNotEmpty;
    for (final request in targets) {
      final body = <String, Object?>{
        'decision': decision,
        if (!accept && (callIds != null || stop)) 'message': why.isEmpty ? 'The user refused this call.' : reason,
      };
      try {
        await _server.call('POST', '/api/session/$_id/permission/$request/reply', body: body);
      } on OpenCodeHttpError catch (e) {
        // Already answered, or the run moved on.
        if (e.status != 404) rethrow;
      }
      _mapper.replied(request, decision);
    }
    if (stop && targets.isNotEmpty) await interrupt();
  }

  /// The app's policy decides every request, whatever the mode.
  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {}

  @override
  Future<void> switchLlm(SessionSpec spec) async {
    final model = openCodeModelRef(spec.model, spec.effort);
    if (model == null) throw HarnessError('OpenCode needs a model as provider/model, not "${spec.model}".');
    await _server.call('POST', '/api/session/$_id/model', body: {'model': model});
  }

  @override
  Future<void> rewindTo(String? head) async => throw HarnessError(rewindRefusal(_info, const {})!);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // An event stream waiting for its next frame may never finish cancelling.
    unawaited(_sub?.cancel());
    await _server.close();
    for (final l in _listeners.toList()) {
      await l.close();
    }
    _commands.close();
    _modes.close();
    onClose?.call();
  }

  void _onSse(SseEvent e) {
    final Object? frame;
    try {
      frame = jsonDecode(e.data);
    } on FormatException {
      return;
    }
    if (frame is! Map<String, Object?>) return;
    if (frame['type'] == 'server.connected') {
      if (_connected case final c? when !c.isCompleted) c.complete();
      return;
    }
    if (frame['type'] == 'command.updated') {
      if (_commandsWanted) unawaited(_loadCommands());
      return;
    }
    if (_ready) {
      _handle(frame);
    } else {
      _early.add(frame);
    }
  }

  void _handle(Map<String, Object?> frame) {
    final data = frame['data'];
    if (data is! Map || data['sessionID'] != _id) return;
    _mapper.live(frame).forEach(_emit);
  }

  void _flush() {
    _ready = true;
    final early = List.of(_early);
    _early.clear();
    early.forEach(_handle);
  }

  Future<void> _replay({required bool resync}) async {
    final messages = <Object?>[];
    const limit = 100;
    Map<String, String> query = {'order': 'asc', 'limit': '$limit'};
    while (true) {
      final page = await _server.call('GET', '/api/session/$_id/message', query: query);
      final data = page is Map ? page['data'] as List<Object?>? ?? const [] : const <Object?>[];
      messages.addAll(data);
      final next = page is Map && page['cursor'] is Map ? (page['cursor'] as Map)['next'] : null;
      if (data.length < limit || next is! String) break;
      query = {'cursor': next, 'limit': '$limit'};
    }
    _mapper.history(messages, resync: resync).forEach(_emit);
    final requests = await _server.call('GET', '/api/session/$_id/permission');
    _mapper.requests(requests is Map ? requests['data'] as List<Object?>? ?? const [] : const []).forEach(_emit);
  }

  void _onDrop() {
    if (_closed) return;
    _ready = false;
    // Closed while connecting: whoever is connecting gets the error.
    if (_connected case final c? when !c.isCompleted) {
      c.completeError(const HarnessError("OpenCode's event stream closed."));
      return;
    }
    if (_reconnecting) return;
    _reconnecting = true;
    _emit(const ConnectionChange(connected: false));
    unawaited(_reconnect().whenComplete(() => _reconnecting = false));
  }

  Future<void> _reconnect() async {
    for (var attempt = 1; attempt <= 20; attempt++) {
      if (reconnectDelay > Duration.zero) await Future<void>.delayed(reconnectDelay * (attempt < 10 ? attempt : 10));
      if (_closed) return;
      if (_server.exited) {
        _emit(const ConnectionChange(connected: false, restarted: true));
        _emit(_failure('OpenCode stopped. Start a new session to go on.'));
        return;
      }
      try {
        await connect();
        await _replay(resync: true);
      } on Object {
        continue;
      }
      _flush();
      _emit(const ConnectionChange(connected: true));
      return;
    }
    // A stream that came back without its history would buffer for good.
    unawaited(_sub?.cancel());
    _sub = null;
    _early.clear();
    _emit(_failure("The app lost touch with OpenCode's server."));
  }

  HarnessEvent _failure(String message) =>
      HarnessEvent.decode({'kind': 'ConversationErrorEvent', 'id': '', 'detail': message});

  void _emit(HarnessEvent e) {
    if (_closed) return;
    if (e is! StreamDelta) _log.add(e);
    for (final l in _listeners) {
      l.add(e);
    }
  }
}
