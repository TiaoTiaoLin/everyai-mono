// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../domain/agent_mode.dart';
import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../briefing/briefing_types.dart' show RpcCall;
import '../driver_events.dart';
import '../event_journal.dart';
import '../json_rpc.dart';
import 'codex_mapping.dart';

// One Codex thread over `codex app-server` (JSON-RPC on stdio, without the
// `"jsonrpc"` field: `codex-rs/app-server-protocol/src/rpc.rs`). Message
// order follows the app-server guide (README at b04ed4c50c5c, removed from
// main in d3ee328ee6); field names follow the schema at 3a2788e6.

/// Sent as `clientInfo` (it shows in OpenAI's logs, so it stays stable).
const codexClientInfo = {'name': 'everyai', 'title': 'EveryAI', 'version': '0.1.0'};

/// How long the setup requests may take before the session gives up.
const codexSetupTimeout = Duration(seconds: 10);

/// Notifications the app doesn't use: whole-turn diffs and output streams
/// (the completed items carry both).
const _optOut = ['turn/diff/updated', 'item/commandExecution/outputDelta', 'item/fileChange/outputDelta'];

/// `initialize`, `initialized` and `account/read` (local auth, no model
/// call); returns the account reply (`{account, requiresOpenaiAuth}`).
Future<Map<String, Object?>> codexHandshake(JsonRpcPeer peer) async {
  await peer.request('initialize', {
    'clientInfo': codexClientInfo,
    'capabilities': {'optOutNotificationMethods': _optOut},
  }, codexSetupTimeout);
  peer.notify('initialized');
  final account = await peer.request('account/read', const <String, Object?>{}, codexSetupTimeout);
  return account is Map<String, Object?> ? account : const {};
}

enum _Decision { accept, decline, cancel }

/// An approval Codex is waiting for: [call] as the app shows it,
/// [synthetic] when the request itself made it (no item stands behind it,
/// so no item completion gives it a result).
final class _Pending {
  _Pending(this.call, this.turnId, {required this.synthetic});
  final ActionCall call;
  final String? turnId;
  final bool synthetic;
  final answer = Completer<_Decision>();
}

final class CodexSession implements HarnessSession, PerCallApprovals, SteersRuns {
  CodexSession(LineChannel channel, {required this.cwd, required AgentMode mode, String? model, String? effort})
    : _currentMode = mode,
      _model = model == null || model.isEmpty ? null : model,
      _effort = codexEffort(effort) {
    _peer = JsonRpcPeer(channel, writeVersion: false, onRequest: _onRequest, onNotify: _onNotify);
    unawaited(_peer.done.then((_) => _gone()));
  }

  final String cwd;
  late final JsonRpcPeer _peer;
  AgentMode _currentMode;
  String? _model;
  String? _effort;
  var _onPlan = false;
  String _threadId = '';
  EventJournal? _journal;

  final _history = <HarnessEvent>[];
  final _listeners = <StreamController<HarnessEvent>>[];
  final _calls = <String, ActionCall>{};
  final _resulted = <String>{};
  final _pending = <String, _Pending>{};
  final _ended = <String>{};
  final _held = <String>[];
  final _heldImages = <String>[];

  String? _turnId;
  Completer<void>? _turnDone;
  var _turnsSeen = false;
  var _plans = 0;
  String? _lastError;
  CodexTokens? _total;
  var _status = ExecutionStatus.idle;
  var _closing = false;

  /// Runs once the session is closed or its process went away.
  void Function()? onClosed;

  @override
  String get id => _threadId;

  ExecutionStatus get status => _status;
  String get model => _model ?? '';
  String? get effort => _effort;
  AgentMode get mode => _currentMode;

  // ------------------------------------------------------------------ setup

  /// The handshake, then [initRequests] (the briefing's skill roots; a
  /// failure leaves the session without them).
  Future<void> open({List<RpcCall> initRequests = const []}) async {
    final reply = await codexHandshake(_peer);
    _onPlan = switch (reply['account']) {
      {'type': 'chatgpt'} => true,
      _ => false,
    };
    for (final r in initRequests) {
      try {
        await _peer.request(r.method, r.params, codexSetupTimeout);
      } on Object {
        // Our skills are a bonus; the session runs without them.
      }
    }
  }

