// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:uuid/uuid.dart';

import '../../domain/agent_mode.dart';
import '../../git/git_service.dart';
import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../driver.dart';
import '../driver_process.dart';
import '../event_journal.dart';
import '../json_rpc.dart';
import 'acp_agents.dart';
import 'acp_files.dart';
import 'acp_mapping.dart' show acpModels;
import 'acp_session.dart';

export 'acp_session.dart' show AcpConnect;

/// An agent that speaks the Agent Client Protocol over stdio
/// (agentclientprotocol.com): Gemini CLI, OpenCode's `acp`, any
/// `acp:<command>`. It runs [command] [args] in the session's worktree; see
/// `acp_agents.dart` for what each known agent gets on top.
///
/// Each conversation keeps `<dataDir>/acp-sessions/<id>/`: `meta.json` (the
/// agent's session id, the folder, the session tag; nothing secret), the
/// event journal and the agent's stderr. Models come from the last session
/// the agent started (no session is started just to ask).
final class AcpDriver implements HarnessDriver, AttachesBriefed {
  AcpDriver({
    required this.id,
    required this.label,
    required this.command,
    this.args = const [],
    this.needsConsent = false,
    this.which,
    Future<String> Function()? dataDir,
    AcpConnect? connect,
    this.signedIn,
    this.initTimeout = const Duration(seconds: 60),
    this.replayQuiet = const Duration(milliseconds: 300),
  }) : _dataDir = dataDir ?? GitService.dataDir,
       _connect = connect ?? _spawn;

  final String id;
  final String label;
  final String command;
  final List<String> args;
  final bool needsConsent;

  /// Replaces the PATH lookup in [detect] and at start (tests).
  final Future<String?> Function(String command)? which;

  /// Replaces the profile's signed-in check in [detect] (tests).
  final Future<bool?> Function()? signedIn;

  /// How long the agent may take to answer `initialize` (Gemini blocks there
  /// when its Google sign-in has gone stale).
  final Duration initTimeout;

  /// How long Gemini's replay of a reopened conversation must stay quiet
  /// before the first prompt goes (it streams on after its load reply).
  final Duration replayQuiet;

  final Future<String> Function() _dataDir;
  final AcpConnect _connect;
  final _live = <String, AcpSession>{};

  /// What runs: the executable, its arguments and its profile.
  late final AcpCommand resolved = acpCommand(command, args);

  static Future<LineChannel> _spawn({
    required String executable,
    required List<String> args,
    required String cwd,
    required String sessionTag,
    required String logPath,
    required Map<String, String> env,
  }) => spawnDriver(executable: executable, args: args, cwd: cwd, sessionTag: sessionTag, logPath: logPath, env: env);

  @override
  DriverInfo get info => DriverInfo(id: id, label: label, needsConsent: needsConsent);

  /// No steering (ACP has none) and no fork or rewind yet.
  @override
  Set<DriverCap> get caps => resolved.profile.caps;

  @override
  Future<DriverStatus> detect() async {
    final s = await detectCli(resolved.executable, which: which);
    if (!s.installed || s.path == null) return s;
    final signed = await (signedIn ?? () => resolved.profile.signedIn(s.path!))();
    final hint = resolved.profile.signIn.isEmpty ? 'Sign in to it in a terminal' : resolved.profile.signIn;
    return DriverStatus(
      installed: true,
      path: s.path,
      version: s.version,
      signedIn: signed,
      problem: s.problem ?? (signed == false ? 'Not signed in. $hint.' : null),
    );
  }

  @override
  Future<List<DriverModel>> models() async {
    final json = await readJsonFile(await _modelsPath());
    return [
      for (final m in (json?['models'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>())
        DriverModel(
          id: '${m['id']}',
          label: '${m['label'] ?? m['id']}',
          isDefault: m['default'] == true,
          efforts: [...?(m['efforts'] as List<Object?>?)?.whereType<String>()],
        ),
    ];
  }

  Future<String> _root() async => '${await _dataDir()}/acp-sessions';

  Future<String> _modelsPath() async =>
      '${await _root()}/models-${id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json';

  Future<void> _offered(Map<String, Object?> reply) async {
    final models = acpModels(reply);
    if (models.isEmpty) return;
    await writeJsonFile(await _modelsPath(), {
      'models': [
        for (final m in models) {'id': m.id, 'label': m.label, 'default': m.isDefault, 'efforts': m.efforts},
      ],
    });
  }

  Future<String> _executable() async {
    final path = await (which ?? whichCommand)(resolved.executable);
    if (path == null) throw HarnessError("$label isn't installed: `${resolved.executable}` wasn't found on your PATH.");
    return path;
  }

  AcpLauncher get _launcher => AcpLauncher(
    info: info,
    caps: caps,
    command: resolved,
    resolve: _executable,
    connect: _connect,
    initTimeout: initTimeout,
    replayQuiet: replayQuiet,
    offered: _offered,
    closed: _live.remove,
  );

  @override
  Future<HarnessSession> start(SessionSpec spec) async {
    final conversationId = const Uuid().v4();
    final session = AcpSession(
      id: conversationId,
      dir: '${await _root()}/$conversationId',
      cwd: spec.workingDir,
      sessionTag: spec.sessionTag,
      launcher: _launcher,
      mode: spec.mode,
      briefing: spec.briefing,
      mcpConfig: spec.mcpConfig,
    );
    try {
      await session.open(model: spec.model, effort: spec.effort);
    } on Object {
      await session.close();
      rethrow;
    }
    _live[conversationId] = session;
    if (spec.initialMessage case final text?) {
      await session.send(text, run: spec.runInitial, images: spec.initialImages);
    }
    return session;
  }

  /// Reopens [conversationId]: its transcript at once, the agent itself only
  /// when the next message is sent.
  @override
  Future<HarnessSession> attach(String conversationId) => _attach(conversationId, null);

  /// [attach] with a new briefing (the old session's MCP token died with the
  /// app), so the reopened agent reaches EveryAI's tools again, and the
  /// user's approved MCP servers ([mcpConfig]; `meta.json` keeps only names).
  @override
  Future<HarnessSession> attachBriefed(
    String conversationId,
    DriverBriefing briefing, {
    Map<String, Object?> mcpConfig = const {},
  }) => _attach(conversationId, briefing, mcpConfig);

  Future<HarnessSession> _attach(
    String conversationId,
    DriverBriefing? briefing, [
    Map<String, Object?> mcpConfig = const {},
  ]) async {
    if (_live[conversationId] case final s?) return s;
    final dir = '${await _root()}/$conversationId';
    final meta = await readJsonFile('$dir/meta.json');
    if (meta == null) throw HarnessError("This $label session can't be reopened: its files are gone.");
    final history = await openEventJournal(dir, 'events').read();
    final session = AcpSession(
      id: conversationId,
      dir: dir,
      cwd: '${meta['cwd']}',
      sessionTag: '${meta['sessionTag']}',
      launcher: _launcher,
      mode: AgentMode.values.where((m) => m.name == meta['mode']).firstOrNull ?? AgentMode.ask,
      briefing: briefing,
      mcpConfig: mcpConfig,
      rememberedMcp: [...?(meta['mcpServers'] as List<Object?>?)?.whereType<String>()],
      acpSessionId: meta['acpSessionId'] as String?,
      history: history,
    )..reopened();
    _live[conversationId] = session;
    return session;
  }

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async {
    final root = await _root();
    return {
      for (final c in conversationIds)
        if (_live[c] case final s?)
          c: s.status
        else if (await readJsonFile('$root/$c/meta.json') != null)
          c: ExecutionStatus.idle,
    };
  }
}
