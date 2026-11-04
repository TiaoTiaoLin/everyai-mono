// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../domain/agent_mode.dart' show askUserQuestionTool, clientToolSpecs, presentPlanTool;
import '../domain/phases.dart' show bugCheckSpec, bugCheckTool;
import '../harness/everyai/project_notes_io.dart' show memoryToolSpec;
import 'host.dart';
import 'host_max_tools.dart' show maxForkSpecs;

// MCP over Streamable HTTP, tools only, stateless (no Mcp-Session-Id), on
// one endpoint that speaks both eras the spec defines:
// - legacy (2025-03-26 … 2025-11-25): initialize handshake, the
//   MCP-Protocol-Version header,
//   https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
// - modern (2026-07-28): the version in each request's `_meta`, the
//   Mcp-Method / Mcp-Name headers, server/discover,
//   https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http
// A tools/call is answered as SSE over the detached socket: dart:io only
// tells us a client left (its cancellation) once the socket is ours.

const _modern = '2026-07-28';
const _legacy = ['2025-11-25', '2025-06-18', '2025-03-26'];
const _metaVersion = 'io.modelcontextprotocol/protocolVersion';
const _maxBody = 4 << 20;

/// `ask_user_question` and `present_plan` with the held wording (the answer
/// is the call's result), then memory, saved plans, the Max fork tools and
/// bug_check.
final List<Map<String, Object?>> hostToolSpecs = List.unmodifiable([
  for (final name in [askUserQuestionTool, presentPlanTool])
    _mcpTool(clientToolSpecs(held: true).firstWhere((s) => s['name'] == name)),
  _mcpTool(memoryToolSpec),
  savedPlansSpec,
  for (final s in maxForkSpecs) _mcpTool(s),
  // It runs the agent's repro command, so a client must not auto-allow it as harmless.
  {
    ..._mcpTool(bugCheckSpec),
    'annotations': {'readOnlyHint': false, 'destructiveHint': true},
  },
]);

/// [hostToolSpecs] without bug_check, for sessions that aren't fixing a bug.
final List<Map<String, Object?>> _plainSpecs = List.unmodifiable(hostToolSpecs.where((t) => t['name'] != bugCheckTool));

/// An OpenAI-style spec (flat or `{function: …}`) in MCP's shape.
Map<String, Object?> _mcpTool(Map<String, Object?> spec) {
  final f = (spec['function'] as Map<String, Object?>?) ?? spec;
  return {
    'name': f['name'],
    'description': f['description'],
    'inputSchema': f['parameters'],
    if (f['annotations'] case final Object a) 'annotations': a,
  };
}

HostServer createHostServer({
  required Duration idleLimit,
  required Duration heldLimit,
  required Duration keepAlive,
  DateTime Function()? now,
  HostTimer? timer,
  @visibleForTesting Future<HttpServer> Function()? bind,
}) => _HostServer(
  idleLimit,
  heldLimit,
  keepAlive,
  now ?? DateTime.now,
  timer ?? Timer.new,
  bind ?? () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
);

/// A live token. Stage 5's grants for outside agents would be a second kind
/// of this record, with their own tool list.
final class _Grant {
  _Grant(this.token, this.sessionId, this.tools, this.specs, this.lastUsed);
  final String token;
  final String sessionId;
  final HostTools tools;

  /// What tools/list shows and tools/call accepts, fixed at mint.
  final List<Map<String, Object?>> specs;
  DateTime lastUsed;
  final pending = <_Pending>{};
}

final class _Pending {
  _Pending(this.grant, this.rpcId, this.call, this.ended);
  final _Grant grant;
  final Object? rpcId;
  final HostCall call;
  final Completer<HostEnd> ended;
  final result = Completer<HostResult>();

  /// The first answer wins; [end] says why the call was given up.
  void finish(HostResult r, [HostEnd? end]) {
    if (result.isCompleted) return;
    if (end != null) ended.complete(end);
    result.complete(r);
  }
}

final class _HostServer implements HostServer {
  _HostServer(this.idleLimit, this.heldLimit, this.keepAlive, this.now, this.timer, this.bind);

  final Duration idleLimit;
  final Duration heldLimit;
  final Duration keepAlive;
  final DateTime Function() now;
  final HostTimer timer;
  final Future<HttpServer> Function() bind;

  final _grants = <_Grant>[];
  final _random = Random.secure();
  HttpServer? _server;
  Future<void> _lifecycle = Future.value();
  Timer? _expiry;
  var _calls = 0;

  static const _ended = (text: 'Error: the EveryAI session ended.', isError: true);