  Future<void> startThread({String? instructions}) async {
    final p = codexPolicy(_currentMode);
    final res = await _peer.request('thread/start', {
      'cwd': cwd,
      'model': ?_model,
      'approvalPolicy': p.approvalPolicy,
      'sandbox': p.sandbox,
      if (instructions != null && instructions.isNotEmpty) 'developerInstructions': instructions,
    }, codexSetupTimeout);
    _threadId = switch (res) {
      {'thread': {'id': final String id}} => id,
      _ => throw const HarnessError("Codex didn't start a thread."),
    };
  }

  /// Rejoins [threadId] without its turns: the transcript comes from our
  /// journal ([replay]), which has our own messages, refusals and usage ids.
  Future<void> resumeThread(String threadId) async {
    final p = codexPolicy(_currentMode);
    await _peer.request('thread/resume', {
      'threadId': threadId,
      'cwd': cwd,
      'excludeTurns': true,
      'approvalPolicy': p.approvalPolicy,
      'sandbox': p.sandbox,
    }, codexSetupTimeout);
    _threadId = threadId;
  }

  void useJournal(EventJournal journal) => _journal = journal;

  /// What an earlier run of the app saw, then a close for every call it
  /// left open, then idle.
  void replay(List<HarnessEvent> events) {
    final open = <String, ActionCall>{};
    for (final e in events) {
      _history.add(e);
      switch (e) {
        case ActionCall():
          open[e.id] = e;
          _calls[e.id] = e;
        case ToolResult():
          open.remove(e.actionId);
          _resulted.add(e.actionId);
        default:
      }
    }
    for (final call in open.values) {
      _result(
        resultEvent(
          id: '${call.id}-result',
          actionId: call.id,
          toolName: call.toolName,
          text: 'Stopped when the app closed.',
          isError: true,
        ),
      );
    }
    _state(ExecutionStatus.idle);
  }

  // ----------------------------------------------------------------- events

  @override
  Stream<HarnessEvent> get events {
    late final StreamController<HarnessEvent> c;
    c = StreamController<HarnessEvent>(
      onListen: () {
        _history.forEach(c.add);
        _listeners.add(c);
      },
      onCancel: () => _listeners.remove(c),
    );
    return c.stream;
  }

  void _emit(HarnessEvent e) {
    if (e is! StreamDelta) {
      _history.add(e);
      _journal?.add(e);
    }
    for (final c in [..._listeners]) {
      c.add(e);
    }
  }

  void _state(ExecutionStatus s) {
    _status = s;
    _emit(stateEvent(_newId(), s));
  }

  void _call(ActionCall call) {
    if (_calls.containsKey(call.id)) return;
    _calls[call.id] = call;
    _emit(call);
  }

  void _result(ToolResult result) {
    if (!_resulted.add(result.actionId)) return;
    _emit(result);
  }

  static String _newId() => const Uuid().v4();

  // ------------------------------------------------------------------ turns

  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async {
    _emit(userMessage('u-${_newId()}', text));
    _held.add(text);
    _heldImages.addAll(images);
    if (!run) return;
    final all = _held.join('\n\n');
    final pictures = [..._heldImages];
    _held.clear();
    _heldImages.clear();
    await _startTurn(all, pictures);
  }

  Future<void> _startTurn(String text, List<String> images) async {
    // A turn/start while one runs could be taken as a steer.
    while (_turnDone != null) {
      await Future.any([_turnDone!.future, _peer.done]);
      if (_peer.isClosed) return;
    }
    final p = codexPolicy(_currentMode);
    final res = await _peer.request('turn/start', {
      'threadId': _threadId,
      'input': _input(text, images),
      'model': ?_model,
      'effort': ?_effort,
      'approvalPolicy': p.approvalPolicy,
      'sandboxPolicy': p.sandboxPolicy,
    });
    if (res case {'turn': {'id': final String turn}}) _begin(turn);
  }

