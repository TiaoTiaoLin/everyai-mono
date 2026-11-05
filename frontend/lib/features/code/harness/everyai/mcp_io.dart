// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../../core/security/untrusted.dart';
import '../../domain/mcp_tool_check.dart';
import 'shell_io.dart';
import 'tools_io.dart';

/// One MCP server a session talks to: started over stdio (a local command)
/// or reached over streamable HTTP, as `mcp_config` describes it (see
/// `McpServer.toAgentConfig`). JSON-RPC 2.0, tools only.
abstract class McpConnection {
  McpConnection(this.name);

  final String name;
  var _ids = 0;

  /// The server's tools, as `tools/list` gave them.
  List<Map<String, Object?>> tools = const [];

  static Future<McpConnection> open(String name, Map<String, Object?> config, {http.Client? client}) async {
    final McpConnection c;
    if (config['url'] case final String url when url.isNotEmpty) {
      if (config['transport'] == 'sse') {
        throw McpError('$name uses the legacy SSE transport, which the EveryAI harness does not support yet.');
      }
      c = _HttpMcp(name, Uri.parse(url), {
        for (final e in (config['headers'] as Map<String, Object?>? ?? const {}).entries) e.key: '${e.value}',
      }, client ?? http.Client());
    } else {
      final command = config['command'] as String? ?? '';
      if (command.isEmpty) throw McpError('$name has no command.');
      c = await _StdioMcp.start(
        name,
        command,
        [for (final a in config['args'] as List<Object?>? ?? const []) '$a'],
        {for (final e in (config['env'] as Map<String, Object?>? ?? const {}).entries) e.key: '${e.value}'},
      );
    }
    try {
      await c._request('initialize', {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'EveryAI', 'version': '1.0'},
      }, timeout: const Duration(seconds: 90));
      await c._notify('notifications/initialized');
      final tools = <Map<String, Object?>>[];
      String? cursor;
      do {
        final page = await c._request('tools/list', {'cursor': ?cursor});
        tools.addAll([...(page['tools'] as List<Object?>? ?? const []).cast<Map<String, Object?>>()]);
        cursor = page['nextCursor'] as String?;
      } while (cursor != null);
      c.tools = tools;
      return c;
    } on Object {
      await c.close();
      rethrow;
    }
  }

  /// Calls [tool]; text parts become the result, image parts pictures.
  /// With [wrap] the server's text (an error's too) is marked as untrusted
  /// data from `mcp:<server>/<tool>`.
  Future<ToolOutput> call(String tool, Map<String, Object?> args, {Future<void>? cancel, bool wrap = false}) async {
    String data(String text) => wrap ? untrusted(text, source: 'mcp:$name/$tool') : text;
    final Map<String, Object?> result;
    try {
      result = await _request('tools/call', {'name': tool, 'arguments': args}, timeout: const Duration(minutes: 5));
    } on McpError catch (e) {
      return ToolOutput('Error from $name: ${data(e.message)}', isError: true);
    }
    final text = StringBuffer();
    final images = <ToolImage>[];
    for (final part in result['content'] as List<Object?>? ?? const []) {
      switch (part) {
        case {'type': 'text', 'text': final String t}:
          if (text.isNotEmpty) text.writeln();
          text.write(t);
        case {'type': 'image', 'data': final String data}:
          final mime = (part['mimeType'] as String?) ?? 'image/png';
          images.add((label: '$name $tool', dataUrl: 'data:$mime;base64,$data'));
        case {'type': 'resource', 'resource': {'text': final String t}}:
          if (text.isNotEmpty) text.writeln();
          text.write(t);
        case {'type': 'resource_link', 'uri': final String uri}:
          text.writeln('Resource: $uri');
      }
    }
    if (result['structuredContent'] case final Object structured when text.isEmpty) {
      text.write(jsonEncode(structured));
    }
    return ToolOutput(
      text.isEmpty
          ? (images.isEmpty ? '(no output)' : '${images.length} image(s) attached below.')
          : data(text.toString()),
      isError: result['isError'] == true,
      images: images,
    );
  }

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 60),
  });

  Future<void> _notify(String method);

  Future<void> close();
}

final class McpError implements Exception {
  McpError(this.message);
  final String message;

  @override
  String toString() => message;
}

Map<String, Object?> _resultOf(Map<String, Object?> reply) {
  if (reply['error'] case final Map<String, Object?> e) {
    throw McpError('${e['message'] ?? 'error'}${e['code'] == null ? '' : ' (${e['code']})'}');
  }
  return (reply['result'] as Map<String, Object?>?) ?? const {};
}

