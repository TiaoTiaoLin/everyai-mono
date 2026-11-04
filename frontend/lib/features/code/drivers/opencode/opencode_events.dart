// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../harness/events.dart';
import '../driver_events.dart';
import '../usage_limit.dart';

/// Turns one OpenCode 2.x session's server events ([live]) and its message
/// list ([history], [requests]) into the app's [HarnessEvent]s. Both paths
/// give the same ids (the user message id, `<message>/text/<n>`, the tool
/// call id, the assistant message id for usage), and every id is emitted
/// once, so a resync after a dropped stream adds only what is new.
///
/// Approvals: a tool call shows when OpenCode asks about it (the session's
/// rules ask for every call, so the app's own policy decides), as an
/// [ActionCall] with the call id plus `waiting_for_confirmation`. A call that
/// asks a second time (a read outside the project asks `external_directory`,
/// then `read`) gets a fresh id `<call>#<request>`, so it is decided again.
/// Calls the rules allow show once they finish.
final class OpenCodeMapper {
  OpenCodeMapper({required this.workingDir, bool Function(String providerId)? onPlan, DateTime Function()? now})
    : _onPlan = onPlan ?? ((_) => false),
      _now = now ?? DateTime.now;

  /// The session's folder; OpenCode's relative paths are made absolute against it.
  final String workingDir;
  final bool Function(String providerId) _onPlan;
  final DateTime Function() _now;

  final _seen = <String>{};
  final _names = <String, String>{};
  final _inputs = <String, Map<String, Object?>>{};
  final _actionOf = <String, String>{};
  final _pending = <String, String>{};
  final _rejected = <String>{};
  var _lastMessage = '';
  var _provider = '';

  /// The status last emitted.
  ExecutionStatus status = ExecutionStatus.unknown;

  /// The calls waiting for an answer: action id → OpenCode's request id.
  Map<String, String> get pending => Map.unmodifiable(_pending);

  /// Notes our own answer to [requestId] before OpenCode confirms it.
  void replied(String requestId, String decision) {
    final action = _actionFor(requestId);
    if (action == null) return;
    _pending.remove(action);
    if (decision == 'reject') _rejected.add(action);
  }

  /// One event from `GET /api/event` (the whole frame: `{type, data}`).
  List<HarnessEvent> live(Map<String, Object?> event) {
    final d = _map(event['data']) ?? const {};
    final out = <HarnessEvent>[];
    switch (event['type']) {
      case 'session.inbox.enqueued':
        final item = _map(d['item']) ?? const {};
        if (item['type'] == 'user') {
          _user(out, _str(d['inboxID']), _str(_map(item['payload'])?['text']));
        }
      case 'session.text.delta':
        out.add(_delta(content: _str(d['delta'])));
      case 'session.reasoning.delta':
        out.add(_delta(reasoning: _str(d['delta'])));
      case 'session.text.ended':
        _text(out, '${d['assistantMessageID']}/text/${d['ordinal']}', _str(d['text']));
      case 'session.reasoning.ended':
        _text(out, '${d['assistantMessageID']}/reasoning/${d['ordinal']}', '', reasoning: _str(d['text']));
      case 'session.step.started':
        _lastMessage = _str(d['assistantMessageID']);
        _provider = _str(_map(d['model'])?['providerID']);
      case 'session.tool.input.started':
        _names[_str(d['id'])] = _str(d['name']);
      case 'session.tool.called':
        if (_map(d['input']) case final input?) _inputs[_str(d['id'])] = input;
      case 'permission.asked':
        _ask(out, d);
      case 'permission.replied':
        final action = _actionFor(_str(d['requestID']));
        if (action != null) {
          _pending.remove(action);
          if (d['reply'] == 'reject') _rejected.add(action);
        }
        if (_pending.isEmpty && status == ExecutionStatus.waitingForConfirmation) {
          _state(out, '', ExecutionStatus.running);
        }
      case 'session.tool.success':
        _finish(out, _str(d['id']), text: _contentText(d['content']));
      case 'session.tool.failed':
        final error = _map(d['error']) ?? const {};
        _finish(out, _str(d['id']), text: _str(error['message']), error: error);
      case 'session.step.ended' || 'session.step.failed':
        _usage(out, _str(d['assistantMessageID']), d, _provider);
      case 'session.execution.started':
        _state(out, '', ExecutionStatus.running);
      case 'session.execution.succeeded':
        _end(out, ExecutionStatus.finished);
      case 'session.execution.failed':
        _end(out, ExecutionStatus.error, error: _map(d['error']), live: true);
      case 'session.execution.interrupted':
        _end(out, ExecutionStatus.idle);
    }
    return out;
  }

