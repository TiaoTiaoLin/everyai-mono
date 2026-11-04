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

/// One OpenCode session on its own server: events from the server's stream
/// (only this session's), history from its message list, answers through
/// its permission replies.
final class OpenCodeSession implements HarnessSession, SteersRuns, PerCallApprovals {
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
  /// its history and waiting requests are read first.
  Future<void> bind(String sessionId, {bool replay = false}) async {
    _id = sessionId;
    if (replay) await _replay(resync: false);
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
  /// reads and carries on; refusing all of them (no [callIds]) sends a bare
  /// refusal, which stops the run.
  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {
    final pending = _mapper.pending;
    final targets = [
      for (final e in pending.entries)
        if (callIds == null || callIds.contains(e.key)) e.value,
    ];
    final decision = accept ? 'once' : 'reject';
    for (final request in targets) {
      final body = <String, Object?>{
        'decision': decision,
        if (!accept && callIds != null)
          'message': (reason ?? '').trim().isEmpty ? 'The user refused this call.' : reason,
      };
      try {
        await _server.call('POST', '/api/session/$_id/permission/$request/reply', body: body);
      } on OpenCodeHttpError catch (e) {
        // Already answered, or the run moved on.
        if (e.status != 404) rethrow;
      }
      _mapper.replied(request, decision);
    }
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
    if (_connected case final c? when !c.isCompleted) {
      c.completeError(const HarnessError("OpenCode's event stream closed."));
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