/// A local server: newline-delimited JSON-RPC on stdin/stdout, started with
/// the user's login-shell environment so `npx` and friends resolve.
final class _StdioMcp extends McpConnection {
  _StdioMcp._(super.name, this._process) {
    _process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_line, onDone: _closed);
    // Drained so a chatty server can't block on a full pipe; the tail helps errors.
    _process.stderr.transform(utf8.decoder).listen((s) {
      _stderr.write(s);
      if (_stderr.length > 4000) {
        final keep = _stderr.toString().substring(_stderr.length - 2000);
        _stderr
          ..clear()
          ..write(keep);
      }
    });
  }

  final Process _process;
  final _pending = <int, Completer<Map<String, Object?>>>{};
  final _stderr = StringBuffer();
  var _done = false;

  static Future<_StdioMcp> start(String name, String command, List<String> args, Map<String, String> env) async {
    final shellEnv = await ShellEnv.load();
    final process = await Process.start(
      command,
      args,
      environment: {...shellEnv.env, ...env},
      // Resolves the command on the login shell's PATH.
      runInShell: true,
    );
    return _StdioMcp._(name, process);
  }

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
    if (id is int && (msg.containsKey('result') || msg.containsKey('error'))) {
      _pending.remove(id)?.complete(msg);
    } else if (id != null && msg['method'] is String) {
      // A request from the server (roots, sampling): not offered, so refused.
      _write({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32601, 'message': 'Not supported by this client'},
      });
    }
  }

  void _closed() {
    _done = true;
    final why = _stderr.toString().trim();
    for (final c in _pending.values) {
      c.completeError(McpError('$name stopped${why.isEmpty ? '' : ': ${why.split('\n').last}'}'));
    }
    _pending.clear();
  }

  void _write(Map<String, Object?> msg) => _process.stdin.writeln(jsonEncode(msg));

  @override
  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_done) throw McpError('$name is not running.');
    final id = ++_ids;
    final reply = _pending[id] = Completer();
    _write({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    try {
      return _resultOf(await reply.future.timeout(timeout));
    } on TimeoutException {
      _pending.remove(id);
      throw McpError('$name did not answer $method within ${timeout.inSeconds} s.');
    }
  }

  @override
  Future<void> _notify(String method) async => _write({'jsonrpc': '2.0', 'method': method});

  @override
  Future<void> close() async {
    if (_done) return;
    _done = true;
    await killTree(_process.pid);
  }
}

/// A remote server over streamable HTTP: each message is a POST; the answer
/// is JSON or an SSE stream that carries it.
final class _HttpMcp extends McpConnection {
  _HttpMcp(super.name, this._url, this._headers, this._http);

  final Uri _url;
  final Map<String, String> _headers;
  final http.Client _http;
  String? _session;

  Future<http.StreamedResponse> _post(Map<String, Object?> msg) {
    final req = http.Request('POST', _url)
      ..headers.addAll({
        ..._headers,
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'MCP-Protocol-Version': '2025-06-18',
        'Mcp-Session-Id': ?_session,
      })
      ..body = jsonEncode(msg);
    return _http.send(req);
  }

  @override
  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final id = ++_ids;
    Future<Map<String, Object?>> go() async {
      final res = await _post({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
      _session = res.headers['mcp-session-id'] ?? _session;
      if (res.statusCode >= 300) {
        final body = await res.stream.bytesToString();
        throw McpError(
          'HTTP ${res.statusCode}${body.isEmpty ? '' : ': ${body.length > 200 ? body.substring(0, 200) : body}'}',
        );
      }
      final type = res.headers['content-type'] ?? '';
      if (type.contains('text/event-stream')) {
        await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
          if (!line.startsWith('data:')) continue;
          final Object? msg;
          try {
            msg = jsonDecode(line.substring(5).trim());
          } on FormatException {
            continue;
          }
          if (msg is Map<String, Object?> && msg['id'] == id) return _resultOf(msg);
        }
        throw McpError('$name closed the stream without answering $method.');
      }
      return _resultOf(jsonDecode(await res.stream.bytesToString()) as Map<String, Object?>);
    }

    try {
      return await go().timeout(timeout);
    } on TimeoutException {
      throw McpError('$name did not answer $method within ${timeout.inSeconds} s.');
    } on McpError {
      rethrow;
    } on Object catch (e) {
      throw McpError("$name isn't reachable: $e");
    }
  }

  @override
  Future<void> _notify(String method) async {
    try {
      final res = await _post({'jsonrpc': '2.0', 'method': method});
      await res.stream.drain<void>();
    } on Object {
      // A notification nobody heard is not an error.
    }
  }