  /// The message list (`GET /api/session/{id}/message`, oldest first). With
  /// [resync] (the stream dropped and came back) the run's state is emitted
  /// only when it changed.
  List<HarnessEvent> history(List<Object?> messages, {bool resync = false}) {
    final out = <HarnessEvent>[];
    var last = ExecutionStatus.idle;
    Map<String, Object?>? failure;
    for (final m in messages.whereType<Map<String, Object?>>()) {
      // Imported history (`opencode_import.dart`) is the app's own record already.
      if (_map(_map(m['metadata'])?['everyai'])?['imported'] == true) continue;
      final id = _str(m['id']);
      switch (m['type']) {
        case 'user':
          _user(out, id, _str(m['text']));
          last = ExecutionStatus.running;
        case 'assistant':
          _lastMessage = id;
          _provider = _str(_map(m['model'])?['providerID']);
          final parts = (m['content'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>().toList();
          // A message still being written may still be adding to its last
          // text: that part comes from the stream's `*.ended` instead.
          final open = _map(m['time'])?['completed'] == null && parts.isNotEmpty ? parts.last : null;
          final ordinals = <String, int>{};
          for (final part in parts) {
            final type = _str(part['type']);
            final n = ordinals[type] = (ordinals[type] ?? -1) + 1;
            if (identical(part, open) && type != 'tool' && _map(part['time'])?['completed'] == null) continue;
            switch (type) {
              case 'text':
                _text(out, '$id/text/$n', _str(part['text']));
              case 'reasoning':
                _text(out, '$id/reasoning/$n', '', reasoning: _str(part['text']));
              case 'tool':
                _historyTool(out, part);
            }
          }
          _usage(out, id, m, _provider);
          last = ExecutionStatus.running;
        case 'idle':
          final outcome = m['outcome'];
          last = switch (outcome) {
            'succeeded' => ExecutionStatus.finished,
            'failed' => ExecutionStatus.error,
            _ => ExecutionStatus.idle,
          };
          failure = outcome == 'failed' ? _map(m['error']) ?? const {} : null;
          if (!resync) _end(out, last, error: failure, emitState: false);
      }
    }
    // A run still going may be waiting on a request; [requests] settles that.
    final same =
        last == status || (last == ExecutionStatus.running && status == ExecutionStatus.waitingForConfirmation);
    if (!resync || !same) {
      if (last == ExecutionStatus.running) {
        _state(out, '', last);
      } else {
        _end(out, last, error: failure);
      }
    }
    return out;
  }

  /// The run the history left going isn't running on this server (it was
  /// cut off when the app quit): it ends as interrupted.
  List<HarnessEvent> notRunning() {
    final out = <HarnessEvent>[];
    if (status == ExecutionStatus.running || status == ExecutionStatus.waitingForConfirmation) {
      _end(out, ExecutionStatus.idle);
    }
    return out;
  }

  /// The requests waiting now (`GET /api/session/{id}/permission`): those
  /// not shown yet are asked, and those answered meanwhile stop waiting.
  List<HarnessEvent> requests(List<Object?> requests) {
    final out = <HarnessEvent>[];
    final open = requests.whereType<Map<String, Object?>>().toList();
    final ids = {for (final r in open) r['id']};
    _pending.removeWhere((_, request) => !ids.contains(request));
    for (final r in open) {
      if (!_pending.containsValue(r['id'])) _ask(out, r);
    }
    if (_pending.isEmpty && status == ExecutionStatus.waitingForConfirmation) _state(out, '', ExecutionStatus.running);
    return out;
  }

  void _ask(List<HarnessEvent> out, Map<String, Object?> req) {
    final requestId = _str(req['id']);
    final source = _map(req['source']) ?? const {};
    final callId = source['type'] == 'tool' ? _str(source['id']) : '';
    final String actionId;
    final String toolName;
    final (String, Map<String, Object?>) kind;
    if (callId.isEmpty) {
      actionId = requestId;
      toolName = _str(req['action']);
      kind = ('OpenCodePermission', {'permission': toolName, 'resources': req['resources'] ?? const []});
    } else {
      final prev = _actionOf[callId];
      actionId = prev == null ? callId : '$callId#$requestId';
      toolName = _names[callId] ?? _str(req['action']);
      // The first answer let it through; this is the next thing it asks.
      if (prev != null) _result(out, prev, toolName, 'Allowed.');
      kind = _kindOf(toolName, _inputs[callId] ?? const {}, req);
      _actionOf[callId] = actionId;
    }
    if (_seen.contains(actionId)) return;
    _seen.add(actionId);
    out.add(actionEvent(id: actionId, toolName: toolName, kind: kind.$1, toolCallId: callId, args: kind.$2));
    _pending[actionId] = requestId;
    _state(out, '', ExecutionStatus.waitingForConfirmation);
  }

  void _historyTool(List<HarnessEvent> out, Map<String, Object?> part) {
    final callId = _str(part['id']);
    final state = _map(part['state']) ?? const {};
    _names[callId] = _str(part['name']);
    if (_map(state['input']) case final input?) _inputs[callId] = input;
    switch (state['status']) {
      case 'completed':
        _finish(out, callId, text: _contentText(state['content']));
      case 'error':
        final error = _map(state['error']) ?? const {};
        _finish(out, callId, text: _str(error['message']), error: error);
    }
  }

  void _finish(List<HarnessEvent> out, String callId, {required String text, Map<String, Object?>? error}) {
    final actionId = _actionOf[callId] ?? callId;
    final name = _names[callId] ?? '';
    if (!_seen.contains(actionId)) {
      _seen.add(actionId);
      final (kind, args) = _kindOf(name, _inputs[callId] ?? const {}, null);
      out.add(actionEvent(id: actionId, toolName: name, kind: kind, toolCallId: callId, args: args));
    }
    _actionOf[callId] = actionId;
    _pending.remove(actionId);
    if (error == null) return _result(out, actionId, name, text);
    if (error['type'] == 'permission.rejected' || _rejected.contains(actionId)) {
      final id = '$actionId/result';
      if (!_seen.add(id)) return;
      out.add(
        HarnessEvent.decode({
          'kind': 'UserRejectObservation',
          'id': id,
          'source': 'user',
          'action_id': actionId,
          'tool_name': name,
          'rejection_reason': text,
        }),
      );
      return;
    }
    _result(out, actionId, name, text.isEmpty ? 'The tool failed.' : text, isError: true);
  }

  void _result(List<HarnessEvent> out, String actionId, String name, String text, {bool isError = false}) {
    final id = '$actionId/result';
    if (_seen.add(id)) {
      out.add(resultEvent(id: id, actionId: actionId, toolName: name, text: text, isError: isError));
    }
  }

  void _usage(List<HarnessEvent> out, String id, Map<String, Object?> d, String provider) {
    final t = _map(d['tokens']);
    if (t == null || id.isEmpty) return;
    int n(Object? v) => (v as num?)?.toInt() ?? 0;
    final cache = _map(t['cache']) ?? const {};
    final input = n(t['input']) + n(cache['read']) + n(cache['write']);
    final output = n(t['output']) + n(t['reasoning']);
    if (input == 0 && output == 0) return;
    if (!_seen.add('$id/usage')) return;
    final cost = (d['cost'] as num?)?.toDouble() ?? 0;
    out.add(
      UsageReport.of(
        id: id,
        input: input,
        output: output,
        cached: n(cache['read']),
        contextTokens: input,
        // OpenCode says 0 for rates it doesn't know, plans included.
        costMicros: cost > 0 ? (cost * 1e6).round() : null,
        onPlan: _onPlan(provider),
      ),
    );
  }

  /// The run ended: whatever was still waiting can't be answered any more.
  ///
  /// A failure typed `provider.quota` / `provider.free-limit` (OpenCode 2.1.3
  /// `Session.StructuredError`; it never retries those) is a usage limit.
  /// `provider.rate-limit` was retried by OpenCode already: a plain failure.
  /// Only a [live] event can date the reset (`retryAfterMs` from now).
  void _end(
    List<HarnessEvent> out,
    ExecutionStatus to, {
    Map<String, Object?>? error,
    bool emitState = true,
    bool live = false,
  }) {
    _pending.clear();
    if (to == ExecutionStatus.error) {
      final id = '$_lastMessage/failed';
      if (_seen.add(id)) {
        final message = _str(error?['message']).isEmpty ? 'OpenCode stopped with an error.' : _str(error?['message']);
        final type = error?['type'];
        final after = error?['retryAfterMs'];
        out.add(
          type == 'provider.quota' || type == 'provider.free-limit'
              ? usageLimitEvent(
                  id,
                  message,
                  resetsAt: live && after is num ? _now().add(Duration(milliseconds: after.round())) : null,
                )
              : HarnessEvent.decode({'kind': 'ConversationErrorEvent', 'id': id, 'detail': message}),
        );
      }
    }
    if (emitState) _state(out, '', to);
  }

  void _state(List<HarnessEvent> out, String id, ExecutionStatus to) {
    status = to;
    out.add(stateEvent(id, to));
  }

  void _user(List<HarnessEvent> out, String id, String text) {
    if (id.isEmpty || !_seen.add(id)) return;
    out.add(
      HarnessEvent.decode({
        'kind': 'MessageEvent',
        'id': id,
        'source': 'user',
        'llm_message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': text},
          ],
        },
      }),
    );
  }

  void _text(List<HarnessEvent> out, String id, String text, {String reasoning = ''}) {
    if (text.trim().isEmpty && reasoning.trim().isEmpty) return;
    if (!_seen.add(id)) return;
    out.add(
      HarnessEvent.decode({
        'kind': 'MessageEvent',
        'id': id,
        'source': 'agent',
        'llm_message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': text},
          ],
          'reasoning_content': ?(reasoning.isEmpty ? null : reasoning),
        },
      }),
    );
  }

  StreamDelta _delta({String content = '', String reasoning = ''}) =>
      HarnessEvent.decode({'kind': 'StreamingDeltaEvent', 'content': content, 'reasoning_content': reasoning})
          as StreamDelta;

  String? _actionFor(String requestId) {
    for (final e in _pending.entries) {
      if (e.value == requestId) return e.key;
    }
    return null;
  }

  /// The app's action kind and fields for OpenCode's tool [name] (see
  /// `HarnessDriver`): the fields the permission rules read are filled, paths
  /// absolute. A read outside the project, a web fetch and tools the rules
  /// can't judge keep kinds of their own, so only the user answers them.
  (String, Map<String, Object?>) _kindOf(String name, Map<String, Object?> input, Map<String, Object?>? req) {
    final resources = [for (final r in req?['resources'] as List<Object?>? ?? const []) '$r'];
    if (req?['action'] == 'external_directory') {
      return ('OpenCodeExternalDirectory', {...input, 'path': resources.isEmpty ? '' : resources.first});
    }
    final path = _abs(_str(input['path'] ?? input['filePath'] ?? input['file_path']));
    // Without the input, every sub-command OpenCode lists, so none slips past the rules.
    final command = _str(input['command']).isNotEmpty ? _str(input['command']) : resources.join(' && ');
    return switch (name) {
      'shell' || 'bash' => ('TerminalAction', {...input, 'command': command}),
      'read' => ('ReadFileAction', {...input, 'path': path}),
      'write' => (
        'FileEditorAction',
        {...input, 'command': 'create', 'path': path, 'file_text': input['content'] ?? ''},
      ),
      'edit' => (
        'FileEditorAction',
        {
          ...input,
          'command': 'str_replace',
          'path': path,
          'old_str': input['oldString'] ?? input['old_string'] ?? '',
          'new_str': input['newString'] ?? input['new_string'] ?? '',
        },
      ),
      'patch' => ('ApplyPatchAction', {...input, 'paths': _patchPaths(resources, req)}),
      'glob' => ('GlobAction', {...input, 'path': path.isEmpty ? workingDir : path}),
      'grep' => ('GrepAction', {...input, 'path': path.isEmpty ? workingDir : path}),
      // It fetches from this machine (loopback and the local network too), not
      // through the backend's safe fetch, so only the user answers it.
      'webfetch' => ('OpenCodeWebFetch', input),
      'websearch' => ('WebSearchAction', input),
      'todowrite' => ('TaskTrackerAction', input),
      _ when name.startsWith('everyai_') => ('MCPToolAction', input),
      _ => ('OpenCodeAction', input),
    };
  }

  List<String> _patchPaths(List<String> resources, Map<String, Object?>? req) {
    final files = [
      for (final f
          in (_map(req?['metadata'])?['files'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>())
        _str(f['file']),
    ];
    return [
      for (final p in resources.isNotEmpty ? resources : files)
        if (p.isNotEmpty) _abs(p),
    ];
  }

  String _abs(String p) {
    if (p.isEmpty || p.startsWith('/')) return p;
    final rel = p.startsWith('./') ? p.substring(2) : p;
    return workingDir.endsWith('/') ? '$workingDir$rel' : '$workingDir/$rel';
  }

  static String _contentText(Object? content) => switch (content) {
    final String s => s,
    final List<Object?> parts => [
      for (final p in parts.whereType<Map<String, Object?>>())
        if (p['text'] case final String t) t,
    ].join('\n'),
    _ => '',
  };

  static Map<String, Object?>? _map(Object? v) => v is Map<String, Object?> ? v : null;
  static String _str(Object? v) => v is String ? v : '';
}