  static List<Map<String, Object?>> _input(String text, List<String> images) => [
    {'type': 'text', 'text': text},
    for (final url in images) {'type': 'image', 'url': url},
  ];

  void _begin(String turn) {
    if (_turnId == turn || _ended.contains(turn)) return;
    _turnId = turn;
    _turnDone = Completer<void>();
    _turnsSeen = true;
    _plans = 0;
    _lastError = null;
  }

  void _end(String turn) {
    _ended.add(turn);
    if (_turnId != turn) return;
    _turnId = null;
    final done = _turnDone;
    _turnDone = null;
    done?.complete();
  }

  @override
  Future<void> steer(String text, {List<String> images = const []}) async {
    final turn = _turnId;
    if (turn == null) return send(text, images: images);
    _emit(userMessage('u-${_newId()}', text));
    try {
      await _peer.request('turn/steer', {'threadId': _threadId, 'input': _input(text, images), 'expectedTurnId': turn});
    } on JsonRpcError {
      // The turn ended meanwhile: the message starts the next one.
      await _startTurn(text, images);
    }
  }

  @override
  Future<void> interrupt() async {
    final turn = _turnId;
    if (turn == null) return;
    try {
      await _peer.request('turn/interrupt', {'threadId': _threadId, 'turnId': turn});
    } on JsonRpcError {
      // Already over.
    }
  }

  @override
  Future<void> pause() => interrupt();

  /// Refusals don't park a Codex turn, so there is nothing to resume.
  @override
  Future<void> resume() async {}

  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async => _currentMode = mode;

  @override
  Future<void> switchLlm(SessionSpec spec) async {
    if (spec.model.isNotEmpty) _model = spec.model;
    _effort = codexEffort(spec.effort);
  }

  @override
  Future<void> rewindTo(String? head) async => throw const HarnessError("Codex can't go back to an earlier turn.");

  @override
  Future<void> close() async {
    _closing = true;
    // Pending approvals are settled once the peer is gone (no reply is sent).
    await _peer.close();
    await _journal?.close();
    for (final c in [..._listeners]) {
      unawaited(c.close());
    }
    _listeners.clear();
  }

  /// The process ended: by [close], or on its own (a crash), which the
  /// transcript shows as a failure.
  void _gone() {
    final open = [..._pending.values];
    _pending.clear();
    for (final p in open) {
      if (!p.answer.isCompleted) p.answer.complete(_Decision.cancel);
    }
    _turnDone?.complete();
    _turnDone = null;
    _turnId = null;
    if (!_closing) {
      for (final p in open) {
        _result(rejectedResult(p.call, 'Codex stopped before it was answered.'));
      }
      final why = _peer.channel.lastError.trim();
      _emit(_failure(why.isEmpty ? 'Codex stopped.' : 'Codex stopped: ${why.split('\n').last}'));
      _state(ExecutionStatus.error);
    }
    onClosed?.call();
  }

  // ---------------------------------------------------------- notifications

  void _onNotify(String method, Object? params) {
    if (params is! Map<String, Object?>) return;
    if (params['threadId'] case final String t when _threadId.isNotEmpty && t != _threadId) return;
    switch (method) {
      case 'turn/started':
        if (params['turn'] case {'id': final String turn}) {
          _begin(turn);
          _state(ExecutionStatus.running);
        }
      case 'turn/completed':
        _turnCompleted(params['turn'] as Map<String, Object?>? ?? const {});
      case 'item/agentMessage/delta':
        _emit(StreamDelta(raw: const {}, content: params['delta'] as String? ?? '', reasoning: ''));
      case 'item/reasoning/summaryTextDelta':
        _emit(StreamDelta(raw: const {}, content: '', reasoning: params['delta'] as String? ?? ''));
      case 'item/started':
        if (params['item'] case final Map<String, Object?> item) {
          if (callOf(item, cwd) case final call?) _call(call);
        }
      case 'item/completed':
        if (params['item'] case final Map<String, Object?> item) _itemCompleted(item);
      case 'turn/plan/updated':
        final turn = params['turnId'] as String? ?? _turnId ?? '';
        final call = planCall('plan-$turn-${_plans++}', params);
        _call(call);
        _result(
          resultEvent(id: '${call.id}-result', actionId: call.id, toolName: call.toolName, text: 'Plan updated.'),
        );
      case 'thread/tokenUsage/updated':
        _usage(params);
      case 'error':
        if (params['willRetry'] == true) return;
        final message = switch (params['error']) {
          {'message': final String m} => m,
          _ => 'Codex failed.',
        };
        if (_turnId != null) {
          _lastError = message;
        } else {
          _emit(_failure(message));
        }
    }
  }