  /// Binds and closes in order, so a mint racing the last revoke is safe. A
  /// failed step fails only its caller, never the steps after it.
  Future<void> _serial(Future<void> Function() step) {
    final run = _lifecycle.then((_) => step());
    _lifecycle = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  @override
  Future<HostToken> mint(String sessionId, HostTools tools, {bool bugFix = false}) async {
    _sweep();
    final token = 'eai_host_${base64Url.encode(List.generate(32, (_) => _random.nextInt(256))).replaceAll('=', '')}';
    final grant = _Grant(token, sessionId, tools, bugFix ? hostToolSpecs : _plainSpecs, now());
    _grants.add(grant);
    try {
      await _serial(() async {
        if (_server != null || !_grants.contains(grant)) return;
        final server = _server = await bind();
        server.listen((req) => unawaited(_handle(server.port, req)));
      });
    } on Object {
      _grants.remove(grant);
      rethrow;
    }
    final port = _server?.port;
    if (port == null) throw StateError('The token was revoked while the server started.');
    _used(grant);
    return (url: Uri.parse('http://127.0.0.1:$port/mcp'), token: token);
  }

  @override
  bool touch(String token) {
    final grant = _find(token);
    if (grant != null) _used(grant);
    return grant != null;
  }

  @override
  Future<void> revoke(String token) => _drop(_grants.where((g) => g.token == token).toList());

  @override
  Future<void> revokeSession(String sessionId) => _drop(_grants.where((g) => g.sessionId == sessionId).toList());

  @override
  Future<void> stop() => _drop([..._grants]);

  Future<void> _drop(List<_Grant> gone) {
    for (final g in gone) {
      _grants.remove(g);
      for (final p in [...g.pending]) {
        p.finish(_ended, HostEnd.sessionClosed);
      }
    }
    return _closeIfIdle();
  }

  Future<void> _closeIfIdle() => _serial(() async {
    if (_grants.isNotEmpty) return;
    _expiry?.cancel();
    final server = _server;
    _server = null;
    await server?.close(force: true);
  });

  /// Drops tokens idle for [idleLimit]; a pending call keeps its token.
  void _sweep() {
    final at = now();
    _grants.removeWhere((g) => g.pending.isEmpty && at.difference(g.lastUsed) >= idleLimit);
  }

  void _used(_Grant grant) {
    grant.lastUsed = now();
    _scheduleExpiry();
  }

  /// One timer for the next token to expire, so the server closes with the
  /// last one even when no request comes.
  void _scheduleExpiry() {
    _expiry?.cancel();
    final idle = _grants.where((g) => g.pending.isEmpty);
    if (idle.isEmpty) return;
    final next = idle.map((g) => g.lastUsed).reduce((a, b) => a.isBefore(b) ? a : b).add(idleLimit);
    final wait = next.difference(now());
    _expiry = timer(wait.isNegative ? Duration.zero : wait, () {
      _sweep();
      if (_grants.isEmpty) {
        unawaited(_closeIfIdle());
      } else {
        _scheduleExpiry();
      }
    });
  }

  _Grant? _find(String token) {
    _sweep();
    _Grant? hit;
    for (final g in _grants) {
      if (_sameSecret(g.token, token)) hit = g;
    }
    return hit;
  }

  Future<void> _handle(int port, HttpRequest req) async {
    try {
      await _serve(port, req);
    } on Object {
      // A client that left mid-answer.
      try {
        await req.response.close();
      } on Object {
        // Already closed.
      }
    }
    if (_grants.isEmpty) unawaited(_closeIfIdle());
  }

  Future<void> _serve(int port, HttpRequest req) async {
    if (req.uri.path != '/mcp') return _reply(req, 404, _error(null, -32601, 'Not found'));
    // DNS rebinding: a web page can reach a loopback port, but its Host or Origin names its own site.
    final local = ['127.0.0.1:$port', 'localhost:$port', '[::1]:$port'];
    if (!local.contains(req.headers.value('host')?.toLowerCase())) {
      return _reply(req, 403, _error(null, -32600, 'Forbidden host'));
    }
    final origin = req.headers.value('origin')?.toLowerCase();
    if (origin != null && !local.any((h) => origin == 'http://$h')) {
      return _reply(req, 403, _error(null, -32600, 'Forbidden origin'));
    }
    final auth = req.headers.value('authorization') ?? '';
    final grant = auth.startsWith('Bearer ') ? _find(auth.substring(7).trim()) : null;
    if (grant == null) return _unauthorized(req);
    _used(grant);
    if (req.method != 'POST') {
      req.response.headers.set('allow', 'POST');
      return _reply(req, 405, _error(null, -32600, 'Only POST is served here'));
    }
    if (req.contentLength > _maxBody) return _reply(req, 413, _error(null, -32600, 'Body too large'));
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req) {
      bytes.add(chunk);
      if (bytes.length > _maxBody) return _reply(req, 413, _error(null, -32600, 'Body too large'));
    }
    // Revoked while the body was read: run nothing for it.
    if (!_grants.contains(grant)) return _unauthorized(req);
    final Object? msg;
    try {
      msg = jsonDecode(utf8.decode(bytes.takeBytes()));
    } on FormatException {
      return _reply(req, 400, _error(null, -32700, 'Parse error'));
    }
    if (msg is! Map<String, Object?> || msg['method'] is! String && !msg.containsKey('id')) {
      return _reply(req, 400, _error(null, -32600, 'Send one JSON-RPC message per request'));
    }
    final id = msg['id'];
    final method = msg['method'];
    final params = switch (msg['params']) {
      null => const <String, Object?>{},
      final Map<String, Object?> p => p,
      _ => null,
    };
    if (method is! String? || params == null) {
      return _reply(req, 400, _error(id, -32600, 'method must be a string and params an object'));
    }
    final header = req.headers.value('mcp-protocol-version');

    final modern = switch (params['_meta']) {
      {_metaVersion: final Object v} => '$v',
      _ => null,
    };
    if (modern != null) {
      if (modern != _modern) {
        return _reply(
          req,
          400,
          _error(id, -32022, 'Unsupported protocol version', {
            'supported': [_modern, ..._legacy],
            'requested': modern,
          }),
        );
      }
      final name = _decodeName(req.headers.value('mcp-name'));
      if (header != modern ||
          req.headers.value('mcp-method') != method ||
          (method == 'tools/call' && name != params['name'])) {
        return _reply(req, 400, _error(id, -32020, 'Headers do not match the body'));
      }
    } else if (header != null && !_legacy.contains(header)) {
      return _reply(req, 400, _error(id, -32600, 'Unsupported MCP-Protocol-Version: $header'));
    }

    if (method == null || id == null) {
      // A notification, or a response to a request we never send.
      if (method == 'notifications/cancelled') {
        final target = params['requestId'];
        for (final p in [...grant.pending.where((p) => p.rpcId == target)]) {
          p.finish((text: 'Error: cancelled by the client.', isError: true), HostEnd.cancelled);
        }
      }
      req.response.statusCode = 202;
      return req.response.close();
    }

    Map<String, Object?> done(Map<String, Object?> result) => {
      'jsonrpc': '2.0',
      'id': id,
      'result': {...result, if (modern != null) 'resultType': 'complete'},
    };
    const cached = {'ttlMs': 3600000, 'cacheScope': 'private'};
    const capabilities = {
      'tools': {'listChanged': false},
    };
    const serverInfo = {'name': 'EveryAI', 'version': '1.0'};
    switch (method) {
      case 'initialize':
        final asked = params['protocolVersion'];
        return _reply(
          req,
          200,
          done({
            'protocolVersion': _legacy.contains(asked) ? asked : _legacy.first,
            'capabilities': capabilities,
            'serverInfo': serverInfo,
          }),
        );
      case 'server/discover':
        return _reply(
          req,
          200,
          done({
            'supportedVersions': [_modern, ..._legacy],
            'capabilities': capabilities,
            '_meta': {'io.modelcontextprotocol/serverInfo': serverInfo},
            ...cached,
          }),
        );
      case 'ping':
        return _reply(req, 200, done({}));
      case 'tools/list':
        return _reply(req, 200, done({'tools': grant.specs, if (modern != null) ...cached}));
      case 'tools/call':
        final name = params['name'];
        if (name is! String || !grant.specs.any((t) => t['name'] == name)) {
          return _reply(req, 200, _error(id, -32602, 'Unknown tool: $name'));
        }
        final args = switch (params['arguments']) {
          null => const <String, Object?>{},
          final Map<String, Object?> a => a,
          _ => null,
        };
        if (args == null) return _reply(req, 200, _error(id, -32602, 'arguments must be an object'));
        final progress = switch (params['_meta']) {
          {'progressToken': final Object t} => t,
          _ => null,
        };
        return _call(req, grant, id, name, args, progress, (r) => done(_toolResult(r)));
      default:
        return _reply(req, modern != null ? 404 : 200, _error(id, -32601, 'Method not found: $method'));
    }
  }

