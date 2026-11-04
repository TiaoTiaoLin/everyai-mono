// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../harness/harness.dart';
import '../briefing/recipes.dart';
import '../driver_process.dart';

/// A private `opencode serve` for one session: its [base] URL on loopback,
/// with a password of its own (HTTP Basic, user `opencode`). OpenCode keeps
/// the password out of the environment its tools get.
final class OpenCodeServer {
  OpenCodeServer({required this.base, required String password, required this.client, this.process})
    : authHeader = 'Basic ${base64.encode(utf8.encode('opencode:$password'))}' {
    unawaited(process?.exitCode.then((_) => _exited = true));
  }

  final Uri base;
  final String authHeader;
  final http.Client client;

  /// The server's process; null for one the app didn't start (tests).
  final DriverProcess? process;
  var _exited = false;

  /// Whether the process has ended.
  bool get exited => _exited;

  /// Calls the API: the decoded JSON reply, null for an empty one. A reply
  /// of 400 or more throws [OpenCodeHttpError].
  Future<Object?> call(String method, String path, {Object? body, Map<String, String>? query}) async {
    final req = http.Request(method, base.replace(path: path, queryParameters: query));
    req.headers['authorization'] = authHeader;
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await client.send(req));
    if (res.statusCode >= 400) throw OpenCodeHttpError(res.statusCode, _errorText(res.body));
    if (res.body.trim().isEmpty) return null;
    try {
      return jsonDecode(res.body);
    } on FormatException {
      // Unknown paths get the web UI's page with a 200.
      throw OpenCodeHttpError(res.statusCode, "OpenCode answered $path with something that isn't JSON.");
    }
  }

  /// The server's event stream (`GET /api/event`), every session's events.
  Future<http.StreamedResponse> events() async {
    final req = http.Request('GET', base.replace(path: '/api/event'));
    req.headers['authorization'] = authHeader;
    req.headers['accept'] = 'text/event-stream';
    final res = await client.send(req);
    if (res.statusCode != 200 || !(res.headers['content-type'] ?? '').contains('text/event-stream')) {
      unawaited(res.stream.drain<void>().catchError((Object _) {}));
      throw OpenCodeHttpError(res.statusCode, "OpenCode's event stream didn't open.");
    }
    return res;
  }

  /// Checks it is an OpenCode 2 server that takes our password.
  Future<void> verify() async {
    final Object? info;
    try {
      info = await call('GET', '/api/info');
    } on OpenCodeHttpError catch (e) {
      if (e.status == 401) throw const HarnessError('OpenCode refused the password the app gave it.');
      throw const HarnessError('This version of OpenCode is not supported. OpenCode 2 is needed.');
    }
    final version = info is Map ? '${info['version'] ?? ''}' : '';
    if (!version.startsWith('2.')) {
      throw HarnessError(
        'This version of OpenCode${version.isEmpty ? '' : ' ($version)'} is not supported. OpenCode 2 is needed.',
      );
    }
  }

  /// Ends the server and everything it runs (once, however often it's asked).
  Future<void> close() => _closing ??= () async {
    client.close();
    await process?.close();
  }();
  Future<void>? _closing;

  static String _errorText(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final m = j['message'] ?? (j['error'] is Map ? (j['error'] as Map)['message'] : j['error']) ?? j['name'];
        if (m is String && m.isNotEmpty) return m;
      }
    } on FormatException {
      // fall through
    }
    return body.length > 300 ? body.substring(0, 300) : body;
  }
}

/// An API call that OpenCode answered with an error.
final class OpenCodeHttpError implements Exception {
  const OpenCodeHttpError(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => 'OpenCode: $message ($status)';
}

/// Starts a server for a session (see [launchOpenCode]).
typedef OpenCodeLauncher = Future<OpenCodeServer> Function({
  required String executable,
  required String cwd,
  required String sessionTag,
  required String logPath,
  Map<String, String> env,
});

/// The arguments of `opencode serve`: a free port on loopback only.
const openCodeServeArgs = ['serve', '--port', '0', '--hostname', '127.0.0.1'];

/// What every session's server gets in its environment, besides its password.
/// A repository's own OpenCode config (`opencode.json`, `.opencode/`: MCP
/// servers, plugins, agents, skills, `{env:…}` lookups) and its
/// `.claude/skills` are not loaded: they would run before the user approved
/// anything, and MCP servers come only from the app (`StoredMcpServers`). The
/// user's global OpenCode config still loads, and so does our briefing
/// (`OPENCODE_CONFIG_CONTENT` is not project config). In 2.1.3 the same
/// switch also skips the project's AGENTS.md (instruction discovery).
const openCodeServeEnv = {
  'OPENCODE_DISABLE_AUTOUPDATE': '1',
  'OPENCODE_DISABLE_PROJECT_CONFIG': '1',
  'OPENCODE_DISABLE_CLAUDE_CODE_SKILLS': '1',
};

/// What the session's server adds to its environment for [briefing]: our
/// MCP server, skills and session text through the [openCode] recipe
/// (nothing without a skill folder to point at).
Map<String, String> openCodeBriefingEnv(DriverBriefing? briefing) {
  final b = briefing;
  final skillDir = b?.skillDir;
  if (b == null || skillDir == null || skillDir.isEmpty) return const {};
  // The recipe reads only the session file's path, not its text.
  return openCode((mcpUrl: Uri.parse(b.mcpUrl), mcpToken: b.mcpToken, skillDir: skillDir, sessionText: '')).env;
}

/// The URL in OpenCode's `server listening on http://127.0.0.1:<port>`, or null.
String? listeningUrl(String line) => RegExp(r'server listening on\s+(https?://\S+)').firstMatch(line)?.group(1);

/// Spawns `opencode serve` in [cwd] (owned by [sessionTag], so Stop ends it)
/// with a fresh password, waits for the address it prints and checks it.
/// [spawn] and [client] are for tests.
Future<OpenCodeServer> launchOpenCode({
  required String executable,
  required String cwd,
  required String sessionTag,
  required String logPath,
  Map<String, String> env = const {},
  Future<DriverProcess> Function({
    required String executable,
    required List<String> args,
    required String cwd,
    required String sessionTag,
    required String logPath,
    Map<String, String> env,
  })?
  spawn,
  http.Client? client,
}) async {
  final password = _password();
  final process = await (spawn ?? spawnDriver)(
    executable: executable,
    args: openCodeServeArgs,
    cwd: cwd,
    sessionTag: sessionTag,
    logPath: logPath,
    env: {...env, ...openCodeServeEnv, 'OPENCODE_PASSWORD': password},
  );
  OpenCodeServer? server;
  try {
    final url = await process.lines
        .map(listeningUrl)
        .firstWhere((u) => u != null, orElse: () => null)
        .timeout(const Duration(seconds: 20), onTimeout: () => null);
    if (url == null) {
      final why = process.lastError.trim();
      throw HarnessError("OpenCode's server didn't start${why.isEmpty ? '.' : ': $why'}");
    }
    server = OpenCodeServer(
      base: Uri.parse(url),
      password: password,
      client: client ?? http.Client(),
      process: process,
    );
    await server.verify();
    return server;
  } on Object {
    await (server?.close() ?? process.close());
    rethrow;
  }
}

String _password() {
  final r = Random.secure();
  return base64Url.encode([for (var i = 0; i < 32; i++) r.nextInt(256)]).replaceAll('=', '');
}
