// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import '../../domain/agent_mode.dart';
import '../../git/git_service.dart';
import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../briefing/briefing_types.dart';
import '../briefing/recipes.dart' as recipes;
import '../driver.dart';
import '../driver_process.dart';
import '../event_journal.dart';
import '../json_rpc.dart';
import 'codex_files.dart';
import 'codex_session.dart';

/// Starts `codex app-server` with [args] after it (tests replace it).
typedef CodexSpawn = Future<LineChannel> Function({
  required List<String> args,
  required String cwd,
  required Map<String, String> env,
  required String sessionTag,
});

/// OpenAI's Codex CLI through its app server (`codex app-server`, JSON-RPC
/// on stdio), on the user's ChatGPT plan or API key. One process per
/// session, so the briefing's token, `-c` overrides and skill roots stay
/// its own. Built from the published protocol (github.com/openai/codex
/// `codex-rs/app-server-protocol` at 3a2788e6) without a live Codex to try
/// it on: see the fixtures' notes.
///
/// It keeps `<data>/drivers/codex/`: `threads/<id>.json` (what [attach]
/// needs to start it again), `journal/<id>.jsonl` (the transcript) and
/// `logs/<session>.log` (stderr).
final class CodexDriver implements HarnessDriver, AttachesBriefed {
  CodexDriver({this.which, this.spawn, this.dataDir});

  /// Replaces the PATH lookup in [detect] (tests).
  final Future<String?> Function(String command)? which;

  /// Replaces starting the process (tests).
  final CodexSpawn? spawn;

  /// Replaces the app's data folder (tests).
  final Future<String> Function()? dataDir;

  final _live = <String, CodexSession>{};

  @override
  DriverInfo get info => const DriverInfo(id: 'codex', label: 'Codex');

  /// Not fork or rewind (Codex has thread forks and rollbacks; not wired
  /// yet), not subagents (its own aren't mapped; ours stand in).
  @override
  Set<DriverCap> get caps => const {
    DriverCap.steer,
    DriverCap.resume,
    DriverCap.approvals,
    DriverCap.perCallApprovals,
    DriverCap.usage,
    DriverCap.mcp,
    DriverCap.skills,
    DriverCap.images,
    DriverCap.switchModel,
    DriverCap.effort,
  };

  static const _notInstalled = HarnessError(
    "Codex isn't installed. Install it, sign in with codex login, then try again.",
  );

  /// Installed, and signed in when it has an account or needs none (a
  /// provider of its own in its config), asked without a model call.
  @override
  Future<DriverStatus> detect() async {
    final found = await detectCli('codex', which: which);
    if (!found.installed || found.path == null || found.problem != null) return found;
    try {
      final account = await _probe(found.path!, (_, account) async => account);
      return DriverStatus(
        installed: true,
        path: found.path,
        version: found.version,
        signedIn: account['account'] != null || account['requiresOpenaiAuth'] == false,
      );
    } on Object catch (e) {
      return found.withProblem("Couldn't ask Codex whether it is signed in: $e");
    }
  }

  /// Its own model list (`model/list`), without the hidden ones.
  @override
  Future<List<DriverModel>> models() async {
    final found = await detectCli('codex', which: which);
    if (!found.installed || found.path == null) return const [];
    return _probe(found.path!, (peer, _) async {
      final out = <DriverModel>[];
      String? cursor;
      for (var page = 0; page < 5; page++) {
        final res = await peer.request('model/list', {'cursor': ?cursor}, codexSetupTimeout);
        if (res is! Map<String, Object?>) break;
        for (final m in (res['data'] as List<Object?>? ?? const [])) {
          if (m is! Map<String, Object?> || m['hidden'] == true) continue;
          final id = m['model'] as String? ?? m['id'] as String? ?? '';
          if (id.isEmpty) continue;
          out.add(
            DriverModel(
              id: id,
              label: m['displayName'] as String? ?? id,
              isDefault: m['isDefault'] == true,
              efforts: [
                for (final e in (m['supportedReasoningEfforts'] as List<Object?>? ?? const []))
                  if (e case {'reasoningEffort': final String r}) r,
              ],
            ),
          );
        }
        cursor = res['nextCursor'] as String?;
        if (cursor == null || cursor.isEmpty) break;
      }
      return out;
    });
  }

  @override
  Future<HarnessSession> start(SessionSpec spec) async {
    final found = await detectCli('codex', which: which);
    if (!found.installed || found.path == null) throw _notInstalled;
    final launch = await _launch(spec.briefing);
    final session = CodexSession(
      await _spawn(found.path!, args: launch.args, cwd: spec.workingDir, env: launch.env, tag: spec.sessionTag),
      cwd: spec.workingDir,
      mode: spec.mode,
      model: spec.model,
      effort: spec.effort,
    );
    try {
      await session.open(initRequests: launch.initRequests);
      await session.startThread(instructions: launch.instructions);
    } on Object catch (e) {
      await session.close();
      throw e is HarnessError ? e : HarnessError("Codex didn't start: $e");
    }
    final data = await _data();
    await _saveMeta(data, session, spec.sessionTag);
    session.useJournal(openEventJournal('$data/journal', session.id));
    _track(
      session,
      data: data,
      tag: spec.sessionTag,
      respawn: () =>
          _spawn(found.path!, args: launch.args, cwd: spec.workingDir, env: launch.env, tag: spec.sessionTag),
    );
    if (spec.initialMessage case final text? when text.isNotEmpty) {
      await session.send(text, run: spec.runInitial, images: spec.initialImages);
    }
    return session;
  }