  /// Answers a tools/call as an SSE stream on the detached socket, with a
  /// keep-alive while [HostTools] works, and gives up on timeout (held
  /// tools), session end, cancellation or the client leaving.
  Future<void> _call(
    HttpRequest req,
    _Grant grant,
    Object id,
    String name,
    Map<String, Object?> args,
    Object? progress,
    Map<String, Object?> Function(HostResult) reply,
  ) async {
    final ended = Completer<HostEnd>();
    final call = HostCall(id: 'h${++_calls}', sessionId: grant.sessionId, name: name, args: args, ended: ended.future);
    final pending = _Pending(grant, id, call, ended);
    req.response
      ..statusCode = 200
      ..persistentConnection = false
      ..headers.chunkedTransferEncoding = false
      ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..headers.set('cache-control', 'no-cache')
      ..headers.set('x-accel-buffering', 'no');
    final socket = await req.response.detachSocket();
    var open = true;
    void send(String event) {
      if (!open) return;
      try {
        socket.write(event);
      } on Object {
        open = false;
      }
    }

    socket.listen(
      (_) {},
      onDone: () {
        open = false;
        pending.finish(_ended, HostEnd.clientGone);
      },
      onError: (Object _) {
        open = false;
        pending.finish(_ended, HostEnd.clientGone);
      },
      cancelOnError: true,
    );
    // Revoked while the socket was detached: answer, but run nothing.
    if (!_grants.contains(grant)) {
      pending.finish(_ended, HostEnd.sessionClosed);
      send('event: message\ndata: ${jsonEncode(reply(_ended))}\n\n');
      try {
        await socket.flush();
      } on Object {
        // Gone.
      }
      socket.destroy();
      return;
    }
    grant.pending.add(pending);
    _scheduleExpiry();
    var ticks = 0;
    Timer? beat;
    void schedule() => beat = timer(keepAlive, () {
      ticks++;
      send(
        progress == null
            ? ':\n\n'
            : 'event: message\ndata: ${jsonEncode({
                'jsonrpc': '2.0',
                'method': 'notifications/progress',
                'params': {'progressToken': progress, 'progress': ticks},
              })}\n\n',
      );
      schedule();
    });
    schedule();
    final limit = heldHostTools.contains(name)
        ? timer(heldLimit, () {
            pending.finish((text: _timeoutText(name), isError: true), HostEnd.timedOut);
          })
        : null;
    unawaited(
      Future.sync(() => grant.tools.call(call))
          .then(pending.finish, onError: (Object e) => pending.finish((text: 'Error: $e', isError: true))),
    );
    final result = await pending.result.future;
    beat?.cancel();
    limit?.cancel();
    grant.pending.remove(pending);
    if (_grants.contains(grant)) _used(grant);
    send('event: message\ndata: ${jsonEncode(reply(result))}\n\n');
    try {
      await socket.flush();
    } on Object {
      // Gone.
    }
    socket.destroy();
  }

  /// What the agent hears when the user didn't answer in time. A plan that
  /// timed out is not approved, so nothing may be built on it.
  String _timeoutText(String name) {
    final head = 'Error (timeout): the user did not answer this $name call within ${heldLimit.inSeconds} s.';
    return name == presentPlanTool
        ? '$head The plan is NOT approved: do not start building it. End your turn and wait for the user; present '
              'the plan again when they reply.'
        : '$head Go on only where one choice is clearly safe, and say which answer you assumed; otherwise end your '
              'turn and ask again when the user replies.';
  }
}