  @override
  Future<void> close() async {
    if (_session == null) return;
    try {
      await _http.delete(_url, headers: {..._headers, 'Mcp-Session-Id': _session!});
    } on Object {
      // Gone already.
    }
  }
}

/// A session's MCP servers: their tools by name, and the servers that
/// couldn't start (with why), for the system prompt.
///
/// A server's tools reach the model only once vetted ([vetMcpTools]): those
/// pinned in its config entry (`pinned`, from Settings), or the clean ones at
/// its first session. The rest are left out ([leftOut]) and reported
/// ([report]) for the user to review in Settings, never asked about mid-run.
/// What an untrusted server returns is wrapped as untrusted data.
final class McpTools {
  McpTools._(this.connections, this.failures, [this._trusted = const {}]);

  final List<McpConnection> connections;
  final Map<String, String> failures;

  /// Servers that are the app's own (the `everyai` host): neither vetted nor wrapped.
  final Set<String> _trusted;

  /// Each vetted server's tools left out of this session, by the server's own names.
  final leftOut = <String, List<String>>{};

  /// What vetting found per server, for the app to store.
  final report = <String, McpToolsReport>{};

  /// The tool name the model sees, to the server and the server's own name.
  final _byName = <String, (McpConnection, String)>{};

  /// Tools of a server in [prefixed] are always named `<server>__<tool>`.
  static Future<McpTools> start(
    Map<String, Object?> config, {
    Set<String> reserved = const {},
    Set<String> prefixed = const {},
    Set<String> trusted = const {},
    http.Client? client,
  }) async {
    final failures = <String, String>{};
    final opened = await Future.wait([
      for (final e in config.entries)
        McpConnection.open(
          e.key,
          (e.value as Map?)?.cast<String, Object?>() ?? const {},
          client: client,
        ).then<McpConnection?>(
          (c) => c,
          onError: (Object err) {
            failures[e.key] = '$err';
            return null;
          },
        ),
    ]);
    final tools = McpTools._([...opened.nonNulls], failures, trusted);
    final namesOf = {
      for (final c in tools.connections)
        c: {
          for (final t in c.tools)
            if (t['name'] case final String n) n,
        },
    };
    for (final c in tools.connections) {
      if (trusted.contains(c.name)) continue;
      final pinned = ((config[c.name] as Map?)?['pinned'] as Map?)?.map((k, v) => MapEntry('$k', '$v'));
      final vetted = vetMcpTools(
        c.tools,
        pinned: pinned,
        otherTools: {
          for (final MapEntry(key: o, value: names) in namesOf.entries)
            if (o != c) ...names,
        },
        builtIns: reserved,
      );
      c.tools = vetted.kept;
      tools.report[c.name] = vetted.report;
      if (vetted.report.pending.isNotEmpty) tools.leftOut[c.name] = [for (final p in vetted.report.pending) p.name];
    }
    final taken = {...reserved};
    for (final c in tools.connections) {
      for (final t in c.tools) {
        final own = t['name'] as String? ?? '';
        if (own.isEmpty) continue;
        // Keeps the server's names (permission rules match them) unless two clash.
        var name = taken.contains(own) || prefixed.contains(c.name) ? '${c.name}__$own' : own;
        name = name.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
        if (name.length > 64) name = name.substring(0, 64);
        taken.add(name);
        tools._byName[name] = (c, own);
      }
    }
    return tools;
  }

  static final empty = McpTools._(const [], const {});

  bool has(String name) => _byName.containsKey(name);

  Iterable<String> get names => _byName.keys;

  /// The server a tool [name] comes from, or null when it isn't one of these.
  String? serverOf(String name) => _byName[name]?.$1.name;

  /// Function specs for the model, in a stable order (the prompt cache).
  List<Map<String, Object?>> get specs {
    final names = _byName.keys.toList()..sort();
    return [
      for (final name in names)
        () {
          final (c, own) = _byName[name]!;
          final t = c.tools.firstWhere((t) => t['name'] == own);
          final desc = (t['description'] as String? ?? '').trim();
          return {
            'type': 'function',
            'function': {
              'name': name,
              'description': '${desc.isEmpty ? own : desc} (MCP server ${c.name})',
              'parameters': t['inputSchema'] ?? {'type': 'object', 'properties': <String, Object?>{}},
            },
          };
        }(),
    ];
  }

  Future<ToolOutput> call(String name, Map<String, Object?> args) async {
    final target = _byName[name];
    if (target == null) return ToolOutput('Error: no MCP tool named $name.', isError: true);
    return target.$1.call(target.$2, args, wrap: !_trusted.contains(target.$1.name));
  }

  Future<void> close() async {
    await Future.wait([for (final c in connections) c.close()]);
  }
}
