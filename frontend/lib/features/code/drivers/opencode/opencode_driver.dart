// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import '../../git/git_service.dart';
import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../driver.dart';
import '../driver_process.dart';
import 'opencode_host.dart';
import 'opencode_server.dart';
import 'opencode_session.dart';

/// OpenCode (`opencode`, version 2) through a local server of its own per
/// session (`opencode serve`, HTTP + server-sent events).
///
/// OpenCode keeps its sessions (they show in the user's own OpenCode too), so
/// reopening one reads its message list back. What [attach] needs besides
/// the id (the folder, the session's tag) is kept in
/// `<data>/driver-sessions/opencode/<id>.json`.
final class OpenCodeDriver implements HarnessDriver {
  OpenCodeDriver({
    this.which,
    OpenCodeLauncher? launch,
    this._run,
    Future<String> Function()? dataDir,
    this.reconnectDelay = const Duration(seconds: 1),
  }) : _launch = launch ?? launchOpenCode,
       _dataDir = dataDir ?? GitService.dataDir;

  /// Replaces the PATH lookup in [detect] (tests).
  final Future<String?> Function(String command)? which;
  final OpenCodeLauncher _launch;

  /// Replaces running `opencode auth list` / `opencode api …` (tests).
  final Future<CliRun> Function(String executable, List<String> args)? _run;
  final Future<String> Function() _dataDir;

  /// How long a session waits before reconnecting its event stream.
  final Duration reconnectDelay;

  final _live = <String, OpenCodeSession>{};

  /// Providers signed in with a login (a subscription), from the last
  /// provider list.
  Set<String>? _oauth;

  @override
  DriverInfo get info => const DriverInfo(id: 'opencode', label: 'OpenCode');

  /// Pictures, forks, rewinding, its own subagents and the user's MCP
  /// servers are not wired up yet.
  @override
  Set<DriverCap> get caps => const {
    DriverCap.steer,
    DriverCap.resume,
    DriverCap.approvals,
    DriverCap.perCallApprovals,
    DriverCap.usage,
    DriverCap.skills,
    DriverCap.switchModel,
    DriverCap.effort,
  };

  /// Signed in: at least one provider has a key or login
  /// (`opencode auth list`, which shows no secrets). No model is called.
  @override
  Future<DriverStatus> detect() async {
    final status = await detectCli('opencode', which: which);
    final path = status.path;
    if (!status.installed || path == null || status.problem != null) return status;
    final signedIn = (await _providers(path))?.isNotEmpty;
    return DriverStatus(
      installed: true,
      path: path,
      version: status.version,
      signedIn: signedIn,
      problem: signedIn == false ? 'Not signed in to any provider. Run "opencode auth login" in a terminal.' : null,
    );
  }

  /// Its enabled models as `provider/model`, with their variants as efforts.
  @override
  Future<List<DriverModel>> models() async {
    final exe = await _executable();
    final list = await _cli(exe, ['api', 'model.list', '--standalone']);
    if (list.exitCode != 0) return const [];
    Object? fallback;
    try {
      final d = await _cli(exe, ['api', 'model.default', '--standalone']);
      if (d.exitCode == 0) fallback = _decode(d.stdout);
    } on Object {
      // No default then.
    }
    return openCodeModels(_decode(list.stdout), fallback);
  }

  @override
  Future<HarnessSession> start(SessionSpec spec) async {
    final exe = await _executable();
    final dir = await _dataDir();
    final server = await _launch(
      executable: exe,
      cwd: spec.workingDir,
      sessionTag: spec.sessionTag,
      logPath: '$dir/driver-sessions/opencode/${spec.sessionTag}.log',
      env: openCodeBriefingEnv(spec.briefing),
    );
    final OpenCodeSession session;
    try {
      session = await _open(server, spec.workingDir, exe);
      final model = openCodeModelRef(spec.model, spec.effort);
      final created = await server.call(
        'POST',
        '/api/session',
        body: {
          'location': {'directory': spec.workingDir},
          'model': ?model,
          'permissions': openCodeSessionRules,
        },
      );
      final data = created is Map ? created['data'] : null;
      final id = data is Map ? '${data['id'] ?? ''}' : '';
      if (id.isEmpty) throw const HarnessError("OpenCode didn't start a session.");
      await session.bind(id);
      await writeTextFile(
        _recordPath(dir, id),
        jsonEncode({
          'workingDir': spec.workingDir,
          'sessionTag': spec.sessionTag,
          'model': spec.model,
          'effort': spec.effort,
        }),
      );
      _live[id] = session;
    } on Object {
      await server.close();
      rethrow;
    }
    if (spec.initialMessage case final text? when text.isNotEmpty) {
      await session.send(text, run: spec.runInitial, images: spec.initialImages);
    }
    return session;
  }