Map<String, Object?> _toolResult(HostResult r) => {
  'content': [
    {'type': 'text', 'text': r.text},
  ],
  'isError': r.isError,
};

Map<String, Object?> _error(Object? id, int code, String message, [Object? data]) => {
  'jsonrpc': '2.0',
  'id': id,
  'error': {'code': code, 'message': message, 'data': ?data},
};

Future<void> _unauthorized(HttpRequest req) {
  req.response.headers.set('www-authenticate', 'Bearer error="invalid_token"');
  return _reply(req, 401, _error(null, -32600, 'Missing, expired or revoked token'));
}

Future<void> _reply(HttpRequest req, int status, Map<String, Object?> body) {
  req.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  return req.response.close();
}

/// Mcp-Name, which may come as `=?base64?<utf-8 in base64>?=`.
String? _decodeName(String? value) {
  if (value == null || !value.startsWith('=?base64?') || !value.endsWith('?=')) return value;
  try {
    return utf8.decode(base64.decode(value.substring(9, value.length - 2)));
  } on FormatException {
    return value;
  }
}

/// Compares in time that depends only on the lengths, not on where the
/// strings first differ.
bool _sameSecret(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length; i++) {
    diff |= x[i] ^ (i < y.length ? y[i] : 0);
  }
  return diff == 0;
}