  /// Starts Codex again on the thread and replays our journal. The EveryAI
  /// MCP server isn't there until a briefing is handed over again (its token
  /// is never written down): see [attachBriefed].
  @override
  Future<HarnessSession> attach(String conversationId) => _attach(conversationId, null);

  /// [attach] with a new briefing (the old token was revoked when the session
  /// closed): the reopened process, and any it is started again as, get its
  /// `-c` overrides, token and skill roots. The session text goes only into
  /// thread/start (`developerInstructions`), so it isn't sent again here. A
  /// session still open here is returned as it is.
  @override
  Future<HarnessSession> attachBriefed(
    String conversationId,
    DriverBriefing briefing, {
    Map<String, Object?> mcpConfig = const {},
  }) => _attach(conversationId, briefing);

  Future<HarnessSession> _attach(String conversationId, DriverBriefing? briefing) async {
    if (_live[conversationId] case final s?) return s;
    final data = await _data();
    final saved = await readText(_metaPath(data, conversationId));
    if (saved == null) throw const HarnessError("This Codex session can't be reopened: its details are gone.");
    final meta = jsonDecode(saved) as Map<String, Object?>;
    final found = await detectCli('codex', which: which);
    if (!found.installed || found.path == null) throw _notInstalled;
    final cwd = meta['cwd'] as String? ?? '';
    final tag = meta['sessionTag'] as String? ?? '';
    final launch = await _launch(briefing);
    Future<LineChannel> respawn() => _spawn(found.path!, args: launch.args, cwd: cwd, env: launch.env, tag: tag);
    final session = CodexSession(
      await respawn(),
      cwd: cwd,
      mode: AgentMode.values.asNameMap()[meta['mode']] ?? AgentMode.ask,
      model: meta['model'] as String?,
      effort: meta['effort'] as String?,
    );
    try {
      await session.open(initRequests: launch.initRequests);
      await session.resumeThread(conversationId);
    } on Object catch (e) {
      await session.close();
      throw HarnessError("Codex couldn't reopen the session: $e");
    }
    final journal = openEventJournal('$data/journal', conversationId);
    final history = await journal.read();
    session
      ..useJournal(journal)
      ..replay(history);
    _track(session, data: data, tag: tag, respawn: respawn);
    return session;
  }

  /// Only sessions running in this app: a closed one has no process to ask.
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => {
    for (final id in conversationIds)
      if (_live[id] case final s?) id: s.status,
  };

  void _track(
    CodexSession session, {
    required String data,
    required String tag,
    required Future<LineChannel> Function() respawn,
  }) {
    final id = session.id;
    _live[id] = session;
    session
      ..onClosed = (() => _live.remove(id))
      ..onChanged = (() => _saveMeta(data, session, tag))
      ..respawn = respawn;
  }

  /// What [attach] starts [session] with: its folder, and its mode, model
  /// and effort as they are now.
  static Future<void> _saveMeta(String data, CodexSession session, String tag) => writeText(
    _metaPath(data, session.id),
    jsonEncode({
      'cwd': session.cwd,
      'sessionTag': tag,
      'model': session.model,
      'effort': session.effort,
      'mode': session.mode.name,
    }),
  );

  Future<String> _home() => (dataDir ?? GitService.dataDir)();

  Future<String> _data() async => '${await _home()}/drivers/codex';

  static String _metaPath(String data, String id) =>
      '$data/threads/${id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json';

  Future<LineChannel> _spawn(
    String path, {
    required List<String> args,
    required String cwd,
    required Map<String, String> env,
    required String tag,
  }) async {
    if (spawn case final s?) return s(args: args, cwd: cwd, env: env, sessionTag: tag);
    return spawnDriver(
      executable: path,
      args: ['app-server', ...args],
      cwd: cwd,
      sessionTag: tag,
      logPath: '${await _data()}/logs/$tag.log',
      env: env,
    );
  }

  /// A short-lived app server for [body] (detect, models).
  Future<T> _probe<T>(String path, Future<T> Function(JsonRpcPeer peer, Map<String, Object?> account) body) async {
    final channel = await _spawn(path, args: const [], cwd: await _home(), env: const {}, tag: 'codex-probe');
    final peer = JsonRpcPeer(channel, writeVersion: false);
    try {
      return await body(peer, await codexHandshake(peer));
    } finally {
      await peer.close();
    }
  }

  /// The briefing as Codex takes it (`recipes.codex`), plus two settings
  /// for our server the recipe doesn't set yet: a tool timeout above the
  /// host's 300 s wait for a question card (Codex's default is 60 s), and
  /// our tools pre-approved, so a card isn't preceded by a Codex prompt.
  /// The session text is read from the briefing folder.
  Future<_Launch> _launch(DriverBriefing? b) async {
    if (b == null) return _noBriefing;
    final skillDir = b.skillDir ?? '';
    final text = skillDir.isEmpty ? '' : await readText('${briefingRootOf(skillDir)}/$sessionFileName') ?? '';
    final d = recipes.codex((mcpUrl: Uri.parse(b.mcpUrl), mcpToken: b.mcpToken, skillDir: skillDir, sessionText: text));
    return (
      args: [
        ...d.args,
        '-c',
        'mcp_servers.$everyaiServerName.tool_timeout_sec=330',
        '-c',
        'mcp_servers.$everyaiServerName.default_tools_approval_mode="approve"',
      ],
      env: d.env,
      initRequests: skillDir.isEmpty ? const <RpcCall>[] : d.initRequests,
      instructions: d.instructions,
    );
  }
}

const _Launch _noBriefing = (args: <String>[], env: <String, String>{}, initRequests: <RpcCall>[], instructions: null);

typedef _Launch = ({List<String> args, Map<String, String> env, List<RpcCall> initRequests, String? instructions});