  /// Reopens a session after a restart: a new server in its folder, its
  /// history from OpenCode, then live events. The briefing given at start
  /// isn't handed to the new server (its MCP token ended with the old one).
  @override
  Future<HarnessSession> attach(String conversationId) async {
    if (_live[conversationId] case final s?) return s;
    final dir = await _dataDir();
    final record = _decode(await readTextFile(_recordPath(dir, conversationId)) ?? '');
    final workingDir = record is Map ? record['workingDir'] : null;
    final tag = record is Map ? record['sessionTag'] : null;
    if (workingDir is! String || tag is! String) throw const HarnessError("This OpenCode session can't be found.");
    final exe = await _executable();
    final server = await _launch(
      executable: exe,
      cwd: workingDir,
      sessionTag: tag,
      logPath: '$dir/driver-sessions/opencode/$tag.log',
    );
    try {
      final session = await _open(server, workingDir, exe);
      await session.bind(conversationId, replay: true);
      _live[conversationId] = session;
      return session;
    } on OpenCodeHttpError catch (e) {
      await server.close();
      if (e.status == 404) throw const HarnessError("OpenCode doesn't have this session any more.");
      throw HarnessError(e.message);
    } on Object {
      await server.close();
      rethrow;
    }
  }

  /// Open sessions say where their run is; a recorded one has no server, so
  /// nothing of it runs.
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async {
    final dir = await _dataDir();
    final out = <String, ExecutionStatus>{};
    for (final id in conversationIds) {
      if (_live[id] case final s?) {
        out[id] = s.status;
      } else if (await readTextFile(_recordPath(dir, id)) != null) {
        out[id] = ExecutionStatus.idle;
      }
    }
    return out;
  }

  Future<OpenCodeSession> _open(OpenCodeServer server, String workingDir, String exe) async {
    if (_oauth == null) await _providers(exe);
    late final OpenCodeSession session;
    session = OpenCodeSession(
      server,
      workingDir: workingDir,
      onPlan: (provider) => _oauth?.contains(provider) ?? false,
      reconnectDelay: reconnectDelay,
      onClose: () => _live.removeWhere((_, s) => identical(s, session)),
    );
    await session.connect();
    return session;
  }

  /// The providers with a key or login, or null when the list can't be read.
  Future<List<String>?> _providers(String exe) async {
    try {
      final res = await _cli(exe, ['auth', 'list', '--standalone', '--format', 'json']);
      final list = res.exitCode == 0 ? _decode(res.stdout) : null;
      if (list is! List) return null;
      final signedIn = <String>[];
      final oauth = <String>{};
      for (final p in list.whereType<Map<String, Object?>>()) {
        final connections = (p['connections'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>();
        if (connections.isEmpty) continue;
        signedIn.add('${p['id']}');
        if (connections.any((c) => c['method'] == 'oauth')) oauth.add('${p['id']}');
      }
      _oauth = oauth;
      return signedIn;
    } on Object {
      return null;
    }
  }

  Future<CliRun> _cli(String exe, List<String> args) async {
    if (_run case final run?) return run(exe, args);
    // In the app's own folder, so no project's config changes the answer.
    return runOpenCodeCli(exe, args, cwd: await _dataDir());
  }

  Future<String> _executable() async {
    final status = await detectCli('opencode', which: which);
    final path = status.path;
    if (!status.installed || path == null) throw const HarnessError('OpenCode is not installed.');
    return path;
  }

  static String _recordPath(String dir, String id) =>
      '$dir/driver-sessions/opencode/${id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json';

  static Object? _decode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }
}

/// [DriverModel]s from `GET /api/model` ([list]) and `GET /api/model/default`
/// ([fallback]): the enabled, active ones, ids `provider/model`.
List<DriverModel> openCodeModels(Object? list, Object? fallback) {
  final data = list is Map ? list['data'] : list;
  final d = fallback is Map ? fallback['data'] : null;
  final defaultId = d is Map ? '${d['providerID']}/${d['id']}' : null;
  return [
    if (data is List)
      for (final m in data.whereType<Map<String, Object?>>())
        if (m['enabled'] != false && (m['status'] ?? 'active') == 'active')
          DriverModel(
            id: '${m['providerID']}/${m['id']}',
            label: '${m['name'] ?? m['id']}',
            isDefault: '${m['providerID']}/${m['id']}' == defaultId,
            efforts: [
              for (final v in (m['variants'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>())
                if (v['id'] case final String id) id,
            ],
          ),
  ];
}