  void _itemCompleted(Map<String, Object?> item) {
    if (messageOf(item) case final message?) {
      _emit(message);
      return;
    }
    final started = callOf(item, cwd);
    if (started == null) return;
    _call(started);
    final call = _calls[started.id]!;
    if (resultOf(item, call) case final ToolResult r?) _result(r);
  }

  void _turnCompleted(Map<String, Object?> turn) {
    final id = turn['id'] as String? ?? _turnId ?? '';
    // Codex drops the approvals of a turn that ends; ours go with them.
    for (final p in [..._pending.values]) {
      if (p.turnId != null && p.turnId != id) continue;
      _pending.remove(p.call.id);
      p.answer.complete(_Decision.cancel);
      _result(rejectedResult(p.call, 'Stopped before it was answered.'));
    }
    final status = turn['status'] as String? ?? 'completed';
    final error = switch (turn['error']) {
      {'message': final String m} => m,
      _ => _lastError,
    };
    _end(id);
    switch (status) {
      case 'interrupted':
        _state(ExecutionStatus.paused);
      case 'failed':
        _emit(_failure(error ?? 'The turn failed.'));
        _state(ExecutionStatus.error);
      default:
        _state(ExecutionStatus.finished);
    }
  }

  HarnessEvent _failure(String message) =>
      HarnessEvent.decode({'kind': 'ConversationErrorEvent', 'id': _newId(), 'detail': message});

  void _usage(Map<String, Object?> params) {
    final usage = params['tokenUsage'] as Map<String, Object?>? ?? const {};
    final total = tokensOf(usage['total']);
    if (total == null) return;
    final previous = _total;
    _total = total;
    // An update before any turn of this process is the saved one a resume
    // replays: it only sets where counting starts.
    if (!_turnsSeen) return;
    final turn = params['turnId'] as String? ?? _turnId ?? '';
    if (usageDelta(previous, total, tokensOf(usage['last']), turnId: turn, onPlan: _onPlan) case final r?) _emit(r);
  }

  // ---------------------------------------------------------------- requests

  Future<Object?> _onRequest(String method, Object? params) async {
    final p = params is Map<String, Object?> ? params : const <String, Object?>{};
    switch (method) {
      case 'item/commandExecution/requestApproval' || 'item/fileChange/requestApproval':
        final decision = await _ask(_approvalCall(method, p), p['turnId'] as String?);
        return {'decision': decision.name};
      case 'mcpServer/elicitation/request':
        final meta = p['_meta'] as Map<String, Object?>? ?? const {};
        if (meta['codex_approval_kind'] != 'mcp_tool_call') return {'action': 'decline', 'content': null};
        final call = actionEvent(
          id: 'mcp-${_newId()}',
          toolName: '${p['serverName']}__${meta['tool_name']}',
          kind: 'MCPToolAction',
          args: {...?meta['tool_params'] as Map<String, Object?>?},
        );
        _call(call);
        final decision = await _ask(call, p['turnId'] as String?, synthetic: true);
        return decision == _Decision.accept
            ? {'action': 'accept', 'content': const <String, Object?>{}}
            : {'action': decision.name, 'content': null};
      case 'item/tool/requestUserInput':
        // Questions reach the user through our MCP server's cards.
        return {'answers': const <String, Object?>{}};
      case 'item/permissions/requestApproval':
        return {'permissions': const <String, Object?>{}};
      case 'execCommandApproval' || 'applyPatchApproval':
        return {'decision': 'denied'};
    }
    throw const JsonRpcError(JsonRpcError.methodNotFound, 'Not supported by this client');
  }

