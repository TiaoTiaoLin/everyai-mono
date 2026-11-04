// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

/// One line in, one line out: a process's stdio, or a recorded transcript
/// in tests (`test/support/replay_transport.dart`).
abstract interface class LineChannel {
  /// Lines from the other side; done when it goes away.
  Stream<String> get lines;
  void send(String line);

  /// What the other side said last on stderr, for errors ('' when unknown).
  String get lastError;
  Future<void> close();
}

/// An error reply, or what a handler throws to send one.
final class JsonRpcError implements Exception {
  const JsonRpcError(this.code, this.message, {this.data});

  /// The peer went away before it answered.
  const JsonRpcError.closed(String message) : this(closedCode, message);

  static const closedCode = -32000;
  static const methodNotFound = -32601;

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => message;
}

/// A JSON-RPC 2.0 peer over newline-delimited JSON (MCP stdio, ACP, the
/// Codex app server): requests with ids, notifications both ways, and
/// requests from the other side, answered by [onRequest] (without one,
/// "method not found"). Lines that aren't JSON objects (logs on stdout) are
/// skipped. [writeVersion] off leaves out `"jsonrpc": "2.0"` for peers that
/// don't send it.
final class JsonRpcPeer {
  JsonRpcPeer(this.channel, {this.onRequest, this.onNotify, this.writeVersion = true}) {
    _sub = channel.lines.listen(_line, onDone: _closed, onError: (Object _) => _closed());
  }

  final LineChannel channel;
  final Future<Object?> Function(String method, Object? params)? onRequest;
  final void Function(String method, Object? params)? onNotify;
  final bool writeVersion;

  late final StreamSubscription<String> _sub;
  final _pending = <int, Completer<Object?>>{};
  final _done = Completer<void>();
  var _ids = 0;

  /// Completes when the other side has gone away.
  Future<void> get done => _done.future;
  bool get isClosed => _done.isCompleted;

  /// Sends [method] and waits for its result; a reply with an error, or the
  /// peer leaving, throws [JsonRpcError]. Without [timeout] it waits as long
  /// as the peer runs.
  Future<Object?> request(String method, [Object? params, Duration? timeout]) async {
    if (isClosed) throw const JsonRpcError.closed('Not running.');
    final id = ++_ids;
    final reply = _pending[id] = Completer<Object?>();
    _write({'id': id, 'method': method, 'params': ?params});
    if (timeout == null) return reply.future;
    try {
      return await reply.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      rethrow;
    }
  }

  void notify(String method, [Object? params]) {
    if (!isClosed) _write({'method': method, 'params': ?params});
  }

  Future<void> close() async {
    await channel.close();
    _closed();
  }

  void _write(Map<String, Object?> msg) => channel.send(jsonEncode({if (writeVersion) 'jsonrpc': '2.0', ...msg}));

  void _line(String line) {
    if (!line.trimLeft().startsWith('{')) return;
    final Object? msg;
    try {
      msg = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (msg is! Map<String, Object?>) return;
    final id = msg['id'];
    final method = msg['method'];
    if (method is String) {
      if (id == null) {
        onNotify?.call(method, msg['params']);
      } else {
        unawaited(_answer(id, method, msg['params']));
      }
      return;
    }
    final key = switch (id) {
      final int i => i,
      final String s => int.tryParse(s),
      _ => null,
    };
    final reply = key == null ? null : _pending.remove(key);
    if (reply == null) return;
    if (msg['error'] case final Map<String, Object?> e) {
      reply.completeError(
        JsonRpcError((e['code'] as num?)?.toInt() ?? 0, e['message'] as String? ?? 'error', data: e['data']),
      );
    } else {
      reply.complete(msg['result']);
    }
  }

  Future<void> _answer(Object id, String method, Object? params) async {
    final handler = onRequest;
    Map<String, Object?> reply;
    if (handler == null) {
      reply = {
        'id': id,
        'error': _error(const JsonRpcError(JsonRpcError.methodNotFound, 'Not supported by this client')),
      };
    } else {
      try {
        reply = {'id': id, 'result': await handler(method, params)};
      } on JsonRpcError catch (e) {
        reply = {'id': id, 'error': _error(e)};
      } on Object catch (e) {
        reply = {'id': id, 'error': _error(JsonRpcError(-32603, '$e'))};
      }
    }
    if (!isClosed) _write(reply);
  }

  static Map<String, Object?> _error(JsonRpcError e) => {'code': e.code, 'message': e.message, 'data': ?e.data};

  void _closed() {
    if (_done.isCompleted) return;
    _done.complete();
    unawaited(_sub.cancel());
    final why = channel.lastError.trim();
    final error = JsonRpcError.closed(why.isEmpty ? 'Stopped.' : 'Stopped: ${why.split('\n').last}');
    for (final c in _pending.values) {
      c.completeError(error);
    }
    _pending.clear();
  }
}