  /// The call an approval request is about: the item's own when it was
  /// started, else one made from the request (a sub-command, stdin, the
  /// network), which only the user may approve unless it is a plain command.
  ActionCall _approvalCall(String method, Map<String, Object?> p) {
    final itemId = p['itemId'] as String? ?? _newId();
    final approvalId = p['approvalId'] as String?;
    final key = approvalId == null || approvalId.isEmpty ? itemId : '$itemId#$approvalId';
    if (_calls[key] case final call?) return call;
    final ActionCall call;
    if (method == 'item/fileChange/requestApproval') {
      call = actionEvent(id: key, toolName: 'apply_patch', kind: 'ApplyPatchAction', args: {'reason': ?p['reason']});
    } else if (p['networkApprovalContext'] case final Map<String, Object?> net) {
      call = actionEvent(id: key, toolName: 'network', kind: 'CodexNetworkAction', args: {...net});
    } else if (p['kind'] == 'writeStdin') {
      call = actionEvent(id: key, toolName: 'shell', kind: 'CodexStdinAction', args: {'command': ?p['command']});
    } else {
      call = actionEvent(
        id: key,
        toolName: 'shell',
        kind: 'TerminalAction',
        args: {if (p['command'] case final String c) 'command': unwrapCommand(c), 'cwd': p['cwd'] as String? ?? cwd},
      );
    }
    _call(call);
    return _calls[key]!;
  }

  Future<_Decision> _ask(ActionCall call, String? turnId, {bool? synthetic}) {
    final pending = _Pending(call, turnId, synthetic: synthetic ?? !_isItem(call));
    _pending[call.id] = pending;
    _state(ExecutionStatus.waitingForConfirmation);
    return pending.answer.future;
  }

  /// Whether a Codex item stands behind [call] (its result comes with the
  /// item's completion).
  bool _isItem(ActionCall call) => !call.id.contains('#') && call.actionKind != 'CodexNetworkAction';

  /// Allowing sends `accept` (never "for the session": each call is the
  /// app's to judge). Refusing named calls sends `decline` and the turn goes
  /// on; refusing them all (Deny all, Stop, a reply typed in chat) sends
  /// `cancel`, which ends the turn. Codex's decision has no reason, so a
  /// refusal's reason follows as one steer.
  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {
    final targets = [
      for (final p in _pending.values)
        if (callIds == null || callIds.contains(p.call.id)) p,
    ];
    if (targets.isEmpty) return;
    final decision = accept
        ? _Decision.accept
        : callIds == null
        ? _Decision.cancel
        : _Decision.decline;
    for (final p in targets) {
      _pending.remove(p.call.id);
      p.answer.complete(decision);
      if (!accept) {
        _result(rejectedResult(p.call, reason == null || reason.isEmpty ? 'Refused.' : reason));
      } else if (p.synthetic) {
        _result(
          resultEvent(id: '${p.call.id}-result', actionId: p.call.id, toolName: p.call.toolName, text: 'Allowed.'),
        );
      }
    }
    if (_pending.isEmpty) _state(ExecutionStatus.running);
    final turn = _turnId;
    if (decision != _Decision.decline || reason == null || reason.trim().isEmpty || turn == null) return;
    // Let the replies go out before the steer.
    await Future<void>.delayed(Duration.zero);
    final what = [for (final p in targets) _describe(p.call)].join('; ');
    try {
      await _peer.request('turn/steer', {
        'threadId': _threadId,
        'input': _input('EveryAI refused $what: ${reason.trim()}', const []),
        'expectedTurnId': turn,
      });
    } on JsonRpcError {
      // The model still sees the refusal, without the reason.
    }
  }

  static String _describe(ActionCall call) => switch (call.actionKind) {
    'TerminalAction' => '`${call.str('command')}`',
    'ApplyPatchAction' => 'the edit to ${(call.action['paths'] as List<Object?>? ?? const []).join(', ')}',
    _ => call.toolName,
  };
}
